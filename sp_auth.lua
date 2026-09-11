--[[
@module  sp_auth
@summary SmsPigeon 短信命令鉴权模块（纯逻辑，零硬件依赖）
@version 1.1
@date    2026.09.11
@usage
鉴权模型（设计决策，两道门禁相互独立、同时开启时必须全部满足）：

1. 初始化门禁：固件未初始化时，只放行"信鸽，初始化"命令，其余静默丢弃；
2. 白名单门禁：白名单开启时，发送者号码必须在白名单内；
3. 密码门禁：设置密码后，命令必须以密码为前缀（由 sp_at.parse 强制，
   密码模式下默认前缀不再有效）。

白名单与密码可独立开/关；两者同时关闭时任何命令短信均可控制本机，
命令层（sp_commands）会在这种状态下给出风险提示。

号码归一化：中文数字先转阿拉伯数字，再剔除非数字字符；长度超过 11 位时
取末 11 位（处理 +86 前缀），因此白名单中只需存储 11 位裸号码。
号码支持分组写法（132-6257-5718、132 6257 5718）与中文数字写法
（一三二六二五七五七一八）。本固件面向中国大陆场景。
]]

local sp_at = require "sp_at"

local sp_auth = {}

--[[
归一化手机号：中文数字转阿拉伯 → 剔除非数字 → 超 11 位取末 11 位。
无效输入返回 nil。示例：
  "+8613800138000"            -> "13800138000"
  "13800138000"                -> "13800138000"
  "132-6257-5718"              -> "13262575718"
  "一三二六二五七五七一八"      -> "13262575718"
  "10086"                      -> "10086"
]]
function sp_auth.normalize_number(num)
    if num == nil then return nil end
    local s = sp_at.digits(num)
    if s == "" then return nil end
    if #s > 11 then s = s:sub(-11) end
    return s
end

-- 发送者是否在白名单内（两侧都做归一化）
function sp_auth.in_whitelist(cfg, sender)
    local n = sp_auth.normalize_number(sender)
    if not n then return false end
    for _, w in ipairs(cfg.whitelist or {}) do
        if w == n then return true end
    end
    return false
end

--[[
初始化后的命令鉴权。密码门禁已由解析器强制（能解析出命令即说明前缀正确），
这里只做白名单检查。
返回：true 放行 / false, 原因 拒绝
]]
function sp_auth.check(cfg, sender)
    if cfg.wl_on and not sp_auth.in_whitelist(cfg, sender) then
        return false, "NOT_IN_WHITELIST"
    end
    return true
end

return sp_auth