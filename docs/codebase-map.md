# Codebase Map —— SmsPigeon

一句话总览：Air780EHV LuatOS 短信转发固件——短信入口把命令与普通
短信分流，命令走「解析→鉴权→执行→应答」，普通短信按配置分发到
短信/钉钉/飞书/Server酱通道；全部状态持久化在 fskv。

## 文件路由

| 文件 | 职责 | 关键符号 |
|---|---|---|
| `main.lua` | 入口：PROJECT/VERSION 与模块装配顺序（顺序有依赖，勿乱动） | `PROJECT` `VERSION` `sys.run` |
| `sp_config.lua` | 配置缓存、fskv 读写、默认值合并、恢复出厂 | `get` `save` `save_iccid` `save_nosim` `factory_reset` `MAX_LIST` |
| `sp_at.lua` | 中文句子命令解析：信鸽前缀、短语最长匹配、全角/顿号句号归一、中文数字（纯逻辑） | `parse(text, password)` `digits` `cn_digits` `trim` |
| `sp_platform.lua` | 硬件适配层（唯一触碰 `mobile`/`rtos` 的模块）+ 短信发送出口 | `imei` `iccid` `msisdn` `registered` `csq` `send_sms` `send_sms_sync` `reboot` |
| `sp_led.lua` | 状态灯（开发板 NET 灯）：网络/初始化指示与短信到达三连闪 | `pattern_for` `blink` |
| `sp_commands.lua` | 命令表（中文命令标识）、执行、应答文案、未初始化/授权门禁 | `handle(sender, text)` `CH_ALIAS` `CMDS` |
| `sp_forward.lua` | 短信接收入口：命令分流/转发分发（发送走 `sp_platform.send_sms`） | `on_sms`（内部）`sms.setNewSmsCb` 注册 |
| `sp_channels.lua` | 通道注册表 + HTTP/表单/联网等待工具 | `register` `dispatch` `keys` `wait_net` `http_post_json` `format_text` |
| `sp_chan_sms.lua` | 短信转发通道（离线可用，注册序第一） | `ch.send` `ch.is_configured` |
| `sp_chan_dingtalk.lua` | 钉钉 Webhook（HmacSHA256 加签，毫秒时间戳） | 同上 |
| `sp_chan_feishu.lua` | 飞书 Webhook（签名校验，秒时间戳） | 同上 |
| `sp_chan_serverchan.lua` | Server酱（SendKey 或完整 URL，表单 POST） | 同上 |
| `sp_chan_wecom.lua` | 企业微信消息推送（key 拼标准 webhook，errcode 判定） | 同上 |
| `sp_sim_guard.lua` | 换卡 ICCID 比对复位、无卡开机计数复位、热插拔监听 | `check_iccid` `handle_no_sim_boot` `boot_task` |
| `sp_net.lua` | IP_READY 追加公共 DNS、SNTP 周期对时 | `ntp_task`（内部） |

测试（不烧录）：

| 文件 | 覆盖 |
|---|---|
| `test/mocks.lua` | LuatOS 全局 API 内存桩（fskv 深拷贝语义、mobile 可变桩） |
| `test/run_tests.lua` | 运行器：每文件独立桩+模块缓存；`test/run_with_lupa.py` 为 Windows 入口 |
| `test/sp_at_test.lua` | 解析器：信鸽前缀、短语/参数、密码模式、中文数字、UTF-8 字节类地雷回归 |
| `test/sp_auth_test.lua` | 归一化、白名单、门禁组合 |
| `test/sp_config_test.lua` | 默认值、持久化往返、损坏数据容错、恢复出厂 |
| `test/sp_commands_test.lua` | 初始化/门禁/白名单/密码/通道命令全流程、AND 语义、防锁死 |
| `test/sp_sim_guard_test.lua` | ICCID 绑定、换卡复位、无卡计数 |
| `test/main_smoke_test.lua` | main.lua 全链路装配、回调贯通、未初始化死寂 |

## By concern（横切关注点 → 归属）

- **初始化与鉴权**：`sp_commands.handle`（门禁编排）→ `sp_auth.check`
  （白名单）→ `sp_at.parse`（密码前缀强制）；未初始化死寂只在 `handle` 中实现
- **配置持久化**：全部经 `sp_config`；fskv 键见该文件顶部 `sp_*` 常量；
  `RESET`/换卡/无卡复位共用 `factory_reset`
- **收到一条短信后发生什么**：`sp_forward.on_sms` → 命令？
  `sp_commands.handle` 应答；否则（已初始化）`sp_channels.dispatch` 分发
- **新增转发通道**：`sp_chan_xxx.lua` 实现 `register{key,name,needs_net,
  is_configured,send}` + `sp_config.defaults().fwd` 增键 +
  `sp_commands.CH_ALIAS` 增别名 + `main.lua` 增 require
  （详见 README「添加新转发通道」）
- **所有出栈短信**统一走 `sp_platform.send_sms`/`send_sms_sync`
- **dispatch 返回各通道结果表**：`results[key]=true|失败原因`（仅被尝试通道）
  （就绪等待 + SMS_SENT 结果日志；命令应答/远程发短信/短信通道转发）
- **适配新模组**：只改 `sp_platform.lua`；LuatOS API 在 Air780E 系列通用
- **Webhook 加签**：`sp_chan_dingtalk`（毫秒+URL编码）/`sp_chan_feishu`
  （秒级+Base64）；时间源依赖 `sp_net` 的 NTP 同步
- **前缀/标识**：转发文本默认无固定标识，前缀与设备标识均可配置
  （`信鸽，设置前缀` / `信鸽，设置标识`，标识自动取 MSISDN 尾 4 位）；
  安全性来自命令语法（转发内容不会被解析为命令），约定不把本机号加白名单
- **状态灯**：`sp_led` 的闪烁语义（快闪/心跳/常亮/三连闪）见模块头注释与
  README「状态灯指示」；引脚与极性是板级事实，定义在 `sp_platform`
- **应答文案**：全部集中在 `sp_commands.lua` 各 `cmd_*` 函数返回值；
  改动需同步 `docs/commands.md` 与 HELP 输出

## 配置数据形状（sp_config 缓存）

```lua
{
  initialized = bool,          -- fskv: sp_state == "INIT"
  wl_on       = bool,          -- fskv: sp_wl_on（默认 true）
  whitelist   = { "138...", }  -- fskv: sp_wl（归一化号码，上限 10）
  password    = "",            -- fskv: sp_pw（""=密码模式关）
  prefix      = "",            -- fskv: sp_pfx（转发前缀，""=无前缀）
  identity    = nil/string,    -- fskv: sp_ident（设备标识：nil=自动取手机号尾4位）
  fwd = {                      -- fskv: sp_fwd
    sms        = { on=bool, targets={...} },
    dingtalk   = { on=bool, url="", secret="" },
    feishu     = { on=bool, url="", secret="" },
    serverchan = { on=bool, sendkey="" },
    wecom      = { on=bool, key="" },
  },
  iccid      = "",             -- fskv: sp_iccid（SIM 绑定，复位判定用）
  nosim_cnt  = 0,             -- fskv: sp_nosim（连续无卡开机计数）
}
```