--[[
sp_config 配置层单元测试：默认值、持久化往返、恢复出厂。
]]

local sp_config = require "sp_config"

local n = 0
local function eq(got, want, msg)
    if got ~= want then
        error(string.format("FAIL %s\n  got:  %s\n  want: %s",
            msg, tostring(got), tostring(want)), 0)
    end
    n = n + 1
end

-- 全新安装：默认值
local cfg = sp_config.get()
eq(cfg.initialized, false, "默认未初始化")
eq(cfg.wl_on, true, "默认白名单开启")
eq(cfg.password, "", "默认无密码")
eq(#cfg.whitelist, 0, "默认白名单为空")
eq(cfg.fwd.sms.on, false, "默认短信通道关闭")
eq(cfg.fwd.dingtalk.url, "", "默认钉钉未配置")
eq(cfg.iccid, "", "默认无ICCID绑定")
eq(cfg.nosim_cnt, 0, "默认无卡计数为0")

-- 修改 + 保存 + 重新加载（模块缓存清空，模拟重启）
cfg.initialized = true
cfg.wl_on = false
cfg.password = "1234"
table.insert(cfg.whitelist, "13800138000")
cfg.fwd.sms.on = true
table.insert(cfg.fwd.sms.targets, "13900139000")
cfg.fwd.dingtalk.url = "https://oapi.example.com/send?access_token=abc"
cfg.fwd.dingtalk.secret = "SECxxx"
sp_config.save()
sp_config.save_iccid("89860000000000000000")
sp_config.save_nosim(2)

package.loaded["sp_config"] = nil
local sp_config2 = require "sp_config"
local cfg2 = sp_config2.get()
eq(cfg2.initialized, true, "重启后初始化状态保持")
eq(cfg2.wl_on, false, "重启后白名单开关保持")
eq(cfg2.password, "1234", "重启后密码保持")
eq(cfg2.whitelist[1], "13800138000", "重启后白名单保持")
eq(cfg2.fwd.sms.on, true, "重启后短信通道开关保持")
eq(cfg2.fwd.sms.targets[1], "13900139000", "重启后转发目标保持")
eq(cfg2.fwd.dingtalk.url, "https://oapi.example.com/send?access_token=abc", "重启后钉钉URL保持")
eq(cfg2.fwd.dingtalk.secret, "SECxxx", "重启后钉钉密钥保持")
eq(cfg2.iccid, "89860000000000000000", "重启后ICCID绑定保持")
eq(cfg2.nosim_cnt, 2, "重启后无卡计数保持")

-- 保存后的内存修改不落盘（深拷贝语义）
cfg2.whitelist[1] = "00000000000"
package.loaded["sp_config"] = nil
local cfg3 = require "sp_config".get()
eq(cfg3.whitelist[1], "13800138000", "未save的修改不落盘")

-- 恢复出厂
sp_config.factory_reset()
local cfg4 = sp_config.get()
eq(cfg4.initialized, false, "复位后未初始化")
eq(cfg4.wl_on, true, "复位后白名单恢复默认开")
eq(cfg4.password, "", "复位后密码清空")
eq(#cfg4.whitelist, 0, "复位后白名单清空")
eq(cfg4.fwd.dingtalk.url, "", "复位后通道配置清空")
eq(cfg4.iccid, "", "复位后ICCID解绑")
eq(cfg4.nosim_cnt, 0, "复位后计数清零")
eq(MOCKS.store["sp_state"], nil, "复位后fskv键删除")

-- 损坏数据容错：直接往 store 塞非法类型
MOCKS.store["sp_wl"] = "not-a-table"
MOCKS.store["sp_wl_on"] = "corrupt"
MOCKS.store["sp_fwd"] = { unknown_channel = { on = true } }
package.loaded["sp_config"] = nil
local cfg5 = require "sp_config".get()
eq(type(cfg5.whitelist), "table", "白名单损坏时回退默认")
eq(cfg5.wl_on, true, "开关损坏时回退默认")
eq(cfg5.fwd.sms.on, false, "未知通道数据被丢弃")

print(string.format("PASS sp_config_test (%d assertions)", n))
