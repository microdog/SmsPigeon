--[[
@module  sp_at
@summary SmsPigeon AT 风格短信命令解析器（纯逻辑，零硬件依赖）
@version 1.0
@date    2026.09.11
@usage
把一条短信文本解析为结构化命令，语法参照标准 AT 命令：

    AT+CMD?          查询（read）
    AT+CMD=A,B,C     设置（write，参数按英文逗号分隔）
    AT+CMD           执行（exec）
    AT+CMD=?         测试，返回用法说明（test）
    AT               单独出现视为链路探测命令（cmd 为空串）

密码模式：设置了密码后，命令的 AT 前缀替换为密码，例如密码为 8888 时：
    8888+ST?
密码模式下不再接受 AT 前缀（避免密码保护被绕过）。

解析规则：
- 命令名大小写不敏感，统一转为大写；参数保持原样（URL/密码区分大小写）；
- 前后空白（含换行）会被剔除；
- 解析失败返回 nil，调用方将其视为普通短信（走转发流程）。

本模块不接触任何硬件/系统 API，可在纯 Lua 环境下单元测试。
]]

local sp_at = {}

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

    local rest        -- 前缀之后的部分
    local via_password = false

    if password and password ~= "" then
        -- 密码模式：必须以密码开头，且剩余部分为空或以"+"开头。
        -- 追加"+"约束是为了排除形如密码"12"、短信"12AT+X"的歧义匹配。
        if s:sub(1, #password) == password then
            local r = s:sub(#password + 1)
            if r == "" or r:sub(1, 1) == "+" then
                rest, via_password = r, true
            end
        end
        -- 密码模式下 AT 前缀一律无效
        if not via_password then return nil end
    else
        if s:sub(1, 2):upper() ~= "AT" then return nil end
        rest = s:sub(3)
    end

    rest = sp_at.trim(rest)

    -- 裸前缀（"AT" 或密码单独出现）：链路探测
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
        -- AT+CMD=? 测试形式（"?" 必须是最后一个字符）
        name, op = rest:sub(1, e - 1), "test"
    elseif q and q == #rest then
        -- AT+CMD? 查询形式（"?" 必须是最后一个字符）
        name, op = rest:sub(1, q - 1), "read"
    elseif e then
        -- AT+CMD=A,B 设置形式（参数中允许出现 "?"，如带查询串的 URL）
        name, op, argstr = rest:sub(1, e - 1), "write", rest:sub(e + 1)
    else
        -- AT+CMD 执行形式
        name, op = rest, "exec"
    end

    name = sp_at.trim(name):upper()
    if name == "" or not name:match("^[A-Z0-9_]+$") then return nil end

    -- 拆分参数：按英文逗号分隔，保留空参数（"AT+PW=" 用于清空密码）
    local args = {}
    if argstr then
        for a in (argstr .. ","):gmatch("([^,]*),") do
            args[#args + 1] = sp_at.trim(a)
        end
    end

    return { cmd = name, op = op, args = args, via_password = via_password }
end

return sp_at
