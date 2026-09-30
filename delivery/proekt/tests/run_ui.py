#!/usr/bin/env python3
"""Запуск test_ui.lua на lupa (Lua 5.4) — headless-проверка вёрстки SFN Logs."""
import sys, os, lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs('/tmp/sfntest_ui', exist_ok=True)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
import sys as _sys, os as _os
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import _runner
_runner.install_hooks(L)           # Lua print/os.exit -> Python (см. tests/_runner.py)
g = L.globals()

# package.path для require 'tests.mock_imgui'
L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")

# os.getenv / os.execute в lupa могут отсутствовать
L.execute("""
os = os or {}
if not os.getenv then os.getenv = function() return '/tmp/sfntest_ui' end end
if not os.execute then os.execute = function() return true end end
""")

# заглушки MoonLoader/SAMP
L.execute("""
getWorkingDirectory = function() return '/tmp/sfntest_ui' end
doesDirectoryExist  = function() return true end
createDirectory     = function() return true end
isSampLoaded        = function() return true end
isSampfuncsLoaded   = function() return true end
isSampAvailable     = function() return true end
wasKeyPressed       = function() return false end
isChatInputActive   = function() return false end
isPauseMenuActive   = function() return false end
lua_thread          = { create = function() return {} end }
sampAddChatMessage  = function() end
sampRegisterChatCommand = function() end
sampGetPlayerNickname = function() return 'Test_Leader' end
sampGetPlayerScore  = function() return 7 end
sampIsPlayerConnected = function() return false end
sampGetPlayerIdByCharHandle = function() return nil end
thisScript          = function() return {} end
PLAYER_PED          = 0
script_name         = function() end
script_version      = function() end
script_author       = function() end
""")

# один и тот же экземпляр мока должны получить и скрипт, и тест
L.execute("package.preload['mimgui'] = function() return require 'tests.mock_imgui'.imgui end")

src = open('SFNLogs.lua', encoding='utf-8').read()
chunk = L.eval("function(s) local c,e = load(s,'SFNLogs.lua') if not c then error(e) end return c end")(src)
chunk()
print("[runner] SFNLogs.lua загружен")

test = open('test_ui.lua', encoding='utf-8').read()
tchunk = L.eval("function(s) local c,e = load(s,'test_ui.lua') if not c then error(e) end return c end")(test)
sys.exit(_runner.run_lua(L, tchunk, "ui"))
