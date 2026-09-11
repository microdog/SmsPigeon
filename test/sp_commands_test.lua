--[[
sp_commands 命令流单元测试：初始化、鉴权门禁、白名单/密码管理、
通道配置、转发分发集成、恢复出厂。
]]

require "sp_channels"
require "sp_chan_sms"
require "sp_chan_dingtalk"
require "sp_chan_feishu"
require "sp_chan_serverchan"

local sp_config   = require "sp_config"
local sp_commands = require "sp_commands"
local sp_channels = require "sp_channels"

local ME    = "13800138000"   -- 机主号码（执行 INIT，进入白名单）
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

local is_cmd, reply = send(ME, "AT+ST?")
eq(is_cmd, true, "未初始化时ST是命令(不转发)")
eq(reply, nil, "未初始化时非INIT命令静默丢弃")

is_cmd, reply = send(ME, "hello world")
eq(is_cmd, false, "普通短信标记为非命令")

is_cmd, reply = send(ME, "AT+INIT=000000000000000")
eq(is_cmd, true, "INIT是命令")
eq(reply, "ERROR", "IMEI错误回笼统ERROR")

is_cmd, reply = send(ME, "AT+INIT=860123456789012")
eq(is_cmd, true, "INIT是命令")
contains(reply, "已初始化", "正确IMEI初始化成功")
contains(reply, ME, "发送者加入白名单")

local cfg = sp_config.get()
eq(cfg.initialized, true, "初始化状态已写入配置")
eq(cfg.whitelist[1], "13800138000", "白名单首个成员为归一化机主号码")

-- 已初始化后再次 INIT 被拒绝
is_cmd, reply = send(ME, "AT+INIT=860123456789012")
eq(reply, "ERROR", "已初始化固件不可再次初始化")

--------------------------------------------------------------------------
-- 初始化后：门禁
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "AT")
eq(is_cmd, true, "AT是命令")
contains(reply, "OK", "AT探测回复OK")

is_cmd, reply = send(OTHER, "AT+ST?")
eq(is_cmd, true, "陌生人命令被识别")
eq(reply, nil, "陌生人命令静默拒绝")

is_cmd, reply = send(ME, "AT+XYZ?")
eq(is_cmd, true, "未知命令")
contains(reply, "未知命令", "未知命令有错误应答")

is_cmd, reply = send(ME, "AT+HELP?")
contains(reply, "AT+INIT", "HELP包含INIT用法")
contains(reply, "AT+RESET", "HELP包含RESET用法")

is_cmd, reply = send(ME, "AT+VER?")
contains(reply, "1.0.0", "VER包含版本号")

is_cmd, reply = send(ME, "AT+ST?")
contains(reply, "IMEI:860123456789012", "ST包含IMEI")
contains(reply, "白名单:开", "ST包含白名单状态")
contains(reply, "密码:未设置", "ST包含密码状态")

is_cmd, reply = send(ME, "AT+WL=?")
contains(reply, "用法:", "test操作返回用法")

--------------------------------------------------------------------------
-- 白名单管理
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "AT+WL=ADD,+8613711112222")
contains(reply, "OK", "白名单添加(+86形式)")
eq(sp_config.get().whitelist[#sp_config.get().whitelist], "13711112222", "白名单存储归一化号码")

is_cmd, reply = send(ME, "AT+WL=ADD,13711112222")
contains(reply, "ERROR", "重复添加报错")

is_cmd, reply = send(ME, "AT+WL=ADD,abc")
contains(reply, "ERROR", "非法号码报错")

-- 13711112222 现在在白名单内，可以发命令
is_cmd, reply = send("+8613711112222", "AT")
contains(reply, "OK", "+86形式发送者命中白名单")

is_cmd, reply = send(ME, "AT+WL?")
contains(reply, "13800138000", "WL查询列出成员")
contains(reply, "13711112222", "WL查询列出第二个成员")

-- 防锁死：白名单开启时删除唯一条目被拒绝
is_cmd, reply = send(ME, "AT+WL=DEL,13711112222")
contains(reply, "OK", "删除非末位成员正常")
is_cmd, reply = send(ME, "AT+WL=DEL,13800138000")
contains(reply, "不可删空", "白名单开启时删空被拒绝")
eq(#sp_config.get().whitelist, 1, "被拒绝的删除不生效")

is_cmd, reply = send(ME, "AT+WL=OFF")
contains(reply, "警告", "关白名单且无密码时警告")

-- 白名单关闭后，陌生人也可控制（危险状态，文档已警示）
is_cmd, reply = send(OTHER, "AT")
contains(reply, "OK", "白名单关闭后陌生人可探测")

is_cmd, reply = send(ME, "AT+WL=ON")
contains(reply, "OK", "重新开启白名单")
is_cmd, reply = send(OTHER, "AT")
eq(reply, nil, "白名单重新生效")

--------------------------------------------------------------------------
-- 密码管理
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "AT+PW=8888")
contains(reply, "OK", "设置密码")
eq(sp_config.get().password, "8888", "密码已保存")

is_cmd, reply = send(ME, "AT+ST?")
eq(is_cmd, false, "密码模式下AT前缀失效,原短信走转发")

is_cmd, reply = send(ME, "8888+ST?")
eq(is_cmd, true, "密码前缀识别为命令")
contains(reply, "OK", "密码前缀命令可用")

-- AND 语义：密码正确但不在白名单 → 拒绝
is_cmd, reply = send(OTHER, "8888+ST?")
eq(is_cmd, true, "陌生人密码命令被识别")
eq(reply, nil, "AND语义:白名单仍拦截")

is_cmd, reply = send(ME, "8888+PW=6666")
contains(reply, "OK", "旧密码可修改密码")
eq(sp_config.get().password, "6666", "新密码生效")

is_cmd, reply = send(ME, "6666+PW=")
contains(reply, "OK", "清空密码")
eq(sp_config.get().password, "", "密码已清空")

is_cmd, reply = send(ME, "AT+PW=abc")
contains(reply, "ERROR", "密码过短报错")
is_cmd, reply = send(ME, "AT+PW=1234,5678")
contains(reply, "ERROR", "多参数按用法错误处理")
is_cmd, reply = send(ME, "AT+PW=AT")
contains(reply, "ERROR", "密码不可为AT")

--------------------------------------------------------------------------
-- 转发通道配置
--------------------------------------------------------------------------

is_cmd, reply = send(ME, "AT+FWD=SMS,ADD,13711112222")
contains(reply, "OK", "添加短信转发目标")

is_cmd, reply = send(ME, "AT+FWD=SMS,ADD,13711112222")
contains(reply, "ERROR", "重复添加转发目标报错")

is_cmd, reply = send(ME, "AT+FWD=SMS,ON")
contains(reply, "OK", "开启短信通道")

is_cmd, reply = send(ME, "AT+FWD=DING,SET,https://oapi.dingtalk.com/robot/send?access_token=abc,SECxxx")

contains(reply, "OK", "配置钉钉(带加签)")
local ding = sp_config.get().fwd.dingtalk
eq(ding.url, "https://oapi.dingtalk.com/robot/send?access_token=abc", "钉钉URL保存")
eq(ding.secret, "SECxxx", "钉钉密钥保存")
eq(ding.on, true, "SET后自动开启")

is_cmd, reply = send(ME, "AT+FWD=DING,SET,ftp://bad")
contains(reply, "ERROR", "非法URL报错")

is_cmd, reply = send(ME, "AT+FWD=SC,SET,SCT1234ABCD")
contains(reply, "OK", "配置Server酱SendKey")
eq(sp_config.get().fwd.serverchan.sendkey, "SCT1234ABCD", "SendKey保存")

is_cmd, reply = send(ME, "AT+FWD=SC,SET,https://sc3.example.com/send/xxx.send")
contains(reply, "OK", "Server酱支持完整URL")

is_cmd, reply = send(ME, "AT+FWD=FS,SET,https://open.feishu.cn/open-apis/bot/v2/hook/xxx")
contains(reply, "OK", "配置飞书(免签)")

is_cmd, reply = send(ME, "AT+FWD=XXX,ON")
contains(reply, "ERROR", "未知通道报错")

is_cmd, reply = send(ME, "AT+FWD=DING,CLR")
contains(reply, "OK", "清空钉钉配置")
eq(sp_config.get().fwd.dingtalk.on, false, "清空后通道关闭")

is_cmd, reply = send(ME, "AT+FWD?")
contains(reply, "短信:开", "FWD查询包含短信通道状态")

--------------------------------------------------------------------------
-- 转发分发集成（短信通道端到端）
--------------------------------------------------------------------------

-- 清场：本测试只验证短信通道端到端（HTTP 通道无桩）
is_cmd, reply = send(ME, "AT+FWD=FS,CLR")
contains(reply, "OK", "清空飞书配置")
is_cmd, reply = send(ME, "AT+FWD=SC,CLR")
contains(reply, "OK", "清空Server酱配置")

local sent_before = #MOCKS.sent
sp_channels.dispatch({ sender = "10086", text = "余额:10元", time = "2026-09-11 10:00:00" },
    sp_config.get().fwd)
eq(#MOCKS.sent - sent_before, 1, "分发触发1条短信转发")
local out = MOCKS.sent[#MOCKS.sent]
eq(out.num, "13711112222", "转发到配置的目标")
contains(out.text, "10086", "转发文本包含来信号码")
contains(out.text, "余额:10元", "转发文本包含原文")
contains(out.text, "SmsPigeon", "转发文本带前缀标记")

--------------------------------------------------------------------------
-- 重启与恢复出厂
--------------------------------------------------------------------------

local action
is_cmd, reply, action = send(ME, "AT+REBOOT")
contains(reply, "OK", "重启命令应答")
eq(action, "reboot", "重启命令返回action")

is_cmd, reply = send(ME, "AT+RESET")
contains(reply, "OK", "恢复出厂应答")
eq(sp_config.get().initialized, false, "复位后回到未初始化")

-- 复位后回到未初始化门禁
is_cmd, reply = send(ME, "AT")
eq(reply, nil, "复位后普通命令静默丢弃")

print(string.format("PASS sp_commands_test (%d assertions)", n))
