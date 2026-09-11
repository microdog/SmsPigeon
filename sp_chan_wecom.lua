--[[
@module  sp_chan_wecom
@summary SmsPigeon 转发通道：企业微信消息推送（原"群机器人"）
@version 1.0
@date    2026.09.11
@usage
配置结构（sp_config.defaults().fwd.wecom）：
  { on = true, key = "693a91f6-7aoc-4bc4-97a0-0ec2sifa5aaa" }

- key：消息推送 webhook 地址中 key= 参数的值（UUID 形式），
  支持配置命令直接提交 key 或完整 webhook URL（由命令层抽取 key）；
- 接口：POST https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<key>
  JSON {"msgtype":"text","text":{"content":"..."}}，content 上限 2048 字节
  UTF-8（本固件最长短信约 1.4KB，含转发头部不会超限）；
- 应答 {"errcode":0,"errmsg":"ok"} 表示成功。

官方文档：https://developer.work.weixin.qq.com/document/path/99110
]]

local json = json
local sp_channels = require "sp_channels"

local URL_BASE = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key="

local ch = {}

ch.key = "wecom"
ch.name = "企业微信"
ch.needs_net = true

function ch.is_configured(chcfg)
    return type(chcfg.key) == "string" and chcfg.key ~= ""
end

function ch.send(msg, chcfg)
    if not sp_channels.wait_net(15000) then
        return false, "网络未就绪"
    end

    local body = json.encode({
        msgtype = "text",
        text = { content = sp_channels.format_text(msg) },
    })
    local ok, resp = sp_channels.http_post_json(URL_BASE .. chcfg.key, body)
    if not ok then return false, resp end

    -- 应答 {"errcode":0,"errmsg":"ok"} 表示成功
    local r = json.decode(tostring(resp))
    if type(r) == "table" and r.errcode == 0 then
        return true
    end
    return false, "企业微信应答: " .. tostring(resp)
end

sp_channels.register(ch)
return ch