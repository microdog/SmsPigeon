--[[
@module  sp_config
@summary SmsPigeon 配置持久化模块（基于 fskv 键值存储）
@version 1.1
@date    2026.09.11
@usage
本模块负责所有用户配置的读写、默认值合并与恢复出厂设置。

设计要点：
1. 所有 fskv 键使用统一前缀 sp_，避免与其他应用冲突；
2. 内存中维护唯一配置缓存 cache，外部通过 sp_config.get() 拿到同一张表，
   修改后必须调用 sp_config.save() 才落盘；
3. 读取时与默认值逐字段合并，保证旧版本固件升级后新增字段有默认值；
4. 恢复出厂只删除 sp_ 前缀的键，不影响其他数据；
5. 本模块不接触任何硬件 API（sms/mobile 等），可在纯 Lua 环境下单元测试。
]]

local sp_config = {}

-- fskv 键名定义
local KEY_STATE = "sp_state"   -- "INIT" 表示固件已初始化，其他/不存在表示未初始化
local KEY_WL_ON = "sp_wl_on"   -- 白名单开关
local KEY_WL    = "sp_wl"      -- 白名单号码列表(table)
local KEY_PW    = "sp_pw"      -- 短信命令密码，"" 表示密码模式关闭
local KEY_PFX   = "sp_pfx"     -- 转发消息前缀，"" 表示不带前缀
local KEY_IDENT = "sp_ident"   -- 设备标识：键不存在=自动(手机号尾4位)，""=关闭，文本=自定义
local KEY_FWD   = "sp_fwd"     -- 各转发通道配置(table)
local KEY_ICCID = "sp_iccid"   -- 最近一次绑定的 SIM 卡 ICCID(复位判定用)
local KEY_NOSIM = "sp_nosim" -- 连续无卡开机计数
local KEY_MARK = "sp_mark"  -- 防环实例标记(随机hex,不随恢复出厂清除:无鉴权作用,清除反而留下无标记空窗)

-- 恢复出厂时清除的键（sp_mark 刻意不在其中，见其注释）
local ALL_KEYS = { KEY_STATE, KEY_WL_ON, KEY_WL, KEY_PW, KEY_PFX, KEY_IDENT, KEY_FWD, KEY_ICCID, KEY_NOSIM }

-- 配置缓存（由 init() 填充）
local cache = nil

-- 白名单/转发目标列表的容量上限，防止 fskv 空间被撑爆
sp_config.MAX_LIST = 10

-- 转发前缀的长度上限（字符数，中文算 1 个）
sp_config.MAX_PREFIX = 30

--[[
返回一份全新默认配置：
- 固件默认未初始化；
- 白名单默认开启且为空（初始化命令会把发起号码写入白名单）；
- 密码默认关闭；
- 转发消息默认不带前缀（避免固定标识特征被运营商过滤）；
- 所有转发通道默认关闭且未配置。
]]
function sp_config.defaults()
    return {
        initialized = false,
        wl_on = true,
        whitelist = {},                                   -- { "13800138000", ... }，存储归一化后的号码
        password = "",
        prefix = "",                                      -- 转发消息前缀（含【】等由用户自定）
        -- 设备标识三态：nil=自动(手机号尾4位，取不到则不带)，""=关闭，文本=自定义
        identity = nil,
        fwd = {
            sms        = { on = false, targets = {} },    -- 短信转发目标列表
            dingtalk   = { on = false, url = "", secret = "" },
            feishu     = { on = false, url = "", secret = "" },
            serverchan = { on = false, sendkey = "" },
            wecom      = { on = false, key = "" },        -- 企业微信消息推送（原群机器人）
        },
        mark = "",                                         -- 防环实例标记（内部字段，sp_forward 首启生成）
        iccid = "",                                       -- SIM 卡绑定信息（内部字段）
        nosim_cnt = 0,                                    -- 连续无卡开机计数（内部字段）
    }
end

-- 从 fskv 读取配置并与默认值合并
local function load_cfg()
    local cfg = sp_config.defaults()
    cfg.initialized = fskv.get(KEY_STATE) == "INIT"

    local v = fskv.get(KEY_WL_ON)
    if type(v) == "boolean" then cfg.wl_on = v end

    v = fskv.get(KEY_WL)
    if type(v) == "table" then
        local wl = {}
        for _, n in ipairs(v) do
            if type(n) == "string" and n ~= "" and #wl < sp_config.MAX_LIST then
                wl[#wl + 1] = n
            end
        end
        cfg.whitelist = wl
    end

    v = fskv.get(KEY_PW)
    if type(v) == "string" then cfg.password = v end

    v = fskv.get(KEY_PFX)
    if type(v) == "string" then cfg.prefix = v end

    -- 标识：键不存在(nil)保持自动态；""=关闭；文本=自定义
    v = fskv.get(KEY_IDENT)
    if v == nil then cfg.identity = nil
    elseif type(v) == "string" then cfg.identity = v end

    v = fskv.get(KEY_FWD)
    if type(v) == "table" then
        -- 只按默认配置里已知的通道与字段合并，丢弃未知/损坏数据
        for key, def in pairs(cfg.fwd) do
            local saved = v[key]
            if type(saved) == "table" then
                for field in pairs(def) do
                    if saved[field] ~= nil then def[field] = saved[field] end
                end
            end
        end
    end
    v = fskv.get(KEY_MARK)
    if type(v) == "string" and v ~= "" then cfg.mark = v end

    v = fskv.get(KEY_ICCID)
    if type(v) == "string" then cfg.iccid = v end

    v = fskv.get(KEY_NOSIM)
    if type(v) == "number" then cfg.nosim_cnt = math.floor(v) end

    return cfg
end

-- 初始化：必须在其他模块使用配置前调用（main.lua 加载本模块时自动执行）
function sp_config.init()
    if fskv and fskv.init then fskv.init() end
    cache = load_cfg()
    log.info("sp_config", "配置加载完成", "已初始化:", tostring(cache.initialized))
    return cache
end

-- 获取内存中的配置表（引用），修改后需调用 save()
function sp_config.get()
    return cache
end

-- 将用户配置整体落盘（iccid/nosim_cnt 内部字段不在此处持久化）
function sp_config.save()
    local c = cache
    fskv.set(KEY_STATE, c.initialized and "INIT" or "")
    fskv.set(KEY_WL_ON, c.wl_on)
    fskv.set(KEY_WL, c.whitelist)
    fskv.set(KEY_PW, c.password)
    fskv.set(KEY_PFX, c.prefix)
    if c.identity == nil then
        fskv.del(KEY_IDENT)   -- 自动态：键不存在
    else
        fskv.set(KEY_IDENT, c.identity)
    end
    fskv.set(KEY_FWD, c.fwd)
end

-- 记录当前绑定的 SIM 卡 ICCID
function sp_config.save_iccid(iccid)
    cache.iccid = iccid
    fskv.set(KEY_ICCID, iccid)
end

-- 记录防环实例标记（sp_forward 首启生成后调用）
function sp_config.save_mark(mark)
    cache.mark = mark
    fskv.set(KEY_MARK, mark)
end

-- 记录连续无卡开机计数
function sp_config.save_nosim(cnt)
    cache.nosim_cnt = cnt
    fskv.set(KEY_NOSIM, cnt)
end

-- 恢复出厂设置：删除全部 sp_ 键，回到未初始化状态
function sp_config.factory_reset()
    for _, k in ipairs(ALL_KEYS) do
        fskv.del(k)
    end
    cache = sp_config.defaults()
    log.warn("sp_config", "已恢复出厂设置，固件回到未初始化状态")
    return cache
end

sp_config.init()

return sp_config