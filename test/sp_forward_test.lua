--[[
sp_forward 转发引擎管线测试：运行统计、转发过滤（黑名单/过滤词）、
验证码提取、失败暂存与重发（IP_READY 自动 / 信鸽，重发 手动）。
命令经 MOCKS.sms_cb 全链路驱动（真实 on_sms 入口，非直调内部函数）。
]]

local sp_config   = require "sp_config"
require "sp_chan_sms"             -- 注册短信通道
local sp_forward  = require "sp_forward"

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

local ADMIN = "13900001111"       -- 白名单管理员
local TARGET = "13899990000"      -- 转发目标

local cfg = sp_config.get()
cfg.initialized = true
cfg.whitelist = { ADMIN }
cfg.fwd.sms = { on = true, targets = { TARGET } }
sp_config.save()

local last_sent = function() return MOCKS.sent[#MOCKS.sent] end
local sent_base = #MOCKS.sent

--------------------------------------------------------------------
-- 运行统计：成功/失败/过滤/丢弃 四路计数
--------------------------------------------------------------------
MOCKS.sms_cb("10086", "普通通知")
run_tasks()
eq(sp_forward.stats().sent, 1, "统计:成功计数")
eq(sp_forward.stats().fail, 0, "统计:无失败")
eq(sp_forward.stats().filtered, 0, "统计:无过滤")
eq(#MOCKS.sent, sent_base + 1, "短信通道转发成功")
sent_base = #MOCKS.sent

--------------------------------------------------------------------
-- 验证码提取：触发词 + 独立 4-8 位数字串
--------------------------------------------------------------------
MOCKS.sms_cb("10086", "您的验证码是4527,请勿泄露")
run_tasks()
assert(last_sent().text:find("[验证码:4527]", 1, true), "验证码行置于文案首部")
n = n + 1

-- 长数字串（手机号/单号）跳过，继续向后找真验证码
MOCKS.sms_cb("10086", "订单13800138000验证码777888")
run_tasks()
assert(last_sent().text:find("[验证码:777888]", 1, true), "11位号码不误报,后段验证码命中")
n = n + 1

-- 无触发词的纯数字（日期/账单）不提取
MOCKS.sms_cb("10086", "09月11日账单2026元已出")
run_tasks()
assert(not last_sent().text:find("验证码:", 1, true), "无触发词不附验证码行")
n = n + 1

-- 关闭开关后不提取
MOCKS.sms_cb(ADMIN, "信鸽，关闭验证码")
run_tasks()
MOCKS.sms_cb("10086", "您的验证码是9988")
run_tasks()
assert(not last_sent().text:find("验证码:9988", 1, true), "开关关闭后不提取")
assert(last_sent().text:find("9988", 1, true), "正文仍完整转发")
n = n + 2
MOCKS.sms_cb(ADMIN, "信鸽，开启验证码")
run_tasks()
sent_base = #MOCKS.sent

--------------------------------------------------------------------
-- 转发过滤：黑名单（不影响命令鉴权）与过滤词
--------------------------------------------------------------------
MOCKS.sms_cb(ADMIN, "信鸽，拉黑，10655566")
run_tasks()
assert(last_sent().text:find("已拉黑", 1, true), "拉黑命令应答")
n = n + 1
sent_base = #MOCKS.sent
MOCKS.sms_cb("10655566", "营销短信")
run_tasks()
eq(sp_forward.stats().filtered, 1, "统计:黑名单命中过滤计数")
eq(#MOCKS.sent, sent_base, "被拉黑来信不转发")

-- 拉黑白名单管理员本人：命令仍可用（鉴权与过滤正交），来信不再转发
MOCKS.sms_cb(ADMIN, "信鸽，拉黑，13900001111")
run_tasks()
sent_base = #MOCKS.sent
MOCKS.sms_cb(ADMIN, "信鸽，验证码")
run_tasks()
assert(last_sent().text:find("OK", 1, true), "拉黑不影响命令鉴权")
n = n + 1
MOCKS.sms_cb(ADMIN, "我自己的来信")
run_tasks()
eq(sp_forward.stats().filtered, 2, "统计:管理员来信被自己拉黑过滤")
eq(#MOCKS.sent, sent_base + 1, "仅验证码查询应答一条,来信未转发")
MOCKS.sms_cb(ADMIN, "信鸽，取消拉黑，13900001111")
run_tasks()
MOCKS.sms_cb(ADMIN, "信鸽，取消拉黑，10655566")
run_tasks()
eq(#sp_config.get().blocklist, 0, "黑名单清空")
MOCKS.sms_cb(ADMIN, "信鸽，取消拉黑，10086")
run_tasks()
assert(last_sent().text:find("ERROR", 1, true), "移除不存在的号码报错")
n = n + 2
sent_base = #MOCKS.sent

-- 过滤词批量增删
MOCKS.sms_cb(ADMIN, "信鸽，添加过滤词，优惠，促销")
run_tasks()
assert(last_sent().text:find("已添加 2 个", 1, true), "过滤词批量添加")
n = n + 1
sent_base = #MOCKS.sent
MOCKS.sms_cb("10086", "限时优惠大甩卖")
run_tasks()
MOCKS.sms_cb("10086", "正常业务通知")
run_tasks()
eq(sp_forward.stats().filtered, 3, "统计:过滤词命中")
eq(#MOCKS.sent, sent_base + 1, "命中词的来信丢弃,未命中的正常转发")
MOCKS.sms_cb(ADMIN, "信鸽，过滤词")
run_tasks()
assert(last_sent().text:find("优惠", 1, true) and last_sent().text:find("促销", 1, true), "过滤词列表可查")
n = n + 1
MOCKS.sms_cb(ADMIN, "信鸽，删除过滤词，优惠，促销")
run_tasks()
eq(#sp_config.get().kwords, 0, "过滤词清空")
MOCKS.sms_cb(ADMIN, "信鸽，添加过滤词，")
run_tasks()
assert(last_sent().text:find("ERROR", 1, true), "空词报错")
n = n + 2
sent_base = #MOCKS.sent

--------------------------------------------------------------------
-- 失败暂存与重发：全通道失败入 fskv 暂存，IP_READY 自动重发
--------------------------------------------------------------------
local st0 = sp_forward.stats()
MOCKS.sms_send_fail = true
MOCKS.sms_cb("10086", "断网时来的短信A")
run_tasks()
eq(sp_forward.stats().fail - st0.fail, 1, "统计:全通道失败计数")
eq(#sp_config.load_retry(), 1, "失败消息入暂存队列")
eq(sp_config.load_retry()[1].txt, "断网时来的短信A", "暂存保留原文")

-- 暂存容量封顶 5：连发 6 条，最旧被挤掉
for i = 1, 6 do
    MOCKS.sms_cb("10086", "失败" .. i)
end
run_tasks()
eq(#sp_config.load_retry(), 5, "暂存队列封顶5(丢最旧)")
eq(sp_config.load_retry()[1].txt, "失败2", "A与失败1两条最旧被挤出")

-- 网络恢复：IP_READY 自动重发，全部成功
MOCKS.sms_send_fail = false
MOCKS.publish("IP_READY")
run_tasks()
eq(#sp_config.load_retry(), 0, "重发后暂存清空")
eq(sp_forward.stats().sent - st0.sent, 5, "重发5条全部成功")
sent_base = #MOCKS.sent

-- 重试一次仍失败 → 永久丢弃（不回暂存，防往复打环）
MOCKS.sms_send_fail = true
MOCKS.sms_cb("10086", "又断网B")
run_tasks()
eq(#sp_config.load_retry(), 1, "首次失败入暂存")
MOCKS.sms_send_fail = false
MOCKS.publish("IP_READY")
MOCKS.sms_send_fail = true
run_tasks()
eq(#sp_config.load_retry(), 0, "重试再失败不回暂存(一次性)")
MOCKS.sms_send_fail = false

-- 手动重发命令：空暂存应答
MOCKS.sms_cb(ADMIN, "信鸽，重发")
run_tasks()
assert(last_sent().text:find("无暂存", 1, true), "空暂存时的重发应答")
n = n + 1
sent_base = #MOCKS.sent

--------------------------------------------------------------------
-- 统计命令与清零
--------------------------------------------------------------------
MOCKS.sms_cb(ADMIN, "信鸽，统计")
run_tasks()
local st = sp_forward.stats()
assert(last_sent().text:find("累计转发:" .. st.sent, 1, true), "统计命令应答含累计转发")
assert(last_sent().text:find("过滤:" .. st.filtered, 1, true), "统计命令应答含过滤计数")
n = n + 2
MOCKS.sms_cb(ADMIN, "信鸽，清零统计")
run_tasks()
st = sp_forward.stats()
eq(st.sent, 0, "清零:累计转发")
eq(st.fail, 0, "清零:失败")
eq(st.filtered, 0, "清零:过滤")
eq(st.dropped, 0, "清零:丢弃")

-- 重启后暂存仍在（fskv 持久）：直接读 store 键断言
eq(type(MOCKS.store["sp_retry"]), "table", "暂存队列经 fskv 持久化")

--------------------------------------------------------------------
-- 导入内容防泄漏闸：疑似配置 blob 不进入转发通道（token/白名单外泄防护）
--------------------------------------------------------------------
local g0 = sp_forward.stats().sent
sent_base = #MOCKS.sent
MOCKS.sms_cb(ADMIN, "转发：信鸽，导入配置\n增加白名单，13800138000\n设置钉钉，03f4753ea97855f4")
run_tasks()
eq(sp_forward.stats().sent, g0, "闸:blob不入转发队列")
eq(#MOCKS.sent, sent_base + 1, "闸:授权发送者收到格式提示")
eq(last_sent().num, ADMIN, "闸:提示只回发送者本人")
assert(last_sent().text:find("ERROR:导入格式错误", 1, true), "闸:提示文案")
n = n + 1
sent_base = #MOCKS.sent

-- 未授权发送者的 blob：静默（无回复、无转发，防探测）
MOCKS.sms_cb("10086", "转发：信鸽，导入配置\n增加白名单，13800138000")
run_tasks()
eq(#MOCKS.sent, sent_base, "闸:未授权无应答")
eq(sp_forward.stats().sent, g0, "闸:未授权无转发")

-- #SmsPigeon 尾注信号（中段截断只剩尾行的 blob 也能识别）
MOCKS.sms_cb("10086", "月底账单已出\n#SmsPigeon 1.3.0 共8条,密码不随导出")
run_tasks()
eq(sp_forward.stats().sent, g0, "闸:尾注标记触发不转发")

-- 对照组：正常短信不受闸影响
MOCKS.sms_cb("10086", "普通短信对照组")
run_tasks()
eq(sp_forward.stats().sent, g0 + 1, "对照:正常短信仍转发")

-- 首行干净的正常导入走命令路径，收到汇总应答
MOCKS.sms_cb(ADMIN, "信鸽，导入配置\n拉黑，10612345")
run_tasks()
assert(last_sent().text:find("OK:导入完成", 1, true), "正常导入得到汇总应答")
n = n + 1
eq(sp_config.get().blocklist[1], "10612345", "导入行已执行")
MOCKS.sms_cb(ADMIN, "信鸽，取消拉黑，10612345")
run_tasks()

print(string.format("PASS sp_forward_test (%d assertions)", n))