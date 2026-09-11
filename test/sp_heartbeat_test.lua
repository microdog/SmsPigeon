--[[
sp_heartbeat 心跳报平安测试：默认关不布防、命令设置/关闭全链路、
中文数字间隔、心跳文案含信号与统计摘要、持久化。
定时器经 mocks 的 MOCKS.timers 记录，直接调用 .fn() 模拟到期。
]]

local sp_config    = require "sp_config"
local sp_heartbeat = require "sp_heartbeat"
require "sp_chan_sms"
require "sp_forward"              -- sms_cb 注册 + 心跳走其队列

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 2)
    end
    n = n + 1
end

-- 常驻任务（状态灯 led_task 是 while true 循环，桩化 sys.wait 下会
-- 死循环）不可直接执行：只驱动装配完成后新增的任务（同 main_smoke
-- 的 run_new_tasks 增量语义）
local task_base = #MOCKS.tasks
local function run_tasks()
    local i = task_base + 1
    while i <= #MOCKS.tasks do
        local t = MOCKS.tasks[i]
        i = i + 1
        t()
    end
    task_base = #MOCKS.tasks
end

-- 心跳定时器（区分其它模块的定时器：周期由间隔推得）
local function hb_timer(hours)
    local ms = hours and hours * 3600 * 1000 or nil
    for _, t in ipairs(MOCKS.timers) do
        if ms == nil or t.ms == ms then return t end
    end
    return nil
end

local ADMIN, TARGET = "13900001111", "13899990000"

eq(#MOCKS.timers, 0, "默认关:开机不布防心跳")

-- 初始化 + 开通短信通道
local cfg = sp_config.get()
cfg.initialized = true
cfg.whitelist = { ADMIN }
cfg.fwd.sms = { on = true, targets = { TARGET } }
sp_config.save()
sp_heartbeat.restart()
eq(hb_timer(), nil, "已初始化但间隔为0:仍不布防")

-- 设置心跳（中文数字二十四）：应答 + 布防 24h 循环定时器
MOCKS.sms_cb(ADMIN, "信鸽，设置心跳，二十四")
run_tasks()
eq(#MOCKS.sent, 1, "设置心跳有应答")
assert(MOCKS.sent[1].text:find("每 24 小时", 1, true), "应答含间隔")
n = n + 1
local t24 = hb_timer(24)
assert(t24 ~= nil, "24小时循环定时器已布防")
n = n + 1
eq(t24.loop, true, "心跳为循环定时器")
eq(sp_config.get().hb_hours, 24, "间隔已持久化到配置")

-- 到期触发：经转发队列推送在线摘要
t24.fn()
run_tasks()
eq(#MOCKS.sent, 2, "心跳经短信通道推送")
local hb = MOCKS.sent[2]
eq(hb.num, TARGET, "心跳发往转发目标")
assert(hb.text:find("在线", 1, true), "心跳文本含在线")
assert(hb.text:find("信号:25", 1, true), "心跳文本含信号强度")
assert(hb.text:find("累计转发:", 1, true), "心跳文本含统计摘要")
assert(hb.text:find("验证码", 1, true) == nil, "心跳文案不附验证码行")
n = n + 4

-- 查询/关闭
MOCKS.sms_cb(ADMIN, "信鸽，心跳")
run_tasks()
assert(MOCKS.sent[3].text:find("每24小时", 1, true), "查询应答含间隔")
n = n + 1
MOCKS.sms_cb(ADMIN, "信鸽，关闭心跳")
run_tasks()
eq(hb_timer(24), nil, "关闭后撤防")
eq(sp_config.get().hb_hours, 0, "间隔归零并持久化")

-- 非法间隔拒绝
MOCKS.sms_cb(ADMIN, "信鸽，设置心跳，200")
run_tasks()
assert(MOCKS.sent[5].text:find("ERROR", 1, true), "超上限拒绝")
n = n + 1
MOCKS.sms_cb(ADMIN, "信鸽，设置心跳，0")
run_tasks()
assert(MOCKS.sent[6].text:find("ERROR", 1, true), "0拒绝(关用关闭心跳)")
n = n + 1
MOCKS.sms_cb(ADMIN, "信鸽，设置心跳，abc")
run_tasks()
assert(MOCKS.sent[7].text:find("ERROR", 1, true), "非数字拒绝")
n = n + 1

-- 未初始化时设置成功也不布防（beat 到期自校验兜底）
cfg = sp_config.get()
cfg.initialized = false
cfg.hb_hours = 12
sp_config.save()
sp_heartbeat.restart()
eq(hb_timer(12), nil, "未初始化不布防")
cfg.initialized = true
cfg.hb_hours = 12
sp_config.save()
sp_heartbeat.restart()
assert(hb_timer(12) ~= nil, "已初始化后布防")
n = n + 1

print(string.format("PASS sp_heartbeat_test (%d assertions)", n))