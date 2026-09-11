--[[
sp_sim_guard 单元测试：ICCID 绑定、换卡复位、无卡开机计数。
通过 MOCKS.mobile.iccid 直接模拟插拔卡，无需重装桩/重载模块。
]]

local sp_config    = require "sp_config"
local sp_sim_guard = require "sp_sim_guard"

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end

--------------------------------------------------------------------------
-- 首次插卡：仅绑定
--------------------------------------------------------------------------

eq(sp_config.get().iccid, "", "初始无绑定")

-- ICCID 不可读：跳过
sp_sim_guard.check_iccid()
eq(sp_config.get().iccid, "", "ICCID不可读时保持不变")

MOCKS.mobile.iccid = "8986AAAA1111"
sp_sim_guard.check_iccid()
eq(sp_config.get().iccid, "8986AAAA1111", "首次插卡绑定ICCID")
eq(sp_config.get().nosim_cnt, 0, "计数保持0")

-- 同卡重复比对：无副作用
sp_sim_guard.check_iccid()
eq(sp_config.get().iccid, "8986AAAA1111", "同卡重复比对无副作用")

--------------------------------------------------------------------------
-- 未初始化换卡：仅更新绑定
--------------------------------------------------------------------------

MOCKS.mobile.iccid = "8986BBBB2222"
sp_sim_guard.check_iccid()
eq(sp_config.get().iccid, "8986BBBB2222", "未初始化换卡仅更新绑定")

--------------------------------------------------------------------------
-- 已初始化换卡：触发恢复出厂并绑定新卡
--------------------------------------------------------------------------

local cfg = sp_config.get()
cfg.initialized = true
cfg.password = "8888"
table.insert(cfg.whitelist, "13800138000")
sp_config.save()

MOCKS.mobile.iccid = "8986CCCC3333"
sp_sim_guard.check_iccid()
eq(sp_config.get().initialized, false, "已初始化换卡触发恢复出厂")
eq(sp_config.get().password, "", "复位清空密码")
eq(#sp_config.get().whitelist, 0, "复位清空白名单")
eq(sp_config.get().iccid, "8986CCCC3333", "复位后绑定新卡")

--------------------------------------------------------------------------
-- 无卡开机计数：第 3 次触发恢复出厂
--------------------------------------------------------------------------

cfg = sp_config.get()
cfg.initialized = true
table.insert(cfg.whitelist, "13800138000")
sp_config.save()

local cnt, reset = sp_sim_guard.handle_no_sim_boot()
eq(cnt, 1, "第1次无卡开机")
eq(reset, false, "第1次不复位")
eq(sp_config.get().nosim_cnt, 1, "计数已持久化")

cnt, reset = sp_sim_guard.handle_no_sim_boot()
eq(cnt, 2, "第2次无卡开机")
eq(reset, false, "第2次不复位")

cnt, reset = sp_sim_guard.handle_no_sim_boot()
eq(cnt, 3, "第3次无卡开机")
eq(reset, true, "第3次触发恢复出厂")
eq(sp_config.get().initialized, false, "复位后未初始化")
eq(sp_config.get().nosim_cnt, 0, "计数随复位清零")

--------------------------------------------------------------------------
-- 插卡清零计数
--------------------------------------------------------------------------

sp_config.save_nosim(2)
MOCKS.mobile.iccid = "8986DDDD4444"
sp_sim_guard.check_iccid()
eq(sp_config.get().nosim_cnt, 0, "插卡后计数清零")

print(string.format("PASS sp_sim_guard_test (%d assertions)", n))
