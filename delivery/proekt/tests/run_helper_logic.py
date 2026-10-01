#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Запуск test_helper_logic.lua (чистая логика SFN_Helper) на lupa — Lua 5.4."""
import os
import sys

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs("/tmp/sfnhelper_test", exist_ok=True)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("loadstring = loadstring or load")
L.execute("arg = { [0]='test_helper_logic.lua', [1]='../../SFN_Helper.lua' }")

src = open("tests/test_helper_logic.lua", encoding="utf-8").read()
chunk = L.eval(
    "function(s) local c,e = load(s,'test_helper_logic.lua') if not c then error(e) end return c end"
)(src)
try:
    chunk()
except lupa.LuaError as e:
    print("[runner] ОШИБКА ВЫПОЛНЕНИЯ:", e)
    sys.exit(2)
