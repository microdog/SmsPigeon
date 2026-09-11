#!/usr/bin/env python3
"""Windows 本地测试入口：经 lupa（内嵌 Lua 运行时）执行 test/run_tests.lua。

依赖：pip install lupa
CI/Linux 环境请直接使用 lua5.3 test/run_tests.lua。
"""

import sys
from pathlib import Path

import lupa

TESTS_DIR = Path(__file__).resolve().parent


def main() -> int:
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g["__LUPA__"] = True
    # run_tests.lua 通过 arg[0] 定位自身目录；统一转为正斜杠避免转义问题
    path = str(TESTS_DIR / "run_tests.lua").replace("\\", "/")
    lua.execute(f'arg = {{ [0] = "{path}" }}')

    runner = (TESTS_DIR / "run_tests.lua").read_text(encoding="utf-8")
    lua.execute(runner)

    failed = g["__TESTS_FAILED__"]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
