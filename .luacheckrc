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

-- 测试文件采用顺序断言风格：先赋值再断言、局部变量重复赋值/复用是刻意写法，
-- 仅对 test/ 放宽这两类风格告警；源码保持零告警
files["test"] = {
    ignore = { "311", "411" },
}
cache = true