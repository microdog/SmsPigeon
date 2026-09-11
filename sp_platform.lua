--[[
@module  sp_platform
@summary SmsPigeon 平台适配层（唯一允许接触硬件差异 API 的模块）
@version 1.0
@date    2026.09.11
@usage
本模块集中封装与模组硬件/固件相关的系统 API 访问：
IMEI/ICCID/信号查询、重启、模块型号等。业务模块只调用本模块的抽象接口，
不直接调用 mobile/rtos，从而在适配新的 LuatOS 模组（Air780EPM/Air780EHM 等）时
只需修改/新增本模块。

当前适配：Air780EHV（LuatOS，仅 Lua 二次开发，无 AT 固件）。
移植说明见 docs/codebase-map.md 与 README「二次开发」章节。

注意：本模块所有函数都在调用时才访问全局 API（不在加载期触碰），
方便在纯 Lua 测试环境中用 mock 替换。
]]

local sp_platform = {}

-- 平台标识（状态查询与日志用）
sp_platform.NAME = "air780ehv"

-- 本机 IMEI（IMEI 鉴权初始化用），取不到返回 ""
function sp_platform.imei()
    if mobile and mobile.imei then
        return mobile.imei() or ""
    end
    return ""
end

-- 当前 SIM 卡 ICCID（换卡检测用），取不到返回 ""
function sp_platform.iccid()
    if mobile and mobile.iccid then
        local s = mobile.iccid(0)
        if type(s) ~= "string" then return "" end
        return (s:gsub("%s", ""))
    end
    return ""
end

-- 网络是否已注册（含漫游）
function sp_platform.registered()
    if mobile and mobile.status and mobile.REGISTERED then
        local s = mobile.status()
        return s == mobile.REGISTERED or s == mobile.REGISTERED_ROAMING
    end
    return false
end

--------------------------------------------------------------------------
-- 板级状态灯（NET 灯）
--------------------------------------------------------------------------

-- Air780Exx 整机开发板 V1.4 的 NET 状态灯由模组 GPIO27 控制
-- （高电平点亮：GPIO → 4.7k 电阻 → NPN MMBT3904 → LED）。
-- 核心板没有此灯，置 nil 即关闭状态灯功能（sp_led 模块自动停用）；
-- 其它板型若灯的逻辑相反，改 LED_ACTIVE_HIGH 为 false。
sp_platform.LED_GPIO = 27
sp_platform.LED_ACTIVE_HIGH = true

-- 信号强度 CSQ（状态查询用）
function sp_platform.csq()
    if mobile and mobile.csq then
        return mobile.csq() or 0
    end
    return 0
end

-- 模组型号字符串
function sp_platform.model()
    if rtos and rtos.bsp then
        return rtos.bsp() or sp_platform.NAME
    end
    return sp_platform.NAME
end

-- 重启模组
function sp_platform.reboot()
    if rtos and rtos.reboot then
        rtos.reboot()
    end
end

return sp_platform
