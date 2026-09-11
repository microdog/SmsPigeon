--[[
@module  sp_sim_guard
@summary SmsPigeon SIM 卡守护（换卡复位 + 连续无卡开机计数复位）
@version 1.0
@date    2026.09.11
@usage
安全策略（丢失/被盗场景的配置自毁）：

1. 换卡检测：SIM 卡就绪后读取 ICCID，与上次绑定的 ICCID 比对；
   不一致且固件已初始化 → 恢复出厂设置（配置与白名单全部清空），
   随后绑定新卡 ICCID。未初始化时只静默更新绑定，不触发复位。
2. 连续无卡开机计数：开机后 15 秒内未检测到 SIM 卡视为一次无卡开机；
   计数持久化保存，第 3 次触发恢复出厂设置并清零；
   任意一次检测到卡则计数清零。
3. 热插拔：开机检测结束后继续监听 SIM_IND，插卡时重新做换卡比对。

注意：ICCID 绑定在首次插卡时即建立（不要求已初始化），因此
"换卡→初始化→再换回第一张卡"同样会触发复位。

核心判定逻辑导出为 check_iccid / handle_no_sim_boot 两个纯函数，
由 boot_task 任务调用，便于单元测试（test/sp_sim_guard_test.lua）。
]]

local sp_config   = require "sp_config"
local sp_platform = require "sp_platform"

local sp_sim_guard = {}

--[[
SIM 就绪后的 ICCID 比对（开机与热插拔共用）。
绑定规则：首次插卡即绑定；换卡且已初始化 → 恢复出厂；
换卡但未初始化 → 仅更新绑定。
]]
function sp_sim_guard.check_iccid()
    local cur = sp_platform.iccid()
    if cur == "" then return end   -- 读不到 ICCID，跳过本次比对

    local cfg = sp_config.get()
    if cfg.iccid ~= "" and cfg.iccid ~= cur then
        if cfg.initialized then
            log.warn("sp_sim_guard", "检测到 SIM 卡变更，执行恢复出厂")
            sp_config.factory_reset()
        else
            log.info("sp_sim_guard", "SIM 卡变更（未初始化，仅更新绑定）")
        end
    end
    -- 绑定当前卡（factory_reset 后 cfg 引用已失效，重新获取）
    if sp_config.get().iccid ~= cur then
        sp_config.save_iccid(cur)
        log.info("sp_sim_guard", "已绑定 ICCID", cur)
    end
    -- 有卡时清零无卡开机计数
    if sp_config.get().nosim_cnt ~= 0 then
        sp_config.save_nosim(0)
    end
end

--[[
无卡开机处理：计数 +1 并持久化；达到 3 次恢复出厂（计数随复位清零）。
返回：计数值, 是否触发了恢复出厂
]]
function sp_sim_guard.handle_no_sim_boot()
    local cnt = (sp_config.get().nosim_cnt or 0) + 1
    if cnt >= 3 then
        log.warn("sp_sim_guard", "连续第 3 次无卡开机，执行恢复出厂")
        sp_config.factory_reset()
        return cnt, true
    end
    sp_config.save_nosim(cnt)
    log.warn("sp_sim_guard", "无卡开机", cnt, "/3")
    return cnt, false
end

-- 开机检测任务：确定卡在位与否，执行对应守护动作，之后转入热插拔监听
local function boot_task()
    -- 阶段一：开机后最多等 15 秒，观察 SIM_IND 事件确定卡状态
    local present = nil
    local function on_boot_ind(status)
        if present ~= nil then return end
        if status == "RDY" then present = true
        elseif status == "NORDY" then present = false end
    end
    sys.subscribe("SIM_IND", on_boot_ind)
    sys.wait(15000)
    sys.unsubscribe("SIM_IND", on_boot_ind)

    -- 没等到事件：用 ICCID 是否可读兜底判断
    if present == nil then
        present = sp_platform.iccid() ~= ""
    end

    if present then
        sp_sim_guard.check_iccid()
        log.info("sp_sim_guard", "SIM 卡就绪，绑定/比对完成")
    else
        sp_sim_guard.handle_no_sim_boot()
    end

    -- 阶段二：持续监听热插拔；插卡后稍等 ICCID 可读再比对。
    -- 回调由调度器直接调用，禁止 sys.wait——用定时器延后比对
    -- （check_iccid 幂等，重复 RDY 多次触发无害）
    local function on_hotplug(status)
        if status == "RDY" then
            sys.timerStart(sp_sim_guard.check_iccid, 2000)
        end
    end
    sys.subscribe("SIM_IND", on_hotplug)
end

sys.taskInit(boot_task)

return sp_sim_guard
