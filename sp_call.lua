--[[
@module  sp_call
@summary SmsPigeon 来电提醒（收到来电时向转发目标推送提醒消息）
@version 1.0
@date    2026.09.11
@usage
订阅内核通话状态广播 CC_IND，收到来电（INCOMINGCALL）时把来电号码
作为一条"来电提醒"事件推入 sp_forward 转发队列，由转发通道分发到
全部已启用的目标（与短信转发共用队列/限速/洪泛保护）。

要点：
1. 固件不接听、不挂断、不录音——只做事件监听，不触碰通话状态机，
   也无需 cc.init/音频初始化（官方 demo 证实纯监听可直接订阅）；
2. 一通来电从响铃到结束会多次触发 INCOMINGCALL（每轮响铃一次），
   用会话标志去重：INCOMINGCALL 置位、结束事件（DISCONNECTED/
   READY/HANGUP_CALL_DONE）复位，一通电话只提醒一次；另设 120s
   兜底定时器，结束事件丢失时超时复位，避免卡死不再提醒；
3. 来电号码取 cc.lastNum()（官方 demo 模式），取不到显示"未知号码"；
4. 未初始化或 信鸽，关闭来电提醒 时不发送，但会话去重照常运转；
5. 多数物联网卡未开通语音，收不到任何来电——本功能不触发，无害。
   想避免漏接电话，配合手机侧呼叫转移使用（见 README FAQ）。
]]

local sp_config  = require "sp_config"
local sp_forward = require "sp_forward"
local sp_auth    = require "sp_auth"
local sp_led     = require "sp_led"

local sys = sys
local cc  = cc
local log = log

local sp_call = {}

-- 一通来电进行中（去重标志，见模块头说明）
local in_call = false

-- 兜底复位定时器周期：结束事件丢失时防卡死（一通电话远不会响 2 分钟）
local IDLE_RESET_MS = 120000

-- 会话结束：复位去重标志并停掉兜底定时器
local function call_end()
    in_call = false
    if sys and sys.timerStop then sys.timerStop(call_end) end
end

local function on_cc_ind(status)
    if status == "INCOMINGCALL" then
        if in_call then return end   -- 同一通电话的后续响铃，已提醒过
        in_call = true
        -- 来电号码：归一化展示（+86 前缀等），取不到用"未知号码"
        -- 归一化失败返回 nil（非空串）：先归一，失败回退原文/未知号码
        local raw = (cc and cc.lastNum and cc.lastNum()) or ""
        local num = sp_auth.normalize_number(raw)
        if not num then num = (raw ~= "" and raw) or "未知号码" end
        log.info("sp_call", "来电", num)
        sp_led.blink()   -- 状态灯闪烁提示（与短信到达同款）
        local cfg = sp_config.get()
        if cfg.initialized and cfg.call_notify then
            sp_forward.notify_call(num)
        end
        if sys and sys.timerStart then
            sys.timerStart(call_end, IDLE_RESET_MS)
        end
    elseif status == "DISCONNECTED" or status == "READY"
        or status == "HANGUP_CALL_DONE" then
        call_end()
    end
end

-- 开机即订阅（CC_IND 属状态广播，晚订阅会错过；sys 不存在的纯 Lua
-- 测试环境自动跳过，测试用 MOCKS.publish("CC_IND", ...) 驱动）
if sys and sys.subscribe then
    sys.subscribe("CC_IND", on_cc_ind)
else
    log.warn("sp_call", "sys.subscribe 不可用,来电提醒未注册")
end

return sp_call