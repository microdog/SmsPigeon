--[[
@module  sp_channels
@summary SmsPigeon 转发通道注册表与公共网络工具
@version 1.0
@date    2026.09.11
@usage
统一转发通道接口（新增转发渠道 = 编写 sp_chan_xxx.lua + 在 main.lua require + 注册）：

  local ch = {
      key         = "dingtalk",              -- 通道标识（与 sp_config.defaults().fwd 中的键一致）
      name        = "钉钉",                  -- 展示名（状态/日志用）
      needs_net   = true,                    -- 是否依赖蜂窝网络（HTTP 类通道为 true）
      is_configured = function(chcfg) ... end, -- 配置是否完整（返回 bool）
      send        = function(msg, chcfg) ... end, -- 发送一条消息，返回 ok, err
  }
  sp_channels.register(ch)

msg 结构：{ sender = "13800138000", text = "短信原文", time = "2026-09-11 12:00:00" }

本模块同时提供 HTTP POST / 表单编码 / 等待联网等公共工具，供各通道复用。
]]

local sp_channels = {}

local registry = {}        -- key -> channel 定义
local order = {}           -- 按注册顺序分发（短信通道优先注册，先于网络通道）

function sp_channels.register(ch)
    registry[ch.key] = ch
    order[#order + 1] = ch.key
end

function sp_channels.get(key)
    return registry[key]
end

-- 按注册顺序返回全部通道 key（状态展示用）
function sp_channels.keys()
    local t = {}
    for i, k in ipairs(order) do t[i] = k end
    return t
end

-- 分发一条短信到所有"已启用且配置完整"的通道。
-- 阻塞执行（HTTP 通道内部会等待联网），必须在 task 上下文中调用。
function sp_channels.dispatch(msg, fwdcfg)
    for _, key in ipairs(order) do
        local ch = registry[key]
        local chcfg = fwdcfg[key]
        if ch and chcfg and chcfg.on and ch.is_configured(chcfg) then
            -- pcall 只区分"是否抛错"；通道自身返回 false 表示发送失败
            local ok, sent_ok, err = pcall(ch.send, msg, chcfg)
            if ok and sent_ok ~= false then
                log.info("sp_channels", "转发成功:", ch.name)
            elseif ok then
                log.warn("sp_channels", "转发失败:", ch.name, tostring(err))
            else
                log.warn("sp_channels", "转发异常:", ch.name, tostring(sent_ok))
            end
        end
    end
end

--------------------------------------------------------------------------
-- 公共工具（供各通道模块使用）
--------------------------------------------------------------------------

-- 等待蜂窝网络就绪（HTTP 类通道发送前调用），返回是否就绪
function sp_channels.wait_net(timeout)
    if socket.adapter(socket.dft()) then return true end
    return sys.waitUntil("IP_READY", timeout or 15000) and socket.adapter(socket.dft())
end

-- POST JSON，返回 ok(bool), errinfo(string)
function sp_channels.http_post_json(url, body)
    local code, _, resp = http.request("POST", url,
        { ["Content-Type"] = "application/json" }, body).wait()
    if code ~= 200 then
        return false, "HTTP " .. tostring(code) .. " " .. tostring(resp)
    end
    return true, resp
end

-- POST 表单（application/x-www-form-urlencoded）
function sp_channels.http_post_form(url, params)
    local body = sp_channels.form_encode(params)
    local code, _, resp = http.request("POST", url,
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, body).wait()
    if code ~= 200 then
        return false, "HTTP " .. tostring(code) .. " " .. tostring(resp)
    end
    return true, resp
end

-- URL 编码（LuatOS 字符串原生带 :urlEncode()；纯 Lua 测试环境走回退实现）
local function url_encode(s)
    if s.urlEncode then
        return s:urlEncode()
    end
    return (s:gsub("[^%w%-._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- 表单编码：{title="x", desp="y"} -> "title=x&desp=y"
function sp_channels.form_encode(params)
    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = k .. "=" .. url_encode(tostring(v))
    end
    return table.concat(parts, "&")
end

-- 网络类通道统一的转发文本。msg.prefix 为用户自定义前缀（默认空串），
-- 不再内置任何固定标识，避免出栈短信携带可被运营商过滤的特征；
-- msg.identity 为设备标识（多设备同群区分来源，"" 则不携带）
function sp_channels.format_text(msg)
    local ident = (msg.identity and msg.identity ~= "") and (" [设备:" .. msg.identity .. "]") or ""
    return string.format("%s收到来自 %s 的短信%s\n时间: %s\n\n%s",
        msg.prefix or "", msg.sender, ident, msg.time, msg.text)
end

return sp_channels
