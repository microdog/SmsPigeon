--[[
@module  test/run_tests
@summary SmsPigeon 单元测试入口（纯 Lua 5.3，不依赖 LuatOS 固件）
@version 1.0
@date    2026.09.11
@usage
运行方式：
  - Linux/CI:      lua5.3 test/run_tests.lua
  - Windows 本地:  python test/run_with_lupa.py （经 lupa 内嵌 Lua 运行时）

每个测试文件在独立环境中执行：重装 mocks、清空 sp_* 模块缓存，
避免测试间状态串扰。全部通过返回退出码 0。
]]

local dir = (arg and arg[0] or "test/run_tests.lua"):match("^(.*)[/\\]") or "."
package.path = dir .. "/?.lua;" .. dir .. "/../?.lua;" .. package.path

local mocks = dofile(dir .. "/mocks.lua")

local TESTS = {
    "sp_at_test",
    "sp_auth_test",
    "sp_config_test",
    "sp_commands_test",
    "sp_sim_guard_test",
    "main_smoke_test",
}

local failed = {}
for _, name in ipairs(TESTS) do
    mocks.install({ imei = "860123456789012" })
    for k in pairs(package.loaded) do
        if k:match("^sp_") then package.loaded[k] = nil end
    end
    local ok, err = pcall(dofile, dir .. "/" .. name .. ".lua")
    if ok then
        print("== " .. name .. " PASS")
    else
        print("== " .. name .. " FAIL:\n" .. tostring(err))
        failed[#failed + 1] = name
    end
end

print(string.format("\n%d/%d 个测试文件通过", #TESTS - #failed, #TESTS))
if __LUPA__ then
    __TESTS_FAILED__ = #failed   -- lupa 环境不能 os.exit，交由 Python 侧处理
else
    os.exit(#failed > 0 and 1 or 0)
end
