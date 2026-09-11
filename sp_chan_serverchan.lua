--[[
@module  sp_chan_serverchan
@summary SmsPigeon 转发通道：Server酱（微信推送）
@version 1.0
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.serverchan）：
  { on = true, sendkey = "SCTxxxxx" }

- sendkey 支持两种写法：
  (1) Server酱 Turbo 版 SendKey（SCT 开头），此时使用官方接口
      https://sctapi.ftqq.com/{SendKey}.send
  (2) 完整推送 URL（以 http 开头），适用于 Server酱³ 或自建兼容服务的场景；
- 请求为表单 POST：title 为消息标题，desp 为 Markdown 正文；
- 应答 {"code":0,...} 表示成功。

不依赖时间签名，无需严格对时。
]]

local json = json
local sp_channels = require "sp_channels"

local BASE_URL = "https://sctapi.ftqq.com/"

local ch = {}

ch.key = "serverchan"
ch.name = "Server酱"
ch.needs_net = true

function ch.is_configured(chcfg)
    return type(chcfg.sendkey) == "string" and chcfg.sendkey ~= ""
end

function ch.send(msg, chcfg)
    if not sp_channels.wait_net(15000) then
        return false, "网络未就绪"
    end

    local key = chcfg.sendkey
    local url = key:sub(1, 4):lower() == "http" and key or (BASE_URL .. key .. ".send")

    local ok, resp = sp_channels.http_post_form(url, {
        title = string.format("SmsPigeon: 来自 %s 的短信", msg.sender),
        desp = sp_channels.format_text(msg),
    })
    if not ok then return false, resp end

    local r = json.decode(tostring(resp))
    if type(r) == "table" and r.code == 0 then
        return true
    end
    return false, "Server酱应答: " .. tostring(resp)
end

sp_channels.register(ch)
return ch
