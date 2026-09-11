--[[
sp_call 来电提醒单元测试：CC_IND 事件驱动、同一来电去重、
开关命令、未知号码、未初始化不发送。
]]

local sp_config  = require "sp_config"
local sp_forward = require "sp_forward"
require "sp_chan_sms"                  -- 注册短信转发通道（dispatch 目标）
local sp_call    = require "sp_call"   -- 加载期完成 CC_IND 订阅

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end
local function run_new_tasks(base)
    for i = base + 1, #MOCKS.tasks do MOCKS.tasks[i]() end
    return #MOCKS.tasks
end
local function cc_ind(status) MOCKS.publish("CC_IND", status) end

-- 模块加载期已订阅 CC_IND（sp_platform 也订阅同名消息，互不影响）
assert(#MOCKS.subs["CC_IND"] >= 2, "CC_IND 至少两个订阅者(平台+来电)")
n = n + 1
eq(sp_config.get().call_notify, true, "来电提醒默认开启")

local base = #MOCKS.tasks

-- 未初始化：来电不提醒（不入队、无任务、无发送）
MOCKS.cc_lastnum = "13712345678"
cc_ind("INCOMINGCALL")
eq(#MOCKS.tasks, base, "未初始化:来电不产生转发任务")
eq(#MOCKS.sent, 0, "未初始化:来电不发送提醒")
cc_ind("DISCONNECTED")   -- 结束这通电话，复位会话去重标志

-- 初始化并配置短信转发目标
MOCKS.sms_cb("13800138000", "信鸽，初始化，" .. MOCKS.mobile.imei)
base = run_new_tasks(base)
MOCKS.sms_cb("13800138000", "信鸽，增加转发号码，13911112222")
base = run_new_tasks(base)
MOCKS.sms_cb("13800138000", "信鸽，开启短信转发")
base = run_new_tasks(base)

-- 来电 → 一条提醒短信（含号码与防环标记，走短信通道）
cc_ind("INCOMINGCALL")
cc_ind("INCOMINGCALL")   -- 同一通电话多次响铃
cc_ind("INCOMINGCALL")
base = run_new_tasks(base)
eq(#MOCKS.sent, 4, "同一通来电多次响铃只提醒一次(3条命令应答+1)")
local callmsg = MOCKS.sent[#MOCKS.sent]
eq(callmsg.num, "13911112222", "来电提醒发往转发目标")
assert(callmsg.text:find("来电", 1, true), "提醒文本含来电字样")
n = n + 1
assert(callmsg.text:find("13712345678", 1, true), "提醒文本含来电号码")
n = n + 1
local mark = sp_config.get().mark
assert(mark ~= "" and callmsg.text:find(mark, 1, true), "提醒短信带防环标记")
n = n + 1

-- 挂断后再来电：再次提醒
cc_ind("DISCONNECTED")
cc_ind("INCOMINGCALL")
base = run_new_tasks(base)
eq(#MOCKS.sent, 5, "挂断后再来电再次提醒")

-- 未知号码（lastNum 返回 nil）
cc_ind("DISCONNECTED")
MOCKS.cc_lastnum = nil
cc_ind("INCOMINGCALL")
base = run_new_tasks(base)
assert(MOCKS.sent[#MOCKS.sent].text:find("未知号码", 1, true), "取不到号码显示未知号码")
n = n + 1
cc_ind("DISCONNECTED")

-- 状态命令显示来电提醒开关
MOCKS.sms_cb("13800138000", "信鸽，状态")
base = run_new_tasks(base)
assert(MOCKS.sent[#MOCKS.sent].text:find("来电提醒:开", 1, true), "状态总览含来电提醒:开")
n = n + 1

-- 关闭后来电不提醒；来电提醒命令回报开关
MOCKS.sms_cb("13800138000", "信鸽，关闭来电提醒")
base = run_new_tasks(base)
cc_ind("INCOMINGCALL")
base = run_new_tasks(base)
-- 累计 8 = 3(初始化组应答) + 3(提醒) + 状态应答 + 关闭应答；
-- 关闭后的来电不应使其变为 9
eq(#MOCKS.sent, 8, "关闭来电提醒后不再发送提醒")
cc_ind("DISCONNECTED")
MOCKS.sms_cb("13800138000", "信鸽，来电提醒")
base = run_new_tasks(base)
assert(MOCKS.sent[#MOCKS.sent].text:find("来电提醒:关", 1, true), "来电提醒命令回报关")
n = n + 1

-- 重新开启后恢复提醒
MOCKS.sms_cb("13800138000", "信鸽，开启来电提醒")
base = run_new_tasks(base)
MOCKS.cc_lastnum = "13712345678"
cc_ind("INCOMINGCALL")
base = run_new_tasks(base)
-- 累计 11 = 8 + 来电提醒查询应答 + 开启应答 + 恢复的提醒
eq(#MOCKS.sent, 11, "重新开启后来电恢复提醒")

-- 网络通道的来电文案（format_text 纯函数，无 HTTP 桩）
local sp_channels = require "sp_channels"
local ft = sp_channels.format_text({
    kind = "call", sender = "13712345678",
    time = "2026-09-11 12:00:00", prefix = "", identity = "",
})
assert(ft:find("来电提醒", 1, true) and ft:find("13712345678", 1, true),
    "网络通道来电文案含提醒与号码")
n = n + 1
assert(sp_channels.format_text({
    kind = "call", sender = "13712345678", time = "t",
    prefix = "【x】", identity = "abcd",
}):find("【x】来电提醒:号码 13712345678 [设备:abcd]", 1, true),
    "来电文案携带前缀与设备标识")
n = n + 1

-- 开关持久化：重载模块后仍为关闭态（此处为开启态校验往返）
MOCKS.sms_cb("13800138000", "信鸽，关闭来电提醒")
run_new_tasks(base)
local saved = MOCKS.store["sp_calln"]
eq(saved, false, "来电提醒开关已落盘")

print(string.format("PASS sp_call_test (%d assertions)", n))