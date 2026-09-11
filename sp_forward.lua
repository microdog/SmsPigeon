--[[
@module  sp_forward
@summary SmsPigeon 转发引擎（短信入口：命令分流 + 消息转发）
@version 1.0
@date    2026.09.11
@usage
本模块注册短信接收回调，是所有短信的唯一入口：

1. 交给 sp_commands.handle 识别命令：
   - 是命令 → 按需短信回复应答（异步），执行附加动作（如重启）；
2. 不是命令 → 普通短信：
   - 未初始化：直接丢弃（不转发）；
   - 已初始化：分发到所有已启用且配置完整的转发通道。

防环说明：本机转发出的短信格式固定带【SmsPigeon】前缀；若收到他人转发的
副本，除非发送者恰好在白名单内且内容恰好是合法命令，否则只会再次被转发，
不会形成循环。请勿将本机号码自身加入白名单或转发列表。
]]

local sp_commands = require "sp_commands"
local sp_config   = require "sp_config"
local sp_channels = require "sp_channels"
local sp_platform = require "sp_platform"

local sp_forward = {}

-- 短信收发是否就绪（就绪后缓存，避免重复等待）
local sms_ready = false

-- 等待短信收发就绪：优先等 SMS_READY（新内核固件），超时回退 CC_IND
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
        log.info("sp_forward", "应答短信 ->", num, ok and "已提交" or "发送失败")
    end)
end

-- 短信入口
local function on_sms(num, txt)
    log.info("sp_forward", "收到短信", num, txt)

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
