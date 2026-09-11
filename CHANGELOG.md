# 更新日志

本项目的显著变更记录在此文件。版本号遵循 `X.Y.Z`（合宙 FOTA 兼容的三段式）。

## 1.0.0 - 2026-09-11

首个正式版本。

### 新增

- 全本地运行的 Air780EHV 短信转发固件：配置与控制仅通过短信完成，
  不依赖任何远程管理 API
- AT 命令风格的短信命令：`AT+INIT` `AT+ST?` `AT+WL` `AT+PW`
  `AT+FWD` `AT+RESET` `AT+REBOOT` 等（见 docs/commands.md）
- 三重独立门禁：IMEI 初始化、白名单（默认开启）、密码前缀模式；
  多门禁同时开启时须全部满足
- 转发通道：短信（离线可用）、钉钉 Webhook（加签）、飞书 Webhook（签名）、
  Server酱（微信推送），插件式注册表可扩展
- 防捡漏自毁：SIM 卡变更、连续第 3 次无卡开机自动恢复出厂
- 纯 Lua 5.3 单元测试套件（含 LuatOS API 桩与 main.lua 装配冒烟），
  GitHub Actions CI（lua5.3 测试 + luacheck 静态检查）
- 状态灯支持（整机开发板 NET 灯，GPIO27）：网络/初始化状态指示与
  短信到达三连闪；修复应答短信错过开机 SMS_READY/CC_IND 广播后
  每条白等 30 秒的问题