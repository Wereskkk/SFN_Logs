#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Запуск test_logic.lua на lupa (Lua 5.4) — для CI и для тех, у кого нет luajit.

В отличие от `luajit test_logic.lua`, не требует отдельного интерпретатора:
нужен только `pip install lupa`. Добавляет шимы loadstring/arg, которых
в Lua 5.4 нет.

Запуск:  python3 tests/run_logic.py        (из delivery/proekt)
"""
import os
import sys

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs("/tmp/sfntest", exist_ok=True)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
import sys as _sys, os as _os
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import _runner
_runner.install_hooks(L)           # Lua print/os.exit -> Python (см. tests/_runner.py)
L.execute("loadstring = loadstring or load")
L.execute("arg = { [0]='test_logic.lua', [1]='SFNLogs.lua' }")

src = open("test_logic.lua", encoding="utf-8").read()
chunk = L.eval(
    "function(s) local c,e = load(s,'test_logic.lua') if not c then error(e) end return c end"
)(src)
sys.exit(_runner.run_lua(L, chunk, "logic"))
