--[[
@module  sp_at
@summary SmsPigeon 中文句子命令解析器（纯逻辑，零硬件依赖）
@version 2.0
@date    2026.09.11
@usage
把短信文本解析为结构化中文命令。前缀为"信鸽"，命令体为自然中文短语：

    信鸽                      链路探测
    信鸽，状态？              查询状态总览
    信鸽，初始化，<IMEI>      初始化（唯一免鉴权命令）
    信鸽，增加白名单，<号码>   白名单管理（号码支持中文数字）

背景：运营商/物联网卡平台会过滤机器特征短信（曾实测 鸽+FWD=SMS,ADD,号码
被拦而全中文句子可达），因此命令整体使用中文句子格式。

解析规则：
- 前缀"信鸽"后须为空或跟分隔符——"信鸽子汤"这类正常短信不会误判；
- 命令短语按"最长匹配"识别，具体短语后须为空或跟分隔符/句读，
  通用动词（开启/关闭/清空）后可直接拼接通道名（开启钉钉）；
- 参数以逗号分隔；冒号/空格保留在参数内（URL 的 "://"、
  分组号码 132-6257-5718 均不受影响）；
- 全角符号/数字/字母自动转半角，顿号句号归一为逗号，句尾 ？；！不算内容；
- 中文数字自动转阿拉伯数字（sp_at.digits）：一三二六→1326，支持幺/两/〇；
- 解析失败返回 nil（非命令，走转发流程）；前缀命中但短语未识别返回
  cmd=nil（按未知命令处理，不转发）。

密码模式：设置密码后，"信鸽"前缀替换为密码（密码支持中文），密码后须为空
或跟分隔符，如密码 8888 时发送 8888，状态。

实现注意（Lua UTF-8 地雷）：多字节字符严禁放入 [] 字符类——字符类是
字节集合，会误吃包含相同字节的汉字（"态"的 80/81 字节曾被 [、。] 吃掉）。
全角转半角用"EF BC + 单字节"序列模式，顿号句号用完整字面量，
中文数字用"一个 UTF-8 字符"通用模式逐字查表。

本模块不接触任何硬件/系统 API，可在纯 Lua 环境下单元测试。
]]

local sp_at = {}

-- 命令唤醒前缀
local PREFIX = "信鸽"

-- 分隔符：逗号(含归一后的、。)、冒号、空白、句读（？；！归一后为半角）
local SEP = "[,:%s;!?]"

-- 中文数字 → 阿拉伯数字（电话号码读法：逐位转换）
local CN_DIGIT = {
    ["零"] = "0", ["〇"] = "0",
    ["一"] = "1", ["幺"] = "1",
    ["二"] = "2", ["两"] = "2",
    ["三"] = "3", ["四"] = "4", ["五"] = "5",
    ["六"] = "6", ["七"] = "7", ["八"] = "8", ["九"] = "9",
}

--[[
全角 ASCII（！～，U+FF01-FF5E）转半角。
中文输入法常敲出全角符号（？＝＋，）与全角数字/大小写字母，统一归一
后再解析。UTF-8 编码分两段：U+FF01-FF3F = EF BC 81-BF（映射 -0x60），
U+FF40-FF5E = EF BD 80-9E（跨过 continuation 边界 0xBF/0x80，
映射 -0x20）。只匹配 EF BC 时全角小写 ａ-ｚ（EF BD 81-9A）永不归一。
]]
local function to_halfwidth(s)
    s = s:gsub("\239\188([\129-\191])", function(c)
        return string.char(string.byte(c) - 96)
    end)
    return (s:gsub("\239\189([\128-\158])", function(c)
        return string.char(string.byte(c) - 32)
    end))
end

-- 文本归一：全角转半角 + 顿号/句号归一为逗号 + 首尾空白剔除
local function normalize(s)
    s = to_halfwidth(s)
    s = s:gsub("、", ","):gsub("。", ",")
    return sp_at.trim(s)
end

--[[
中文数字转阿拉伯数字（逐字符）。
不能用 [] 收集多字节字符（字节集合地雷）：用"一个 UTF-8 字符"的
通用模式逐字查表，表外字符（nil）由 gsub 语义原样保留。
]]
function sp_at.cn_digits(s)
    return (s:gsub("[%z\1-\127\194-\244][\128-\191]*", CN_DIGIT))
end

--[[
提取数字串：中文数字转阿拉伯后剔除全部非数字。
号码可用横线/空格分组，可用中文数字书写，均可得到纯数字。
]]
function sp_at.digits(s)
    return sp_at.cn_digits(tostring(s)):gsub("%D", "")
end

-- 去除首尾空白字符：ASCII 空白用字符类，全角空格(U+3000)用完整字面量
function sp_at.trim(s)
    s = s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
    s = s:gsub("^　+", ""):gsub("　+$", "")
    return s
end

--[[
命令短语表：{ 短语, 命令标识, free }。
- 匹配按短语长度降序尝试（最长优先），"开启白名单" 先于通用动词 "开启"；
- free=true（通用动词）不要求短语后有分隔符，通道名可直接拼接；
- cmd 标识由 sp_commands 消费。
]]
local PHRASES = {
    -- 状态与信息
    { "帮助",         "HELP" },
    { "命令列表",     "HELP" },
    { "查看状态",     "ST" },
    { "查询状态",     "ST" },
    { "状态",         "ST" },
    { "调试",         "DBG" },
    { "版本",         "VER" },
    -- 初始化与复位
    { "初始化设备",   "INIT" },
    { "初始化",       "INIT" },
    { "恢复出厂设置", "RESET" },
    { "恢复出厂",     "RESET" },
    { "恢复默认",     "RESET" },
    { "重启模块",     "REBOOT" },
    { "重启",         "REBOOT" },
    -- 白名单
    { "查看白名单",   "WL_READ" },
    { "开启白名单",   "WL_ON" },
    { "关闭白名单",   "WL_OFF" },
    { "增加白名单",   "WL_ADD" },
    { "添加白名单",   "WL_ADD" },
    { "删除白名单",   "WL_DEL" },
    { "移除白名单",   "WL_DEL" },
    { "白名单",       "WL_READ" },
    -- 转发前缀
    { "设置前缀",     "PREFIX_SET" },
    -- 远程发短信（控制本机向指定号码发送一条短信）
    { "发送短信",     "SMS_SEND" },
    { "发短信",       "SMS_SEND" },
    -- 设备标识（多设备同群转发时区分来源）
    { "设置标识",     "IDENT_SET" },
    { "关闭标识",     "IDENT_OFF" },
    { "清除标识",     "IDENT_AUTO" },
    { "清空标识",     "IDENT_AUTO" },
    { "标识",         "IDENT_READ" },
    { "清除前缀",     "PREFIX_CLR" },
    { "清空前缀",     "PREFIX_CLR" },
    { "前缀",         "PREFIX_READ" },
    -- 密码
    { "设置密码",     "PW_SET" },
    { "清除密码",     "PW_CLR" },
    { "清空密码",     "PW_CLR" },
    -- 短信转发目标
    { "增加短信转发号码", "FWD_SMS_ADD" },
    { "添加短信转发号码", "FWD_SMS_ADD" },
    { "删除短信转发号码", "FWD_SMS_DEL" },
    { "移除短信转发号码", "FWD_SMS_DEL" },
    { "增加转发号码",     "FWD_SMS_ADD" },
    { "添加转发号码",     "FWD_SMS_ADD" },
    { "增加转发目标",     "FWD_SMS_ADD" },
    { "添加转发目标",     "FWD_SMS_ADD" },
    { "删除转发号码",     "FWD_SMS_DEL" },
    { "移除转发号码",     "FWD_SMS_DEL" },
    { "删除转发目标",     "FWD_SMS_DEL" },
    -- 通道配置
    { "查看转发",     "FWD_READ" },
    { "转发状态",     "FWD_READ" },
    { "设置钉钉",     "DING_SET" },
    { "配置钉钉",     "DING_SET" },
    { "设置飞书",     "FS_SET" },
    { "配置飞书",     "FS_SET" },
    { "设置企业微信", "WECOM_SET" },
    { "配置企业微信", "WECOM_SET" },
    { "设置Server酱", "SC_SET" },
    { "配置Server酱", "SC_SET" },
    { "转发",         "FWD_READ" },
    -- 通用通道动词（free：通道名可直接拼接，且降序保证最后才尝试）
    { "开启",         "CH_ON",  true },
    { "关闭",         "CH_OFF", true },
    { "清空",         "CH_CLR", true },
}

-- 按短语长度降序排列（最长优先匹配）
table.sort(PHRASES, function(a, b) return #a[1] > #b[1] end)

-- 匹配命令短语：命中返回 cmd 与短语后剩余文本，未命中返回 nil
local function match_phrase(body)
    for _, e in ipairs(PHRASES) do
        local ph, cmd, free = e[1], e[2], e[3]
        if body:sub(1, #ph) == ph then
            local nxt = body:sub(#ph + 1, #ph + 1)
            if free or nxt == "" or nxt:match(SEP) then
                return cmd, body:sub(#ph + 1)
            end
        end
    end
    return nil
end

--[[
解析短信文本。
参数：
  text     短信原文
  password 当前密码（"" 或 nil 表示密码模式关闭）
返回：
  成功: { cmd = "ST"|..., args = {...}, via_password = bool }（cmd 为空串=链路探测）
  前缀命中但短语未识别: { cmd = nil, args = {}, via_password = bool }
  失败: nil（不是命令，调用方按普通短信转发）
]]
function sp_at.parse(text, password)
    if type(text) ~= "string" then return nil end
    local s = normalize(text)
    if s == "" then return nil end

    local rest          -- 前缀之后的部分
    local via_password = false

    if password and password ~= "" then
        -- 密码模式：必须以密码开头，其后为空或跟分隔符
        -- （分隔符约束排除形如密码"12"、短信"12信鸽，X"的歧义匹配）
        if s:sub(1, #password) == password then
            local r = s:sub(#password + 1)
            if r == "" or r:sub(1, 1):match(SEP) then
                rest, via_password = r, true
            end
        end
        -- 密码模式下默认前缀一律无效
        if not via_password then return nil end
    else
        if s:sub(1, #PREFIX) ~= PREFIX then return nil end
        rest = s:sub(#PREFIX + 1)
        -- 前缀后必须为空或跟分隔符："信鸽子汤"这类正常短信不误判
        if rest ~= "" and not rest:sub(1, 1):match(SEP) then return nil end
    end

    -- 去掉前缀后的分隔符
    rest = rest:gsub("^" .. SEP .. "+", "")
    -- 裸前缀（"信鸽" 或密码单独出现）：链路探测
    if rest == "" then
        return { cmd = "", args = {}, via_password = via_password }
    end

    local cmd, after = match_phrase(rest)
    if not cmd then
        -- 前缀命中但短语未识别：按未知命令处理（不进入转发）
        return { cmd = nil, args = {}, via_password = via_password }
    end

    -- 提取参数：去掉短语后的分隔符，按逗号拆分（保留参数内的冒号与空格）
    after = after:gsub("^" .. SEP .. "+", "")
    local args = {}
    if after ~= "" then
        for a in (after .. ","):gmatch("([^,]*),") do
            args[#args + 1] = sp_at.trim(a)
        end
    end

    return { cmd = cmd, args = args, via_password = via_password }
end

return sp_at