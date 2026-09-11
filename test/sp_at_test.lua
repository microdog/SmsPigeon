--[[
sp_at 解析器单元测试：AT 语法、密码模式、边界与非法输入。
]]

local sp_at = require "sp_at"

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end

-- 基本形式
local p = sp_at.parse("AT+ST?", "")
eq(p.cmd, "ST", "查询命令名")
eq(p.op, "read", "查询操作")
eq(#p.args, 0, "查询无参数")

p = sp_at.parse("at+st?", "")
eq(p.cmd, "ST", "命令名大小写不敏感")

p = sp_at.parse("AT+FWD=DING,SET,https://oapi.dingtalk.com/robot/send?access_token=abc", "")
eq(p.cmd, "FWD", "设置命令名")
eq(p.op, "write", "设置操作")
eq(p.args[1], "DING", "参数1")
eq(p.args[2], "SET", "参数2")
eq(p.args[3], "https://oapi.dingtalk.com/robot/send?access_token=abc", "URL参数保留原样")

p = sp_at.parse("AT+ST", "")
eq(p.op, "exec", "执行操作")

p = sp_at.parse("AT+ST=?", "")
eq(p.op, "test", "测试操作")

p = sp_at.parse("AT", "")
eq(p.cmd, "", "裸AT为探测命令")
eq(p.op, "exec", "探测为exec")

p = sp_at.parse("  AT+ST? \r\n", "")
eq(p.cmd, "ST", "首尾空白被剔除")

p = sp_at.parse("　AT+ST?", "")
eq(p.cmd, "ST", "全角空格被剔除")

-- 空参数（清除密码用）
p = sp_at.parse("AT+PW=", "")
eq(p.op, "write", "空值仍是write")
eq(#p.args, 1, "空值产生1个空参数")
eq(p.args[1], "", "空参数值为空串")

-- 非命令
eq(sp_at.parse("hello", ""), nil, "普通短信")
eq(sp_at.parse("ATX", ""), nil, "AT后无+号")
eq(sp_at.parse("AT+", ""), nil, "+后无命令名")
eq(sp_at.parse("AT+ST?a", ""), nil, "命令名含非法字符")
eq(sp_at.parse("", ""), nil, "空串")
eq(sp_at.parse(nil, ""), nil, "nil输入")
eq(sp_at.parse("attack at dawn", ""), nil, "正文含at不算前缀")

-- 密码模式
p = sp_at.parse("8888+ST?", "8888")
eq(p.cmd, "ST", "密码前缀命令")
eq(p.via_password, true, "标记via_password")
eq(p.op, "read", "密码模式查询操作")

p = sp_at.parse("8888", "8888")
eq(p.cmd, "", "裸密码为探测命令")
eq(p.via_password, true, "裸密码via_password")

eq(sp_at.parse("AT+ST?", "8888"), nil, "密码模式下AT前缀失效")
eq(sp_at.parse("8888AT+ST?", "8888"), nil, "密码后必须紧跟+号")
eq(sp_at.parse("9999+ST?", "8888"), nil, "错误密码")

-- 密码歧义边界：单字符密码
p = sp_at.parse("A+ST?", "A")
eq(p.cmd, "ST", "单字符密码正常匹配")
eq(sp_at.parse("AT+ST?", "A"), nil, "单字符密码不吞AT前缀")

-- 密码含+号
p = sp_at.parse("12+34+ST?", "12+34")
eq(p.cmd, "ST", "含+号密码正常匹配")

-- trim 工具
eq(sp_at.trim("  x  "), "x", "trim基本")
eq(sp_at.trim("　x　"), "x", "trim全角空格")

print(string.format("PASS sp_at_test (%d assertions)", n))
