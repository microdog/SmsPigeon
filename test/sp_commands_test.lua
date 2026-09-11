--[[
sp_commands 命令流单元测试：初始化、鉴权门禁、白名单/密码管理、
通道配置、中文数字号码、转发分发集成、恢复出厂。
命令均为中文句子格式（前缀"信鸽"）。
]]

require "sp_channels"
require "sp_chan_sms"
require "sp_chan_dingtalk"
require "sp_chan_feishu"
require "sp_chan_serverchan"

local sp_config   = require "sp_config"
local sp_commands = require "sp_commands"
local sp_channels = require "sp_channels"

local ME    = "13800138000"   -- 机主号码（执行初始化，进入白名单）
local OTHER = "13900139000"   -- 陌生人号码

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end
local function contains(s, sub, msg)
    if not tostring(s):find(sub, 1, true) then
        error(string.format("FAIL %s\n  got: %s\n 缺少: %s", msg, tostring(s), sub), 0)
    end
    n = n + 1
end

local function send(from, text)
    return sp_commands.handle(from, text)
end

--------------------------------------------------------------------------
-- 未初始化状态
--------------------------------------------------------------------------

local is_cmd, reply = send(ME, "信鸽，状态")
eq(is_cmd, true, "未初始化时状态是命令(不转发)")
eq(reply, nil, "未初始化时非初始化命令静默丢弃")

is_cmd, reply = send(ME, "hello world")
eq(is_cmd, false, "普通短信标记为非命令")

is_cmd, reply = send(ME, "信鸽，初始化，000000000000000")
eq(is_cmd, true, "初始化是命令")
eq(reply, "ERROR", "IMEI错误回笼统ERROR")

-- IMEI 支持中文数字
is_cmd, reply = send(ME, "信鸽，初始化，八六四三一七零八零三四九三一二")
eq(reply, "ERROR", "中文数字IMEI也参与比对(错误值)")

is_cmd, reply = send(ME, "信鸽，初始化，" .. MOCKS.mobile.imei)
eq(is_cmd, true, "初始化是命令")
contains(reply, "已初始化", "正确IMEI初始化成功")
contains(reply, ME, "发送者加入白名单")

local cfg = sp_config.get()
eq(cfg.initialized, true, "初始化状态已写入配置")
eq(cfg.whitelist[1], "13800138000", "白名单首个成员为归一化机主号码")

-- 已初始化后再次初始化被拒绝
is_cmd, reply = send(ME, "信鸽，初始化，" .. MOCKS.mobile.imei)
eq(reply, "ERROR", "已初始化固件不可再次初始化")

--------------------------------------------------------------------------
-- 初始化后：门禁
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "信鸽")
eq(is_cmd, true, "信鸽是命令")
contains(reply, "OK", "信鸽探测回复OK")

is_cmd, reply = send(OTHER, "信鸽，状态")
eq(is_cmd, true, "陌生人命令被识别")
eq(reply, nil, "陌生人命令静默拒绝")

is_cmd, reply = send(ME, "信鸽，天气怎么样")
eq(is_cmd, true, "未知短语被识别为命令")
contains(reply, "未知命令", "未知短语有错误应答")

is_cmd, reply = send(ME, "信鸽，帮助")
contains(reply, "信鸽，初始化", "帮助包含初始化用法")
contains(reply, "信鸽，恢复出厂", "帮助包含恢复出厂用法")

is_cmd, reply = send(ME, "信鸽，版本")
contains(reply, "1.0.0", "版本包含版本号")

is_cmd, reply = send(ME, "信鸽，状态")
contains(reply, "IMEI:" .. MOCKS.mobile.imei, "状态包含IMEI")
contains(reply, "白名单:开", "状态包含白名单状态")
contains(reply, "密码:未设置", "状态包含密码状态")

is_cmd, reply = send(ME, "信鸽，查询状态？")
contains(reply, "OK:", "别名与句尾问号均可识别")

--------------------------------------------------------------------------
-- 白名单管理
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "信鸽，增加白名单，+8613711112222")
contains(reply, "OK", "白名单添加(+86形式)")
eq(sp_config.get().whitelist[#sp_config.get().whitelist], "13711112222", "白名单存储归一化号码")

is_cmd, reply = send(ME, "信鸽，增加白名单，13711112222")
contains(reply, "ERROR", "重复添加报错")

is_cmd, reply = send(ME, "信鸽，增加白名单，abc")
contains(reply, "ERROR", "非法号码报错")

-- 中文数字号码端到端
is_cmd, reply = send(ME, "信鸽，增加白名单，一三八零零一三九零零零")
contains(reply, "OK", "中文数字号码添加成功")
eq(sp_config.get().whitelist[#sp_config.get().whitelist], "13800139000", "中文数字号码归一化存储")

-- 13711112222 现在在白名单内，可以发命令
is_cmd, reply = send("+8613711112222", "信鸽")
contains(reply, "OK", "+86形式发送者命中白名单")

is_cmd, reply = send(ME, "信鸽，白名单")
contains(reply, "13800138000", "白名单查询列出成员")
contains(reply, "13711112222", "白名单查询列出第二个成员")

-- 防锁死：白名单开启时删除唯一条目被拒绝
is_cmd, reply = send(ME, "信鸽，删除白名单，13711112222")
contains(reply, "OK", "删除非末位成员正常")
is_cmd, reply = send(ME, "信鸽，删除白名单，一三八零零一三九零零零")
contains(reply, "OK", "删除中文数字添加的成员")
is_cmd, reply = send(ME, "信鸽，删除白名单，13800138000")

is_cmd, reply = send(ME, "信鸽，关闭白名单")
contains(reply, "警告", "关白名单且无密码时警告")

is_cmd, reply = send(OTHER, "信鸽")
contains(reply, "OK", "白名单关闭后陌生人可探测")

is_cmd, reply = send(ME, "信鸽，开启白名单")
contains(reply, "OK", "重新开启白名单")
is_cmd, reply = send(OTHER, "信鸽")
eq(reply, nil, "白名单重新生效")

--------------------------------------------------------------------------
-- 密码管理
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "信鸽，设置密码，8888")
contains(reply, "OK", "设置密码")
eq(sp_config.get().password, "8888", "密码已保存")

is_cmd, reply = send(ME, "信鸽，状态")
eq(is_cmd, false, "密码模式下默认前缀失效,原短信走转发")

is_cmd, reply = send(ME, "8888，状态")
eq(is_cmd, true, "密码前缀识别为命令")
contains(reply, "OK", "密码前缀命令可用")

-- AND 语义：密码正确但不在白名单 → 拒绝
is_cmd, reply = send(OTHER, "8888，状态")
eq(is_cmd, true, "陌生人密码命令被识别")
eq(reply, nil, "AND语义:白名单仍拦截")

is_cmd, reply = send(ME, "8888，设置密码，6666")
contains(reply, "OK", "旧密码可修改密码")
eq(sp_config.get().password, "6666", "新密码生效")

is_cmd, reply = send(ME, "6666，清除密码")
contains(reply, "OK", "清空密码")
eq(sp_config.get().password, "", "密码已清空")

is_cmd, reply = send(ME, "信鸽，设置密码，abc")
contains(reply, "ERROR", "密码过短报错")
is_cmd, reply = send(ME, "信鸽，设置密码，一二三四，五六")
contains(reply, "ERROR", "多参数按用法错误处理")
is_cmd, reply = send(ME, "信鸽，设置密码，信鸽")
contains(reply, "ERROR", "密码不可为信鸽")

-- 中文密码：4个汉字=4字符
is_cmd, reply = send(ME, "信鸽，设置密码，蓝色风筝")
contains(reply, "OK", "设置中文密码")
eq(sp_config.get().password, "蓝色风筝", "中文密码已保存")

is_cmd, reply = send(ME, "蓝色风筝，状态")
contains(reply, "OK", "中文密码命令可用")

is_cmd, reply = send(ME, "蓝色风筝，清除密码")
contains(reply, "OK", "用中文密码清除密码")
eq(sp_config.get().password, "", "密码已清空")

--------------------------------------------------------------------------
-- 转发通道配置
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "信鸽，增加转发号码，13262575718")
contains(reply, "OK", "添加短信转发目标")

is_cmd, reply = send(ME, "信鸽，增加短信转发号码：一三二六二五七五七一八")
contains(reply, "ERROR", "中文数字重复添加报错(等效同一号码)")

is_cmd, reply = send(ME, "信鸽，开启短信转发")
contains(reply, "OK", "开启短信通道")

is_cmd, reply = send(ME, "信鸽，设置钉钉，https://oapi.dingtalk.com/robot/send?access_token=abc，SECxxx")
contains(reply, "OK", "配置钉钉(带加签)")
local ding = sp_config.get().fwd.dingtalk
eq(ding.url, "https://oapi.dingtalk.com/robot/send?access_token=abc", "钉钉URL保存")
eq(ding.secret, "SECxxx", "钉钉密钥保存")
eq(ding.on, true, "设置后自动开启")

is_cmd, reply = send(ME, "信鸽，设置钉钉，ftp://bad")
contains(reply, "ERROR", "非法URL报错")

is_cmd, reply = send(ME, "信鸽，设置Server酱，SCT1234ABCD")
contains(reply, "OK", "配置Server酱SendKey")
eq(sp_config.get().fwd.serverchan.sendkey, "SCT1234ABCD", "SendKey保存")

is_cmd, reply = send(ME, "信鸽，设置Server酱，https://sc3.example.com/send/xxx.send")
contains(reply, "OK", "Server酱支持完整URL")

is_cmd, reply = send(ME, "信鸽，关闭Server酱")
contains(reply, "OK", "通用动词使用品牌名Server酱")


-- 纯 token 配置：规避运营商对 URL 特征短信的过滤
is_cmd, reply = send(ME, "信鸽，清空钉钉")
contains(reply, "OK", "清空钉钉以便重配")
is_cmd, reply = send(ME, "信鸽，设置钉钉，03f4753ec6aa6f0524fb85907c94b17f3fa0fed3107d4e8f4eee1d4a97855f4d，SECxxx")
contains(reply, "OK", "纯token配置钉钉")
eq(sp_config.get().fwd.dingtalk.url,
   "https://oapi.dingtalk.com/robot/send?access_token=03f4753ec6aa6f0524fb85907c94b17f3fa0fed3107d4e8f4eee1d4a97855f4d",
   "纯token拼出标准webhook地址")
eq(sp_config.get().fwd.dingtalk.secret, "SECxxx", "token形式同样支持加签密钥")

is_cmd, reply = send(ME, "信鸽，设置飞书，bb089165-4b73-4f80-9ed0-da0c908b44e5")
contains(reply, "OK", "纯hook_id配置飞书")
eq(sp_config.get().fwd.feishu.url,
   "https://open.feishu.cn/open-apis/bot/v2/hook/bb089165-4b73-4f80-9ed0-da0c908b44e5",
   "hook_id拼出标准webhook地址")

is_cmd, reply = send(ME, "信鸽，设置钉钉，短token")
contains(reply, "ERROR", "过短token报错")
is_cmd, reply = send(ME, "信鸽，设置飞书，带空格的 token")
contains(reply, "ERROR", "含空格token报错")
is_cmd, reply = send(ME, "信鸽，设置飞书，https://open.feishu.cn/open-apis/bot/v2/hook/xxx")
contains(reply, "OK", "配置飞书(免签)")

is_cmd, reply = send(ME, "信鸽，开启，不存在的通道")
contains(reply, "ERROR", "未知通道报错")

is_cmd, reply = send(ME, "信鸽，清空钉钉")
contains(reply, "OK", "清空钉钉配置")
eq(sp_config.get().fwd.dingtalk.on, false, "清空后通道关闭")

is_cmd, reply = send(ME, "信鸽，转发")
contains(reply, "短信:开", "转发查询包含短信通道状态")

--------------------------------------------------------------------------
-- 转发分发集成（短信通道端到端）
--------------------------------------------------------------------------

local sent_before = #MOCKS.sent
sp_channels.dispatch({ sender = "10086", text = "余额:10元", time = "2026-09-11 10:00:00" },
    sp_config.get().fwd)
eq(#MOCKS.sent - sent_before, 1, "分发触发1条短信转发")
local out = MOCKS.sent[#MOCKS.sent]
eq(out.num, "13262575718", "转发到配置的目标")
contains(out.text, "10086", "转发文本包含来信号码")
contains(out.text, "余额:10元", "转发文本包含原文")
contains(out.text, "SmsPigeon", "转发文本带前缀标记")

--------------------------------------------------------------------------
-- 重启与恢复出厂
--------------------------------------------------------------------------

local action
is_cmd, reply, action = send(ME, "信鸽，重启")
contains(reply, "OK", "重启命令应答")
eq(action, "reboot", "重启命令返回action")

is_cmd, reply = send(ME, "信鸽，恢复出厂")
contains(reply, "OK", "恢复出厂应答")
eq(sp_config.get().initialized, false, "恢复出厂后回到未初始化")

-- 恢复出厂后回到未初始化门禁
is_cmd, reply = send(ME, "信鸽")
eq(reply, nil, "恢复出厂后普通命令静默丢弃")

print(string.format("PASS sp_commands_test (%d assertions)", n))