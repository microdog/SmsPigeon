--[[
@module  sp_channels
@summary SmsPigeon 转发通道注册表与公共网络工具
@version 1.2
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
-- 返回结果表 results[key]：true=发送成功，字符串=失败/异常原因
-- （仅包含被尝试的通道；未启用/未配置的通道不在表内）
function sp_channels.dispatch(msg, fwdcfg)
    local results = {}
    for _, key in ipairs(order) do
        local ch = registry[key]
        local chcfg = fwdcfg[key]
        if ch and chcfg and chcfg.on and ch.is_configured(chcfg) then
            -- pcall 只区分"是否抛错"；通道契约：返回 true 才算成功，
            -- false/nil/其它值一律按失败记录原因（nil+err 形态此前
            -- 会被误记为成功）
            local ok, sent_ok, err = pcall(ch.send, msg, chcfg)
            if not ok then
                results[key] = "执行异常: " .. tostring(sent_ok)
                log.warn("sp_channels", "转发异常:", ch.name, tostring(sent_ok))
            elseif sent_ok == true then
                results[key] = true
                log.info("sp_channels", "转发成功:", ch.name)
            else
                results[key] = "发送失败: " .. tostring(err or "通道未返回成功")
                log.warn("sp_channels", "转发失败:", ch.name, tostring(err or "通道未返回成功"))
            end
        end
    end
    return results
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

-- 验证码触发词：正文含任一词才尝试提取（避免日期/单号等纯数字误报）
local CODE_TRIGGERS = {
    "验证码", "校验码", "动态码", "授权码", "认证码", "取件码", "效验码",
}

-- 从正文中提取疑似验证码：首个"独立的 4-8 位数字串"。
-- 跳过超长数字串（11 位手机号/单号）继续向后找；无触发词或找不到
-- 返回 nil。纯函数，两条通道共用。
function sp_channels.extract_code(text)
    if type(text) ~= "string" then return nil end
    local hit = false
    for _, w in ipairs(CODE_TRIGGERS) do
        if text:find(w, 1, true) then hit = true break end
    end
    if not hit then return nil end
    for run in text:gmatch("%d+") do
        if #run >= 4 and #run <= 8 then return run end
    end
    return nil
end

-- 短信正文的验证码前置行（msg.pick_code 为 false 或提取不到则空串）：
-- 置于文案首行，手机/webhook 通知预览即可直接看到验证码
local function code_line(msg)
    if msg.pick_code == false then return "" end
    local c = sp_channels.extract_code(msg.text)
    return c and ("[验证码:" .. c .. "]\n") or ""
end

-- 网络类通道统一的转发文本。msg.prefix 为用户自定义前缀（默认空串），
-- 不再内置任何固定标识，避免出栈短信携带可被运营商过滤的特征；
-- msg.identity 为设备标识（多设备同群区分来源，"" 则不携带）
function sp_channels.format_text(msg)
    local ident = (msg.identity and msg.identity ~= "") and (" [设备:" .. msg.identity .. "]") or ""
    -- 来电提醒（msg.kind == "call"）：只有号码没有正文
    if msg.kind == "call" then
        return string.format("%s来电提醒:号码 %s%s\n时间: %s\n固件不接听,如需通话请回拨",
            msg.prefix or "", msg.sender, ident, msg.time)
    end
    -- 心跳（msg.kind == "hb"）：msg.text 为固件自产的状态摘要
    if msg.kind == "hb" then
        return string.format("%s心跳:模块在线%s\n时间: %s\n%s",
            msg.prefix or "", ident, msg.time, msg.text)
    end
    return string.format("%s%s收到来自 %s 的短信%s\n时间: %s\n\n%s",
        msg.prefix or "", code_line(msg), msg.sender, ident, msg.time, msg.text)
end

return sp_channels
