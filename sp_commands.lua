--[[
@module  sp_commands
@summary SmsPigeon 短信命令处理模块（中文句子命令表 + 执行 + 应答文案）
@version 2.4
@date    2026.09.12
@usage
命令总览（详见 docs/commands.md，全部以"信鸽"为前缀）：

  信鸽                        链路探测
  信鸽，帮助                  命令列表
  信鸽，初始化，<IMEI>        初始化（未初始化状态唯一可用命令，发送者入白名单）
  信鸽，状态                  状态总览
  信鸽，版本                  固件版本
  信鸽，白名单                查看白名单
  信鸽，开启白名单 / 关闭白名单
  信鸽，增加白名单，<号码> / 删除白名单，<号码>
  信鸽，设置密码，<密码> / 清除密码
  信鸽，设置前缀，<前缀文本> / 清除前缀   转发消息自定义前缀（默认空）
  信鸽，设置标识，<标识文本> / 关闭标识 / 清除标识   设备标识（默认自动取手机号尾4位）
  信鸽，发送短信，<号码>，<内容>         控制本机向指定号码发送一条短信
  信鸽，转发                  查看转发通道
  信鸽，增加转发号码，<号码> / 删除转发号码，<号码>
  信鸽，开启<通道> / 关闭<通道> / 清空<通道>（通道：短信/钉钉/飞书/Server酱/企业微信）
  信鸽，设置钉钉，<webhook或token>[，<加签密钥>]
  信鸽，设置飞书，<webhook或hook>[，<签名密钥>]
  信鸽，设置Server酱，<SendKey或URL>
  信鸽，设置企业微信，<key或webhook>
  信鸽，导出配置               导出全部配置为一条可转发的导入短信（密码不随导出）
  信鸽，导入配置               首行之后每行一条命令，批量导入（合并语义）

号码与 IMEI 支持中文数字（一三二六二五七五七一八）与分组写法（132-6257-5718）。
鉴权流程见 sp_auth；应答统一通过短信回复给命令发送者。
本模块依赖 sp_platform（硬件访问）与 sp_channels（通道注册表）。
]]

local sp_at        = require "sp_at"
local sp_auth      = require "sp_auth"
local sp_config    = require "sp_config"
local sp_platform  = require "sp_platform"
local sp_channels  = require "sp_channels"
local sp_heartbeat = require "sp_heartbeat"

local sp_commands = {}

-- 通道别名（命令参数 → sp_config.fwd 键名）
local CH_ALIAS = {
    ["短信"] = "sms", ["短信转发"] = "sms",
    ["钉钉"] = "dingtalk",
    ["飞书"] = "feishu",
    ["企业微信"] = "wecom", ["wecom"] = "wecom",
    ["Server酱"] = "serverchan",
    ["serverchan"] = "serverchan", ["SC"] = "serverchan",
}

--------------------------------------------------------------------------
-- 校验工具
--------------------------------------------------------------------------

-- 手机号有效性（归一化后 5-11 位数字）
local function num_valid(n)
    return n ~= nil and #n >= 5 and #n <= 11
end

-- URL 有效性（http/https 开头且不含逗号——逗号是参数分隔符）
local function url_valid(u)
    return u ~= nil and u ~= "" and not u:find(",", 1, true)
        and (u:sub(1, 7):lower() == "http://" or u:sub(1, 8):lower() == "https://")
end

-- 通道名解析：无效返回 nil
local function channel_of(name)
    if name == nil then return nil end
    return CH_ALIAS[name] or CH_ALIAS[sp_at.trim(name)]
end

--------------------------------------------------------------------------
-- 各命令实现：统一签名 run(cfg, args, sender) -> reply[, action]
--------------------------------------------------------------------------

local function cmd_ping(cfg, args, sender)
    return "OK:SmsPigeon"
end

local function cmd_init(cfg, args, sender)
    -- 已初始化的固件不可再次初始化
    if cfg.initialized then return "ERROR" end
    -- IMEI 鉴权：数字串必须与本机 IMEI 完全一致（支持中文数字/分组写法）；
    -- 本机 IMEI 不可读（空/过短）时一律拒绝——否则比对退化为 "" == ""，
    -- 任何人发"信鸽，初始化"即可接管设备；失败回笼统 ERROR，不泄露原因
    local imei = sp_at.digits(sp_platform.imei())
    if #imei < 15 or imei ~= sp_at.digits(args[1] or "") then
        return "ERROR"
    end
    local n = sp_auth.normalize_number(sender)
    if not num_valid(n) then return "ERROR" end

    cfg.initialized = true
    cfg.whitelist = { n }
    sp_config.save()
    log.info("sp_commands", "固件初始化完成，白名单：", n)
    -- 初始化完成才可能布防心跳（hb_hours 默认 0 = 关，空操作居多）
    sp_heartbeat.restart()
    return "OK:SmsPigeon 已初始化\n" .. n .. " 已加入白名单\n发送 信鸽，帮助 查看命令"
end

local function cmd_ver(cfg, args, sender)
    return "OK:SmsPigeon " .. tostring(VERSION or "?") .. " (" .. sp_platform.model() .. ")"
end

local function cmd_st(cfg, args, sender)
    local iccid = sp_platform.iccid()
    local lines = {
        "OK:",
        "版本:SmsPigeon " .. tostring(VERSION or "?"),
        "模块:" .. sp_platform.model(),
        "IMEI:" .. sp_platform.imei(),
        "ICCID:" .. (iccid ~= "" and iccid or "未插卡"),
        "信号:" .. tostring(sp_platform.csq()),
        "白名单:" .. (cfg.wl_on and "开" or "关") .. string.format("(%d个)", #cfg.whitelist),
        "密码:" .. (cfg.password ~= "" and "已设置" or "未设置"),
        "前缀:" .. (cfg.prefix ~= "" and cfg.prefix or "无"),
        "标识:" .. (function()
            if cfg.identity == "" then return "关闭" end
            local id = sp_commands.resolve_identity(cfg)
            return id ~= "" and id or "无"
        end)(),
        "来电提醒:" .. (cfg.call_notify and "开" or "关"),
        "心跳:" .. ((cfg.hb_hours or 0) > 0 and (cfg.hb_hours .. "小时") or "关"),
        "过滤:拉黑" .. #(cfg.blocklist or {}) .. "个,过滤词" .. #(cfg.kwords or {}) .. "个",
        "验证码提取:" .. (cfg.code_pick and "开" or "关"),
        "通道:",
    }
    for _, key in ipairs(sp_channels.keys()) do
        local ch = sp_channels.get(key)
        local chcfg = cfg.fwd[key]
        local state
        if ch.is_configured(chcfg) then
            state = chcfg.on and "开" or "关"
        else
            state = "未配置"
        end
        lines[#lines + 1] = " " .. ch.name .. ":" .. state
    end
    return table.concat(lines, "\n")
end

--------------------------------------------------------------------------
-- 白名单
--------------------------------------------------------------------------

local function cmd_wl_read(cfg, args, sender)
    local lines = {}
    for i, n in ipairs(cfg.whitelist) do
        lines[#lines + 1] = i .. "." .. n
    end
    return "OK:白名单(" .. (cfg.wl_on and "开" or "关") .. ")\n"
        .. (#lines > 0 and table.concat(lines, "\n") or "(空)")
end
local function cmd_wl_on(cfg, args, sender)
    -- 空白名单 + 开启 = AND 语义下无人能再控制设备（密码也救不回），
    -- 只能拔卡三次或重烧——拒绝开启，提示先补号码
    if #cfg.whitelist == 0 then
        return "ERROR:白名单为空,请先发送 信鸽，增加白名单，<号码>"
    end
    cfg.wl_on = true
    sp_config.save()
    return "OK:白名单已开启"
end

local function cmd_wl_off(cfg, args, sender)
    cfg.wl_on = false
    sp_config.save()
    if cfg.password == "" then
        return "OK:白名单已关闭\n警告:未设置密码,任何人均可控制本机"
    end
    return "OK:白名单已关闭"
end

local function cmd_wl_add(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1])
    if not num_valid(n) then return "ERROR:号码无效" end
    for _, w in ipairs(cfg.whitelist) do
        if w == n then return "ERROR:号码已在白名单" end
    end
    if #cfg.whitelist >= sp_config.MAX_LIST then
        return "ERROR:白名单已满(上限" .. sp_config.MAX_LIST .. "个)"
    end
    table.insert(cfg.whitelist, n)
    sp_config.save()
    return "OK:" .. n .. " 已加入白名单"
end

local function cmd_wl_del(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1])
    if not num_valid(n) then return "ERROR:号码无效" end
    -- 防锁死：白名单开启时不允许删空（删空后无人能再控制本机）
    if cfg.wl_on and #cfg.whitelist == 1 and cfg.whitelist[1] == n then
        return "ERROR:白名单开启时不可删空,请先发送 信鸽，关闭白名单"
    end
    for i, w in ipairs(cfg.whitelist) do
        if w == n then
            table.remove(cfg.whitelist, i)
            sp_config.save()
            return "OK:" .. n .. " 已移出白名单"
        end
    end
    return "ERROR:号码不在白名单"
end

--------------------------------------------------------------------------
-- 密码
--------------------------------------------------------------------------

local function cmd_pw_set(cfg, args, sender)
    if #args > 1 then
        -- 多参数意味着密码里出现了逗号（参数分隔符）
        return "ERROR:密码不可包含逗号或空格"
    end
    local pwd = args[1] or ""
    if pwd == "" then
        return "ERROR:用法 信鸽，设置密码，<新密码>(4-16字符,不含逗号空格)"
    end
    -- 密码支持中文：按字符数而非字节数限制长度
    local len = (utf8 and utf8.len(pwd)) or #pwd
    if not len or len < 4 or len > 16 then
        return "ERROR:密码长度需为4-16个字符(中文算1个)"
    end
    if pwd:find(" ", 1, true) then
        return "ERROR:密码不可包含逗号或空格"
    end
    if pwd == "信鸽" or pwd == "鸽" or pwd:upper() == "AT" then
        -- 密码即默认前缀等于把前缀公开，禁止
        return "ERROR:密码不可为信鸽或AT"
    end
    if cfg.prefix ~= "" and cfg.prefix:sub(1, #pwd) == pwd then
        -- 已有转发前缀与密码同头：转发内容会构成命令形式
        return "ERROR:密码与已设置的转发前缀同头,请先更换前缀"
    end
    cfg.password = pwd
    sp_config.save()
    -- 应答不回显密码：明文会留存于手机短信历史并随云备份同步
    return "OK:密码已设置,此后命令以密码开头(如 密码，状态)"
end

local function cmd_pw_clr(cfg, args, sender)
    cfg.password = ""
    sp_config.save()
    if not cfg.wl_on then
        return "OK:密码已清除\n警告:白名单已关闭且未设密码,任何人均可控制本机"
    end
    return "OK:密码已清除,命令恢复默认前缀 信鸽"
end

--------------------------------------------------------------------------
-- 远程发短信（控制本机向指定号码发送一条短信）
--------------------------------------------------------------------------

local function cmd_sms_send(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1] or "")
    if not num_valid(n) then
        return "ERROR:号码无效,用法 信鸽，发送短信，<号码>，<内容>"
    end
    -- 内容为其余参数：拆分产生的逗号用中文逗号拼回
    local parts = {}
    for i = 2, #args do parts[#parts + 1] = args[i] end
    local content = table.concat(parts, "，")
    if content == "" then
        return "ERROR:缺少短信内容"
    end
    sp_platform.send_sms(n, content)
    return "OK:已提交发送,收件:" .. n
end

--------------------------------------------------------------------------
-- 设备标识（多设备转发到同一群时区分来源）
-- cfg.identity 三态：nil=自动(手机号尾4位，取不到则不带)，""=关闭，文本=自定义
--------------------------------------------------------------------------

-- 解析出实际携带的标识文本；返回 "" 表示转发时不携带
function sp_commands.resolve_identity(cfg)
    local ident = cfg.identity
    if ident == nil then
        local num = sp_platform.msisdn()
        if num:match("^%d+$") and #num >= 7 then
            return num:sub(-4)
        end
        return ""
    elseif ident == "" then
        return ""
    end
    return ident
end

local function cmd_ident_read(cfg, args, sender)
    if cfg.identity == nil then
        local num = sp_platform.msisdn()
        if num:match("^%d+$") and #num >= 7 then
            return "OK:标识:自动(手机号尾号" .. num:sub(-4) .. ")"
        end
        return "OK:标识:自动(SIM未写号码,当前不携带)"
    elseif cfg.identity == "" then
        return "OK:标识:关闭"
    end
    return "OK:标识:" .. cfg.identity .. "(自定义)"
end

local function cmd_ident_set(cfg, args, sender)
    local ident = table.concat(args, "，")
    if ident == "" then
        return "ERROR:用法 信鸽，设置标识，<标识文本>"
    end
    local len = (utf8 and utf8.len(ident)) or #ident
    if not len or len > 16 then
        return "ERROR:标识过长(上限16个字符)"
    end
    cfg.identity = ident
    sp_config.save()
    return "OK:设备标识已设置:" .. ident
end

local function cmd_ident_off(cfg, args, sender)
    cfg.identity = ""
    sp_config.save()
    return "OK:转发不再携带设备标识"
end

local function cmd_ident_auto(cfg, args, sender)
    cfg.identity = nil
    sp_config.save()
    return "OK:标识已恢复自动(手机号尾4位,取不到则不携带)"
end

--------------------------------------------------------------------------
-- 转发前缀（默认空：转发消息不携带任何固定标识，防运营商特征过滤）
--------------------------------------------------------------------------

local function cmd_prefix_read(cfg, args, sender)
    return "OK:当前转发前缀:" .. (cfg.prefix ~= "" and cfg.prefix or "(无)")
end

local function cmd_prefix_set(cfg, args, sender)
    -- 前缀中的逗号按原样保留：参数拆分后用中文逗号拼回
    local pfx = table.concat(args, "，")
    if pfx == "" then
        return "ERROR:用法 信鸽，设置前缀，<前缀文本>"
    end
    local len = (utf8 and utf8.len(pfx)) or #pfx
    if not len or len > sp_config.MAX_PREFIX then
        return "ERROR:前缀过长(上限" .. sp_config.MAX_PREFIX .. "个字符)"
    end
    if pfx:sub(1, 6) == "信鸽" or pfx:sub(1, 3) == "鸽" then
        -- 前缀若为命令形式，转发出的短信会被误判为命令
        return "ERROR:前缀不可为信鸽等命令形式"
    end
    if cfg.password ~= "" and pfx:sub(1, #cfg.password) == cfg.password then
        -- 密码模式下命令以密码开头，前缀与密码同头会构成命令形式
        return "ERROR:前缀不可与密码同头(防转发内容被解析为命令)"
    end
    cfg.prefix = pfx
    sp_config.save()
    return "OK:转发前缀已设置:" .. pfx
end

local function cmd_prefix_clr(cfg, args, sender)
    cfg.prefix = ""
    sp_config.save()
    return "OK:转发前缀已清除"
end

--------------------------------------------------------------------------
-- 来电提醒（收到来电时向转发目标推送提醒，sp_call 模块监听 CC_IND）
--------------------------------------------------------------------------

local function cmd_calln_read(cfg, args, sender)
    return "OK:来电提醒:" .. (cfg.call_notify and "开" or "关")
        .. "\n收到来电时向已启用的转发目标发送提醒(固件不接听)"
end

local function cmd_calln_on(cfg, args, sender)
    cfg.call_notify = true
    sp_config.save()
    return "OK:来电提醒已开启,来电将发送提醒到转发目标"
end

local function cmd_calln_off(cfg, args, sender)
    cfg.call_notify = false
    sp_config.save()
    return "OK:来电提醒已关闭,来电不再提醒"
end

--------------------------------------------------------------------------
-- 运行统计（sp_forward 计数器；惰性 require 避开与本模块的加载环）
--------------------------------------------------------------------------

local function cmd_stats(cfg, args, sender)
    local st = require "sp_forward".stats()
    return "OK:运行统计(重启后清零):\n"
        .. string.format("累计转发:%d 条\n失败:%d 条(全部通道失败)\n丢弃:%d 条(队列溢出)\n过滤:%d 条(黑名单/过滤词)\n待发:%d 条",
            st.sent, st.fail, st.dropped, st.filtered, st.pending)
end

local function cmd_stats_reset(cfg, args, sender)
    require "sp_forward".reset_stats()
    return "OK:统计已清零"
end

--------------------------------------------------------------------------
-- 心跳报平安（sp_heartbeat 定时向转发目标推送在线摘要）
--------------------------------------------------------------------------

local function cmd_hb_read(cfg, args, sender)
    local h = cfg.hb_hours or 0
    return "OK:心跳:" .. (h > 0 and ("每" .. h .. "小时") or "关")
        .. "\n到期向已启用的转发目标推送在线状态摘要"
end

local function cmd_hb_set(cfg, args, sender)
    -- 间隔是数量：只认阿拉伯数字。中文数字是电话号码"逐位读法"
    -- （sp_at.digits 逐字查表），数量词会静默错值（二十→2、一百→1），
    -- 宁可报错提示也不猜
    local a = args[1] or ""
    if not a:match("^%d+$") then
        return "ERROR:间隔请用阿拉伯数字(1-168)\n用法 信鸽，设置心跳，24"
    end
    local h = tonumber(a)
    if not sp_heartbeat.valid_hours(h) then
        return "ERROR:间隔需 1-168 的整数小时\n用法 信鸽，设置心跳，24"
    end
    cfg.hb_hours = h
    sp_config.save()
    sp_heartbeat.restart()
    return "OK:心跳已设置,每 " .. h .. " 小时报一次平安\n短信通道启用时心跳计话费,纯网络通道免费"
end

local function cmd_hb_off(cfg, args, sender)
    cfg.hb_hours = 0
    sp_config.save()
    sp_heartbeat.restart()
    return "OK:心跳已关闭"
end

--------------------------------------------------------------------------
-- 转发过滤：黑名单（发件人）与过滤词（正文），命中静默丢弃并计数。
-- 只作用于转发路径，不影响命令鉴权（白名单/密码照常独立判定）
--------------------------------------------------------------------------

local function blk_full(cfg)
    return #cfg.blocklist >= sp_config.MAX_LIST
end

local function cmd_blk_add(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1])
    if not n or #n < 5 then
        return "ERROR:号码无效\n用法 信鸽，拉黑，<号码>"
    end
    for _, b in ipairs(cfg.blocklist) do
        if b == n then return "OK:" .. n .. " 已在黑名单" end
    end
    if blk_full(cfg) then
        return "ERROR:黑名单已满(" .. sp_config.MAX_LIST .. "个)"
    end
    cfg.blocklist[#cfg.blocklist + 1] = n
    sp_config.save()
    return "OK:" .. n .. " 已拉黑,其来信不再转发(其命令鉴权不受影响)"
end

local function cmd_blk_del(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1])
    for i, b in ipairs(cfg.blocklist) do
        if b == n then
            table.remove(cfg.blocklist, i)
            sp_config.save()
            return "OK:" .. n .. " 已移出黑名单"
        end
    end
    return "ERROR:号码不在黑名单"
end

local function cmd_blk_read(cfg, args, sender)
    local lines = {}
    for _, b in ipairs(cfg.blocklist) do lines[#lines + 1] = b end
    return "OK:黑名单(" .. #lines .. "/" .. sp_config.MAX_LIST .. "):\n"
        .. (#lines > 0 and table.concat(lines, "\n") or "(空)")
end

-- 过滤词有效性：字符数 1-10（utf8.len 计字符不计字节，中文安全）
local function kw_valid(w)
    local n = utf8 and utf8.len and utf8.len(w)
    return n ~= nil and n >= 1 and n <= sp_config.MAX_KEYWORD
end

local function cmd_kw_add(cfg, args, sender)
    local added, skipped = 0, 0
    for _, a in ipairs(args) do
        local w = sp_at.trim(tostring(a or ""))
        local dup = false
        for _, k in ipairs(cfg.kwords) do
            if k == w then dup = true break end
        end
        if not kw_valid(w) or dup or #cfg.kwords >= sp_config.MAX_LIST then
            skipped = skipped + 1
        else
            cfg.kwords[#cfg.kwords + 1] = w
            added = added + 1
        end
    end
    if added == 0 then
        return "ERROR:无有效新词(1-" .. sp_config.MAX_KEYWORD .. "字,可批量)\n用法 信鸽，添加过滤词，词1，词2"
    end
    sp_config.save()
    return "OK:已添加 " .. added .. " 个过滤词,命中来信不再转发"
        .. (skipped > 0 and ("\n跳过 " .. skipped .. " 个(重复/无效/已满)") or "")
end

local function cmd_kw_del(cfg, args, sender)
    local removed = 0
    for _, a in ipairs(args) do
        local w = sp_at.trim(tostring(a or ""))
        for i, k in ipairs(cfg.kwords) do
            if k == w then
                table.remove(cfg.kwords, i)
                removed = removed + 1
                break
            end
        end
    end
    if removed == 0 then return "ERROR:词不在过滤词列表" end
    sp_config.save()
    return "OK:已删除 " .. removed .. " 个过滤词"
end

local function cmd_kw_read(cfg, args, sender)
    local lines = {}
    for _, k in ipairs(cfg.kwords) do lines[#lines + 1] = k end
    return "OK:过滤词(" .. #lines .. "/" .. sp_config.MAX_LIST .. "):\n"
        .. (#lines > 0 and table.concat(lines, "\n") or "(空)")
end

--------------------------------------------------------------------------
-- 验证码提取（转发文案首行附 [验证码:xxxx]，通知栏预览直接可见）
--------------------------------------------------------------------------

local function cmd_codep_read(cfg, args, sender)
    return "OK:验证码提取:" .. (cfg.code_pick and "开" or "关")
        .. "\n正文含 验证码/校验码 等触发词时,转发首行附 [验证码:xxxx]"
end

local function cmd_codep_on(cfg, args, sender)
    cfg.code_pick = true
    sp_config.save()
    return "OK:验证码提取已开启"
end

local function cmd_codep_off(cfg, args, sender)
    cfg.code_pick = false
    sp_config.save()
    return "OK:验证码提取已关闭,转发不再附验证码行"
end

--------------------------------------------------------------------------
-- 失败暂存重发（sp_forward 暂存队列的手动排空入口）
--------------------------------------------------------------------------

local function cmd_retry(cfg, args, sender)
    local n = require "sp_forward".retry_now()
    if n == 0 then return "OK:无暂存消息" end
    return "OK:已重新入队 " .. n .. " 条暂存消息,随转发队列发出"
end

--------------------------------------------------------------------------
-- 转发通道
--------------------------------------------------------------------------

local function cmd_fwd_read(cfg, args, sender)
    local lines = { "OK:转发通道:" }
    for _, key in ipairs(sp_channels.keys()) do
        local ch = sp_channels.get(key)
        local chcfg = cfg.fwd[key]
        local state
        if ch.is_configured(chcfg) then
            state = chcfg.on and "开" or "关"
        else
            state = "未配置"
        end
        local extra = ""
        if key == "sms" and type(chcfg.targets) == "table" then
            extra = string.format("(%d个目标)", #chcfg.targets)
        end
        lines[#lines + 1] = " " .. ch.name .. ":" .. state .. extra
    end
    lines[#lines + 1] = "配置示例:信鸽，设置钉钉，webhook地址，加签密钥"
    return table.concat(lines, "\n")
end

local function cmd_fwd_sms_add(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1])
    if not num_valid(n) then return "ERROR:号码无效" end
    -- targets 缺失时重建（防御手改/损坏的持久化数据）
    if type(cfg.fwd.sms.targets) ~= "table" then cfg.fwd.sms.targets = {} end
    local t = cfg.fwd.sms.targets
    for _, x in ipairs(t) do
        if x == n then return "ERROR:号码已在转发列表" end
    end
    if #t >= sp_config.MAX_LIST then
        return "ERROR:转发列表已满(上限" .. sp_config.MAX_LIST .. "个)"
    end
    table.insert(t, n)
    sp_config.save()
    return "OK:" .. n .. " 已加入短信转发列表"
end

local function cmd_fwd_sms_del(cfg, args, sender)
    local n = sp_auth.normalize_number(args[1])
    if not num_valid(n) then return "ERROR:号码无效" end
    if type(cfg.fwd.sms.targets) ~= "table" then cfg.fwd.sms.targets = {} end
    for i, x in ipairs(cfg.fwd.sms.targets) do
        if x == n then
            table.remove(cfg.fwd.sms.targets, i)
            sp_config.save()
            return "OK:" .. n .. " 已移出短信转发列表"
        end
    end
    return "ERROR:号码不在转发列表"
end

-- 通用通道开关/清空：开启<通道> / 关闭<通道> / 清空<通道>
local function cmd_ch_on(cfg, args, sender)
    local key = channel_of(args[1])
    if not key then return "ERROR:未知通道,支持 短信/钉钉/飞书/Server酱/企业微信" end
    local ch = sp_channels.get(key)
    if not ch then return "ERROR:未知通道" end   -- 防御：别名有效但通道未注册
    if not ch.is_configured(cfg.fwd[key]) then
        return "ERROR:" .. ch.name .. " 未配置,请先设置"
    end
    cfg.fwd[key].on = true
    sp_config.save()
    return "OK:" .. ch.name .. "转发已开启"
end

local function cmd_ch_off(cfg, args, sender)
    local key = channel_of(args[1])
    if not key then return "ERROR:未知通道,支持 短信/钉钉/飞书/Server酱/企业微信" end
    local ch = sp_channels.get(key)
    if not ch then return "ERROR:未知通道" end   -- 防御：别名有效但通道未注册
    cfg.fwd[key].on = false
    sp_config.save()
    return "OK:" .. ch.name .. "转发已关闭"
end

local function cmd_ch_clr(cfg, args, sender)
    local key = channel_of(args[1])
    if not key then return "ERROR:未知通道,支持 短信/钉钉/飞书/Server酱/企业微信" end
    local ch = sp_channels.get(key)
    if not ch then return "ERROR:未知通道" end   -- 防御：别名有效但通道未注册
    -- 重置为该通道的默认配置形状：整体替换会丢字段（曾因 { on=false }
    -- 丢掉 targets，导致后续 增加转发号码 ipairs(nil) 抛错）
    cfg.fwd[key] = sp_config.defaults().fwd[key]
    sp_config.save()
    return "OK:" .. ch.name .. "配置已清空"
end

-- 钉钉/飞书：设置<通道>，<webhook或token>[，<密钥>]
-- webhook 完整 URL 带 http://、access_token= 等特征，易被运营商内容
-- 过滤拦截；纯 token 形式（钉钉=access_token 的值，飞书=URL 末段
-- hook id）只含字母数字横线，由固件拼出标准 webhook 地址
local WEBHOOK_BASE = {
    dingtalk = "https://oapi.dingtalk.com/robot/send?access_token=",
    feishu   = "https://open.feishu.cn/open-apis/bot/v2/hook/",
}

local function make_web_set(key)
    return function(cfg, args, sender)
        local ch = sp_channels.get(key)
        local url, secret = args[1], args[2] or ""
        if not url or url == "" then
            return "ERROR:缺少 webhook 或 token"
        end
        if url:sub(1, 7):lower() ~= "http://" and url:sub(1, 8):lower() ~= "https://" then
            -- 纯 token 形式：仅字母数字横线，最短 16 位，拼标准地址
            if not url:match("^[%w%-]+$") or #url < 16 then
                return "ERROR:webhook 或 token 无效(token为URL末段,仅含字母数字横线)"
            end
            url = WEBHOOK_BASE[key] .. url
        end
        if url:find(",", 1, true) then
            return "ERROR:地址不可包含逗号"
        end
        if secret:find(" ", 1, true) then return "ERROR:密钥不可含空格" end
        local chcfg = cfg.fwd[key]
        chcfg.url = url
        chcfg.secret = secret
        chcfg.on = true
        sp_config.save()
        return "OK:" .. ch.name .. "已配置并开启" .. (secret ~= "" and "(加签)" or "")
    end
end

-- 企业微信消息推送（原"群机器人"，文档 path/99110）：
-- 设置企业微信，<key或webhook地址>；key 为地址中 key= 参数的值
local function cmd_wecom_set(cfg, args, sender)
    local k = args[1] or ""
    if k == "" then return "ERROR:缺少 key" end
    if k:sub(1, 7):lower() == "http://" or k:sub(1, 8):lower() == "https://" then
        k = k:match("key=([%w%-]+)") or ""
    end
    if not k:match("^[%w%-]+$") or #k < 16 then
        return "ERROR:key 无效(为webhook地址中 key= 后面的部分)"
    end
    local chcfg = cfg.fwd.wecom
    chcfg.key = k
    chcfg.on = true
    sp_config.save()
    return "OK:企业微信已配置并开启"
end

-- Server酱：设置Server酱，<SendKey或完整URL>
local function cmd_sc_set(cfg, args, sender)
    local k = args[1] or ""
    if k == "" then return "ERROR:缺少 SendKey" end
    -- 接受 SendKey（字母数字，真实 SendKey 为 SCT+长串，≥16 与其它
    -- 通道 token 一致——短 key 必为误输，配了也必然推送失败）或完整 URL
    if not (url_valid(k) or (k:match("^[%w%-]+$") and #k >= 16)) then
        return "ERROR:SendKey 无效"
    end
    local chcfg = cfg.fwd.serverchan
    chcfg.sendkey = k
    chcfg.on = true
    sp_config.save()
    return "OK:Server酱已配置并开启"
end

--------------------------------------------------------------------------
-- 内核短信调试日志开关（运行时，不持久化，重启自动复位为关）
--------------------------------------------------------------------------
local function cmd_dbg(cfg, args, sender)
    local a = args[1] or ""
    if a == "开" or a == "开启" then
        sp_platform.set_sms_debug(true)
        return "OK:内核短信调试日志已开启(含PDU与内容,重启后自动关闭)"
    end
    if a == "关" or a == "关闭" then
        sp_platform.set_sms_debug(false)
        return "OK:内核短信调试日志已关闭"
    end
    return "OK:调试日志:" .. (sp_platform.sms_debug_on() and "开" or "关")
        .. "\n用法 信鸽，调试，开 或 信鸽，调试，关"
end

--------------------------------------------------------------------------
-- 复位与重启
--------------------------------------------------------------------------

local function cmd_reset(cfg, args, sender)
    sp_config.factory_reset()
    return "OK:已恢复出厂设置,固件回到未初始化状态"
end

local function cmd_reboot(cfg, args, sender)
    return "OK:3秒后重启", "reboot"
end

--------------------------------------------------------------------------
-- 配置导出/导入：命令回放格式
-- 导出应答 = 一条可直接原样转发的短信：首行 信鸽，导入配置，其后每行
-- 一条命令，尾行 # 注释。导入逐行执行"允许清单"内的命令，合并语义
-- （不清空目标机配置，重复项按跳过计，重发幂等）。
-- 密码不随导出（导出内容驻留管理员收件箱，密码=完全控制权）；
-- ICCID 绑定/无卡计数/防环标记/统计/失败暂存为设备私有状态，同样不导出。
--------------------------------------------------------------------------

-- 允许导入的命令（允许清单，默认拒绝）：与导出可重建的配置面一致，
-- 外加删除/清空类（手工编写的迁移 blob 可做减法）。生命周期与动作类
-- 命令（初始化/恢复出厂/重启/发送短信/重发/导出/导入自身/查询统计）
-- 一律不可导入；未来新增命令默认不可导入，需显式登记。
local IMPORT_OK = {
    WL_ON = true, WL_OFF = true, WL_ADD = true, WL_DEL = true,
    PREFIX_SET = true, PREFIX_CLR = true,
    IDENT_SET = true, IDENT_OFF = true, IDENT_AUTO = true,
    FWD_SMS_ADD = true, FWD_SMS_DEL = true,
    CH_ON = true, CH_OFF = true, CH_CLR = true,
    DING_SET = true, FS_SET = true, SC_SET = true, WECOM_SET = true,
    CALLN_ON = true, CALLN_OFF = true,
    HB_SET = true, HB_OFF = true,
    BLK_ADD = true, BLK_DEL = true,
    KW_ADD = true, KW_DEL = true,
    CODEP_ON = true, CODEP_OFF = true,
}

-- 导入行数上限（最坏配置 ~40 行：白名单/转发/拉黑各 10 + 通道 + 杂项）
local IMPORT_MAX = 50

-- 合并语义下的良性重复（重导幂等）：目标机已有同项
local function benign_dup(reply)
    return reply:find("已在白名单", 1, true) ~= nil
        or reply:find("已在转发列表", 1, true) ~= nil
        or reply:find("已在黑名单", 1, true) ~= nil
end

-- 按字节截断并剥掉不完整的 UTF-8 序列（失败行摘要用：裸 sub 会把
-- 3 字节汉字拦腰切断，应答短信出现乱码尾字节）
local function utf8_cut(s, n)
    if #s <= n then return s end
    local i = n
    while i > 0 and s:byte(i) >= 0x80 and s:byte(i) <= 0xBF do
        i = i - 1                                -- 回退到多字节引导字节处
    end
    if i > 0 then
        local b = s:byte(i)
        local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
        if i + len - 1 > n then i = i - 1 end    -- 字符被截断，整体丢弃
    end
    return s:sub(1, i)
end

-- CMD_MAP 前置声明（导入执行器运行期查表，注册表在文件后段填充）
local CMD_MAP = {}

-- webhook URL → 纯 token（导出用：出站短信避免 URL 特征被运营商过滤，
-- 重新导入时由命令层拼回标准地址）
local function web_token(url, pat)
    if not url or url == "" then return nil end
    return url:match(pat)
end

local function cmd_export(cfg, args, sender)
    local L = {}
    local function add(line) L[#L + 1] = line end
    -- 白名单开关总是显式（安全态必须随克隆走）；其余非默认态才导出，
    -- 默认态交给目标机默认值（前向兼容：默认值改进不影响旧导出）
    add(cfg.wl_on and "开启白名单" or "关闭白名单")
    for _, num in ipairs(cfg.whitelist) do add("增加白名单，" .. num) end
    if cfg.prefix ~= "" then add("设置前缀，" .. cfg.prefix) end
    if cfg.identity == nil then
        -- 自动模式 = 默认，不导出
    elseif cfg.identity == "" then
        add("关闭标识")
    else
        add("设置标识，" .. cfg.identity)
    end
    local sms = cfg.fwd.sms
    for _, num in ipairs(sms.targets or {}) do add("增加转发号码，" .. num) end
    if sms.on and #(sms.targets or {}) > 0 then add("开启短信转发") end
    local dd = cfg.fwd.dingtalk
    if dd.url ~= "" then
        add("设置钉钉，" .. (web_token(dd.url, "access_token=([%w%-]+)") or dd.url)
            .. (dd.secret ~= "" and ("，" .. dd.secret) or ""))
        if not dd.on then add("关闭钉钉") end
    end
    local fs = cfg.fwd.feishu
    if fs.url ~= "" then
        add("设置飞书，" .. (web_token(fs.url, "/hook/([%w%-]+)") or fs.url)
            .. (fs.secret ~= "" and ("，" .. fs.secret) or ""))
        if not fs.on then add("关闭飞书") end
    end
    local sc = cfg.fwd.serverchan
    if sc.sendkey ~= "" then
        local k = sc.sendkey
        if k:sub(1, 4):lower() == "http" then
            k = k:match("/send/([%w%-]+)%.send$") or k   -- URL 形式尽量还原 SendKey
        end
        add("设置Server酱，" .. k)
        if not sc.on then add("关闭Server酱") end
    end
    local wc = cfg.fwd.wecom
    if wc.key ~= "" then
        add("设置企业微信，" .. wc.key)
        if not wc.on then add("关闭企业微信") end
    end
    if cfg.call_notify == false then add("关闭来电提醒") end
    if (cfg.hb_hours or 0) > 0 then add("设置心跳，" .. cfg.hb_hours) end
    for _, num in ipairs(cfg.blocklist) do add("拉黑，" .. num) end
    if #(cfg.kwords or {}) > 0 then add("添加过滤词，" .. table.concat(cfg.kwords, "，")) end
    if cfg.code_pick == false then add("关闭验证码") end
    return "信鸽，导入配置\n" .. table.concat(L, "\n")
        .. "\n#SmsPigeon " .. tostring(VERSION or "?") .. " 共" .. #L
        .. "条,密码不随导出,原样转发即可导入"
end

-- 导入执行（handle 中特判调用，text 为整条短信原文）：
-- 鉴权已在包装短信上完成一次，行内容不再重复鉴权
local function cmd_import(cfg, text, sender)
    local eff = (cfg.password ~= "" and cfg.password or "信鸽")
    local okc, skip, fail, total = 0, 0, 0, 0
    local fails = {}
    local first = true
    for line in text:gmatch("[^\r\n]+") do
        if first then
            first = false                      -- 首行 = 导入包装命令本身
        else
            local ln = sp_at.trim(line)
            if ln ~= "" and ln:sub(1, 1) ~= "#" then
                total = total + 1
                if total > IMPORT_MAX then
                    fail = fail + 1
                    fails[#fails + 1] = "超出" .. IMPORT_MAX .. "行上限"
                    break
                end
                -- 前置有效前缀后复用完整解析器（归一/短语匹配/参数拆分
                -- 全部一致）；行自带 信鸽/密码 前缀时按原行解析（手工粘贴容错）
                local p = sp_at.parse(eff .. "，" .. ln, cfg.password)
                if p == nil or p.cmd == nil then
                    p = sp_at.parse(ln, cfg.password)
                end
                if p == nil or p.cmd == nil then
                    fail = fail + 1
                    fails[#fails + 1] = utf8_cut(ln, 10) .. " 非命令"
                elseif not IMPORT_OK[p.cmd] or not CMD_MAP[p.cmd] then
                    fail = fail + 1
                    fails[#fails + 1] = utf8_cut(ln, 10) .. " 不允许导入"
                else
                    local rok, r = pcall(CMD_MAP[p.cmd].run, cfg, p.args, sender)
                    if not rok then
                        fail = fail + 1
                        fails[#fails + 1] = utf8_cut(ln, 10) .. " 执行出错"
                    elseif type(r) == "string" and r:sub(1, 5) == "ERROR" then
                        if benign_dup(r) then
                            skip = skip + 1
                        else
                            fail = fail + 1
                            fails[#fails + 1] = utf8_cut(ln, 10) .. " " .. r:gsub("^ERROR:?", "")
                        end
                    else
                        okc = okc + 1
                    end
                end
            end
        end
    end
    if total == 0 then
        return "ERROR:导入内容为空,首行 信鸽，导入配置,其后每行一条命令"
    end
    local out = "OK:导入完成 成功" .. okc .. " 跳过" .. skip
    if fail > 0 then
        local shown = {}
        for i = 1, math.min(#fails, 3) do shown[#shown + 1] = fails[i] end
        if #fails > 3 then shown[#shown + 1] = "……(共" .. fail .. "条失败)" end
        out = out .. " 失败" .. fail .. "\n" .. table.concat(shown, "\n")
    end
    return out
end

--------------------------------------------------------------------------
-- 命令注册表
--------------------------------------------------------------------------

local CMDS

local function cmd_help(cfg, args, sender)
    local lines = { "OK:命令列表(前缀:信鸽):" }
    for _, e in ipairs(CMDS) do
        if e.cmd ~= "HELP" then
            lines[#lines + 1] = " " .. e.usage
        end
    end
    lines[#lines + 1] = " 号码支持中文数字与分组写法"
    return table.concat(lines, "\n")
end

CMDS = {
    { cmd = "",           usage = "信鸽",                       run = cmd_ping },
    { cmd = "HELP",       usage = "信鸽，帮助",                 run = cmd_help },
    { cmd = "INIT",       usage = "信鸽，初始化，<IMEI>",       run = cmd_init },
    { cmd = "VER",        usage = "信鸽，版本",                 run = cmd_ver },
    { cmd = "ST",         usage = "信鸽，状态",                 run = cmd_st },
    { cmd = "WL_READ",    usage = "信鸽，白名单",               run = cmd_wl_read },
    { cmd = "WL_ON",      usage = "信鸽，开启白名单",           run = cmd_wl_on },
    { cmd = "WL_OFF",     usage = "信鸽，关闭白名单",           run = cmd_wl_off },
    { cmd = "WL_ADD",     usage = "信鸽，增加白名单，<号码>",   run = cmd_wl_add },
    { cmd = "WL_DEL",     usage = "信鸽，删除白名单，<号码>",   run = cmd_wl_del },
    { cmd = "PW_SET",     usage = "信鸽，设置密码，<密码>",     run = cmd_pw_set },
    { cmd = "PW_CLR",     usage = "信鸽，清除密码",             run = cmd_pw_clr },
    { cmd = "PREFIX_READ", usage = "信鸽，前缀",                 run = cmd_prefix_read },
    { cmd = "PREFIX_SET",  usage = "信鸽，设置前缀，<前缀文本>", run = cmd_prefix_set },
    { cmd = "PREFIX_CLR",  usage = "信鸽，清除前缀",             run = cmd_prefix_clr },
    { cmd = "IDENT_READ", usage = "信鸽，标识",                 run = cmd_ident_read },
    { cmd = "IDENT_SET",  usage = "信鸽，设置标识，<标识文本>", run = cmd_ident_set },
    { cmd = "IDENT_OFF",  usage = "信鸽，关闭标识",             run = cmd_ident_off },
    { cmd = "IDENT_AUTO", usage = "信鸽，清除标识",             run = cmd_ident_auto },
    { cmd = "SMS_SEND",  usage = "信鸽，发送短信，<号码>，<内容>", run = cmd_sms_send },
    { cmd = "FWD_READ",   usage = "信鸽，转发",                 run = cmd_fwd_read },
    { cmd = "FWD_SMS_ADD", usage = "信鸽，增加转发号码，<号码>", run = cmd_fwd_sms_add },
    { cmd = "FWD_SMS_DEL", usage = "信鸽，删除转发号码，<号码>", run = cmd_fwd_sms_del },
    { cmd = "CALLN_READ", usage = "信鸽，来电提醒",             run = cmd_calln_read },
    { cmd = "CALLN_ON",   usage = "信鸽，开启来电提醒",          run = cmd_calln_on },
    { cmd = "CALLN_OFF",  usage = "信鸽，关闭来电提醒",          run = cmd_calln_off },
    { cmd = "ST_STATS",   usage = "信鸽，统计",                  run = cmd_stats },
    { cmd = "ST_RESET",   usage = "信鸽，清零统计",              run = cmd_stats_reset },
    { cmd = "HB_READ",    usage = "信鸽，心跳",                  run = cmd_hb_read },
    { cmd = "HB_SET",     usage = "信鸽，设置心跳，<小时1-168>",  run = cmd_hb_set },
    { cmd = "HB_OFF",     usage = "信鸽，关闭心跳",              run = cmd_hb_off },
    { cmd = "BLK_READ",   usage = "信鸽，拉黑列表",              run = cmd_blk_read },
    { cmd = "BLK_ADD",    usage = "信鸽，拉黑，<号码>",           run = cmd_blk_add },
    { cmd = "BLK_DEL",    usage = "信鸽，取消拉黑，<号码>",       run = cmd_blk_del },
    { cmd = "KW_READ",    usage = "信鸽，过滤词",                run = cmd_kw_read },
    { cmd = "KW_ADD",     usage = "信鸽，添加过滤词，<词>[，<词>...]", run = cmd_kw_add },
    { cmd = "KW_DEL",     usage = "信鸽，删除过滤词，<词>[，<词>...]", run = cmd_kw_del },
    { cmd = "CODEP_READ", usage = "信鸽，验证码",                run = cmd_codep_read },
    { cmd = "CODEP_ON",   usage = "信鸽，开启验证码",             run = cmd_codep_on },
    { cmd = "CODEP_OFF",  usage = "信鸽，关闭验证码",             run = cmd_codep_off },
    { cmd = "RETRY_NOW",  usage = "信鸽，重发",                  run = cmd_retry },
    { cmd = "CH_ON",      usage = "信鸽，开启<通道>",            run = cmd_ch_on },
    { cmd = "CH_OFF",     usage = "信鸽，关闭<通道>",            run = cmd_ch_off },
    { cmd = "CH_CLR",     usage = "信鸽，清空<通道>",            run = cmd_ch_clr },
    { cmd = "DING_SET",   usage = "信鸽，设置钉钉，<webhook或token>[，<加签密钥>]", run = make_web_set("dingtalk") },
    { cmd = "FS_SET",     usage = "信鸽，设置飞书，<webhook或hook>[，<签名密钥>]", run = make_web_set("feishu") },
    { cmd = "SC_SET",     usage = "信鸽，设置Server酱，<SendKey>", run = cmd_sc_set },
    { cmd = "WECOM_SET",  usage = "信鸽，设置企业微信，<key或webhook>", run = cmd_wecom_set },
    { cmd = "EXPORT",     usage = "信鸽，导出配置",               run = cmd_export },
    { cmd = "IMPORT",     usage = "信鸽，导入配置(每行一条命令)",  run = cmd_import },
    { cmd = "RESET",      usage = "信鸽，恢复出厂",             run = cmd_reset },
    { cmd = "DBG",       usage = "信鸽，调试，[开/关]",          run = cmd_dbg },
    { cmd = "REBOOT",     usage = "信鸽，重启",                 run = cmd_reboot },
}

for _, e in ipairs(CMDS) do CMD_MAP[e.cmd] = e end

--[[
疑似配置导入内容（sp_forward 防泄漏闸用）：正文首行含 "，导入配置"
（手机转发预加"转发："前缀、密码模式机收到默认前缀 blob 等命令解析
失败的情形），或正文携带 #SmsPigeon 导出尾注。命中则绝不进入转发
通道（webhook token 与白名单不得外泄），由调用方决定回提示或静默。
]]
function sp_commands.is_import_blob(text)
    if type(text) ~= "string" then return false end
    if text:find("#SmsPigeon", 1, true) then return true end
    local first = text:match("^[^\r\n]*") or ""
    return first:find("，导入配置", 1, true) ~= nil
end

--------------------------------------------------------------------------
-- 命令入口
--------------------------------------------------------------------------

--[[
处理一条收到的短信。
返回值：
  is_cmd  是否被识别为命令（true 时不进入转发流程）
  reply   应答文本（nil 表示静默，不回复）
  action  附加动作（目前仅 "reboot"，由转发层执行）
]]
function sp_commands.handle(sender, text)
    local cfg = sp_config.get()
    local p = sp_at.parse(text, cfg.password)
    if not p then
        return false, nil, nil
    end

    -- 门禁 1：未初始化时只放行 INIT，其余命令静默丢弃
    if not cfg.initialized then
        if p.cmd ~= "INIT" then
            log.warn("sp_commands", "未初始化，丢弃命令", tostring(p.cmd))
            return true, nil, nil
        end
    else
        -- 门禁 2/3：白名单检查（密码门禁已由解析器强制生效）
        local ok = sp_auth.check(cfg, sender)
        if not ok then
            log.warn("sp_commands", "拒绝未授权命令", sender, tostring(p.cmd))
            return true, nil, nil
        end
    end

    -- 导入：整条短信 = 包装命令 + 逐行命令回放。行内容不重复鉴权
    -- （三重门禁已在包装短信上完成），仅执行允许清单内的命令
    if p.cmd == "IMPORT" then
        local iok, reply = pcall(cmd_import, cfg, text, sender)
        if not iok then
            log.error("sp_commands", "导入执行出错", tostring(reply))
            return true, "错误:导入执行出错", nil
        end
        return true, reply, nil
    end

    local entry = CMD_MAP[p.cmd]
    if not entry then
        return true, "错误:未知命令,发送 信鸽，帮助 查看命令列表", nil
    end

    local ok, reply, action = pcall(entry.run, cfg, p.args, sender)
    if not ok then
        log.error("sp_commands", "命令执行出错", tostring(p.cmd), tostring(reply))
        return true, "错误:命令执行出错", nil
    end
    return true, reply, action
end

return sp_commands