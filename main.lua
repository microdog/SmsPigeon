--[[
@module  main
@summary SmsPigeon 固件入口（LuatOS 用户应用脚本）
@version 1.3.0
@date    2026.09.12
@usage
SmsPigeon（短信鸽）：全本地运行的 Air780EHV 短信转发固件。
配置与控制全部通过短信命令完成，固件自身不连接任何远程管理 API。

模块装配顺序（存在依赖，勿随意调整）：
  sp_config           配置持久化（最先加载，其余模块依赖其缓存）
  sp_platform         平台适配层（IMEI/ICCID 等硬件访问）
  sp_net              联网状态 + NTP 对时（Webhook 加签依赖）
  sp_channels         转发通道注册表
  sp_chan_sms         短信通道（离线可用，优先注册）
  sp_chan_dingtalk    钉钉 Webhook
  sp_chan_feishu      飞书 Webhook
  sp_chan_serverchan  Server酱
  sp_commands         短信命令处理
  sp_forward          短信入口（命令分流 + 转发分发）
  sp_call             来电提醒（CC_IND 监听 → 转发队列）
  sp_heartbeat        心跳报平安（定时 → 转发队列）
  sp_sim_guard        SIM 卡守护（换卡/连续无卡开机复位）

快速上手：
  1. 用 Luatools 烧录本工程脚本 + Air780EHV LuatOS 固件（V2018+）；
  2. 插卡开机，从你的手机向模块发送短信 信鸽，初始化，<模块IMEI>；
  3. 收到 OK 应答后，发送 信鸽，帮助 查看全部命令。

完整文档：README.md 与 docs/commands.md
]]

-- Luatools 工具与远程升级依赖的项目级全局变量
PROJECT = "SmsPigeon"
VERSION = "1.3.0"

local sys = require "sys"
log.info("main", PROJECT, VERSION)

-- errDump 会将错误日志周期性上传到合宙服务器，与本项目"全本地运行"的
-- 隐私定位不符，默认不启用；如需远程排障可取消下行注释。
-- if errDump then errDump.config(true, 600) end

require "sp_config"             -- 配置持久化
require "sp_platform"           -- 平台适配层
require "sp_net"                -- 联网与 NTP 对时

require "sp_channels"           -- 转发通道注册表
require "sp_chan_sms"           -- 短信通道
require "sp_chan_dingtalk"      -- 钉钉通道
require "sp_chan_feishu"        -- 飞书通道
require "sp_chan_serverchan"    -- Server酱通道
require "sp_chan_wecom"         -- 企业微信通道

require "sp_commands"           -- 短信命令处理
require "sp_forward"            -- 短信入口（命令 + 转发）
require "sp_call"               -- 来电提醒
require "sp_heartbeat"          -- 心跳报平安（sp_commands 已提前加载它）
require "sp_sim_guard"          -- SIM 卡守护
require "sp_led"                -- 状态灯（整机开发板 NET 灯）

-- 启动系统调度（必须放在最后）
sys.run()
