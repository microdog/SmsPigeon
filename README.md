# SmsPigeon 短信鸽

基于 [Air780EHV](https://docs.openluat.com/air780ehv/product/) + [LuatOS](https://docs.openluat.com/osapi/) 的短信转发固件：把收到的短信转发到你的手机、钉钉、飞书或微信（Server酱）。

**全本地运行**是本项目的核心特性：配置、鉴权、控制全部通过短信完成，固件自身不连接任何远程管理 API——短信内容不经过第三方管理服务，配置只存在模块本地，最大程度保证隐私与安全。

## 功能特性

- **短信命令控制**：AT 风格语法、中文前缀 `鸽+`（规避运营商对 AT 特征短信的过滤），全部配置通过短信完成，无需连接电脑
- **多种转发通道**：短信 / 钉钉 Webhook / 飞书 Webhook / Server酱（微信推送），可同时启用
- **白名单鉴权**：默认仅白名单号码可下发命令（初始化时自动登记第一个号码）
- **密码模式**：可选将 `鸽` 前缀替换为自定义密码，与白名单相互独立、可叠加
- **IMEI 初始化**：首次使用必须 `鸽+INIT=<IMEI>`，防误配防冒配；已初始化不可重复初始化
- **防捡漏自毁**：检测到换卡、或连续第 3 次无卡开机，自动恢复出厂
- **离线优先**：短信通道不依赖蜂窝数据网络，无流量也可转发
- **可扩展**：转发通道为插件式注册表，新通道=一个文件+一行注册
- **状态灯**（整机开发板 NET 灯）：快闪=无网络、慢心跳=待初始化、常亮=正常、三连闪=收到短信

## 硬件与烧录

- 合宙 Air780EHV 核心板（或自绘电路的 Air780EHV 模组）+ 能收发短信的 SIM 卡
- 内核固件：Air780EHV LuatOS 固件 **V2018 或更高**
  （[固件版本说明](https://docs.openluat.com/air780ehv/luatos/firmware/version/)）
- 烧录工具：[Luatools](https://luatos.com/luatools)

烧录步骤（Luatools）：

1. 打开 Luatools，进入「项目管理测试」，新建项目；
2. 选择本仓库根目录作为脚本目录，入口脚本 `main.lua`，
   脚本目录内全部 `.lua` 文件勾选下载；
3. 选择 Air780EHV 对应的 LuatOS 固件（.soc）；
4. 核心板插 USB、插 SIM 卡，按 Luatools 提示下载（开机+下载模式）；
5. 下载完成自动重启运行。

> `test/` 目录是单元测试，烧录时无需勾选。

## 快速上手

假设模块 IMEI 为 `861234567890123`，你的手机号为 `13800138000`：

```
[手机] 发送短信:  鸽+INIT=861234567890123
[模块] 回复:     OK:SmsPigeon 已初始化
                 13800138000 已加入白名单
                 发送 鸽+ST? 查看状态

[手机] 鸽+FWD=SMS,ADD,13800138000      ← 短信转发到自己手机
[模块] OK:13800138000 已加入短信转发列表

[手机] 鸽+FWD=SMS,ON
[模块] OK:短信转发已开启

[手机] 鸽+HELP?                        ← 查看全部命令
```

此后任何号码发给模块的短信都会以 `【SmsPigeon】来自 xxx:` 开头转发到你的手机。

钉钉/飞书/Server酱通道的配置示例、命令细节与鉴权规则见
**[docs/commands.md](docs/commands.md)**。

## 工作原理

```
                    ┌────────────────────────────────────┐
   任意发件人 ──SMS──▶│ sp_forward 收到短信                 │
                    └──────┬─────────────────────────────┘
                           │
              是命令(鸽+/密码前缀)？──否──▶ 转发分发 sp_channels
                           │                    │
                           ▼                    ├─▶ 短信通道（离线）
                  sp_commands 命令处理           ├─▶ 钉钉 Webhook
                  （鉴权→执行→短信应答）          ├─▶ 飞书 Webhook
                                                └─▶ Server酱
```

- 未初始化：不转发任何短信，只接受 `鸽+INIT`，其余静默丢弃；
- 命令与转发互斥：一条短信要么是命令，要么被转发；
- 换卡 / 连续 3 次无卡开机 → 恢复出厂，回到未初始化状态。

## 项目结构

```
main.lua                  固件入口：模块装配顺序
sp_config.lua             配置持久化（fskv）与恢复出厂
sp_at.lua                 AT 风格短信命令解析器（纯逻辑）
sp_auth.lua               鉴权状态机：初始化/白名单/密码（纯逻辑）
sp_commands.lua           命令表与执行、应答文案
sp_forward.lua            短信入口：命令分流 + 转发分发
sp_channels.lua           转发通道注册表与 HTTP 工具
sp_chan_sms.lua           通道：短信转发
sp_chan_dingtalk.lua      通道：钉钉 Webhook（加签）
sp_chan_feishu.lua        通道：飞书 Webhook（签名）
sp_chan_serverchan.lua    通道：Server酱
sp_sim_guard.lua          换卡检测 + 无卡开机计数 + 自动复位
sp_net.lua                联网状态 + NTP 对时（Webhook 加签依赖）
sp_platform.lua           平台适配层（唯一接触硬件差异的模块）
sp_led.lua                状态灯（整机开发板 NET 灯）
test/                     单元测试（纯 Lua 5.3，含 LuatOS API 桩）
docs/                     命令手册 / 代码地图 / agent 指南
```


## 状态灯指示（整机开发板）

Air780Exx 整机开发板左上角的 NET 灯由模组 GPIO27 控制（官方开发板手册
明确其工作逻辑由用户自定义），固件定义如下语义：

| 灯效 | 含义 |
|---|---|
| 快闪（约 2Hz） | 网络未注册/无 SIM——异常，需要关注 |
| 慢心跳（2 秒周期短亮） | 已注册但固件未初始化——等待 `鸽+INIT` |
| 常亮 | 已初始化且网络已注册——正常工作中 |
| 三连闪 | 收到一条短信（活动指示） |

核心板没有此灯：`sp_platform.lua` 中 `LED_GPIO` 置 nil 即停用该功能；
其它板型若灯的亮灭逻辑相反，改 `LED_ACTIVE_HIGH = false`。

## 开发

### 本地跑单元测试

```bash
# Windows（经 pip install lupa 的内嵌 Lua 运行时）
python test/run_with_lupa.py

# Linux / CI（原生 Lua 5.3）
lua5.3 test/run_tests.lua
```

测试覆盖命令解析、鉴权门禁组合、配置持久化/恢复出厂、换卡与无卡复位、
main.lua 全链路装配冒烟（197 项断言）。HTTP 通道的真实推送与硬件行为
（短信收发、SIM 事件时序）无法在纯 Lua 环境模拟，以下硬件验收清单为准。

### 硬件验收清单

烧录后逐项实测：

1. 未初始化时：发普通短信和 `鸽` 均无应答、无转发；
2. `鸽+INIT=<IMEI>` 收到 OK，错误 IMEI 收到 `ERROR`；
3. 重复 INIT 收到 `ERROR`；
4. 非白名单号码发命令无应答；
5. 配置短信转发后，其他号码发短信能收到转发文本；
6. 配置钉钉（建议加签）后能收到群消息（需 NTP 成功，观察日志
   `NTP 对时成功`）；
7. `鸽+RESET` 后回到未初始化；换卡后同样自动复位；
8. 拔卡连续 3 次开机后复位（日志 `连续第 3 次无卡开机`）；
9. 状态灯：未初始化慢心跳、初始化后常亮、收到短信三连闪、拔卡后快闪。

## 常见问题：发命令没反应 / 收不到转发

1. **先看日志有没有"收到短信"**：固件对每条到达的短信（无论是否命令）
   都会先打印 `I/user.sp_forward 收到短信 <号码> <完整内容>`，随后打印
   `短信中心时间戳`（SCTS，运营商下发时刻——与你发送时刻相差大即说明
   运营商延迟投递）；同时固件已开启官方内核短信调试日志（`sms.debug`），
   短信到达模组时内核会打印 `CMI_SMS_NEW_MSG_IND` / `D/sms` 行。
   - 有"收到短信"但命令无应答 → 命令格式问题：半角符号、IMEI 是否与
     日志 `self_info` 行一致（见 docs/commands.md）；
   - 内核行都没有 → 短信根本没到模组，继续往下。
2. **物联网卡限制（最常见）**：物联网卡（如 ICCID `8986112…` 号段）
   常未开通点对点短信接收，部分专用号段普通手机号根本无法发送；
   已知案例中短信在运营商侧滞留 6 分钟以上才投递（对时间戳即可确认）。
   请联系运营商开通"点对点短信"，或先换普通消费级 SIM 卡验证。
   也可能是**内容特征过滤**（如命令含连续 11 位手机号被当垃圾短信拦截）：
   号码加分隔符（`鸽+FWD=SMS,ADD,132-6257-5718`）、放慢发送节奏、
   启用密码模式均可规避，详见 docs/commands.md「运营商内容过滤的规避」。
3. **验证短信链路**：在 `main.lua` 的 `sys.run()` 前临时加入自检任务，
   确认模块能发出短信并获知号码（验证后删除）：

   ```lua
   sys.taskInit(function()
       sys.waitUntil("CC_IND", 30000)
       log.info("自检", "本机号码", mobile.number(0) or "卡商未写入")
       sms.send("138xxxxxxxx", "SmsPigeon 自检短信")  -- 改成你的手机号
   end)
   ```

   手机收到后直接回复该短信发 INIT 命令，回信地址即模块号码；
   出栈正常而入栈收不到 → 坐实卡的接收限制。
4. **发送侧**：以普通文本短信发送（勿用 iMessage/5G 消息/彩信），
   使用 11 位裸号码，换一部手机交叉验证。
5. 若内核有 `CMI_SMS_NEW_MSG_IND` 行但没有 `收到短信` 行，属于固件
   问题，请附带该段日志提 issue。

### 添加新转发通道

1. 新建 `sp_chan_xxx.lua`，实现并注册通道接口：

   ```lua
   local sp_channels = require "sp_channels"
   sp_channels.register {
       key = "xxx",          -- 与 sp_config.defaults().fwd 中的键一致
       name = "某平台",
       needs_net = true,     -- HTTP 类通道为 true
       is_configured = function(chcfg) ... end,   -- 配置是否完整
       send = function(msg, chcfg) ... end,        -- 返回 true 或 nil, err
   }
   ```

2. 在 `sp_config.defaults().fwd` 增加 `xxx` 默认配置结构；
3. 在 `sp_commands.lua` 的 `CH_ALIAS` 增加命令别名（如 `XX`）；
4. `main.lua` 增加 `require "sp_chan_xxx"`。

### 移植到其它 LuatOS 模组

业务模块只通过 `sp_platform.lua` 访问硬件差异 API（IMEI/ICCID/信号/重启），
其余 LuatOS API（sms/fskv/http/crypto）在 Air780E 系列上通用。
移植 Air780EPM/EHM/EGH 等型号通常只需确认 fskv 分区可用、
`rtos.bsp()` 返回值，必要时在 `sp_platform.lua` 内做适配。

## 文档索引

- [docs/commands.md](docs/commands.md) — 短信命令完整手册（语法、鉴权、示例）
- [docs/codebase-map.md](docs/codebase-map.md) — 代码结构与路由地图
- [docs/agent-onboarding.md](docs/agent-onboarding.md) — 贡献者/agent 上手指南

## 许可证

[MIT](LICENSE)