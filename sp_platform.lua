--[[
@module  sp_platform
@summary SmsPigeon 平台适配层（唯一允许接触硬件/系统差异 API 的模块）
@version 1.1
@date    2026.09.11
@usage
本模块集中封装与模组硬件/固件相关的系统 API 访问：
IMEI/ICCID/信号查询、重启、模块型号、短信发送（send_sms/send_sms_sync）。
业务模块只调用本模块的抽象接口，不直接调用 mobile/rtos/sms 发送，
从而在适配新的 LuatOS 模组（Air780EPM/Air780EHM 等）时只需修改本模块。

当前适配：Air780EHV（LuatOS，仅 Lua 二次开发，无 AT 固件）。
移植说明见 docs/codebase-map.md 与 README「二次开发」章节。

注意：本模块函数都在调用时才访问全局 API；例外是短信收发就绪广播
（SMS_READY/CC_IND，开机一次性广播，晚订阅永远错过）与 sms.debug，
这两者在模块加载期订阅/设置，sys/sms 不存在的纯 Lua 环境自动跳过。
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

-- 本机手机号 MSISDN（标识自动取尾号用），SIM 未写号码或未就绪返回 ""
-- mobile.number(0) 在 SIM 就绪后返回卡内号码；物联网卡常不写 MSISDN，此时为空
function sp_platform.msisdn()
    if mobile and mobile.number then
        local s = mobile.number(0)
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
-- 短信发送出口（系统 sms API 的唯一发送路径）
--------------------------------------------------------------------------

-- 内核短信调试日志（PDU 级，含短信全文）：默认关闭——开启后收发
-- 内容会落入日志。排障时用 信鸽，调试，开 临时打开，重启自动复位
local sms_debug_on = false
local function apply_sms_debug()
    if sms and sms.debug then sms.debug(sms_debug_on) end
end

function sp_platform.set_sms_debug(on)
    sms_debug_on = (on == true)
    apply_sms_debug()
end

function sp_platform.sms_debug_on()
    return sms_debug_on
end

apply_sms_debug()

-- 短信收发是否就绪（就绪后缓存，避免重复等待）
local sms_ready = false

-- 开机即订阅：捕获一次性的 SMS_READY/CC_IND 广播
if sys and sys.subscribe then
    sys.subscribe("SMS_READY", function() sms_ready = true end)
    sys.subscribe("CC_IND", function() sms_ready = true end)
end

-- 等待短信收发就绪：优先 SMS_READY（新内核固件），回退 CC_IND；
-- 就绪标志已被开机订阅置位时立即返回；都未广播时超时后仍尝试发送
local function ensure_sms_ready()
    if sms_ready then return true end
    if not (sys and sys.waitUntil) then return true end
    if sys.waitUntil("SMS_READY", 10000) then
        sms_ready = true
    elseif sys.waitUntil("CC_IND", 20000) then
        sms_ready = true
    else
        log.warn("sp_platform", "等待短信就绪超时，仍尝试发送")
    end
    return sms_ready
end

-- 发送互斥：短信 modem 同一时刻只允许一个在途发送。并发出栈
-- （命令应答与远程发短信同时触发、转发与应答交叠）会撞上
-- 内核 "sms is busy"，后者提交失败丢消息——真机实测曾丢命令应答。
local send_lock = false

-- 核心发送（调用方已持锁）
local function core_send(num, text)
    ensure_sms_ready()
    if not sms.send(num, text) then
        log.warn("sp_platform", "短信提交失败 ->", num)
        return false
    end
    if not (sys and sys.waitUntil) then return true end
    local got, result, _, rp_cause_str, _, error_code =
        sys.waitUntil("SMS_SENT", 10000)
    if got and result then
        log.info("sp_platform", "短信 ->", num, "发送成功")
        return true
    elseif got then
        log.warn("sp_platform", "短信 ->", num, "发送失败",
            "error_code=" .. tostring(error_code), tostring(rp_cause_str))
        return false
    end
    log.warn("sp_platform", "短信 ->", num, "结果超时,视为已提交")
    return true
end

--[[
同步发送一条短信：就绪等待 + 提交 + SMS_SENT 结果等待与日志。
返回 true 表示提交成功且未收到失败事件（SMS_SENT 超时视为成功：
旧固件无此事件）；false 表示提交失败或收到明确失败事件。
必须在任务上下文（sys.taskInit 内）调用；多个发送自动串行化
（等待在途发送完成后才提交下一条）。
真实投递结果由 SMS_SENT 事件携带：result, rp_cause, rp_cause_str,
msg_ref, error_code（error_code：0成功 331无网络/SIM未开通短信
332网络超时 500未知 等，详见 docs.openluat.com/osapi/core/sms）
]]
function sp_platform.send_sms_sync(num, text)
    if not (sms and sms.send) then
        log.warn("sp_platform", "sms.send 不可用")
        return false
    end
    -- 串行化：等待在途发送完成（sys.wait 让出调度，20ms 重查）
    while send_lock and sys and sys.wait do sys.wait(20) end
    send_lock = true
    local ok, res = pcall(core_send, num, text)
    send_lock = false
    if not ok then
        log.warn("sp_platform", "短信发送异常 ->", num, tostring(res))
        return false
    end
    return res
end

-- 异步发送一条短信（独立任务，不阻塞短信接收回调）：
-- 命令应答与远程发短信等场合使用
function sp_platform.send_sms(num, text)
    if sys and sys.taskInit then
        sys.taskInit(function()
            sp_platform.send_sms_sync(num, text)
        end)
    else
        sp_platform.send_sms_sync(num, text)
    end
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