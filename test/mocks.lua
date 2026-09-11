--[[
@module  test/mocks
@summary LuatOS 全局 API 的内存桩（单元测试专用，不烧录进固件）
@version 1.0
@date    2026.09.11
@usage
提供 fskv/log/sys/mobile/sms/http/socket/rtos/json/VERSION 的最小替身，
令业务模块可以在纯 Lua 5.3 环境下运行。

调用 M.install(opts) 重建全部桩（每个测试文件独立安装一次），并更新
全局 MOCKS 表供断言使用（mobile 字段可在测试中直接修改以模拟换卡等场景）：
  MOCKS.store   fskv 键值内存库
  MOCKS.sent    sms.send 发出的短信 {num=, text=} 列表
  MOCKS.reboots rtos.reboot 调用次数
  MOCKS.mobile  {imei=, iccid=, csq=} mobile 桩返回值
  MOCKS.sms_cb  sms.setNewSmsCb 注册的回调

opts 可设置初始 imei/iccid/csq/version。
]]

local M = {}

-- 深拷贝：模拟 fskv 序列化落盘语义（保存后修改内存表不影响已存值）
local function deep(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = deep(val) end
    return t
end

function M.install(opts)
    opts = opts or {}
    local store, sent = {}, {}
    MOCKS = {
        store = store, sent = sent, reboots = 0, tasks = {},
        mobile = {
            imei  = opts.imei or "860123456789012",
            iccid = opts.iccid or "",
            csq   = opts.csq or 25,
        },
    }

    fskv = {
        init = function() return true end,
        set  = function(k, v) store[k] = deep(v) return true end,
        get  = function(k) return store[k] end,
        del  = function(k) store[k] = nil return true end,
    }

    sys = {
        -- 任务只记录不执行：避免常驻任务（NTP 循环等）挂死测试；
        -- 需要驱动任务的测试按增量执行 MOCKS.tasks
        taskInit    = function(fn) MOCKS.tasks[#MOCKS.tasks + 1] = fn end,
        wait        = function() end,
        waitUntil   = function() return true end,
        subscribe   = function() end,
        unsubscribe = function() end,
        timerStart  = function() end,
        timerStop   = function() end,
        run         = function() end,   -- 供 main.lua 装配冒烟测试
    }

    log = {
        info   = function() end,
        debug  = function() end,
        warn   = function(tag, ...) print("[W]" .. tostring(tag), ...) end,
        error  = function(tag, ...) print("[E]" .. tostring(tag), ...) end,
    }
    -- main.lua 里 require "sys"：让该 require 返回上面的全局桩
    package.preload["sys"] = function() return sys end

    mobile = {
        imei  = function() return MOCKS.mobile.imei end,
        iccid = function() return MOCKS.mobile.iccid end,
        csq   = function() return MOCKS.mobile.csq end,
    }

    sms = {
        send = function(num, text)
            sent[#sent + 1] = { num = num, text = text }
            return true
        end,
        setNewSmsCb = function(fn) MOCKS.sms_cb = fn end,
    }

    http = { request = function() error("http mock: 单元测试未实现 HTTP") end }

    -- 最小 json 桩：覆盖模块加载期的 local json = json 捕获与基本编码；
    -- 单元测试不覆盖 HTTP 通道的应答解析路径
    json = {
        encode = function(v)
            if type(v) == "string" then return '"' .. v .. '"' end
            if type(v) == "table" then
                local parts = {}
                for k, val in pairs(v) do
                    parts[#parts + 1] = '"' .. tostring(k) .. '":' .. json.encode(val)
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            return tostring(v)
        end,
        decode = function() error("json mock: decode 未实现") end,
    }

    socket = {
        LWIP_GP = 0,
        dft     = function() return 0 end,
        adapter = function() return true end,
        setDNS  = function() end,
        sntp    = function() end,
    }

    rtos = {
        bsp    = function() return "TEST_BSP" end,
        reboot = function() MOCKS.reboots = MOCKS.reboots + 1 end,
    }

    VERSION = opts.version or "1.0.0-test"
    return MOCKS
end

return M
