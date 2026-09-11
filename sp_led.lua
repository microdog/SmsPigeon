--[[
@module  sp_led
@summary SmsPigeon 状态灯模块（整机开发板 NET 灯，默认 GPIO27）
@version 1.0
@date    2026.09.11
@usage
Air780Exx 整机开发板 V1.4 的 NET 状态灯由模组 GPIO27 控制（高电平点亮），
官方手册明确其"工作逻辑由用户自定义"，本模块定义如下指示语义：

  快闪（约2Hz）     网络未注册/无 SIM —— 异常，需要关注
  慢心跳（2s周期）   网络已注册但固件未初始化 —— 等待 AT+INIT
  常亮              已初始化且已注册 —— 正常工作中
  三连闪            收到一条短信（活动指示，由 sp_forward 触发，优先于状态模式）

引脚与极性在 sp_platform.lua 配置（LED_GPIO / LED_ACTIVE_HIGH）；
核心板没有此灯，置 LED_GPIO = nil 后本模块自动停用。
纯逻辑函数 pattern_for 可单元测试；闪烁任务在 sys 调度下常驻运行。
]]

local sp_platform = require "sp_platform"
local sp_config   = require "sp_config"

local sp_led = {}

-- 引脚与亮灭电平（按极性换算）
local PIN = sp_platform.LED_GPIO
local ON  = sp_platform.LED_ACTIVE_HIGH and 1 or 0
local OFF = sp_platform.LED_ACTIVE_HIGH and 0 or 1

-- 活动闪烁请求计数（收到短信时 +1，闪烁任务消费）
local blink_req = 0

--[[
纯函数：根据（网络已注册, 固件已初始化）返回指示模式。
返回 "fast"（未注册快闪）/ "slow"（待初始化心跳）/ "on"（正常常亮）。
]]
function sp_led.pattern_for(registered, initialized)
    if not registered then return "fast" end
    if not initialized then return "slow" end
    return "on"
end

-- 请求一次活动闪烁（收到短信时调用；未启用状态灯时为无害空操作）
function sp_led.blink()
    blink_req = blink_req + 1
end

local function led_task()
    gpio.setup(PIN, OFF)
    log.info("sp_led", "状态灯已启用 GPIO" .. tostring(PIN))
    while true do
        if blink_req > 0 then
            -- 活动指示：三连闪，优先于状态模式
            blink_req = 0
            for _ = 1, 3 do
                gpio.set(PIN, ON)
                sys.wait(80)
                gpio.set(PIN, OFF)
                sys.wait(80)
            end
        else
            local pattern = sp_led.pattern_for(
                sp_platform.registered(), sp_config.get().initialized)
            if pattern == "on" then
                -- 正常：常亮，每 500ms 重估一次状态并响应闪烁请求
                gpio.set(PIN, ON)
                sys.wait(500)
            elseif pattern == "slow" then
                -- 等待初始化：2 秒周期心跳短亮
                gpio.set(PIN, ON)
                sys.wait(100)
                gpio.set(PIN, OFF)
                sys.wait(1900)
            else
                -- 网络异常：约 2Hz 快闪（亮150ms/灭150ms，两拍后歇550ms）
                gpio.set(PIN, ON)
                sys.wait(150)
                gpio.set(PIN, OFF)
                sys.wait(150)
                gpio.set(PIN, ON)
                sys.wait(150)
                gpio.set(PIN, OFF)
                sys.wait(550)
            end
        end
    end
end

if PIN and gpio and gpio.setup then
    sys.taskInit(led_task)
else
    log.info("sp_led", "未配置状态灯（LED_GPIO 为空或无 gpio 库），模块停用")
end

return sp_led