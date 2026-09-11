--[[
@module  sp_net
@summary SmsPigeon 网络就绪与 NTP 时间同步模块
@version 1.1
@date    2026.09.11
@usage
1. Air780EHV 内核固件启动后默认网卡即为 4G（socket.LWIP_GP），无需额外
   网卡初始化；这里在 IP_READY 时追加两个国内公共 DNS，提升解析稳定性；
2. 钉钉/飞书 Webhook 加签依赖准确的系统时间，联网成功后通过 SNTP 对时，
   成功后每小时校准一次，失败 10 秒后重试；
3. 其余模块通过等待 "IP_READY" 系统消息感知联网状态；
4. 网络失联自愈：每 5 分钟轮询注册状态，连续 30 分钟未注册（模组
   4G 假死等）直接重启。不加触发次数上限——重启本身即恢复手段，
   长期无信号场景反复重启无害（开机后 30 分钟才首次触发，弱信号
   环境注册慢也有充足窗口）。
]]

local sp_net = {}

-- IP 就绪时设置公共 DNS（阿里 + 通用），专网卡/海外卡场景请自行调整
local function ip_ready_func(ip, adapter)
    if adapter == socket.LWIP_GP then
        socket.setDNS(adapter, 1, "223.5.5.5")
        socket.setDNS(adapter, 2, "114.114.114.114")
        log.info("sp_net", "IP_READY", ip)
    end
end

sys.subscribe("IP_READY", ip_ready_func)

-- NTP 对时任务
local function ntp_task()
    while true do
        -- 等待默认联网网卡就绪
        while not socket.adapter(socket.dft()) do
            sys.waitUntil("IP_READY", 1000)
        end
        -- 发起 SNTP，等待同步结果（正常几百毫秒内完成）
        socket.sntp()
        local ok = sys.waitUntil("NTP_UPDATE", 30000)
        if ok then
            log.info("sp_net", "NTP 对时成功", os.date())
            sys.wait(3600000)   -- 成功后 1 小时校准一次
        else
            log.warn("sp_net", "NTP 对时失败，10 秒后重试")
            sys.wait(10000)
        end
    end
end

sys.taskInit(ntp_task)

--------------------------------------------------------------------------
-- 网络失联自愈：轮询注册状态，连续 30 分钟未注册 → 重启模组
--------------------------------------------------------------------------
local sp_platform = require "sp_platform"

local NET_POLL_MS   = 300000   -- 轮询周期：5 分钟
local NET_LOSS_LIMIT = 6       -- 连续失败阈值：6 × 5 分钟 = 30 分钟

local net_fail = 0

-- 单次轮询（导出供单元测试驱动；返回本次是否已注册）
function sp_net.net_watch()
    if sp_platform.registered() then
        net_fail = 0
        return true
    end
    net_fail = net_fail + 1
    log.warn("sp_net", "网络未注册", net_fail .. "/" .. NET_LOSS_LIMIT)
    if net_fail >= NET_LOSS_LIMIT then
        -- 先复位计数再重启：重启失败/测试环境下不会立刻再次触发
        net_fail = 0
        log.error("sp_net", "连续 30 分钟无网络注册,重启自愈")
        sp_platform.reboot()
    end
    return false
end

if sys and sys.timerLoop then
    sys.timerLoop(sp_net.net_watch, NET_POLL_MS)
end

return sp_net
