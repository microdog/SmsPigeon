--[[
@module  sp_chan_sms
@summary SmsPigeon 转发通道：短信（转发到指定手机号）
@version 1.3
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.sms）：
  { on = true, targets = { "13800138000", ... } }

不依赖蜂窝数据网络（PS 域），短信通道是唯一离线可用的转发方式，
因此在注册顺序中放在最前。发送走 sp_platform.send_sms_sync
（含短信就绪等待与 SMS_SENT 结果日志）。

防环两层：发送前跳过等于本机 MSISDN 的目标；转发末尾附加防环
实例标记（msg.mark，随机 8 位十六进制），sp_forward 收到含本机
标记的短信直接丢弃。
]]

local sp_channels = require "sp_channels"
local sp_platform = require "sp_platform"
local sp_auth     = require "sp_auth"

local ch = {}

ch.key = "sms"
ch.name = "短信"
ch.needs_net = false

function ch.is_configured(chcfg)
    return type(chcfg.targets) == "table" and #chcfg.targets > 0
end

function ch.send(msg, chcfg)
    -- 短信通道刻意压缩格式，节省短信条数（不含时间戳）；
    -- msg.prefix 为用户自定义前缀，默认空（不带任何固定标识）；
    -- msg.identity 为设备标识（"" 则不携带）
    local ident = (msg.identity and msg.identity ~= "") and (" [设备:" .. msg.identity .. "]") or ""
    -- 来电提醒刻意更短（一条短信内），只有号码没有正文
    local text
    if msg.kind == "call" then
        text = string.format("%s来电:%s%s", msg.prefix or "", msg.sender, ident)
    else
        text = string.format("%s来自 %s%s:\n%s", msg.prefix or "", msg.sender, ident, msg.text)
    end
    -- 防环：末行附加本机实例标记（随机 8 位十六进制）。sp_forward 收到
    -- 含本机标记的短信直接丢弃；纯随机串无固定词，不构成跨设备特征
    if msg.mark and msg.mark ~= "" then
        text = text .. "\n" .. msg.mark
    end
    -- 防环：跳过等于本机 MSISDN 的目标（物联网卡常读不到 MSISDN，
    -- 该层失效时由上面的实例标记兜底）
    local self_num = sp_auth.normalize_number(sp_platform.msisdn())
    local failed, attempted = {}, 0
    for _, target in ipairs(chcfg.targets) do
        if self_num ~= "" and target == self_num then
            log.warn("sp_chan_sms", "跳过本机号码目标", target)
        else
            attempted = attempted + 1
            if not sp_platform.send_sms_sync(target, text) then
                failed[#failed + 1] = target
            end
        end
    end
    if #failed > 0 then
        return false, "发送失败: " .. table.concat(failed, ",")
    end
    if attempted == 0 then
        return false, "全部目标为本机号码"
    end
    return true
end

sp_channels.register(ch)
return ch