--[[
@module  sp_at
@summary SmsPigeon AT 风格短信命令解析器（纯逻辑，零硬件依赖）
@version 1.1
@date    2026.09.11
@usage
把一条短信文本解析为结构化命令。语法保留 AT 命令风格（?/=），但前缀为中文
"鸽"——运营商/物联网卡平台可能过滤 "AT" 开头的机器特征短信，中文前缀可规避：

    鸽+CMD?          查询（read）
    鸽+CMD=A,B,C     设置（write，参数按英文逗号分隔）
    鸽+CMD           执行（exec）
    鸽+CMD=?         测试，返回用法说明（test）
    鸽               单独出现视为链路探测命令（cmd 为空串）

注意：AT 前缀已完全移除，"AT+X" 一律按普通短信处理（会被转发）。

密码模式：设置了密码后，命令的 "鸽" 前缀替换为密码，例如密码为 8888 时：
    8888+ST?
密码模式下不再接受默认前缀（避免密码保护被绕过），密码本身也不可设为
"AT" 或 "鸽"（sp_commands 层校验），否则等于把前缀公开。

解析规则：
- 命令名大小写不敏感，统一转为大写；参数保持原样（URL/密码区分大小写）；
- 前后空白（含换行/全角空格）会被剔除；
- 前缀后必须紧跟 "+"：因此"鸽子汤多少钱"这类正常短信不会被误判为命令；
- 解析失败返回 nil，调用方将其视为普通短信（走转发流程）。

本模块不接触任何硬件/系统 API，可在纯 Lua 环境下单元测试。
]]

local sp_at = {}

-- 默认命令前缀（UTF-8 多字节，#取得字节数，sub 按字节切分同样正确）
local PREFIX = "鸽"

-- 去除首尾空白字符（空格/制表符/回车/换行/全角空格）
function sp_at.trim(s)
    return (s:gsub("^[ \t\r\n　]+", ""):gsub("[ \t\r\n　]+$", ""))
end

--[[
解析短信文本。
参数：
  text    短信原文
  password 当前密码（"" 或 nil 表示密码模式关闭）
返回：
  成功: { cmd = "FWD", op = "read|write|exec|test", args = {...}, via_password = bool }
  失败: nil（不是命令）
]]
function sp_at.parse(text, password)
    if type(text) ~= "string" then return nil end
    local s = sp_at.trim(text)
    if s == "" then return nil end

    local rest         -- 前缀之后的部分
    local via_password = false

    if password and password ~= "" then
        -- 密码模式：必须以密码开头，且剩余部分为空或以"+"开头。
        -- 追加"+"约束是为了排除形如密码"12"、短信"12鸽+X"的歧义匹配。
        if s:sub(1, #password) == password then
            local r = s:sub(#password + 1)
            if r == "" or r:sub(1, 1) == "+" then
                rest, via_password = r, true
            end
        end
        -- 密码模式下默认前缀一律无效
        if not via_password then return nil end
    else
        if s:sub(1, #PREFIX) ~= PREFIX then return nil end
        rest = s:sub(#PREFIX + 1)
    end

    rest = sp_at.trim(rest)

    -- 裸前缀（"鸽" 或密码单独出现）：链路探测
    if rest == "" then
        return { cmd = "", op = "exec", args = {}, via_password = via_password }
    end

    if rest:sub(1, 1) ~= "+" then return nil end
    rest = rest:sub(2)

    -- 拆出命令名与操作类型
    local q = rest:find("?", 1, true)
    local e = rest:find("=", 1, true)
    local name, op, argstr
    if e and q == e + 1 and q == #rest then
        -- 鸽+CMD=? 测试形式（"?" 必须是最后一个字符）
        name, op = rest:sub(1, e - 1), "test"
    elseif q and q == #rest then
        -- 鸽+CMD? 查询形式（"?" 必须是最后一个字符）
        name, op = rest:sub(1, q - 1), "read"
    elseif e then
        -- 鸽+CMD=A,B 设置形式（参数中允许出现 "?"，如带查询串的 URL）
        name, op, argstr = rest:sub(1, e - 1), "write", rest:sub(e + 1)
    else
        -- 鸽+CMD 执行形式
        name, op = rest, "exec"
    end

    name = sp_at.trim(name):upper()
    if name == "" or not name:match("^[A-Z0-9_]+$") then return nil end

    -- 拆分参数：按英文逗号分隔，保留空参数（"鸽+PW=" 用于清空密码）
    local args = {}
    if argstr then
        for a in (argstr .. ","):gmatch("([^,]*),") do
            args[#args + 1] = sp_at.trim(a)
        end
    end

    return { cmd = name, op = op, args = args, via_password = via_password }
end

return sp_at