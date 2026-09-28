#!/usr/bin/env python3
"""Запуск tests/test_api.lua на lupa (Lua 5.4): регрессии сетевого слоя."""
import sys, os, lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs('/tmp/sfntest_api', exist_ok=True)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")
L.execute("""
os = os or {}
if not os.getenv then os.getenv = function() return '/tmp/sfntest_api' end end
if not os.execute then os.execute = function() return true end end
getWorkingDirectory = function() return '/tmp/sfntest_api' end
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
L.execute("package.preload['mimgui'] = function() return require 'tests.mock_imgui'.imgui end")
L.execute("""
package.preload['fAwesome6_solid'] = function()
    local icons = {
        ANGLE_LEFT = '<', MAGNIFYING_GLASS = '@', ROTATE = 'R', DOWNLOAD = 'D',
        CLOCK = 'C', FIRE = 'F', POWER_OFF = 'P',
    }
    icons.Init = function(size) return true end
    return icons
end
""")

test = open('tests/test_api.lua', encoding='utf-8').read()
tchunk = L.eval("function(s) local c,e = load(s,'test_api.lua') if not c then error(e) end return c end")(test)
try:
    tchunk()
except lupa.LuaError as e:
    print("[runner] ОШИБКА ВЫПОЛНЕНИЯ:", e)
    sys.exit(2)
