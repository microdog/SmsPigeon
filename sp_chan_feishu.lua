--[[
@module  sp_chan_feishu
@summary SmsPigeon 转发通道：飞书群机器人 Webhook
@version 1.0
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.feishu）：
  { on = true, url = "https://open.feishu.cn/open-apis/bot/v2/hook/xxx", secret = "xxx" }

- url：飞书群机器人的 Webhook 地址；
- secret：机器人安全设置选择"签名校验"时生成的密钥，留空则不签名；
- 加签方式（飞书规范）：timestamp 秒；把 timestamp+"\n"+密钥 作为 HmacSHA256
  的 Key 对空串签名，结果 Base64 编码，随 body 一起提交。

依赖 NTP 对时（sp_net 模块负责），时间偏差超过 1 小时会返回签名过期错误。
]]

local json = json
local sp_channels = require "sp_channels"

local ch = {}

ch.key = "feishu"
ch.name = "飞书"
ch.needs_net = true

function ch.is_configured(chcfg)
    return type(chcfg.url) == "string" and chcfg.url ~= ""
end

function ch.send(msg, chcfg)
    if not sp_channels.wait_net(15000) then
        return false, "网络未就绪"
    end

    local payload = {
        msg_type = "text",
        content = { text = sp_channels.format_text(msg) },
    }

    -- 签名校验（配置了 secret 才进行）
    if chcfg.secret and chcfg.secret ~= "" then
        local ts = tostring(os.time())   -- 飞书只要秒级时间戳
        local sign = crypto.hmac_sha256("", ts .. "\n" .. chcfg.secret)
            :fromHex():toBase64()
        payload.timestamp = ts
        payload.sign = sign
    end

    local ok, resp = sp_channels.http_post_json(chcfg.url, json.encode(payload))
    if not ok then return false, resp end

    -- 应答 {"code":0,...} 或 {"StatusCode":0,...} 表示成功
    local r = json.decode(tostring(resp))
    if type(r) == "table" and (r.code == 0 or r.StatusCode == 0) then
        return true
    end
    return false, "飞书应答: " .. tostring(resp)
end

sp_channels.register(ch)
return ch
