--[[
@module  sp_chan_sms
@summary SmsPigeon 转发通道：短信（转发到指定手机号）
@version 1.0
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.sms）：
  { on = true, targets = { "13800138000", ... } }

不依赖蜂窝数据网络（PS 域），短信通道是唯一离线可用的转发方式，
因此在注册顺序中放在最前。
]]

local sp_channels = require "sp_channels"

local ch = {}

ch.key = "sms"
ch.name = "短信"
ch.needs_net = false

function ch.is_configured(chcfg)
    return type(chcfg.targets) == "table" and #chcfg.targets > 0
end

function ch.send(msg, chcfg)
    -- 短信通道刻意压缩格式，节省短信条数（不含时间戳）
    local text = string.format("【SmsPigeon】来自 %s:\n%s", msg.sender, msg.text)
    local failed = {}
    for _, target in ipairs(chcfg.targets) do
        -- sms.send 同步返回值仅表示发送任务启动成功，
        -- 最终结果通过 SMS_SEND_RESULT 事件异步通知（当前内核固件可选等待）
        local ok = sms.send(target, text)
        if ok then
            sys.waitUntil("SMS_SEND_RESULT", 5000)
        else
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
