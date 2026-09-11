# Agent Onboarding —— SmsPigeon

面向贡献者与 AI agent 的项目速览。命令、工作流、硬件操作以
[README.md](../README.md) 为准；文件路由以
[codebase-map.md](codebase-map.md) 为准。本文不重复这两者的内容。

## 项目是什么

SmsPigeon 是运行在 Air780EHV（LuatOS）上的短信转发固件：
收到短信后转发到用户配置的通道（短信/钉钉/飞书/Server酱），
所有配置与控制通过短信命令完成。**全本地运行**是核心卖点：
固件不连接任何远程管理 API，配置只存本机 fskv。

## 技术栈与拓扑

- LuatOS（Lua 5.3 方言）应用脚本，运行于 Air780EHV LuatOS 固件 V2018+；
- LuatOS 全局库直接可用：`sys` `log` `json` `fskv` `sms` `mobile`
  `http` `socket` `crypto` `rtos`——模块里**不 require 这些库**，直接引用全局；
- 存储：fskv 键值（键前缀 `sp_`）；无文件系统依赖；
- 网络通道依赖蜂窝数据（4G 默认网卡）+ NTP 对时（Webhook 加签需要）；
- 烧录与真机调试用 Luatools；单元测试在纯 Lua 5.3 + API 桩上运行。

## 不变量与约定

1. **鉴权语义**：白名单与密码是两道独立门禁，同时开启时必须全部满足
   （AND）。修改鉴权逻辑必须保持该语义并更新 `test/sp_commands_test.lua`。
2. **未初始化 = 死寂**：未初始化状态不转发任何短信、不回复任何命令
   （INIT 成功/失败除外）。任何新功能不得绕过此门禁。
3. **静默拒绝**：未授权命令不回复，防探测。不要给拒绝路径加应答。
4. **复位即全清**：恢复出厂删除全部 `sp_` 键并回到未初始化（防环
   标记 `sp_mark` 例外保留：无鉴权作用，清除会留下复位后同会话
   转发无标记的防环空窗）；换卡与
   连续 3 次无卡开机两条复位路径必须保持。
5. **模块纪律**：
   - `sp_platform.lua` 是唯一允许触碰 `mobile`/`rtos` 的模块；
   - 纯逻辑模块（`sp_at`/`sp_auth`/`sp_config`）不得引用任何硬件
     全局库（`sms`/`mobile`/`http`/`socket`），保持可单测；
   - 收路径事件订阅例外：`sp_forward`（`sms` 收信 + `IP_READY` 暂存
     排空）、`sp_call`（`cc` 来电）、`sp_net`（`IP_READY`）在加载期
     直接订阅全局库回调/定时器，不走 `sp_platform`；
   - 转发通道必须走 `sp_channels.register` 注册表接口。
6. **配置落盘**：修改 `sp_config.get()` 返回的表后必须调用
   `sp_config.save()`；`RESET` 类命令不得留下未保存的内存残留。
7. **版本号**：`main.lua` 的 `VERSION` 保持三段式 `X.Y.Z`（合宙 FOTA 兼容）。
8. **errDump 默认关闭**：与全本地隐私定位一致，勿默认启用。
9. 代码注释、用户可见文案（短信应答）使用中文；模块头部保持
   `@module/@summary/@version/@date/@usage` 注释块。

## 测试与验证

- `python test/run_with_lupa.py`（Windows）或 `lua5.3 test/run_tests.lua`
  （Linux/CI）；改动后必须全绿；
- 新增行为必须有对应断言：解析器/鉴权/配置/复位路径在
  `test/sp_*_test.lua`，装配链路在 `test/main_smoke_test.lua`；
- HTTP 通道与真机短信路径无法本地模拟，改动后对照 README
  「硬件验收清单」在真机回归。

## 文档维护责任

- 命令变更 → [docs/commands.md](commands.md) 与 `sp_commands.lua` 的帮助输出
  保持一致（自然命令短语在 `sp_at.lua` 的 `PHRASES` 表，命令语义在
  `sp_commands.lua` 的 `CMDS` 表，两处需同步）
- 文件/职责/接口变更 → [docs/codebase-map.md](codebase-map.md)；
- 面向用户的烧录/上手流程变更 → [README.md](../README.md)。