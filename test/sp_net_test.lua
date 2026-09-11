--[[
sp_net 网络失联自愈测试：轮询注册状态，连续 30 分钟（6 次 × 5 分钟）
未注册触发重启；注册恢复清零计数；触发后计数复位防抖。
net_watch 经 MOCKS.timers 注册，测试直调 sp_net.net_watch() 驱动。
注意：ntp_task 常驻任务已注册但测试不驱动（其内部死循环属正常形态）。
]]

local sp_net = require "sp_net"

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 2)
    end
    n = n + 1
end

-- 装配即布防轮询（5 分钟周期循环定时器）
local armed
for _, t in ipairs(MOCKS.timers) do
    if t.fn == sp_net.net_watch then armed = t end
end
assert(armed ~= nil, "网络监视定时器已布防")
n = n + 1
eq(armed.ms, 300000, "轮询周期5分钟")
eq(armed.loop, true, "为循环定时器")

-- 已注册（默认桩 status=1）：返回 true 且计数为零
eq(sp_net.net_watch(), true, "已注册时轮询返回true")
MOCKS.mobile.status = 0

-- 连续 5 次未注册：不重启
for i = 1, 5 do sp_net.net_watch() end
eq(MOCKS.reboots, 0, "5次(25分钟)未注册不重启")

-- 第 6 次：触发重启自愈
eq(sp_net.net_watch(), false, "未注册时轮询返回false")
eq(MOCKS.reboots, 1, "连续6次(30分钟)触发重启")

-- 触发后计数已复位：再来 5 次不重启（无次数上限，靠周期自然节流）
for i = 1, 5 do sp_net.net_watch() end
eq(MOCKS.reboots, 1, "重启后计数复位,5次内不再触发")

-- 注册恢复 → 计数清零
MOCKS.mobile.status = 1
eq(sp_net.net_watch(), true, "注册恢复")
MOCKS.mobile.status = 0
for i = 1, 5 do sp_net.net_watch() end
eq(MOCKS.reboots, 1, "恢复后重新计数,5次不触发")
eq(sp_net.net_watch(), false, "第6次再次触发")
eq(MOCKS.reboots, 2, "长期无信号持续自愈(无上限)")

print(string.format("PASS sp_net_test (%d assertions)", n))