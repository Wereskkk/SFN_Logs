#!/usr/bin/env python3
"""Регресс v2.0.1: реальный mimgui не имеет GetColorU32(ImVec4) — только
ColorConvertFloat4ToU32/GetColorU32Vec4. Загружаем SFNLogs с «суровым» моком
и проверяем, что дизайн НЕ падает в текстовый fallback."""
import sys, os, lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
os.makedirs('/tmp/sfntest_strict', exist_ok=True)

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute("package.path = './?.lua;./?/init.lua;' .. package.path")
L.execute("""
os = os or {}
if not os.getenv then os.getenv = function() return '/tmp/sfntest_strict' end end
if not os.execute then os.execute = function() return true end end
getWorkingDirectory = function() return '/tmp/sfntest_strict' end
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
package.preload['mimgui'] = function() return require 'tests.mock_imgui'.imgui end
""")

# «суровый» mimgui: Vec4-перегрузок нет, GetColorU32 принимает только U32
L.execute("""
local mock = require 'tests.mock_imgui'
mock.imgui.ColorConvertFloat4ToU32 = nil
mock.imgui.GetColorU32Vec4 = nil
mock.imgui.GetColorU32 = function(v)
    if type(v) ~= 'number' then error('GetColorU32: ImVec4 not supported (как в реальном mimgui)') end
    return v
end
""")

src = open('SFNLogs.lua', encoding='utf-8').read()
chunk = L.eval("function(s) local c,e = load(s,'SFNLogs.lua') if not c then error(e) end return c end")(src)
chunk()

res = L.execute("""
local mock = require 'tests.mock_imgui'
mock.runInit()
loadConfig(); loadRoster()
SFNLogs.setVisible(true)
addMember('Ivan_Petrov', 'Test_Leader', os.time() - 86400, 2, 5)
for _ = 1, 5 do mock.frame({}) end
local info = mock.frame({})
local dlOk = SFNLogs.layoutInfo().drawListOk
local err  = SFNLogs.lastUiError
if not dlOk then error('FALLBACK: дизайн упал в текстовый режим: ' .. tostring(err)) end
if err then error('осталась ошибка UI: ' .. tostring(err)) end
if info.win.x < 1000 then error('окно подозрительно узкое: ' .. info.win.x) end
print(string.format('strict-colors: OK — DrawList жив, окно %.0fx%.0f, ошибок нет', info.win.x, info.win.y))
""")
print('STRICT COLORS PASSED')
