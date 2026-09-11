--[[
@module  sp_net
@summary SmsPigeon 网络就绪与 NTP 时间同步模块
@version 1.0
@date    2026.09.11
@usage
1. Air780EHV 内核固件启动后默认网卡即为 4G（socket.LWIP_GP），无需额外
   网卡初始化；这里在 IP_READY 时追加两个国内公共 DNS，提升解析稳定性；
2. 钉钉/飞书 Webhook 加签依赖准确的系统时间，联网成功后通过 SNTP 对时，
   成功后每小时校准一次，失败 10 秒后重试；
3. 其余模块通过等待 "IP_READY" 系统消息感知联网状态。
]]

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
