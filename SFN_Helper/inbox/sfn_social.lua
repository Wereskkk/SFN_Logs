-- sfn_social.lua
-- Соцопрос + Раздача листовок для SFN (San Fierro News)
-- v4.0: убраны pcall вокруг wait() — причина краша lua_yield/lua_close
-- ВАЖНО: файл в UTF-8 (без BOM).

---@diagnostic disable: undefined-global
---@diagnostic disable: lowercase-global

-- ============================================
-- ПОДКЛЮЧЕНИЕ
-- ============================================
local imgui    = require('mimgui')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8       = encoding.UTF8
local new      = imgui.new
local memory   = require('memory')
local vkeys    = require('vkeys')
local ffi      = require('ffi')

local sampev_ok, sampev = pcall(require, 'samp.events')

-- ============================================
-- ПУТИ
-- ============================================
local DATA_DIR     = getWorkingDirectory() .. "\\sfn_photo_data"
local SOCIAL_PATH  = DATA_DIR .. "\\social.json"
local GENDERS_PATH = DATA_DIR .. "\\genders.json"

-- ============================================
-- НАСТРОЙКИ
-- ============================================
local SURVEY_LIMIT  = 100
local FLYER_LIMIT   = 100
local RANGE_FILTER  = 3.0
local MAX_TARGET_RANGE = 10.0
local CHAT_DELAY    = 1500
local CLEAR_CHAT_DELAY = 800
local SCREENSHOT_TIME_WAIT = 1500
local SCREENSHOT_HIDE_WAIT = 300
local TIME_COMMAND  = "/time 1"

local MIN_WINDOW_WIDTH = 380
local PLAYERS_CACHE_TTL_MS = 200

local DEFAULT_HOTKEY = 0x7A
local CHAT_MSG_WARN_LEN = 128
local QUESTION_BUF_SIZE = 256
local FLYER_ME_BUF_SIZE = 256
local FLYER_ME_WARN_LEN = 128

local DEFAULT_FLYER_ME_TEXT = "протянул листовку о вреде экологии человеку напротив"

local AGREE_WORDS = {
    "да", "ок", "окей", "конечно", "давай", "ага", "угу", "yes",
    "хорошо", "без проблем", "не вопрос", "валяй", "го", "ok",
    "слушаю",
}

-- Парсинг ников
local PATTERN_NICK_WITH_ID = "([%a][%w_]*)%[(%d+)%]"
local PATTERN_NICK_ONLY    = "^%-?%s*([%a][%w_]*):%s*(.+)$"
local PATTERN_ME_LINE      = "^%s*([%a][%w_]*)%s+(.+)$"
-- /me-строка с ID: "Yuliya_Gomes[70] взяла"
local PATTERN_ME_WITH_ID   = "^%s*([%a][%w_]*)%[(%d+)%]%s+(.+)$"

-- ============================================
-- КИРИЛЛИЦА CP1251
-- ============================================
local str_char   = string.char
local tbl_concat = table.concat

local lu_rus, ul_rus = {}, {}
for i = 192, 223 do
    local A, a = str_char(i), str_char(i + 32)
    ul_rus[A] = a
    lu_rus[a] = A
end
local E_UP, E_LO = str_char(168), str_char(184)
ul_rus[E_UP] = E_LO
lu_rus[E_LO] = E_UP

local function toLowerRu(s)
    if not s then return s end
    local ok, cp = pcall(function() return u8:decode(s) end)
    if not ok or not cp then return s end
    local res = {}
    for i = 1, #cp do
        local ch = cp:sub(i, i)
        res[i] = ul_rus[ch] or ch
    end
    local ok2, enc = pcall(function() return u8:encode(tbl_concat(res)) end)
    if not ok2 or not enc then return s end
    return enc
end

-- ============================================
-- ЛОГ В КОНСОЛЬ
-- ============================================
local function logPrint(msg)
    pcall(print, "[SFN-Social] " .. tostring(msg))
end

-- ============================================
-- ОЧИСТКА ЧАТА
-- ============================================
local function clearLocalChat()
    local ok, chatPtr = pcall(sampGetChatInfoPtr)
    if not ok or not chatPtr or chatPtr == 0 then return false end

    pcall(memory.fill, chatPtr + 306, 0, 25200)
    pcall(memory.write, chatPtr + 306, 25562, 4, 0)
    pcall(memory.write, chatPtr + 25562, 1, 1)
    return true
end

-- ============================================
-- ТЕМА
-- ============================================
local function ApplyTheme()
    imgui.SwitchContext()
    local style = imgui.GetStyle()
    local colors = style.Colors
    local ImVec4 = imgui.ImVec4

    style.WindowRounding = 10
    style.FrameRounding = 6
    style.GrabRounding = 6
    style.ScrollbarRounding = 6
    style.TabRounding = 6
    style.WindowPadding = imgui.ImVec2(10, 10)
    style.FramePadding = imgui.ImVec2(8, 6)
    style.ItemSpacing = imgui.ImVec2(6, 6)
    style.ItemInnerSpacing = imgui.ImVec2(4, 4)
    style.WindowBorderSize = 0
    style.FrameBorderSize = 0
    style.ScrollbarSize = 10
    style.GrabMinSize = 10

    colors[imgui.Col.WindowBg] = ImVec4(0.95, 0.95, 0.97, 1.0)
    colors[imgui.Col.ChildBg] = ImVec4(1.0, 1.0, 1.0, 1.0)
    colors[imgui.Col.PopupBg] = ImVec4(1.0, 1.0, 1.0, 0.98)
    colors[imgui.Col.FrameBg] = ImVec4(0.90, 0.90, 0.92, 1.0)
    colors[imgui.Col.FrameBgHovered] = ImVec4(0.85, 0.85, 0.87, 1.0)
    colors[imgui.Col.FrameBgActive] = ImVec4(0.80, 0.80, 0.82, 1.0)
    colors[imgui.Col.TitleBg] = ImVec4(0.95, 0.95, 0.97, 1.0)
    colors[imgui.Col.TitleBgActive] = ImVec4(0.90, 0.90, 0.92, 1.0)
    colors[imgui.Col.TitleBgCollapsed] = ImVec4(0.95, 0.95, 0.97, 1.0)
    colors[imgui.Col.Button] = ImVec4(0.0, 0.48, 1.0, 0.9)
    colors[imgui.Col.ButtonHovered] = ImVec4(0.1, 0.55, 1.0, 1.0)
    colors[imgui.Col.ButtonActive] = ImVec4(0.0, 0.42, 0.9, 1.0)
    colors[imgui.Col.Text] = ImVec4(0.1, 0.1, 0.1, 1.0)
    colors[imgui.Col.TextDisabled] = ImVec4(0.5, 0.5, 0.5, 1.0)
    colors[imgui.Col.Header] = ImVec4(0.85, 0.85, 0.87, 1.0)
    colors[imgui.Col.HeaderHovered] = ImVec4(0.80, 0.80, 0.82, 1.0)
    colors[imgui.Col.HeaderActive] = ImVec4(0.75, 0.75, 0.77, 1.0)
    colors[imgui.Col.Separator] = ImVec4(0.80, 0.80, 0.82, 1.0)
    colors[imgui.Col.Border] = ImVec4(0.85, 0.85, 0.87, 1.0)
    colors[imgui.Col.ScrollbarBg] = ImVec4(0.95, 0.95, 0.97, 1.0)
    colors[imgui.Col.ScrollbarGrab] = ImVec4(0.75, 0.75, 0.77, 1.0)
    colors[imgui.Col.ScrollbarGrabHovered] = ImVec4(0.70, 0.70, 0.72, 1.0)
    colors[imgui.Col.ScrollbarGrabActive] = ImVec4(0.65, 0.65, 0.67, 1.0)
end

imgui.OnInitialize(function()
    local ok, err = pcall(ApplyTheme)
    if not ok then logPrint("ApplyTheme ERR: " .. tostring(err)) end
end)

-- ============================================
-- СОСТОЯНИЕ
-- ============================================
local WinState    = new.bool(true)
local hideForShot = false

local selectedTargetId = nil

local HOTKEY = DEFAULT_HOTKEY
local hotkeyWaiting = false
local hotkeyPressedThisFrame = false

local social = {
    active       = false,
    stage        = 0,
    targetId     = nil,
    targetNick   = nil,
    surveys      = {},
    flyers       = {},
    log          = {},
}

local myNick        = nil
local myDisplayNick = nil
local myId          = -1

local genders = {}
local pendingGenderConfirm = nil
local genderWindowOpen = new.bool(false)

local surveyQuestion = ""
local questionBuf = imgui.new.char[QUESTION_BUF_SIZE]()

local flyerMeText = DEFAULT_FLYER_ME_TEXT
local flyerMeBuf  = imgui.new.char[FLYER_ME_BUF_SIZE]()

local function setQuestionBuffer(str)
    if type(str) ~= "string" then str = "" end
    local n = math.min(#str, QUESTION_BUF_SIZE - 1)
    pcall(ffi.fill, questionBuf, QUESTION_BUF_SIZE, 0)
    if n > 0 then pcall(ffi.copy, questionBuf, str, n) end
end

local function getQuestionBuffer()
    local ok, s = pcall(ffi.string, questionBuf)
    if ok and type(s) == "string" then return s end
    return ""
end

local function setFlyerMeBuffer(str)
    if type(str) ~= "string" then str = "" end
    local n = math.min(#str, FLYER_ME_BUF_SIZE - 1)
    pcall(ffi.fill, flyerMeBuf, FLYER_ME_BUF_SIZE, 0)
    if n > 0 then pcall(ffi.copy, flyerMeBuf, str, n) end
end

local function getFlyerMeBuffer()
    local ok, s = pcall(ffi.string, flyerMeBuf)
    if ok and type(s) == "string" then return s end
    return ""
end

-- ============================================
-- JSON
-- ============================================
local function prettyJson(t, indent)
    indent = indent or 0
    local sp  = string.rep("    ", indent)
    local sp2 = string.rep("    ", indent + 1)

    if type(t) ~= "table" then
        if type(t) == "string" then
            return '"' .. t:gsub('"', '\\"') .. '"'
        elseif type(t) == "number" or type(t) == "boolean" then
            return tostring(t)
        else
            return "null"
        end
    end

    if next(t) == nil then return "{}" end

    local isArray = true
    for k, _ in pairs(t) do
        if type(k) ~= "number" then isArray = false break end
    end

    local parts = {}
    if isArray then
        for i = 1, #t do
            table.insert(parts, sp2 .. prettyJson(t[i], indent + 1))
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. sp .. "]"
    else
        local keys = {}
        for k, _ in pairs(t) do table.insert(keys, k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            table.insert(parts, sp2 .. '"' .. tostring(k) .. '": ' .. prettyJson(t[k], indent + 1))
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. sp .. "}"
    end
end

local function writeFile(path, content)
    local ok, f = pcall(io.open, path, "w")
    if not ok or not f then return false end
    pcall(f.write, f, content)
    pcall(f.flush, f)
    pcall(f.close, f)
    return true
end

local function readFile(path)
    local ok, f = pcall(io.open, path, "r")
    if not ok or not f then return nil end
    local ok2, c = pcall(f.read, f, "*a")
    pcall(f.close, f)
    if not ok2 then return nil end
    return c
end

-- ============================================
-- ПОЛ
-- ============================================
local function saveGenders()
    writeFile(GENDERS_PATH, prettyJson(genders))
end

local function loadGenders()
    local content = readFile(GENDERS_PATH)
    if not content or #content == 0 then return {} end
    local ok, data = pcall(decodeJson, content)
    if not ok or not data then return {} end
    local result = {}
    for nick, g in pairs(data) do
        if g == "m" or g == "f" then
            result[nick] = g
        end
    end
    return result
end

local function getGender(nick)
    if not nick then return "m" end
    return genders[nick] or "m"
end

-- ============================================
-- СОБЫТИЯ (в UI, без вывода в консоль)
-- ============================================
local function logEvent(msg)
    local ok = pcall(function()
        table.insert(social.log, 1, string.format("[%s] %s", os.date("%H:%M:%S"), msg))
        while #social.log > 20 do table.remove(social.log) end
    end)
    if not ok then social.log = {} end
end

-- ============================================
-- ЧАТ
-- ============================================
local function sayLocal(msg)
    local ok, cp = pcall(function() return u8:decode(msg) end)
    if not ok or not cp then return end
    pcall(sampAddChatMessage, cp, -1)
end

local function sendChat(msg)
    if type(msg) ~= "string" or #msg == 0 then return end
    local ok, cp = pcall(function() return u8:decode(msg) end)
    if not ok or not cp then return end
    pcall(sampSendChat, cp)
end

-- ============================================
-- СОЦИАЛЬНЫЙ ФАЙЛ
-- ============================================
local function saveSocial()
    pcall(function()
        local data = {
            surveys        = social.surveys,
            flyers         = social.flyers,
            log            = social.log,
            hotkey         = HOTKEY,
            surveyQuestion = surveyQuestion,
            flyerMeText    = flyerMeText,
        }
        writeFile(SOCIAL_PATH, prettyJson(data))
    end)
end

local function loadSocial()
    local content = readFile(SOCIAL_PATH)
    if not content or #content == 0 then
        social.surveys = {}
        social.flyers  = {}
        return
    end
    local ok, data = pcall(decodeJson, content)
    if not ok or type(data) ~= "table" then
        social.surveys = {}
        social.flyers  = {}
        return
    end
    social.surveys = data.surveys or {}
    social.flyers  = data.flyers  or {}
    if type(data.log) == "table" then social.log = data.log end

    if type(data.hotkey) == "number"
       and data.hotkey >= 1 and data.hotkey <= 254
       and data.hotkey ~= 1 and data.hotkey ~= 2
       and data.hotkey ~= 4 and data.hotkey ~= 5 and data.hotkey ~= 6
    then
        HOTKEY = data.hotkey
    end

    if type(data.surveyQuestion) == "string" then
        surveyQuestion = data.surveyQuestion
    end

    if type(data.flyerMeText) == "string" and #data.flyerMeText > 0 then
        flyerMeText = data.flyerMeText
    end
end

local function ensureDataDir()
    if not doesDirectoryExist(DATA_DIR) then createDirectory(DATA_DIR) end
    if not doesFileExist(SOCIAL_PATH) then
        writeFile(SOCIAL_PATH, prettyJson({
            surveys = {}, flyers = {}, hotkey = HOTKEY,
            surveyQuestion = "",
            flyerMeText = DEFAULT_FLYER_ME_TEXT,
        }))
    end
    if not doesFileExist(GENDERS_PATH) then
        writeFile(GENDERS_PATH, "{}")
    end
end

-- ============================================
-- УТИЛИТЫ
-- ============================================
local function today()
    return os.date("%Y-%m-%d")
end

local function countTable(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function containsAny(text, words)
    if not text then return false end
    local lower = toLowerRu(text)
    for _, w in ipairs(words) do
        if lower:find(w, 1, true) then return true end
    end
    return false
end

local function vkToName(vk)
    if not vk or vk == 0 then return "—" end
    local ok, name = pcall(vkeys.id_to_name, vk)
    if ok and name then return name end
    return string.format("VK_0x%02X", vk)
end

local function nowMs()
    return math.floor(os.clock() * 1000)
end

-- ============================================
-- ОПРЕДЕЛЕНИЕ СВОЕГО НИКА И ID
-- ============================================
local function detectMyNick()
    if myNick and myId and myId >= 0 then return true end
    if not PLAYER_PED or PLAYER_PED == -1 then return false end

    local ok0, exists = pcall(doesCharExist, PLAYER_PED)
    if not ok0 or not exists then return false end

    local ok, isPlayer, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    if not ok or not isPlayer or type(id) ~= "number" or id < 0 then return false end

    local ok2, nick = pcall(sampGetPlayerNickname, id)
    if not ok2 or not nick or #nick == 0 then return false end

    myNick = nick
    myDisplayNick = nick:gsub("_", " ")
    myId = id
    logPrint("Мой ник: " .. myNick .. " (ID " .. myId .. ")")
    return true
end

-- ============================================
-- ИГРОКИ В РАДИУСЕ + КЭШ
-- ============================================
local function getPlayersInRange(maxDist)
    maxDist = maxDist or RANGE_FILTER
    local list = {}

    if not detectMyNick() then return list end

    local ok0, exists = pcall(doesCharExist, PLAYER_PED)
    if not ok0 or not exists then return list end

    local ok1, px, py, pz = pcall(getCharCoordinates, PLAYER_PED)
    if not ok1 then return list end

    local okA, allChars = pcall(getAllChars)
    if not okA or type(allChars) ~= "table" then return list end

    for _, handle in ipairs(allChars) do
        local okC, exists2 = pcall(doesCharExist, handle)
        if okC and exists2 and handle ~= PLAYER_PED then
            local okP, isPlayer, id = pcall(sampGetPlayerIdByCharHandle, handle)
            if okP and isPlayer and type(id) == "number" and id >= 0 and id ~= myId then
                local okN, nick = pcall(sampGetPlayerNickname, id)
                if okN and nick and #nick > 0 then
                    local okX, x, y, z = pcall(getCharCoordinates, handle)
                    if okX and type(x) == "number" then
                        local dx, dy, dz = x - px, y - py, z - pz
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                        if dist <= maxDist then
                            table.insert(list, { id = id, nick = nick, dist = dist })
                        end
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

local playersCache = { list = {}, time = -1e9 }

local function getPlayersCached(maxDist)
    maxDist = maxDist or RANGE_FILTER
    local now = nowMs()
    if now - playersCache.time > PLAYERS_CACHE_TTL_MS then
        local ok, lst = pcall(getPlayersInRange, MAX_TARGET_RANGE)
        playersCache.list = (ok and lst) or {}
        playersCache.time = now
    end
    if maxDist >= MAX_TARGET_RANGE then
        return playersCache.list
    end
    local out = {}
    for _, p in ipairs(playersCache.list) do
        if p.dist <= maxDist then table.insert(out, p) end
    end
    return out
end

local function invalidatePlayersCache()
    playersCache.time = -1e9
end

local function getActualTarget()
    local list = getPlayersCached(MAX_TARGET_RANGE)
    if #list == 0 then return nil end

    if selectedTargetId then
        for _, p in ipairs(list) do
            if p.id == selectedTargetId then return p end
        end
        selectedTargetId = nil
    end

    return list[1]
end

-- ============================================
-- СКРИНШОТ
-- ============================================
-- ВАЖНО: эта функция вызывается только из lua_thread (не из pcall)
local function makeScreenshot()
    logEvent("Скриншот: " .. TIME_COMMAND .. " -> F8")

    hideForShot = true
    wait(SCREENSHOT_HIDE_WAIT)

    sendChat(TIME_COMMAND)
    wait(SCREENSHOT_TIME_WAIT)

    pcall(setVirtualKeyDown, 0x77, true)
    wait(50)
    pcall(setVirtualKeyDown, 0x77, false)
    wait(300)

    hideForShot = false
end

-- ============================================
-- ЛИСТОВКА
-- ============================================
-- ВАЖНО: без pcall — wait() внутри pcall ломает корутину MoonLoader
local function giveFlyer(nick)
    lua_thread.create(function()
        if not social.active or social.stage ~= 3 then return end

        local g = getGender(nick)
        local tookWord = (g == "f") and "взяла" or "взял"

        sendChat("Спасибо за ваш ответ")
        wait(CHAT_DELAY)
        if not social.active or social.stage ~= 3 then return end
        sendChat("А так-же возьмите пожалуйста нашу листовку")
        wait(CHAT_DELAY)
        if not social.active or social.stage ~= 3 then return end
        sendChat("/me " .. flyerMeText)
        wait(CHAT_DELAY)
        if not social.active or social.stage ~= 3 then return end
        sendChat("/b /me " .. tookWord .. " листовку")
    end)
end

-- ============================================
-- ПРИВЕТСТВИЕ
-- ============================================
local function beginInterview(nick)
    lua_thread.create(function()
        if not social.active or social.stage ~= 1 then return end

        local g = getGender(nick)
        local citizenWord = (g == "f") and "Гражданка" or "Гражданин"

        clearLocalChat()
        sendChat("/clearchat")
        wait(CLEAR_CHAT_DELAY)
        if not social.active or social.stage ~= 1 then return end

        sendChat(citizenWord .. ", здравствуйте, я сотрудник San Fierro News - " .. (myDisplayNick or "?") .. ", уделите мне буквально минуту")
        wait(CHAT_DELAY + 500)

        if social.active and social.stage == 1 then
            sendChat("Я провожу Социальный опрос, сможете ответить на один вопрос?")
        end
    end)
end

-- ============================================
-- ЦИКЛ
-- ============================================
local function abortCycle(reason)
    if not social.active then return end
    logEvent("Прервано: " .. tostring(reason))
    social.active     = false
    social.stage      = 0
    social.targetId   = nil
    social.targetNick = nil
    pendingGenderConfirm = nil
    genderWindowOpen[0]  = false
end

local function startCycle()
    if social.active then
        sayLocal("[SFN] Цикл уже идёт.")
        return
    end
    if #surveyQuestion == 0 then
        sayLocal("[SFN] Сначала задай вопрос недели в окне скрипта (/social).")
        return
    end
    if not detectMyNick() then return end

    invalidatePlayersCache()

    local target = getActualTarget()
    if not target then
        sayLocal("[SFN] Нет игроков в радиусе " .. RANGE_FILTER .. "м.")
        return
    end

    logEvent("Старт: цель " .. target.nick .. " (" .. string.format("%.1f", target.dist) .. "м)")

    social.active     = true
    social.stage      = 1
    social.targetId   = target.id
    social.targetNick = target.nick

    if not genders[target.nick] then
        pendingGenderConfirm = {
            nick = target.nick,
            id   = target.id,
            callback = function()
                beginInterview(target.nick)
            end,
        }
        genderWindowOpen[0] = true
    else
        beginInterview(target.nick)
    end
end

-- ============================================
-- ПЕРЕХОД НА СТАДИЮ 2
-- ============================================
local function goToStage2(nick)
    social.stage      = 2
    logEvent("Согласие от " .. tostring(nick))
    lua_thread.create(function()
        wait(500)
        if not social.active or social.stage ~= 2 then return end
        sendChat(surveyQuestion)
    end)
end

-- ============================================
-- ОБРАБОТКА СООБЩЕНИЙ
-- ============================================
local function handlePlayerMessage(playerId, text)
    if not social.active then return end
    if playerId == myId then return end

    local okN, nick = pcall(sampGetPlayerNickname, playerId)
    if not okN or not nick then nick = "?" end

    local lower = toLowerRu(text or "")

    if social.stage == 1 then
        if playerId ~= social.targetId then return end
        if containsAny(text, AGREE_WORDS) then
            social.targetId   = playerId
            social.targetNick = nick
            goToStage2(nick)
        end

    elseif social.stage == 2 then
        if playerId ~= social.targetId then return end

        social.stage = 2.5
        social.surveys[nick] = { date = today() }
        saveSocial()
        logEvent("Опрос сдан: " .. nick .. " (" .. countTable(social.surveys) .. "/" .. SURVEY_LIMIT .. ") — ждём скрин №1")

    elseif social.stage == 3 then
        if playerId ~= social.targetId then return end

        -- засчитываем "взял" и "взяла" (без обязательного "листовк")
        local hasVzyal = lower:find("взял", 1, true) ~= nil
        if not hasVzyal then return end

        social.flyers[nick] = { date = today() }
        saveSocial()
        logEvent("Листовка сдана: " .. nick .. " (" .. countTable(social.flyers) .. "/" .. FLYER_LIMIT .. ") — ждём скрин №2")

        social.stage = 3.5
    end
end

-- ============================================
-- КНОПКИ СКРИНШОТОВ + ПОДТВЕРЖДЕНИЯ
-- ============================================
local function onConfirmAgree()
    if social.stage ~= 1 then return end
    local nick = social.targetNick
    if not nick then return end
    goToStage2(nick)
end

local function onScreenshot1()
    if social.stage ~= 2.5 then return end
    lua_thread.create(function()
        makeScreenshot()
        wait(500)
        if not social.active or social.stage ~= 2.5 then return end
        social.stage = 3
        giveFlyer(social.targetNick)
        logEvent("Скрин №1 сделан → этап 2 (листовка)")
    end)
end

-- Скриншот №2 доступен на двух стадиях:
--   3   — "ждём /me листовки": засчитываем вручную, если цель ответила нестандартно
--   3.5 — "ждём СКРИН №2": штатный путь после /me
local function onScreenshot2()
    if social.stage ~= 3.5 and social.stage ~= 3 then return end

    local forced = (social.stage == 3)
    local nick   = social.targetNick

    lua_thread.create(function()
        makeScreenshot()
        wait(500)
        if not social.active then return end

        -- Если принудительно, а листовка ещё не записана — записываем сейчас
        if forced and nick and not social.flyers[nick] then
            social.flyers[nick] = { date = today() }
            saveSocial()
            logEvent("Листовка сдана (вручную): " .. nick ..
                     " (" .. countTable(social.flyers) .. "/" .. FLYER_LIMIT .. ")")
        end

        sendChat("Спасибо")
        wait(CHAT_DELAY)
        if not social.active then return end
        abortCycle(forced and "успешно (вручную)" or "успешно")
    end)
end

-- ============================================
-- ПАРСИНГ СЕРВЕРНЫХ СТРОК
-- ============================================
local function parseChatLine(text)
    if not social.active then return end
    if not text then return end

    local okEnc, utf8text = pcall(function() return u8:encode(text) end)
    if not okEnc or not utf8text then utf8text = text end

    -- 1) "Nick[ID]: текст" (обычный чат)
    local bufNick, bufId = utf8text:match(PATTERN_NICK_WITH_ID)
    if bufNick and bufId then
        bufId = tonumber(bufId)
        if bufId and bufId ~= myId then
            local msg = utf8text:match(bufNick .. "%[" .. bufId .. "%]:%s*(.+)$")
            if msg then handlePlayerMessage(bufId, msg) return end
        end
    end

    -- 2) "/me" с ID: "Yuliya_Gomes[70] взяла"
    local meNickId, meIdStr, meMsgId = utf8text:match(PATTERN_ME_WITH_ID)
    if meNickId and meIdStr and meMsgId then
        local mid = tonumber(meIdStr)
        if mid and mid ~= myId then
            handlePlayerMessage(mid, meMsgId)
            return
        end
    end

    -- 3) "Nick: текст" (без ID)
    local nick, msg = utf8text:match(PATTERN_NICK_ONLY)
    if not (nick and msg and #msg > 0) then
        nick, msg = utf8text:match(PATTERN_ME_LINE)
    end
    if nick and msg and #msg > 0 then
        for _, p in ipairs(getPlayersCached(MAX_TARGET_RANGE)) do
            if p.nick == nick then handlePlayerMessage(p.id, msg) return end
        end
    end
end

if sampev_ok and sampev then
    function sampev.onServerMessage(color, text)
        if not text then return end
        pcall(parseChatLine, text)
    end

    function sampev.onChatMessage(playerId, text)
        if not social.active then return end
        if not text then return end
        if playerId == myId then return end
        pcall(function()
            local okEnc, utf8text = pcall(function() return u8:encode(text) end)
            if not okEnc or not utf8text then utf8text = text end
            handlePlayerMessage(playerId, utf8text)
        end)
    end

    function sampev.onPlayerDisconnect(playerId, reason)
        if not social.active then return end
        if playerId == social.targetId then
            abortCycle("цель отключилась (id " .. tostring(playerId) .. ")")
        end
    end
end

-- ============================================
-- ХЕЛПЕРЫ
-- ============================================
local BTN_START_W = 260
local function centeredButton(label, w, h)
    local avail = imgui.GetWindowWidth()
    imgui.SetCursorPosX((avail - w) / 2)
    return imgui.Button(label, imgui.ImVec2(w, h))
end

-- ============================================
-- ХОТКЕЙ
-- ============================================
local function isMouseVk(vk)
    return vk == 1 or vk == 2 or vk == 4 or vk == 5 or vk == 6
end

local function updateHotkey()
    if not WinState[0] then hotkeyWaiting = false end

    if hotkeyWaiting then
        if isKeyDown(0x1B) then
            hotkeyWaiting = false
            hotkeyPressedThisFrame = true
            return
        end
        for vk = 1, 254 do
            if isKeyDown(vk) and not isMouseVk(vk) then
                HOTKEY = vk
                hotkeyWaiting = false
                hotkeyPressedThisFrame = true
                saveSocial()
                logEvent("Хоткей изменён: " .. vkToName(vk))
                return
            end
        end
        return
    end

    if isKeyDown(HOTKEY) and not sampIsCursorActive() and not sampIsChatInputActive() then
        if not hotkeyPressedThisFrame then
            WinState[0] = not WinState[0]
            hotkeyPressedThisFrame = true
        end
    else
        hotkeyPressedThisFrame = false
    end
end

-- ============================================
-- ОКНО
-- ============================================
imgui.OnFrame(function() return WinState[0] and not hideForShot end, function()
    local ok, err = pcall(function()

    imgui.SetNextWindowSizeConstraints(
        imgui.ImVec2(MIN_WINDOW_WIDTH, 100),
        imgui.ImVec2(700, 900)
    )
    imgui.SetNextWindowBgAlpha(1.0)

    local isOpen, _ = imgui.Begin("SFN | Соцопрос и листовки", WinState,
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysAutoResize)

    if not isOpen then imgui.End() return end

    imgui.Text("Хоткей окна: ")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.2, 0.6, 0.9, 1), vkToName(HOTKEY))
    imgui.SameLine()
    if hotkeyWaiting then
        imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1), "  [нажмите клавишу / ESC — отмена]")
    else
        if imgui.SmallButton("Изменить") then hotkeyWaiting = true end
    end

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    local players = getPlayersCached(RANGE_FILTER)
    imgui.Text("Игроков в радиусе " .. RANGE_FILTER .. "м: " .. #players)

    if #players > 0 then
        imgui.BeginChild("players_in_range", imgui.ImVec2(-1, math.min(#players * 22 + 8, 130)), false)
        for i, p in ipairs(players) do
            local isSelected      = (selectedTargetId and p.id == selectedTargetId)
                                    or (not selectedTargetId and i == 1)
            local alreadySurveyed = social.surveys[p.nick] ~= nil
            local alreadyFlyered  = social.flyers[p.nick] ~= nil

            if isSelected then
                imgui.TextColored(imgui.ImVec4(0.9, 0.6, 0.0, 1), "*")
            else
                imgui.Text(" ")
            end
            imgui.SameLine()

            -- Приоритет цвета ника:
            --   1) уже опрошен — красный
            --   2) выбран как цель — оранжевый
            --   3) обычный — тёмный
            local col
            if alreadySurveyed then
                col = imgui.ImVec4(0.85, 0.15, 0.15, 1)
            elseif isSelected then
                col = imgui.ImVec4(0.9, 0.6, 0.0, 1)
            else
                col = imgui.ImVec4(0.15, 0.15, 0.15, 1)
            end

            imgui.TextColored(col, p.nick)
            if imgui.IsItemClicked() then selectedTargetId = p.id end
            if imgui.IsItemHovered() then
                imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                if alreadySurveyed and alreadyFlyered then
                    imgui.SetTooltip("Уже опрошен и листовка выдана — лучше выбрать другого")
                elseif alreadySurveyed then
                    imgui.SetTooltip("Уже опрошен — лучше выбрать другого")
                elseif alreadyFlyered then
                    imgui.SetTooltip("Опрос ещё не сдан, но листовка уже выдана")
                end
            end

            -- Метки справа от ника
            if alreadySurveyed then
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.85, 0.15, 0.15, 1), "[ОПРОШЕН]")
            end
            if alreadyFlyered then
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1), "[ЛИСТ]")
            end

            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), string.format("%.1f м", p.dist))

            imgui.SameLine()
            local g = genders[p.nick]
            if g == "f" then
                imgui.TextColored(imgui.ImVec4(0.9, 0.4, 0.7, 1), "[Ж]")
            elseif g == "m" then
                imgui.TextColored(imgui.ImVec4(0.2, 0.5, 0.9, 1), "[М]")
            else
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), "[?]")
                if imgui.IsItemHovered() then
                    imgui.SetTooltip("Пол не указан — спросим при старте")
                end
            end
        end
        imgui.EndChild()
    end

    imgui.Dummy(imgui.ImVec2(0, 2))
    local realTarget = getActualTarget()
    if realTarget then
        local rtSurveyed = social.surveys[realTarget.nick] ~= nil

        imgui.Text("Цель: ")
        imgui.SameLine()
        if rtSurveyed then
            imgui.TextColored(imgui.ImVec4(0.85, 0.15, 0.15, 1), realTarget.nick)
        else
            imgui.TextColored(imgui.ImVec4(0.9, 0.6, 0.0, 1), realTarget.nick)
        end

        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), string.format("(%.1f м)", realTarget.dist))

        if rtSurveyed then
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.85, 0.15, 0.15, 1), "[УЖЕ ОПРОШЕН]")
        end

        imgui.SameLine()
        if selectedTargetId then
            if imgui.SmallButton("сброс") then selectedTargetId = nil end
        else
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), "[авто]")
        end
    else
        imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), "Цель: —")
    end

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    local cntS = countTable(social.surveys)
    local cntF = countTable(social.flyers)

    imgui.Text("Опросы:   ")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.2, 0.6, 0.9, 1), string.format("%d / %d", cntS, SURVEY_LIMIT))

    imgui.Text("Листовки: ")
    imgui.SameLine()
    imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1), string.format("%d / %d", cntF, FLYER_LIMIT))

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    -- ============================================
    -- ВОПРОС НЕДЕЛИ
    -- ============================================
    if imgui.CollapsingHeader("Вопрос недели##q_header", imgui.TreeNodeFlags.DefaultOpen) then

        if #surveyQuestion > 0 then
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), "Сейчас задаётся игрокам:")
            imgui.PushTextWrapPos(imgui.GetWindowWidth() - 12)
            imgui.TextWrapped(surveyQuestion)
            imgui.PopTextWrapPos()
        else
            imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1),
                "Вопрос не задан — впиши ниже и нажми «Применить».")
        end

        imgui.Dummy(imgui.ImVec2(0, 4))
        imgui.Text("Новый вопрос:")

        imgui.PushItemWidth(-1)
        imgui.InputText("##survey_q_buf", questionBuf, QUESTION_BUF_SIZE)
        imgui.PopItemWidth()

        local qLen    = #getQuestionBuffer()
        local qOver   = qLen > CHAT_MSG_WARN_LEN
        local qEmpty  = qLen == 0
        local qLenCol = qOver and imgui.ImVec4(0.9, 0.3, 0.3, 1)
                               or imgui.ImVec4(0.55, 0.55, 0.55, 1)
        imgui.TextColored(qLenCol, string.format("%d / %d символов (лимит чата SA-MP)",
                                                 qLen, CHAT_MSG_WARN_LEN))

        if not qEmpty and getQuestionBuffer() ~= surveyQuestion then
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1), "● не применено")
        end

        imgui.Dummy(imgui.ImVec2(0, 2))

        local canApply = (not qEmpty) and (not qOver) and (getQuestionBuffer() ~= surveyQuestion)

        if canApply then
            imgui.PushStyleColor(imgui.Col.Button,         imgui.ImVec4(0.20, 0.60, 0.90, 0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered,  imgui.ImVec4(0.30, 0.70, 1.00, 1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,   imgui.ImVec4(0.10, 0.50, 0.80, 1.00))
        else
            local gray = imgui.ImVec4(0.75, 0.75, 0.78, 0.75)
            imgui.PushStyleColor(imgui.Col.Button,         gray)
            imgui.PushStyleColor(imgui.Col.ButtonHovered,  gray)
            imgui.PushStyleColor(imgui.Col.ButtonActive,   gray)
        end

        if imgui.Button("Применить вопрос", imgui.ImVec2(-1, 30)) and canApply then
            surveyQuestion = getQuestionBuffer()
            saveSocial()
            logEvent("Вопрос обновлён: " .. surveyQuestion)
        end

        imgui.PopStyleColor(3)
    end

    -- ============================================
    -- ТЕКСТ /me ДЛЯ ЛИСТОВКИ
    -- ============================================
    if imgui.CollapsingHeader("Текст /me для листовки##flyer_me_header", imgui.TreeNodeFlags.DefaultOpen) then

        if #flyerMeText > 0 then
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), "Сейчас отправляется:")
            imgui.PushTextWrapPos(imgui.GetWindowWidth() - 12)
            imgui.TextWrapped("/me " .. flyerMeText)
            imgui.PopTextWrapPos()
        else
            imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1),
                "Текст /me пуст — впиши ниже и нажми «Применить».")
        end

        imgui.Dummy(imgui.ImVec2(0, 4))
        imgui.Text("Новый текст (без \"/me\"):")

        imgui.PushItemWidth(-1)
        imgui.InputText("##flyer_me_buf", flyerMeBuf, FLYER_ME_BUF_SIZE)
        imgui.PopItemWidth()

        local fmLen    = #getFlyerMeBuffer()
        local fmOver   = fmLen > FLYER_ME_WARN_LEN
        local fmEmpty  = fmLen == 0
        local fmLenCol = fmOver and imgui.ImVec4(0.9, 0.3, 0.3, 1)
                                or imgui.ImVec4(0.55, 0.55, 0.55, 1)
        imgui.TextColored(fmLenCol, string.format("%d / %d символов (лимит чата SA-MP)",
                                                  fmLen, FLYER_ME_WARN_LEN))

        if not fmEmpty and getFlyerMeBuffer() ~= flyerMeText then
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1), "● не применено")
        end

        imgui.Dummy(imgui.ImVec2(0, 2))

        local canApplyFm = (not fmEmpty) and (not fmOver) and (getFlyerMeBuffer() ~= flyerMeText)

        if canApplyFm then
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.20, 0.60, 0.90, 0.90))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.30, 0.70, 1.00, 1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.10, 0.50, 0.80, 1.00))
        else
            local gray = imgui.ImVec4(0.75, 0.75, 0.78, 0.75)
            imgui.PushStyleColor(imgui.Col.Button,        gray)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, gray)
            imgui.PushStyleColor(imgui.Col.ButtonActive,  gray)
        end

        if imgui.Button("Применить текст", imgui.ImVec2(-1, 30)) and canApplyFm then
            flyerMeText = getFlyerMeBuffer()
            saveSocial()
            logEvent("Текст /me листовки обновлён: " .. flyerMeText)
        end

        imgui.PopStyleColor(3)

        imgui.Dummy(imgui.ImVec2(0, 2))
        if imgui.SmallButton("Сбросить к стандартному") then
            flyerMeText = DEFAULT_FLYER_ME_TEXT
            setFlyerMeBuffer(flyerMeText)
            saveSocial()
            logEvent("Текст /me листовки сброшен к стандартному")
        end
    end

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    -- СТАДИЯ / КНОПКА
    if social.active then
        local activeSurveyed = social.targetNick and social.surveys[social.targetNick] ~= nil

        imgui.Text("Цель: ")
        imgui.SameLine()
        if activeSurveyed then
            imgui.TextColored(imgui.ImVec4(0.85, 0.15, 0.15, 1), social.targetNick)
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.85, 0.15, 0.15, 1), "[УЖЕ ОПРОШЕН]")
        else
            imgui.TextColored(imgui.ImVec4(0.9, 0.6, 0.0, 1), social.targetNick or "—")
        end

        local stageNames = {
            [0]   = "—",
            [1]   = "ждём согласие",
            [2]   = "ждём ответ",
            [2.5] = "ЖДЁМ СКРИН №1 (соцопрос)",
            [3]   = "ждём /me листовки",
            [3.5] = "ЖДЁМ СКРИН №2 (листовка)",
        }
        local stageName = stageNames[social.stage] or "?"
        if social.stage == 2.5 or social.stage == 3.5 then
            imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1), "Стадия: " .. stageName)
        else
            imgui.Text("Стадия: " .. stageName)
        end

        imgui.Dummy(imgui.ImVec2(0, 4))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
        if centeredButton("Стоп", BTN_START_W, 28) then abortCycle("вручную") end
        imgui.PopStyleColor(3)
    else
        local noQuestion = (#surveyQuestion == 0)

        if noQuestion then
            local gray = imgui.ImVec4(0.75, 0.75, 0.78, 0.75)
            imgui.PushStyleColor(imgui.Col.Button,         gray)
            imgui.PushStyleColor(imgui.Col.ButtonHovered,  gray)
            imgui.PushStyleColor(imgui.Col.ButtonActive,   gray)
        else
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.7, 0.3, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.8, 0.4, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.6, 0.2, 1.0))
        end

        if centeredButton("Старт", BTN_START_W, 32) and not noQuestion then
            startCycle()
        end

        imgui.PopStyleColor(3)

        if noQuestion then
            imgui.TextColored(imgui.ImVec4(0.9, 0.5, 0.1, 1),
                "Сначала задай вопрос недели (выше).")
        end
    end

    if social.active and social.stage == 1 then
        imgui.Dummy(imgui.ImVec2(0, 6))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 0.9, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.7, 1.0, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.5, 0.8, 1.0))
        if centeredButton("Подтвердить согласие", BTN_START_W, 32) then
            onConfirmAgree()
        end
        imgui.PopStyleColor(3)
    end

    -- КНОПКА СКРИНШОТ №1 (соцопрос)
    if social.active and social.stage == 2.5 then
        imgui.Dummy(imgui.ImVec2(0, 6))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.7, 0.3, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.8, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.6, 0.2, 1.0))
        if centeredButton("СКРИНШОТ №1 (соцопрос)", BTN_START_W, 36) then
            onScreenshot1()
        end
        imgui.PopStyleColor(3)
    end

    -- КНОПКА СКРИНШОТ №2 (листовка)
    --   стадия 3.5 — штатный путь (после /me взял)
    --   стадия 3   — принудительно, если цель ответила нестандартно
    if social.active and (social.stage == 3.5 or social.stage == 3) then
        local isForced = (social.stage == 3)

        imgui.Dummy(imgui.ImVec2(0, 6))

        if isForced then
            -- Оранжевый = «нажми, если цель уже взяла, но /me не распознался»
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.95, 0.55, 0.10, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.00, 0.65, 0.20, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.80, 0.45, 0.05, 1.0))
        else
            imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.2, 0.7, 0.3, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.8, 0.4, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.1, 0.6, 0.2, 1.0))
        end

        local label = isForced
            and "СКРИНШОТ №2 (цель уже взяла)"
            or  "СКРИНШОТ №2 (листовка)"

        if centeredButton(label, BTN_START_W, 36) then
            onScreenshot2()
        end
        imgui.PopStyleColor(3)

        if isForced then
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1),
                "Нажми, если цель взяла листовку, но /me не распознан.")
        end
    end

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    if imgui.CollapsingHeader("Опросы (" .. cntS .. ")") then
        if cntS == 0 then
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), "Пока пусто")
        else
            local sorted = {}
            for nick, info in pairs(social.surveys) do
                table.insert(sorted, { nick = nick, date = info.date })
            end
            table.sort(sorted, function(a, b) return a.nick < b.nick end)

            imgui.BeginChild("surveys_list", imgui.ImVec2(-1, math.min(#sorted * 22 + 8, 200)), false)
            for i, it in ipairs(sorted) do
                imgui.Text(string.format("%d. %s", i, it.nick))
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), " (" .. it.date .. ")")
            end
            imgui.EndChild()
        end
    end

    if imgui.CollapsingHeader("Листовки (" .. cntF .. ")") then
        if cntF == 0 then
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1), "Пока пусто")
        else
            local sorted = {}
            for nick, info in pairs(social.flyers) do
                table.insert(sorted, { nick = nick, date = info.date })
            end
            table.sort(sorted, function(a, b) return a.nick < b.nick end)

            imgui.BeginChild("flyers_list", imgui.ImVec2(-1, math.min(#sorted * 22 + 8, 200)), false)
            for i, it in ipairs(sorted) do
                imgui.Text(string.format("%d. %s", i, it.nick))
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), " (" .. it.date .. ")")
            end
            imgui.EndChild()
        end
    end

    imgui.Dummy(imgui.ImVec2(0, 4))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
    if centeredButton("Очистить базы", BTN_START_W, 26) then
        imgui.OpenPopup("confirm_clear_social")
    end
    imgui.PopStyleColor(3)

    if imgui.BeginPopupModal("confirm_clear_social", nil, imgui.WindowFlags.AlwaysAutoResize) then
        imgui.Text("Очистить базы опросов и листовок?")
        imgui.Dummy(imgui.ImVec2(0, 10))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
        if imgui.Button("Да, очистить", imgui.ImVec2(140, 28)) then
            social.surveys = {}
            social.flyers  = {}
            saveSocial()
            logEvent("Базы очищены")
            imgui.CloseCurrentPopup()
        end
        imgui.PopStyleColor(3)
        imgui.SameLine()
        if imgui.Button("Отмена", imgui.ImVec2(140, 28)) then
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end

    imgui.End()

    if genderWindowOpen[0] and pendingGenderConfirm then
        imgui.SetNextWindowSize(imgui.ImVec2(320, 150), imgui.Cond.Always)
        imgui.SetNextWindowBgAlpha(1.0)
        imgui.SetNextWindowPos(
            imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2 - 160,
                         imgui.GetIO().DisplaySize.y / 2 - 75),
            imgui.Cond.Always
        )

        local isOpenG, _ = imgui.Begin("Пол игрока", genderWindowOpen,
            imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)

        if isOpenG then
            imgui.Text("Укажите пол игрока:")
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.5, 0.9, 1))
            imgui.Text("   " .. pendingGenderConfirm.nick)
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(0, 10))

            local btnW = (imgui.GetWindowWidth() - 30) / 2

            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.55, 0.9, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.65, 1.0, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.45, 0.8, 1.0))
            if imgui.Button("Парень", imgui.ImVec2(btnW, 34)) then
                genders[pendingGenderConfirm.nick] = "m"
                saveGenders()
                logEvent("Пол для " .. pendingGenderConfirm.nick .. ": парень")
                local cb = pendingGenderConfirm.callback
                pendingGenderConfirm = nil
                genderWindowOpen[0] = false
                if cb then cb() end
            end
            imgui.PopStyleColor(3)

            imgui.SameLine()

            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.4, 0.7, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.5, 0.8, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.8, 0.3, 0.6, 1.0))
            if imgui.Button("Девушка", imgui.ImVec2(btnW, 34)) then
                genders[pendingGenderConfirm.nick] = "f"
                saveGenders()
                logEvent("Пол для " .. pendingGenderConfirm.nick .. ": девушка")
                local cb = pendingGenderConfirm.callback
                pendingGenderConfirm = nil
                genderWindowOpen[0] = false
                if cb then cb() end
            end
            imgui.PopStyleColor(3)

            imgui.Dummy(imgui.ImVec2(0, 6))
            imgui.TextColored(imgui.ImVec4(0.55, 0.55, 0.55, 1),
                "Пол сохранится в базу и больше не спросит.")
        else
            local nick = pendingGenderConfirm and pendingGenderConfirm.nick
            pendingGenderConfirm = nil
            genderWindowOpen[0] = false
            if social.active and social.stage == 1 then
                abortCycle("пол не выбран" .. (nick and (" для " .. nick) or ""))
            end
        end
        imgui.End()
    end

    end)
    if not ok then logPrint("OnFrame ERR: " .. tostring(err)) end
end)

-- ============================================
-- КОМАНДЫ
-- ============================================
local function cmd_social() WinState[0] = not WinState[0] end
local function cmd_socialstart() startCycle() end
local function cmd_socialstop() abortCycle("вручную") end

local function cmd_socialreset()
    social.surveys = {}
    social.flyers  = {}
    saveSocial()
    sayLocal("[SFN] Базы опросов и листовок очищены.")
    logEvent("Базы очищены вручную")
end

local function cmd_genders()
    sayLocal("[SFN] База полов: " .. countTable(genders) .. " записей")
end

-- ============================================
-- MAIN
-- ============================================
function main()
    while not isSampAvailable() do wait(0) end

    pcall(function()
        ensureDataDir()
        loadSocial()
        genders = loadGenders()
        setQuestionBuffer(surveyQuestion)
        setFlyerMeBuffer(flyerMeText)
    end)

    -- init-тред: без pcall, wait() внутри нельзя оборачивать
    lua_thread.create(function()
        while not detectMyNick() do wait(500) end
    end)

    pcall(sampRegisterChatCommand, "social",      cmd_social)
    pcall(sampRegisterChatCommand, "socialstart", cmd_socialstart)
    pcall(sampRegisterChatCommand, "socialstop",  cmd_socialstop)
    pcall(sampRegisterChatCommand, "socialreset", cmd_socialreset)
    pcall(sampRegisterChatCommand, "genders",     cmd_genders)

    logPrint("Загружен. /social — окно, " .. vkToName(HOTKEY) .. " — хоткей.")

    while true do
        wait(0)
        pcall(function()
            if not myNick or not myId or myId < 0 then detectMyNick() end
            updateHotkey()
        end)
    end
end

function scriptUnload()
    saveSocial()
    saveGenders()
end