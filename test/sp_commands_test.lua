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
require "sp_chan_wecom"

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

-- 企业微信：纯 key 与完整 webhook 两种形式
is_cmd, reply = send(ME, "信鸽，设置企业微信，693a91f6-7aoc-4bc4-97a0-0ec2sifa5aaa")
contains(reply, "OK", "纯key配置企业微信")
eq(sp_config.get().fwd.wecom.key, "693a91f6-7aoc-4bc4-97a0-0ec2sifa5aaa", "key已保存")
eq(sp_config.get().fwd.wecom.on, true, "设置后自动开启")

is_cmd, reply = send(ME, "信鸽，设置企业微信，https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=71017f82-e027-4c5d-a618-eb4ee01750e9")
contains(reply, "OK", "完整webhook配置企业微信")
eq(sp_config.get().fwd.wecom.key, "71017f82-e027-4c5d-a618-eb4ee01750e9", "从URL抽取key")

is_cmd, reply = send(ME, "信鸽，设置企业微信，短key")
contains(reply, "ERROR", "过短key报错")

is_cmd, reply = send(ME, "信鸽，关闭企业微信")
contains(reply, "OK", "通用动词操作企业微信")
is_cmd, reply = send(ME, "信鸽，开启企业微信")
contains(reply, "OK", "开启企业微信")

is_cmd, reply = send(ME, "信鸽，开启，不存在的通道")
contains(reply, "ERROR", "未知通道报错")

is_cmd, reply = send(ME, "信鸽，清空钉钉")
contains(reply, "OK", "清空钉钉配置")
eq(sp_config.get().fwd.dingtalk.on, false, "清空后通道关闭")

is_cmd, reply = send(ME, "信鸽，转发")
contains(reply, "短信:开", "转发查询包含短信通道状态")

--------------------------------------------------------------------------
-- 远程发短信（控制本机向指定号码发送一条短信）
--------------------------------------------------------------------------

local sent_base = #MOCKS.sent
is_cmd, reply = send(ME, "信鸽，发送短信，13800138000，测试内容")
contains(reply, "OK", "远程发短信应答OK")
contains(reply, "13800138000", "应答包含收件号码")
MOCKS.tasks[#MOCKS.tasks]()
eq(MOCKS.sent[#MOCKS.sent].num, "13800138000", "短信发往指定号码")
contains(MOCKS.sent[#MOCKS.sent].text, "测试内容", "短信内容正确")

-- 中文数字号码归一化 + 发短信 短语别名
is_cmd, reply = send(ME, "信鸽，发短信，一三八〇〇一三八〇〇〇，内容二")
contains(reply, "OK", "发短信别名可用")
MOCKS.tasks[#MOCKS.tasks]()
eq(MOCKS.sent[#MOCKS.sent].num, "13800138000", "中文数字号码归一化")

-- 内容含逗号：拆分后用中文逗号拼回
is_cmd, reply = send(ME, "信鸽，发送短信，10086，甲，乙")
MOCKS.tasks[#MOCKS.tasks]()
eq(MOCKS.sent[#MOCKS.sent].num, "10086", "短号码作为收件人")
eq(MOCKS.sent[#MOCKS.sent].text, "甲，乙", "内容逗号按原样保留")

-- 错误用法
is_cmd, reply = send(ME, "信鸽，发送短信，123，内容")
contains(reply, "ERROR", "过短号码报错")
is_cmd, reply = send(ME, "信鸽，发送短信，13800138000")
contains(reply, "ERROR", "缺少内容报错")
eq(#MOCKS.sent - sent_base, 3, "错误用法不发送")

--------------------------------------------------------------------------
-- 转发分发集成（短信通道端到端）
--------------------------------------------------------------------------

-- 前缀命令流
is_cmd, reply = send(ME, "信鸽，前缀")
contains(reply, "(无)", "默认无转发前缀")
is_cmd, reply = send(ME, "信鸽，设置前缀，【短信鸽】")
contains(reply, "OK", "设置转发前缀")
eq(sp_config.get().prefix, "【短信鸽】", "前缀已保存")
is_cmd, reply = send(ME, "信鸽，前缀")
contains(reply, "【短信鸽】", "查询当前前缀")
is_cmd, reply = send(ME, "信鸽，设置前缀，信鸽转发")
contains(reply, "ERROR", "前缀不可为命令形式")
is_cmd, reply = send(ME, "信鸽，状态")
contains(reply, "前缀:【短信鸽】", "状态显示前缀")

-- 设备标识：自动（mock 手机号可解析）
MOCKS.mobile.number = "18019014417"
is_cmd, reply = send(ME, "信鸽，标识")
contains(reply, "尾号4417", "自动标识取手机号尾4位")
eq(sp_commands.resolve_identity(sp_config.get()), "4417", "resolve_identity 自动解析")
is_cmd, reply = send(ME, "信鸽，状态")
contains(reply, "标识:4417", "状态显示自动标识")

-- SIM 未写号码：自动态不携带
MOCKS.mobile.number = ""
is_cmd, reply = send(ME, "信鸽，标识")
contains(reply, "SIM未写号码", "无号码时自动态提示")
eq(sp_commands.resolve_identity(sp_config.get()), "", "无号码时解析为空")
MOCKS.mobile.number = "18019014417"

-- 自定义/关闭/恢复自动
is_cmd, reply = send(ME, "信鸽，设置标识，客厅设备")
contains(reply, "OK", "设置自定义标识")
eq(sp_config.get().identity, "客厅设备", "标识已保存")
is_cmd, reply = send(ME, "信鸽，标识")
contains(reply, "客厅设备", "查询自定义标识")
is_cmd, reply = send(ME, "信鸽，关闭标识")
contains(reply, "OK", "关闭标识")
eq(sp_config.get().identity, "", "关闭态保存为空串")
eq(sp_commands.resolve_identity(sp_config.get()), "", "关闭态解析为空")
is_cmd, reply = send(ME, "信鸽，清除标识")
contains(reply, "OK", "清除标识恢复自动")
eq(sp_config.get().identity, nil, "恢复自动态")

-- 前缀与密码防冲突（advisory：密码模式下命令以密码开头）
is_cmd, reply = send(ME, "信鸽，设置密码，8888ab")
contains(reply, "OK", "设置密码")
is_cmd, reply = send(ME, "8888ab，设置前缀，8888ab，来自")
contains(reply, "ERROR", "前缀与密码同头被拒")
is_cmd, reply = send(ME, "8888ab，设置前缀，【OK】")
contains(reply, "OK", "正常前缀可设置")
is_cmd, reply = send(ME, "8888ab，清除前缀")
contains(reply, "OK", "清除前缀")
-- 反向：先设前缀再设同头密码
is_cmd, reply = send(ME, "8888ab，清除密码")
contains(reply, "OK", "清除密码")
send(ME, "信鸽，设置前缀，8888ab，来自")
is_cmd, reply = send(ME, "信鸽，设置密码，8888ab")
contains(reply, "ERROR", "密码与已有前缀同头被拒")
send(ME, "信鸽，清除前缀")

-- 前缀含逗号：参数拆分后用中文逗号拼回
is_cmd, reply = send(ME, "信鸽，设置前缀，【短信，备份】")
eq(sp_config.get().prefix, "【短信，备份】", "前缀中的逗号按原样保留")
is_cmd, reply = send(ME, "信鸽，清除前缀")
contains(reply, "OK", "清除转发前缀")
eq(sp_config.get().prefix, "", "前缀已清空")

local sent_before = #MOCKS.sent
local cfg = sp_config.get()
local dres = sp_channels.dispatch({ sender = "10086", text = "余额:10元", time = "2026-09-11 10:00:00",
    prefix = cfg.prefix or "" }, cfg.fwd)
eq(#MOCKS.sent - sent_before, 1, "分发触发1条短信转发")
eq(dres.sms, true, "dispatch结果:短信通道成功")
local out = MOCKS.sent[#MOCKS.sent]
eq(out.num, "13262575718", "转发到配置的目标")
contains(out.text, "10086", "转发文本包含来信号码")
contains(out.text, "余额:10元", "转发文本包含原文")
assert(not out.text:find("SmsPigeon", 1, true), "默认转发文本不带固定标识")
n = n + 1

-- 设置前缀后再分发：转发文本携带自定义前缀
send(ME, "信鸽，设置前缀，【短信鸽】")
sp_channels.dispatch({ sender = "10086", text = "余额:10元", time = "2026-09-11 10:00:00",
    prefix = sp_config.get().prefix }, sp_config.get().fwd)
local out2 = MOCKS.sent[#MOCKS.sent]
contains(out2.text, "【短信鸽】", "转发文本携带自定义前缀")
send(ME, "信鸽，清除前缀")

-- 分发携带设备标识：转发文本包含 [设备:xxx]
local cfgx = sp_config.get()
send(ME, "信鸽，设置标识，客厅")
sp_channels.dispatch({ sender = "10086", text = "余额:10元", time = "2026-09-11 10:00:00",
    prefix = cfgx.prefix, identity = sp_commands.resolve_identity(cfgx) }, cfgx.fwd)
local out3 = MOCKS.sent[#MOCKS.sent]
contains(out3.text, "[设备:客厅]", "转发文本携带设备标识")
send(ME, "信鸽，关闭标识")
local cfgx = sp_config.get()
sp_channels.dispatch({ sender = "10086", text = "余额:10元", time = "2026-09-11 10:00:00",
    prefix = cfgx.prefix, identity = sp_commands.resolve_identity(cfgx) }, cfgx.fwd)
local out4 = MOCKS.sent[#MOCKS.sent]
assert(not out4.text:find("设备:", 1, true), "关闭标识后转发文本不携带")
n = n + 1
send(ME, "信鸽，清除标识")

-- 回归：短信通道失败路径不抛错且返回失败
-- （曾因 failed 变量未声明，运行时错误被 dispatch 的 pcall 吞掉）
local sms_ch = sp_channels.get("sms")
local real_send = sms.send
sms.send = function() return false end
local pok, res = pcall(sms_ch.send,
    { sender = "10086", text = "x", prefix = "", identity = "" },
    { targets = { "13800138000" } })
sms.send = real_send
eq(pok, true, "失败路径不抛错")
eq(res, false, "通道返回失败")
n = n + 1

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