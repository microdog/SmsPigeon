--[[
sp_at 解析器单元测试：鸽+ 语法、密码模式、边界与非法输入。
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
local p = sp_at.parse("鸽+ST?", "")
eq(p.cmd, "ST", "查询命令名")
eq(p.op, "read", "查询操作")
eq(#p.args, 0, "查询无参数")

p = sp_at.parse("鸽+st?", "")
eq(p.cmd, "ST", "命令名大小写不敏感")

p = sp_at.parse("鸽+FWD=DING,SET,https://oapi.dingtalk.com/robot/send?access_token=abc", "")
eq(p.cmd, "FWD", "设置命令名")
eq(p.op, "write", "设置操作")
eq(p.args[1], "DING", "参数1")
eq(p.args[2], "SET", "参数2")
eq(p.args[3], "https://oapi.dingtalk.com/robot/send?access_token=abc", "URL参数保留原样")

p = sp_at.parse("鸽+ST", "")
eq(p.op, "exec", "执行操作")

p = sp_at.parse("鸽+ST=?", "")
eq(p.op, "test", "测试操作")

p = sp_at.parse("鸽", "")
eq(p.cmd, "", "裸前缀为探测命令")
eq(p.op, "exec", "探测为exec")

p = sp_at.parse("  鸽+ST? \r\n", "")
eq(p.cmd, "ST", "首尾空白被剔除")

p = sp_at.parse("　鸽+ST?", "")
eq(p.cmd, "ST", "全角空格被剔除")

-- 空参数（清除密码用）
p = sp_at.parse("鸽+PW=", "")
eq(p.op, "write", "空值仍是write")
eq(#p.args, 1, "空值产生1个空参数")
eq(p.args[1], "", "空参数值为空串")

-- 非命令
eq(sp_at.parse("hello", ""), nil, "普通短信")
eq(sp_at.parse("鸽子汤多少钱", ""), nil, "正常中文短信不误判")
eq(sp_at.parse("鸽+汤", ""), nil, "前缀后必须接合法命令名")
eq(sp_at.parse("鸽+", ""), nil, "+后无命令名")
eq(sp_at.parse("鸽+ST?a", ""), nil, "命令名含非法字符")
-- 全角归一（真机案例：中文输入法敲出 鸽+ST？ 全角问号）
p = sp_at.parse("鸽+ST？", "")
eq(p.cmd, "ST", "全角问号识别为查询")
eq(p.op, "read", "全角问号操作为read")

p = sp_at.parse("鸽＋ST?", "")
eq(p.cmd, "ST", "全角加号识别")

p = sp_at.parse("鸽＋ＳＴ？", "")
eq(p.cmd, "ST", "全角加号+全角命令名+全角问号")

p = sp_at.parse("鸽+WL＝ON", "")
eq(p.op, "write", "全角等号识别为设置")
eq(p.args[1], "ON", "全角等号参数正常")

p = sp_at.parse("鸽+FWD=SMS,ADD，13800138000", "")
eq(#p.args, 3, "全角逗号按分隔符拆分")
eq(p.args[3], "13800138000", "全角逗号参数内容正确")

p = sp_at.parse("８８８８+ST?", "8888")
eq(p.cmd, "ST", "全角数字密码匹配")
eq(p.via_password, true, "全角数字密码via_password")

eq(sp_at.parse("", ""), nil, "空串")
eq(sp_at.parse(nil, ""), nil, "nil输入")

-- AT 前缀已完全移除
eq(sp_at.parse("AT+ST?", ""), nil, "AT前缀不再识别")
eq(sp_at.parse("AT", ""), nil, "裸AT不再识别")
eq(sp_at.parse("at+st?", ""), nil, "小写at同样不识别")

-- 密码模式
p = sp_at.parse("8888+ST?", "8888")
eq(p.cmd, "ST", "密码前缀命令")
eq(p.via_password, true, "标记via_password")
eq(p.op, "read", "密码模式查询操作")

p = sp_at.parse("8888", "8888")
eq(p.cmd, "", "裸密码为探测命令")
eq(p.via_password, true, "裸密码via_password")

eq(sp_at.parse("鸽+ST?", "8888"), nil, "密码模式下默认前缀失效")
eq(sp_at.parse("8888鸽+ST?", "8888"), nil, "密码后必须紧跟+号")
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