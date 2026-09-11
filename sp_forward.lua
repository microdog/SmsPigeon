--[[
@module  sp_forward
@summary SmsPigeon 转发引擎（短信入口：命令分流 + 消息转发）
@version 1.6
@date    2026.09.11
@usage
本模块注册短信接收回调，是所有收到短信的唯一入口：

1. 交给 sp_commands.handle 识别命令：
   - 是命令 → 按需短信回复应答（异步，经 sp_platform.send_sms），执行
     附加动作（如重启）；
2. 不是命令 → 普通短信：
   - 未初始化：直接丢弃（不转发）；
   - 已初始化：分发到所有已启用且配置完整的转发通道。

防环说明（代码级，两层）：
1. 短信通道发送前跳过等于本机 MSISDN 的目标；
2. 短信通道转发末尾追加本机实例标记（随机 8 位十六进制，首启生成并
   持久化）；收到含本机标记的短信直接丢弃——自身回环与双机互转均
   在一跳内断链。标记为纯随机串，无固定词、无跨设备特征，不构成
   运营商可识别的指纹。命令语法层面转发内容也不会以"信鸽+分隔符"
   开头被再解析为命令。

短信收发就绪说明：SMS_READY/CC_IND 就绪广播的捕获与发送路径
（就绪等待/提交/SMS_SENT 结果日志）统一封装在 sp_platform，
本模块只保留接收回调注册。
]]

local sp_commands = require "sp_commands"
local sp_config   = require "sp_config"
local sp_channels = require "sp_channels"
local sp_platform = require "sp_platform"
local sp_auth     = require "sp_auth"
local sp_led      = require "sp_led"

local sms = sms
local sys = sys
local log = log

local sp_forward = {}

local enqueue_forward   -- 前置声明：on_sms 在定义前引用（见下方队列节）
local filtered = 0      -- 前置声明：on_sms 先于队列节引用（命中过滤的丢弃计数）
local spool             -- 前置声明：fwd_worker 先于失败暂存节的定义引用
local function on_sms(num, txt, metas)
    -- 只记号码与长度，不落正文：命令短信含密码/token，第三方短信
    -- 内容同样不应进日志（排障需要正文时临时发 信鸽，调试，开）
    log.info("sp_forward", "收到短信", num, "长度", tostring(#txt))
    if type(metas) == "table" then
        -- SCTS：短信中心下发时间。若与你发送时刻相差很大，
        -- 说明短信在运营商侧滞留/延迟投递，不是固件问题。
        -- 3GPP 时间戳年份为两位数（如 26 = 2026），补 2000 偏移
        local y = tonumber(metas.year) or 0
        if y < 100 then y = y + 2000 end
        local tz = tonumber(metas.tz)
        local tzstr = ""
        if tz then
            tzstr = string.format(" (UTC%s%02d:%02d)",
                tz >= 0 and "+" or "-",
                math.abs(tz) // 60, math.abs(tz) % 60)
        end
        log.info("sp_forward", "短信中心时间戳",
            string.format("%04d-%02d-%02d %02d:%02d:%02d%s",
                y, metas.mon or 0, metas.day or 0,
                metas.hour or 0, metas.min or 0, metas.sec or 0, tzstr))
    end
    -- 防环：含本机实例标记 = 自己发出的转发回来了（自环/对端回环），丢弃
    local mark = sp_config.get().mark or ""
    if mark ~= "" and txt:find(mark, 1, true) then
        log.warn("sp_forward", "丢弃回环短信(含本机标记)", num)
        return
    end
     sp_led.blink()   -- 状态灯三连闪提示短信到达
    -- 1. 命令分流
    local is_cmd, reply, action = sp_commands.handle(num, txt)
    if is_cmd then
        if reply then
            sp_platform.send_sms(num, reply)
        end
        if action == "reboot" then
            -- 留出应答短信的发送时间
            sys.timerStart(sp_platform.reboot, 3000)
        end
        return
    end

    -- 2. 普通短信转发：入有界队列，由单 worker 串行消费
    local cfg = sp_config.get()
    if not cfg.initialized then
        log.info("sp_forward", "固件未初始化，短信不转发")
        return
    end
    -- 3. 转发过滤（只作用于转发，不影响命令鉴权）：黑名单号码或正文
    -- 命中过滤词 → 静默丢弃并计数（信鸽，统计 可查丢弃原因分布）
    local sender_n = sp_auth.normalize_number(num)
    for _, b in ipairs(cfg.blocklist or {}) do
        if sender_n and b == sender_n then
            filtered = filtered + 1
            log.info("sp_forward", "发件人已拉黑,丢弃短信", num)
            return
        end
    end
    for _, kw in ipairs(cfg.kwords or {}) do
        if txt:find(kw, 1, true) then
            filtered = filtered + 1
            log.info("sp_forward", "正文命中过滤词,丢弃短信", num)
            return
        end
    end
    enqueue_forward(num, txt)
end

--------------------------------------------------------------------------
-- 转发队列：单 worker + 有界 + 限速
-- 逐条 taskInit 的做法在短信洪泛下无界堆积（HTTP 通道联网等待 15s、
-- 短信通道串行 10s/条，任务驻留长），受限 RAM 会被耗尽；且每条入站
-- 短信被放大为 N 个目标出站（本机话费）。队列溢出丢最旧并计数。
--------------------------------------------------------------------------
local QUEUE_MAX    = 20     -- 队列上限（溢出丢最旧）
local FWD_INTERVAL = 2000   -- 两次转发之间的最小间隔（ms，限速）

local queue = {}
local dropped = 0        -- 队列溢出丢最旧计数
local sent = 0           -- 至少一个通道成功的事件数
local fail = 0           -- 有通道被尝试但全部失败的事件数
-- filtered 已在文件头部前置声明（on_sms 先于此处引用）
local worker_running = false

local function fwd_worker()
    while #queue > 0 do
        local m = table.remove(queue, 1)
        local cfg = sp_config.get()
        local results = sp_channels.dispatch({
            kind = m.kind or "sms",
            sender = m.num,
            text = m.txt,
            time = m.time,
            prefix = cfg.prefix or "",   -- 用户自定义转发前缀，默认空
            identity = sp_commands.resolve_identity(cfg), -- 设备标识（自动/自定义/关闭）
            mark = cfg.mark or "",       -- 防环实例标记（短信通道附加）
            pick_code = cfg.code_pick,   -- 验证码提取开关（nil 视为开）
        }, cfg.fwd)
        -- 结果统计：≥1 通道成功计 sent；有尝试但全失败计 fail，
        -- 且首次失败暂存（网络恢复后自动重发，重试失败则永久丢弃）
        local attempted, any_ok = false, false
        for _, v in pairs(results) do
            attempted = true
            if v == true then any_ok = true end
        end
        if attempted then
            if any_ok then
                sent = sent + 1
            else
                fail = fail + 1
                if not (m.tries and m.tries >= 1) then spool(m) end
            end
        end
        if #queue > 0 then sys.wait(FWD_INTERVAL) end
    end
    worker_running = false
end

-- 事件入队：kind 为 "sms"（普通短信转发）/"call"（来电提醒）/
-- "hb"（心跳报平安），通道按 msg.kind 渲染对应文案；共用同一队列
-- 与限速（来电/心跳同样受洪泛保护与 2s 间隔约束）。
-- time/tries 供失败暂存重发时保留原始时间戳与重试标记
local function push_event(kind, num, txt, time, tries)
    queue[#queue + 1] = {
        kind = kind, num = num, txt = txt, tries = tries,
        time = time or os.date("%Y-%m-%d %H:%M:%S"),
    }
    if #queue > QUEUE_MAX then
        table.remove(queue, 1)
        dropped = dropped + 1
        log.warn("sp_forward", "转发队列已满,丢弃最旧消息,累计丢弃", dropped)
    end
    if not worker_running and sys and sys.taskInit then
        worker_running = true
        sys.taskInit(fwd_worker)
    end
end

enqueue_forward = function(num, txt)
    push_event("sms", num, txt)
end

-- 来电提醒入口（sp_call 调用）：将来电推入转发队列
function sp_forward.notify_call(num)
    push_event("call", num)
end

-- 心跳入口（sp_heartbeat 调用）：txt 为固件自产状态摘要
function sp_forward.notify_hb(txt)
    push_event("hb", "", txt)
end

--------------------------------------------------------------------------
-- 失败暂存重发：全部通道失败的事件存 fskv（容量 sp_config.RETRY_MAX，
-- 仅失败时写入，写频极低以护闪存寿命），网络就绪（IP_READY）或
-- 信鸽，重发 时重新入队；重试一次仍失败则永久丢弃（防往复打环）
--------------------------------------------------------------------------
spool = function(m)
    local list = sp_config.load_retry()
    while #list >= sp_config.RETRY_MAX do
        table.remove(list, 1)   -- 丢最旧
    end
    list[#list + 1] = { kind = m.kind, num = m.num, txt = m.txt, time = m.time }
    sp_config.save_retry(list)
    log.warn("sp_forward", "全部通道失败,已暂存待重发", #list)
end

local function drain_retry()
    if not sp_config.get().initialized then return 0 end
    local list = sp_config.load_retry()
    if #list == 0 then return 0 end
    sp_config.save_retry({})
    for _, e in ipairs(list) do
        push_event(e.kind or "sms", e.num, e.txt, e.time, 1)   -- tries=1：重试不再暂存
    end
    log.info("sp_forward", "网络恢复,重发暂存消息", #list, "条")
    return #list
end

-- 手动重发入口（信鸽，重发 命令）：返回重发条数
function sp_forward.retry_now()
    return drain_retry()
end

if sys and sys.subscribe then
    sys.subscribe("IP_READY", function() drain_retry() end)
end

-- 队列运行状态（排障/信鸽，统计 命令用）
function sp_forward.stats()
    return {
        pending = #queue, dropped = dropped,
        sent = sent, fail = fail, filtered = filtered,
    }
end

-- 清零统计（信鸽，清零统计 命令用；不影响待发队列）
function sp_forward.reset_stats()
    dropped, sent, fail, filtered = 0, 0, 0, 0
end

-- 注册短信回调：优先 setNewSmsCb，不支持时退回系统消息
if sms and sms.setNewSmsCb then
    sms.setNewSmsCb(on_sms)
else
    log.warn("sp_forward", "sms.setNewSmsCb 不可用，改用 SMS_INC 消息监听")
    sys.subscribe("SMS_INC", on_sms)
end

-- 防环实例标记：首启生成随机 8 位十六进制并持久化（sp_mark 键）。
-- 刻意不随恢复出厂清除：标记无鉴权作用，清除反而留下"转发无标记"
-- 的空窗（复位后无需重启即可继续转发）
do
    local c = sp_config.get()
    if c.mark == nil or c.mark == "" then
        c.mark = sp_platform.rand_hex8()
        sp_config.save_mark(c.mark)
        log.info("sp_forward", "防环实例标记已生成")
    end
end

return sp_forward