--[[
@module  sp_commands
@summary SmsPigeon 短信命令处理模块（中文句子命令表 + 执行 + 应答文案）
@version 2.0
@date    2026.09.11
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
  信鸽，恢复出厂
  信鸽，重启

号码与 IMEI 支持中文数字（一三二六二五七五七一八）与分组写法（132-6257-5718）。
鉴权流程见 sp_auth；应答统一通过短信回复给命令发送者。
本模块依赖 sp_platform（硬件访问）与 sp_channels（通道注册表）。
]]

local sp_at       = require "sp_at"
local sp_auth     = require "sp_auth"
local sp_config   = require "sp_config"
local sp_platform = require "sp_platform"
local sp_channels = require "sp_channels"

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
    return "OK:密码已设置,此后命令以密码开头,如 " .. pwd .. "，状态"
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
    cfg.fwd[key].on = false
    sp_config.save()
    return "OK:" .. ch.name .. "转发已关闭"
end

local function cmd_ch_clr(cfg, args, sender)
    local key = channel_of(args[1])
    if not key then return "ERROR:未知通道,支持 短信/钉钉/飞书/Server酱/企业微信" end
    local ch = sp_channels.get(key)
    cfg.fwd[key] = { on = false }
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
    -- 接受 SendKey（字母数字）或完整推送 URL
    if not (url_valid(k) or k:match("^[%w%-]+$")) then
        return "ERROR:SendKey 无效"
    end
    local chcfg = cfg.fwd.serverchan
    chcfg.sendkey = k
    chcfg.on = true
    sp_config.save()
    return "OK:Server酱已配置并开启"
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
    { cmd = "CH_ON",      usage = "信鸽，开启<通道>",            run = cmd_ch_on },
    { cmd = "CH_OFF",     usage = "信鸽，关闭<通道>",            run = cmd_ch_off },
    { cmd = "CH_CLR",     usage = "信鸽，清空<通道>",            run = cmd_ch_clr },
    { cmd = "DING_SET",   usage = "信鸽，设置钉钉，<webhook或token>[，<加签密钥>]", run = make_web_set("dingtalk") },
    { cmd = "FS_SET",     usage = "信鸽，设置飞书，<webhook或hook>[，<签名密钥>]", run = make_web_set("feishu") },
    { cmd = "SC_SET",     usage = "信鸽，设置Server酱，<SendKey>", run = cmd_sc_set },
    { cmd = "WECOM_SET",  usage = "信鸽，设置企业微信，<key或webhook>", run = cmd_wecom_set },
    { cmd = "RESET",      usage = "信鸽，恢复出厂",             run = cmd_reset },
    { cmd = "REBOOT",     usage = "信鸽，重启",                 run = cmd_reboot },
}

local CMD_MAP = {}
for _, e in ipairs(CMDS) do CMD_MAP[e.cmd] = e end

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