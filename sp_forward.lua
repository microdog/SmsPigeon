--[[
@module  sp_forward
@summary SmsPigeon 转发引擎（短信入口：命令分流 + 消息转发）
@version 1.2
@date    2026.09.11
@usage
本模块注册短信接收回调，是所有收到短信的唯一入口：

1. 交给 sp_commands.handle 识别命令：
   - 是命令 → 按需短信回复应答（异步，经 sp_platform.send_sms），执行
     附加动作（如重启）；
2. 不是命令 → 普通短信：
   - 未初始化：直接丢弃（不转发）；
   - 已初始化：分发到所有已启用且配置完整的转发通道。

防环说明：转发消息不内置任何固定标识（前缀可由用户自定义，默认空）。
安全性来自命令语法本身——转发出去的内容不会以"信鸽+分隔符"开头，不会被
再次解析为命令，因此不形成循环。请勿将本机号码加入白名单或转发列表，
也勿把转发前缀设为"信鸽，"等命令形式。

短信收发就绪说明：SMS_READY/CC_IND 就绪广播的捕获与发送路径
（就绪等待/提交/SMS_SENT 结果日志）统一封装在 sp_platform，
本模块只保留接收回调注册。
]]

local sp_commands = require "sp_commands"
local sp_config   = require "sp_config"
local sp_channels = require "sp_channels"
local sp_platform = require "sp_platform"
local sp_led      = require "sp_led"

local sms = sms
local sys = sys
local log = log

local sp_forward = {}

-- 短信入口（V2050+ 回调第三参数 metas 携带短信中心时间戳）
local function on_sms(num, txt, metas)
    -- 无条件打印每条收到的短信（内容+号码），先于任何鉴权/分流
    log.info("sp_forward", "收到短信", num, txt)
    if type(metas) == "table" then
        -- SCTS：短信中心下发时间。若与你发送时刻相差很大，
        -- 说明短信在运营商侧滞留/延迟投递，不是固件问题。
        -- 3GPP 时间戳年份为两位数（如 26 = 2026），补 2000 偏移
        local y = tonumber(metas.year) or 0
        if y < 100 then y = y + 2000 end
        local tz = tonumber(metas.tz)
        local tzstr = ""
        if tz then
            tzstr = string.format(" (UTC%s%02d:%02d)",
                tz >= 0 and "+" or "-",
                math.abs(tz) // 60, math.abs(tz) % 60)
        end
        log.info("sp_forward", "短信中心时间戳",
            string.format("%04d-%02d-%02d %02d:%02d:%02d%s",
                y, metas.mon or 0, metas.day or 0,
                metas.hour or 0, metas.min or 0, metas.sec or 0, tzstr))
    end
    sp_led.blink()   -- 状态灯三连闪提示短信到达
    -- 1. 命令分流
    local is_cmd, reply, action = sp_commands.handle(num, txt)
    if is_cmd then
        if reply then
            sp_platform.send_sms(num, reply)
        end
        if action == "reboot" then
            -- 留出应答短信的发送时间
            sys.timerStart(sp_platform.reboot, 3000)
        end
        return
    end

    -- 2. 普通短信转发
    local cfg = sp_config.get()
    if not cfg.initialized then
        log.info("sp_forward", "固件未初始化，短信不转发")
        return
    end
    sys.taskInit(function()
        sp_channels.dispatch({
            sender = num,
            text = txt,
            time = os.date("%Y-%m-%d %H:%M:%S"),
            prefix = cfg.prefix or "",   -- 用户自定义转发前缀，默认空
            identity = sp_commands.resolve_identity(cfg), -- 设备标识（自动/自定义/关闭）
        }, cfg.fwd)
    end)
end

-- 注册短信回调：优先 setNewSmsCb，不支持时退回系统消息
if sms and sms.setNewSmsCb then
    sms.setNewSmsCb(on_sms)
else
    log.warn("sp_forward", "sms.setNewSmsCb 不可用，改用 SMS_INC 消息监听")
    sys.subscribe("SMS_INC", on_sms)
end

return sp_forward