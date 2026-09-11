--[[
sp_auth 鉴权单元测试：号码归一化、白名单匹配、门禁组合。
]]

local sp_auth = require "sp_auth"

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end

-- 号码归一化
eq(sp_auth.normalize_number("+8613800138000"), "13800138000", "+86前缀归一化")
eq(sp_auth.normalize_number("13800138000"), "13800138000", "11位原样")
eq(sp_auth.normalize_number("10086"), "10086", "短号保留")
eq(sp_auth.normalize_number("abc"), nil, "无数字无效")
eq(sp_auth.normalize_number(nil), nil, "nil无效")
eq(sp_auth.normalize_number(" 86 138-0013-8000 "), "13800138000", "混杂字符归一化")

-- 白名单匹配
local cfg = { wl_on = true, whitelist = { "13800138000" } }
eq(sp_auth.in_whitelist(cfg, "+8613800138000"), true, "白名单命中(+86形式)")
eq(sp_auth.in_whitelist(cfg, "13800138000"), true, "白名单命中(裸号)")
eq(sp_auth.in_whitelist(cfg, "13900139000"), false, "白名单未命中")
eq(sp_auth.in_whitelist({ wl_on = true, whitelist = {} }, "13800138000"), false, "空白名单")

-- 门禁组合（密码门禁由解析器强制，这里只测白名单门禁）
eq((sp_auth.check(cfg, "13800138000")), true, "白名单开+在名单→放行")
eq((sp_auth.check(cfg, "13900139000")), false, "白名单开+不在名单→拒绝")
local off = { wl_on = false, whitelist = {} }
eq((sp_auth.check(off, "13900139000")), true, "白名单关→放行")
eq((sp_auth.check(off, "任意号码")), true, "白名单关→任意放行")

print(string.format("PASS sp_auth_test (%d assertions)", n))
