--[[
main.lua 装配冒烟测试：完整加载固件入口，验证模块装配顺序无错、
短信回调已注册、全局变量就位、中文命令应答与未初始化丢弃逻辑贯通。

mock 的 sys.taskInit 只记录不执行（避免常驻任务挂死测试），
本测试按增量驱动回调产生的任务来验证应答短信真正发出。
]]

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end

-- 执行 base 之后新增的任务（仅回调产生的增量，不含常驻任务）
local function run_new_tasks(base)
    for i = base + 1, #MOCKS.tasks do
        local ok, err = pcall(MOCKS.tasks[i])
        if not ok then error("任务执行失败: " .. tostring(err), 0) end
    end
    return #MOCKS.tasks
end

local dir = ((arg and arg[0] or ""):match("^(.*)[/\\]") or ".")
dofile(dir .. "/../main.lua")

eq(type(MOCKS.sms_cb), "function", "main装配后短信回调已注册")
eq(PROJECT, "SmsPigeon", "PROJECT全局变量")
eq(VERSION, "1.0.0", "VERSION全局变量")

-- 状态灯模块：模式决策纯函数 + 活动闪烁接口
local sp_led = require "sp_led"
eq(sp_led.pattern_for(false, false), "fast", "状态灯:无网络快闪")
eq(sp_led.pattern_for(false, true), "fast", "状态灯:未注册已初始化仍快闪")
eq(sp_led.pattern_for(true, false), "slow", "状态灯:未初始化心跳")
eq(sp_led.pattern_for(true, true), "on", "状态灯:正常常亮")
sp_led.blink()   -- 活动闪烁接口，即便未驱动任务也应无害
eq(MOCKS.sms_debug, false, "内核短信调试日志默认关闭(sms.debug)")

-- 未初始化：命令无应答、普通短信不转发
local base = #MOCKS.tasks
MOCKS.sms_cb("13800138000", "信鸽，状态")
base = run_new_tasks(base)
eq(#MOCKS.sent, 0, "未初始化:命令无应答")
MOCKS.sms_cb("13800138000", "普通短信")
base = run_new_tasks(base)
eq(#MOCKS.sent, 0, "未初始化:普通短信不转发不回复")

-- 初始化：完整链路收命令、发应答（用户实测原句风格）
MOCKS.sms_cb("13800138000", "信鸽，初始化，" .. MOCKS.mobile.imei)
base = run_new_tasks(base)
eq(#MOCKS.sent, 1, "初始化应答已发出")
eq(MOCKS.sent[1].num, "13800138000", "应答发回命令发送者")
assert(MOCKS.sent[1].text:find("已初始化", 1, true), "应答内容为初始化成功")
n = n + 1

-- 初始化后：命令可探测
MOCKS.sms_cb("13800138000", "信鸽")
base = run_new_tasks(base)
eq(#MOCKS.sent, 2, "信鸽探测应答已发出")
assert(MOCKS.sent[2].text:find("OK", 1, true), "信鸽应答为OK")
n = n + 1

-- S2：调试命令可运行时开关内核短信日志（默认关）
MOCKS.sms_cb("13800138000", "信鸽，调试，开")
base = run_new_tasks(base)
eq(MOCKS.sms_debug, true, "调试命令开启内核短信日志")
eq(#MOCKS.sent, 3, "调试命令有应答")
MOCKS.sms_cb("13800138000", "信鸽，调试，关")
base = run_new_tasks(base)
eq(MOCKS.sms_debug, false, "调试命令关闭内核短信日志")
eq(#MOCKS.sent, 4, "调试命令有应答")
n = n + 2

-- 初始化后：普通短信走转发（无通道配置 → 无发送、无报错）
MOCKS.sms_cb("10086", "余额:10元")
base = run_new_tasks(base)
eq(#MOCKS.sent, 4, "无通道配置时转发不产生短信")

-- S3 防环：转发携带实例标记、回环短信被丢弃、本机号码目标被跳过
local sp_config = require "sp_config"
MOCKS.sms_cb("13800138000", "信鸽，增加转发号码，13911112222")
base = run_new_tasks(base)
MOCKS.sms_cb("13800138000", "信鸽，开启短信转发")
base = run_new_tasks(base)
local mark = sp_config.get().mark
assert(type(mark) == "string" and #mark == 8, "防环实例标记已生成(8位hex)")
MOCKS.sms_cb("10086", "余额:20元")
base = run_new_tasks(base)
eq(#MOCKS.sent, 7, "普通短信经短信通道转发(含两条命令应答)")
local fwd = MOCKS.sent[#MOCKS.sent]
eq(fwd.num, "13911112222", "转发发往配置目标")
assert(fwd.text:find(mark, 1, true), "转发文本末尾携带防环标记")
n = n + 2

MOCKS.sms_cb("13911112222", "来自 10086:\n余额:20元\n" .. mark)
base = run_new_tasks(base)
eq(#MOCKS.sent, 7, "含本机标记的回环短信被丢弃(不转发不回复)")

MOCKS.mobile.number = "13911112222"   -- 目标==本机 MSISDN
MOCKS.sms_cb("10086", "余额:30元")
base = run_new_tasks(base)
eq(#MOCKS.sent, 7, "等于本机号码的转发目标被跳过")
MOCKS.mobile.number = ""

local sp_forward = require "sp_forward"
-- S4 队列：洪泛时上限 20、丢最旧计数；worker 一次驱动排空
for i = 1, 25 do
    MOCKS.sms_cb("10086", "洪水" .. i)
end
eq(sp_forward.stats().pending, 20, "队列封顶在20(丢最旧)")
eq(sp_forward.stats().dropped, 5, "溢出丢弃计数=5")
base = run_new_tasks(base)
eq(sp_forward.stats().pending, 0, "worker 一次排空队列")
eq(#MOCKS.sent, 27, "排空仅转发队列内的20条(7+20)")

print(string.format("PASS main_smoke_test (%d assertions)", n))