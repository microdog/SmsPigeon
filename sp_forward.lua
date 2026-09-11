--[[
@module  sp_forward
@summary SmsPigeon 转发引擎（短信入口：命令分流 + 消息转发）
@version 1.1
@date    2026.09.11
@usage
本模块注册短信接收回调，是所有短信的唯一入口：

1. 交给 sp_commands.handle 识别命令：
   - 是命令 → 按需短信回复应答（异步），执行附加动作（如重启）；
2. 不是命令 → 普通短信：
   - 未初始化：直接丢弃（不转发）；
   - 已初始化：分发到所有已启用且配置完整的转发通道。

短信收发就绪说明：
- SMS_READY/CC_IND 是开机时一次性广播的事件，晚订阅会永远错过
  （真机日志验证：开机 11 秒广播、380 秒后才等 → 每条应答白等 30 秒）；
  因此模块加载（开机即执行）时就订阅置位，应答前检查立即短路；
- 两事件都未广播的旧固件上，就绪检查超时后仍尝试发送（已验证可成功）。

防环说明：本机转发出的短信格式固定带【SmsPigeon】前缀；若收到他人转发的
副本，除非发送者恰好在白名单内且内容恰好是合法命令，否则只会再次被转发，
不会形成循环。请勿将本机号码自身加入白名单或转发列表。
]]

local sp_commands = require "sp_commands"
local sp_config   = require "sp_config"
local sp_channels = require "sp_channels"
local sp_platform = require "sp_platform"
local sp_led      = require "sp_led"

local sp_forward = {}

-- 开启内核短信调试日志（官方 sms.debug 开关）：
-- 打印收发短信的 PDU 级细节，排查"短信是否到达模组"类问题必需
if sms and sms.debug then
    sms.debug(true)
end

-- 短信收发是否就绪（就绪后缓存，避免重复等待）
local sms_ready = false

-- 开机即订阅：捕获一次性的 SMS_READY/CC_IND 广播
sys.subscribe("SMS_READY", function() sms_ready = true end)
sys.subscribe("CC_IND", function() sms_ready = true end)

-- 等待短信收发就绪：优先 SMS_READY（新内核固件），回退 CC_IND；
-- 就绪标志已被开机订阅置位时立即返回；都未广播时超时后仍尝试发送
local function ensure_sms_ready()
    if sms_ready then return true end
    if sys.waitUntil("SMS_READY", 10000) then
        sms_ready = true
    elseif sys.waitUntil("CC_IND", 20000) then
        sms_ready = true
    else
        log.warn("sp_forward", "等待短信就绪超时，仍尝试发送")
    end
    return sms_ready
end

-- 异步发送短信（独立 task，不阻塞短信接收回调）
local function send_sms_async(num, text)
    sys.taskInit(function()
        ensure_sms_ready()
        local ok = sms.send(num, text)
        if ok then
            -- SMS_SENT 事件携带完整提交结果：result, rp_cause, rp_cause_str,
            -- msg_ref, error_code（error_code：0成功 331无网络/SIM未开通短信
            -- 332网络超时 500未知 等，详见 docs.openluat.com/osapi/core/sms）
            local got, result, _, rp_cause_str, _, error_code =
                sys.waitUntil("SMS_SENT", 10000)
            if got and result then
                log.info("sp_forward", "应答短信 ->", num, "发送成功")
            elseif got then
                log.warn("sp_forward", "应答短信 ->", num, "发送失败",
                    "error_code=" .. tostring(error_code),
                    tostring(rp_cause_str))
            else
                log.warn("sp_forward", "应答短信 ->", num, "结果超时")
            end
        else
            log.warn("sp_forward", "应答短信提交失败 ->", num)
        end
    end)
end

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
            send_sms_async(num, reply)
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