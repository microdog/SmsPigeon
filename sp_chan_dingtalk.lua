--[[
@module  sp_chan_dingtalk
@summary SmsPigeon 转发通道：钉钉群机器人 Webhook
@version 1.0
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.dingtalk）：
  { on = true, url = "https://oapi.dingtalk.com/robot/send?access_token=xxx", secret = "SECxxx" }

- url：钉钉群机器人的 Webhook 地址（安全设置任选其一）；
- secret：机器人安全设置选择"加签"时生成的密钥，以 SEC 开头；
  若机器人使用"自定义关键词"安全设置，secret 留空即可。
- 加签方式（钉钉规范）：timestamp 毫秒；把 timestamp+"\n"+密钥 作为 HmacSHA256
  的 Key 对空串签名，结果 Base64 后 URL 编码，拼在 Webhook 后。

依赖 NTP 对时（sp_net 模块负责），时间偏差过大会返回加签错误。
]]

local json = json
local sp_channels = require "sp_channels"

local ch = {}

ch.key = "dingtalk"
ch.name = "钉钉"
ch.needs_net = true

function ch.is_configured(chcfg)
    return type(chcfg.url) == "string" and chcfg.url ~= ""
end

function ch.send(msg, chcfg)
    if not sp_channels.wait_net(15000) then
        return false, "网络未就绪"
    end

    local url = chcfg.url
    -- 加签（配置了 secret 才进行）
    if chcfg.secret and chcfg.secret ~= "" then
        local ts = tostring(os.time()) .. "000"   -- 钉钉需要毫秒时间戳
        local sign = crypto.hmac_sha256(ts .. "\n" .. chcfg.secret, chcfg.secret)
            :fromHex():toBase64():urlEncode()
        url = url .. (url:find("?", 1, true) and "&" or "?")
            .. "timestamp=" .. ts .. "&sign=" .. sign
    end

    local body = json.encode({
        msgtype = "text",
        text = { content = sp_channels.format_text(msg) },
    })
    local ok, resp = sp_channels.http_post_json(url, body)
    if not ok then return false, resp end

    -- 应答 {"errcode":0,"errmsg":"ok"} 表示成功
    local r = json.decode(tostring(resp))
    if type(r) == "table" and r.errcode == 0 then
        return true
    end
    return false, "钉钉应答: " .. tostring(resp)
end

sp_channels.register(ch)
return ch
