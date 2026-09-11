--[[
@module  sp_chan_sms
@summary SmsPigeon 转发通道：短信（转发到指定手机号）
@version 1.1
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.sms）：
  { on = true, targets = { "13800138000", ... } }

不依赖蜂窝数据网络（PS 域），短信通道是唯一离线可用的转发方式，
因此在注册顺序中放在最前。发送走 sp_platform.send_sms_sync
（含短信就绪等待与 SMS_SENT 结果日志）。
]]

local sp_channels = require "sp_channels"
local sp_platform = require "sp_platform"

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
    local text = string.format("%s来自 %s%s:\n%s", msg.prefix or "", msg.sender, ident, msg.text)
    local failed = {}
    for _, target in ipairs(chcfg.targets) do
        if not sp_platform.send_sms_sync(target, text) then
            failed[#failed + 1] = target
        end
    end
    if #failed > 0 then
        return false, "发送失败: " .. table.concat(failed, ",")
    end
    return true
end

sp_channels.register(ch)
return ch