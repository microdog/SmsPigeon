--[[
@module  sp_heartbeat
@summary SmsPigeon 心跳报平安（定时向转发目标推送在线状态摘要）
@version 1.0
@date    2026.09.11
@usage
按配置间隔向全部已启用的转发目标推送一条"模块在线"心跳，附信号/
累计转发的统计摘要。解决无人值守部署的最大运维痛点：设备断网/
死机是"静默死亡"，没有心跳就几天后才发现。

要点：
1. 默认关闭（hb_hours=0），需 信鸽，设置心跳，<小时> 显式开启；
   间隔 1-168 小时；发送方与转发目标一致——短信通道启用时心跳
   计话费，纯 webhook 通道免费（README 有说明）；
2. 只在已初始化且开关 >0 时布防；布防点：开机加载、初始化成功、
   心跳命令变更（restart 重建定时器）；
3. 心跳文案由 sp_forward.notify_hb 走统一转发队列（kind="hb"），
   与短信/来电共用限速与洪泛保护；状态摘要取 sp_forward.stats()；
4. 定时器周期毫秒数上限：168h ≈ 6×10^8 ms，在 32 位安全范围内；
5. sp_forward 在 beat 内惰性 require：避免 sp_commands→本模块→
   sp_forward→sp_commands 的加载期循环依赖。
]]

local sp_config   = require "sp_config"
local sp_platform = require "sp_platform"

local sys = sys
local log = log

local sp_heartbeat = {}

local HB_MIN_H, HB_MAX_H = 1, 168   -- 间隔上下限（小时）

-- 间隔合法性（cmd 校验与布防共用）
function sp_heartbeat.valid_hours(h)
    return type(h) == "number" and h >= HB_MIN_H and h <= HB_MAX_H
        and h == math.floor(h)
end

-- 心跳回调：到期时再校验一次开关与初始化状态（期间可能已变更）
local function beat()
    local cfg = sp_config.get()
    if not (cfg.initialized and sp_heartbeat.valid_hours(cfg.hb_hours)) then
        return
    end
    -- 惰性加载：避开 sp_commands→本模块→sp_forward 的加载期循环
    local sp_forward = require "sp_forward"
    local st = sp_forward.stats()
    sp_forward.notify_hb(string.format(
        "信号:%d\n累计转发:%d 失败:%d 丢弃:%d 过滤:%d\n待发:%d",
        sp_platform.csq(), st.sent, st.fail, st.dropped, st.filtered, st.pending))
    log.info("sp_heartbeat", "心跳已推送,间隔", cfg.hb_hours, "小时")
end

-- 按当前配置（重）布防心跳定时器：关/未初始化时撤防
function sp_heartbeat.restart()
    if sys and sys.timerStop then sys.timerStop(beat) end
    local cfg = sp_config.get()
    if sys and sys.timerLoop and cfg.initialized
        and sp_heartbeat.valid_hours(cfg.hb_hours) then
        sys.timerLoop(beat, cfg.hb_hours * 3600 * 1000)
        log.info("sp_heartbeat", "心跳已布防,间隔", cfg.hb_hours, "小时")
    end
end

-- 开机按已存配置布防（未初始化/默认关时为空操作）
if sys and sys.timerLoop then
    sp_heartbeat.restart()
end

return sp_heartbeat