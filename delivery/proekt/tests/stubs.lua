os = os or {}
if not os.getenv then os.getenv = function() return '/tmp/sfntest_ui' end end
if not os.execute then os.execute = function() return true end end
getWorkingDirectory = function() return '/tmp/sfntest_ui' end
doesDirectoryExist  = function() return true end
createDirectory     = function() return true end
isSampLoaded = function() return true end
isSampfuncsLoaded = function() return true end
isSampAvailable = function() return true end
wasKeyPressed = function() return false end
isChatInputActive = function() return false end
isPauseMenuActive = function() return false end
lua_thread = { create = function() return {} end }
sampAddChatMessage = function() end
sampRegisterChatCommand = function() end
sampGetPlayerNickname = function() return 'Test_Leader' end
sampGetPlayerScore = function() return 7 end
sampIsPlayerConnected = function() return false end
sampGetPlayerIdByCharHandle = function() return nil end
thisScript = function() return {} end
PLAYER_PED = 0
script_name = function() end
script_version = function() end
script_author = function() end
package.preload['mimgui'] = function() return require 'tests.mock_imgui'.imgui end

getFolderPath = function() return 'C:\\Windows\\Fonts' end
package.preload['fAwesome6_solid'] = function()
    local icons = {
        ANGLE_LEFT = '<', MAGNIFYING_GLASS = '@', ROTATE = 'R', DOWNLOAD = 'D',
        CLOCK = 'C', FIRE = 'F', POWER_OFF = 'P',
    }
    icons.Init = function(size) return true end
    return icons
end
