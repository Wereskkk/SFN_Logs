#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Запуск test_helper_ui.lua на headless-моке mimgui (lupa, Lua 5.4)."""
import os
import sys

import lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs('/tmp/sfnhelper_ui', exist_ok=True)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()

L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")
L.execute("""
os = os or {}
if not os.getenv then os.getenv = function() return '/tmp/sfnhelper_ui' end end
if not os.execute then os.execute = function() return true end end
getWorkingDirectory = function() return '/tmp/sfnhelper_ui' end
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
__cmds = {}
sampRegisterChatCommand = function(name, fn) __cmds[name] = fn end
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
L.execute("package.preload['mimgui'] = function() return require 'tests.mock_imgui'.imgui end")
L.execute("""
package.preload['fAwesome6_solid'] = function()
    local icons = {
        ANGLE_LEFT = '<', MAGNIFYING_GLASS = '@', ROTATE = 'R', DOWNLOAD = 'D',
        CLOCK = 'C', FIRE = 'F', POWER_OFF = 'P', USERS = 'U',
    }
    icons.Init = function(size) return true end
    return icons
end
""")

src = open('../../SFN_Helper.lua', encoding='utf-8').read()
chunk = L.eval("function(s) local c,e = load(s,'SFN_Helper.lua') if not c then error(e) end return c end")(src)
chunk()
print("[runner] SFN_Helper.lua загружен")

test = open('tests/test_helper_ui.lua', encoding='utf-8').read()
tchunk = L.eval("function(s) local c,e = load(s,'test_helper_ui.lua') if not c then error(e) end return c end")(test)

import sys as _sys
_sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _runner
_runner.install_hooks(L)
_sys.exit(_runner.run_lua(L, tchunk, "helper-ui"))
