--[[
@module  sp_commands
@summary SmsPigeon 短信命令处理模块（命令表 + 执行 + 应答文案）
@version 1.0
@date    2026.09.11
@usage
命令总览（详见 docs/commands.md）：

  鸽                        链路探测
  鸽+HELP?                  命令列表
  鸽+INIT=<IMEI>            初始化（未初始化状态唯一可用命令，发送者入白名单）
  鸽+VER?                   固件版本
  鸽+ST?                    状态总览
  鸽+WL?                    查看白名单
  鸽+WL=ON/OFF              白名单开关
  鸽+WL=ADD/DEL,号码        白名单增删
  鸽+PW=<新密码> / 鸽+PW=    设置/清除密码
  鸽+FWD?                   查看转发通道
  鸽+FWD=SMS,ADD/DEL,号码   短信转发目标
  鸽+FWD=DING,SET,webhook[,secret]
  鸽+FWD=FS,SET,webhook[,secret]
  鸽+FWD=SC,SET,sendkey
  鸽+FWD=<通道>,ON/OFF/CLR  通道开关/清空配置
  鸽+RESET                  恢复出厂（回到未初始化）
  鸽+REBOOT                 重启模组

鉴权流程见 sp_auth；应答统一通过短信回复给命令发送者。
本模块依赖 sp_platform（硬件访问）与 sp_channels（通道注册表）。
]]

local sp_at       = require "sp_at"
local sp_auth     = require "sp_auth"
local sp_config   = require "sp_config"
local sp_platform = require "sp_platform"
local sp_channels = require "sp_channels"

local sp_commands = {}

-- FWD 命令的通道别名（命令参数 → sp_config.fwd 键名）
local CH_ALIAS = {
    SMS = "sms",
    DING = "dingtalk", DINGTALK = "dingtalk",
    FS = "feishu",     FEISHU = "feishu",
    SC = "serverchan", SERVERCHAN = "serverchan", FTQQ = "serverchan",
}

-- 用法说明文本（HELP/用法应答复用）
local USAGE_WL  = "鸽+WL?|鸽+WL=ON/OFF|鸽+WL=ADD,号码|鸽+WL=DEL,号码"
local USAGE_FWD = "鸽+FWD?|鸽+FWD=SMS,ADD/DEL,号码|鸽+FWD=DING/FS,SET,webhook[,secret]|鸽+FWD=SC,SET,sendkey|鸽+FWD=通道,ON/OFF/CLR"

--------------------------------------------------------------------------
-- 校验工具
--------------------------------------------------------------------------

-- 手机号有效性（归一化后 5-11 位数字）
local function num_valid(n)
    return n ~= nil and #n >= 5 and #n <= 11
end

-- URL 有效性（http/https 开头且不含逗号——逗号是参数分隔符）
local function url_valid(u)
    return u ~= nil and not u:find(",", 1, true)
        and (u:sub(1, 7):lower() == "http://" or u:sub(1, 8):lower() == "https://")
end

--------------------------------------------------------------------------
-- 各命令实现：统一签名 run(cfg, p, sender) -> reply[, action]
--------------------------------------------------------------------------

local function cmd_ping(cfg, p, sender)
    return "OK:SmsPigeon"
end

local function cmd_init(cfg, p, sender)
    -- 已初始化的固件不可再次初始化
    if cfg.initialized then return "ERROR" end
    if p.op ~= "write" or (p.args[1] or "") == "" then return "ERROR" end
    -- IMEI 鉴权：必须与本机 IMEI 完全一致；失败回笼统 ERROR，不泄露原因
    if sp_at.trim(p.args[1]) ~= sp_platform.imei() then return "ERROR" end
    local n = sp_auth.normalize_number(sender)
    if not num_valid(n) then return "ERROR" end

    cfg.initialized = true
    cfg.whitelist = { n }
    sp_config.save()
    log.info("sp_commands", "固件初始化完成，白名单：", n)
    return "OK:SmsPigeon 已初始化\n" .. n .. " 已加入白名单\n发送 鸽+ST? 查看状态"
end

local function cmd_ver(cfg, p, sender)
    return "OK:SmsPigeon " .. tostring(VERSION or "?") .. " (" .. sp_platform.model() .. ")"
end

local function cmd_st(cfg, p, sender)
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

local function cmd_wl(cfg, p, sender)
    if p.op == "read" then
        local lines = {}
        for i, n in ipairs(cfg.whitelist) do
            lines[#lines + 1] = i .. "." .. n
        end
        return "OK:白名单(" .. (cfg.wl_on and "开" or "关") .. ")\n"
            .. (#lines > 0 and table.concat(lines, "\n") or "(空)")
    end
    if p.op ~= "write" then return "用法:" .. USAGE_WL end

    local sub = (p.args[1] or ""):upper()
    if sub == "ON" then
        cfg.wl_on = true
        sp_config.save()
        return "OK:白名单已开启"
    elseif sub == "OFF" then
        cfg.wl_on = false
        sp_config.save()
        if cfg.password == "" then
            return "OK:白名单已关闭\n警告:未设置密码,任何人均可控制本机"
        end
        return "OK:白名单已关闭"
    elseif sub == "ADD" then
        local n = sp_auth.normalize_number(p.args[2])
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
    elseif sub == "DEL" then
        local n = sp_auth.normalize_number(p.args[2])
        if not num_valid(n) then return "ERROR:号码无效" end
        -- 防锁死：白名单开启时不允许删空（删空后无人能再控制本机）
        if cfg.wl_on and #cfg.whitelist == 1 and cfg.whitelist[1] == n then
            return "ERROR:白名单开启时不可删空,请先发送 鸽+WL=OFF"
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
    return "ERROR:子命令无效,支持 ON/OFF/ADD/DEL"
end

local function cmd_pw(cfg, p, sender)
    if p.op ~= "write" or #p.args ~= 1 then
        return "ERROR:用法 鸽+PW=<新密码>(4-16位,不含逗号空格) 或 鸽+PW= 清除密码"
    end
    local pwd = p.args[1]
    if pwd == "" then
        cfg.password = ""
        sp_config.save()
        if not cfg.wl_on then
            return "OK:密码已清除\n警告:白名单已关闭且未设密码,任何人均可控制本机"
        end
        return "OK:密码已清除,命令恢复默认前缀 鸽+"
    end
    if #pwd < 4 or #pwd > 16 then return "ERROR:密码长度需为4-16位" end
    if pwd:find(",", 1, true) or pwd:find(" ", 1, true) then
        return "ERROR:密码不可包含逗号或空格"
    end
    if pwd:upper() == "AT" or pwd == "鸽" then
        -- 密码即默认前缀等于把前缀公开，禁止
        return "ERROR:密码不可为AT或鸽"
    end
    cfg.password = pwd
    sp_config.save()
    return "OK:密码已设置,此后命令以 " .. pwd .. "+ 开头(如 " .. pwd .. "+ST?)"
end

-- 单个通道的通用子命令处理（SET 由各通道分支自行实现）
local function cmd_fwd(cfg, p, sender)
    if p.op == "read" then
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
        lines[#lines + 1] = "配置示例:FWD=DING,SET,webhook地址[,加签密钥]"
        return table.concat(lines, "\n")
    end
    if p.op ~= "write" then return "用法:" .. USAGE_FWD end

    local key = CH_ALIAS[(p.args[1] or ""):upper()]
    local sub = (p.args[2] or ""):upper()
    if not key then
        return "ERROR:未知通道,支持 SMS/DING/FS/SC"
    end
    local ch = sp_channels.get(key)
    local chcfg = cfg.fwd[key]

    if sub == "ON" then
        if not ch.is_configured(chcfg) then
            return "ERROR:" .. ch.name .. " 未配置,请先 SET"
        end
        chcfg.on = true
        sp_config.save()
        return "OK:" .. ch.name .. "转发已开启"
    elseif sub == "OFF" then
        chcfg.on = false
        sp_config.save()
        return "OK:" .. ch.name .. "转发已关闭"
    elseif sub == "CLR" then
        cfg.fwd[key] = { on = false }
        sp_config.save()
        return "OK:" .. ch.name .. "配置已清空"
    end

    if key == "sms" then
        if sub == "ADD" or sub == "DEL" then
            local n = sp_auth.normalize_number(p.args[3])
            if not num_valid(n) then return "ERROR:号码无效" end
            chcfg.targets = type(chcfg.targets) == "table" and chcfg.targets or {}
            if sub == "ADD" then
                for _, t in ipairs(chcfg.targets) do
                    if t == n then return "ERROR:号码已在转发列表" end
                end
                if #chcfg.targets >= sp_config.MAX_LIST then
                    return "ERROR:转发列表已满(上限" .. sp_config.MAX_LIST .. "个)"
                end
                table.insert(chcfg.targets, n)
                sp_config.save()
                return "OK:" .. n .. " 已加入短信转发列表"
            else
                for i, t in ipairs(chcfg.targets) do
                    if t == n then
                        table.remove(chcfg.targets, i)
                        sp_config.save()
                        return "OK:" .. n .. " 已移出短信转发列表"
                    end
                end
                return "ERROR:号码不在转发列表"
            end
        end
        return "ERROR:子命令无效,支持 ADD/DEL/ON/OFF/CLR"

    elseif key == "serverchan" then
        if sub == "SET" then
            local k = p.args[3] or ""
            if k == "" then return "ERROR:缺少 SendKey" end
            -- 接受 SendKey（字母数字）或完整推送 URL
            if not (url_valid(k) or k:match("^[%w%-]+$")) then
                return "ERROR:SendKey 无效"
            end
            chcfg.sendkey = k
            chcfg.on = true
            sp_config.save()
            return "OK:Server酱已配置并开启"
        end
        return "ERROR:子命令无效,支持 SET/ON/OFF/CLR"

    else
        -- dingtalk / feishu：FWD=<CH>,SET,webhook[,secret]
        if sub == "SET" then
            local url = p.args[3] or ""
            local secret = p.args[4] or ""
            if not url_valid(url) then
                return "ERROR:Webhook 地址无效(需 http(s):// 开头,不含逗号)"
            end
            if secret:find(" ", 1, true) then return "ERROR:密钥不可含空格" end
            chcfg.url = url
            chcfg.secret = secret
            chcfg.on = true
            sp_config.save()
            return "OK:" .. ch.name .. "已配置并开启" .. (secret ~= "" and "(加签)" or "")
        end
        return "ERROR:子命令无效,支持 SET/ON/OFF/CLR"
    end
end

local function cmd_reset(cfg, p, sender)
    if p.op ~= "exec" then return "用法:鸽+RESET(将清空全部配置并回到未初始化)" end
    sp_config.factory_reset()
    return "OK:已恢复出厂设置,固件回到未初始化状态"
end

local function cmd_reboot(cfg, p, sender)
    if p.op ~= "exec" then return "用法:鸽+REBOOT" end
    return "OK:3秒后重启", "reboot"
end

--------------------------------------------------------------------------
-- 命令注册表
--------------------------------------------------------------------------

local CMDS = {
    { cmd = "",      usage = "鸽",                    run = cmd_ping },
    { cmd = "INIT",  usage = "鸽+INIT=<本机IMEI>",    run = cmd_init },
    { cmd = "VER",   usage = "鸽+VER?",               run = cmd_ver },
    { cmd = "ST",    usage = "鸽+ST?",                run = cmd_st },
    { cmd = "WL",    usage = USAGE_WL,                run = cmd_wl },
    { cmd = "PW",    usage = "鸽+PW=<新密码>|鸽+PW=", run = cmd_pw },
    { cmd = "FWD",   usage = USAGE_FWD,               run = cmd_fwd },
    { cmd = "RESET", usage = "鸽+RESET",              run = cmd_reset },
    { cmd = "REBOOT",usage = "鸽+REBOOT",             run = cmd_reboot },
}

local CMD_MAP = {}
for _, e in ipairs(CMDS) do CMD_MAP[e.cmd] = e end

local function cmd_help(cfg, p, sender)
    local lines = { "OK:命令列表:" }
    for _, e in ipairs(CMDS) do
        lines[#lines + 1] = " " .. e.usage
    end
    return table.concat(lines, "\n")
end

CMD_MAP["HELP"] = { usage = "鸽+HELP?", run = cmd_help }
table.insert(CMDS, CMD_MAP["HELP"])

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
            log.warn("sp_commands", "未初始化，丢弃命令", p.cmd)
            return true, nil, nil
        end
    else
        -- 门禁 2/3：白名单检查（密码门禁已由解析器强制生效）
        local ok = sp_auth.check(cfg, sender)
        if not ok then
            log.warn("sp_commands", "拒绝未授权命令", sender, p.cmd)
            return true, nil, nil
        end
    end

    local entry = CMD_MAP[p.cmd]
    if not entry then
        return true, "ERROR:未知命令,发送 鸽+HELP? 查看命令列表", nil
    end
    if p.op == "test" then
        return true, "用法:" .. entry.usage, nil
    end

    local ok, reply, action = pcall(entry.run, cfg, p, sender)
    if not ok then
        log.error("sp_commands", "命令执行出错", p.cmd, tostring(reply))
        return true, "ERROR:命令执行出错", nil
    end
    return true, reply, action
end

return sp_commands
