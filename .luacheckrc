-- luacheck 配置：LuatOS 全局环境 + 项目约定
std = "lua53"

-- LuatOS 固件提供的全局库与项目级全局变量
globals = {
    "PROJECT", "VERSION",
    "sys", "log", "json", "fskv", "sms", "mobile",
    "http", "socket", "crypto", "rtos", "gpio", "cc",
    "network", "errDump", "iob", "fs",
    -- 测试桩与运行器变量
    "MOCKS", "__LUPA__", "__TESTS_FAILED__", "arg",
}

-- 命令处理函数统一签名 (cfg, p, sender)，部分参数故意不用
unused_args = false

max_line_length = 120
cache = true