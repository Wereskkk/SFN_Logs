local imgui = require('mimgui')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new
local ffi = require('ffi')

local sha256 = (function()
    local band    = bit.band
    local bxor    = bit.bxor
    local bor     = bit.bor
    local bnot    = bit.bnot
    local rrotate = bit.ror
    local lshift  = bit.lshift
    local rshift  = bit.rshift
    local tobit   = bit.tobit

    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    local function preprocess(msg)
        local len = #msg
        local bitlen = len * 8
        msg = msg .. "\128"
        while (#msg % 64) ~= 56 do msg = msg .. "\0" end
        msg = msg .. "\0\0\0\0" .. string.char(
            band(rshift(bitlen, 24), 0xff),
            band(rshift(bitlen, 16), 0xff),
            band(rshift(bitlen,  8), 0xff),
            band(bitlen, 0xff))
        return msg
    end

    local function hash(msg)
        msg = preprocess(msg)
        local H = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        }
        for i = 1, #msg, 64 do
            local w = {}
            for j = 0, 15 do
                local k = i + j * 4
                w[j] = bor(
                    lshift(msg:byte(k), 24),
                    lshift(msg:byte(k + 1), 16),
                    lshift(msg:byte(k + 2), 8),
                    msg:byte(k + 3))
            end
            for j = 16, 63 do
                local s0 = bxor(rrotate(w[j-15], 7), rrotate(w[j-15], 18), rshift(w[j-15], 3))
                local s1 = bxor(rrotate(w[j-2], 17), rrotate(w[j-2], 19), rshift(w[j-2], 10))
                w[j] = tobit(w[j-16] + s0 + w[j-7] + s1)
            end
            local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for j = 0, 63 do
                local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local t1 = tobit(h + S1 + ch + K[j + 1] + w[j])
                local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
                local maj = bxor(band(a, b), band(a, c), band(b, c))
                local t2 = tobit(S0 + maj)
                h = g; g = f; f = e
                e = tobit(d + t1)
                d = c; c = b; b = a
                a = tobit(t1 + t2)
            end
            H[1] = tobit(H[1] + a); H[2] = tobit(H[2] + b)
            H[3] = tobit(H[3] + c); H[4] = tobit(H[4] + d)
            H[5] = tobit(H[5] + e); H[6] = tobit(H[6] + f)
            H[7] = tobit(H[7] + g); H[8] = tobit(H[8] + h)
        end
        return bit.tohex(H[1], 8) .. bit.tohex(H[2], 8) ..
               bit.tohex(H[3], 8) .. bit.tohex(H[4], 8) ..
               bit.tohex(H[5], 8) .. bit.tohex(H[6], 8) ..
               bit.tohex(H[7], 8) .. bit.tohex(H[8], 8)
    end

    return { hash = hash }
end)()

local sampev_ok, sampev = pcall(require, 'samp.events')

local function logPrint(msg) print(u8:decode(tostring(msg))) end
local function logAction(msg) logPrint("[SFN] " .. os.date("%H:%M:%S") .. " " .. msg) end

CURRENT_VERSION = "7.0.1"

VERSION_URL = "https://raw.githubusercontent.com/Wereskkk/sfn-efir/refs/heads/main/sfn_version.txt"
UPDATE_URL  = "https://raw.githubusercontent.com/Wereskkk/sfn-efir/refs/heads/main/sfn_efir_helper.lua"

local function resolveScriptPath()
    local ok, sp = pcall(thisScript)
    if ok and type(sp) == "string" and #sp > 0 and sp:find("%.lua") then
        return sp
    end
    local wd = getWorkingDirectory() or ""
    local candidates = {
        wd .. "\\moonloader\\sfn_efir_helper.lua",
        wd .. "\\packs\\Default\\moonloader\\sfn_efir_helper.lua",
        wd .. "\\..\\moonloader\\sfn_efir_helper.lua",
        wd .. "\\sfn_efir_helper.lua",
    }
    for _, path in ipairs(candidates) do
        if doesFileExist(path) then return path end
    end
    return ""
end

SCRIPT_PATH = resolveScriptPath()
SCRIPT_DIR  = (SCRIPT_PATH ~= "" and SCRIPT_PATH:match("^(.*)\\[^\\]+$")) or getWorkingDirectory() or ""
UPDATE_TMP  = (SCRIPT_PATH ~= "" and (SCRIPT_PATH .. ".new")) or ""

local function applyPendingUpdate()
    if SCRIPT_PATH == "" or UPDATE_TMP == "" then return false end
    if not doesFileExist(UPDATE_TMP) then return false end
    local f = io.open(UPDATE_TMP, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    if not data or #data < 1024 then
        os.remove(UPDATE_TMP)
        return false
    end
    local out = io.open(SCRIPT_PATH, "wb")
    if not out then return false end
    out:write(data)
    out:close()
    os.remove(UPDATE_TMP)
    return true
end

local function checkForUpdates()
    if VERSION_URL == "" or UPDATE_URL == "" then return end
    if SCRIPT_PATH == "" or UPDATE_TMP == "" then return end

    lua_thread.create(function()
        wait(8000)
        local verTmp = SCRIPT_DIR .. "\\sfn_version.tmp"
        local ok = downloadUrlToFile(VERSION_URL, verTmp)
        if not ok then return end
        wait(400)
        local f = io.open(verTmp, "r")
        if not f then return end
        local remoteVersion = f:read("*a"):gsub("%s+", "")
        f:close()
        os.remove(verTmp)
        if remoteVersion == "" or remoteVersion == CURRENT_VERSION then return end
        logPrint("[SFN] Доступна новая версия: " .. remoteVersion)
        local ok2 = downloadUrlToFile(UPDATE_URL, UPDATE_TMP)
        if not ok2 then return end
        wait(400)
        local nf = io.open(UPDATE_TMP, "rb")
        if not nf then return end
        local data = nf:read("*a")
        nf:close()
        if not data or #data < 1024 then
            os.remove(UPDATE_TMP)
            return
        end
        logPrint("[SFN] Обновление загружено.")
        sampAddChatMessage(
            "{FFD700}[SFN] Доступно обновление " .. remoteVersion ..
            ". Перезапустите игру.", -1)
    end)
end

local DATA_DIR = getWorkingDirectory() .. "\\sfn_data"
local CONFIG_PATH = DATA_DIR .. "\\config.json"
local SCORES_PATH = DATA_DIR .. "\\scores.json"
local GENDERS_PATH = DATA_DIR .. "\\genders.json"
local TEXTS_PATH  = DATA_DIR .. "\\texts.lua"
local ANAGRAMS_PATH = DATA_DIR .. "\\anagrams.lua"
local WORDS_PATH = DATA_DIR .. "\\words.lua"

local DEFAULT_HOTKEY = 0x7A
local PRICE_PER_MINUTE = 6000
local SCREENSHOT_INTERVAL = 10 * 60
local SPEECH_DELAY = 5

local MIN_WINDOW_WIDTH = 340
local CHAT_MAX_LEN = 120

local PATTERN_AIR_MESSAGE        = "%[[^%]]+%]%s*(%d+)%."
local PATTERN_ANAGRAM_MESSAGE    = "%[[^%]]+%]%s*([^%[%]%.]+)%."
local PATTERN_NICK_WITH_ID       = "([%a][%w_]+)%[(%d+)%]"
local PATTERN_AIR_MESSAGE_SIGNED = "%[[^%]]+%]%s*(%-?%s*%d+)%."

local SCRIPT_NAME = "Помощник эфира"

local AUTH_SALT = "SFN_2026_SECURE_x7p9nq2m"

local ADMIN_NICK_HASHES = {
    "548213b64ed49aaf6e51ff5f263e266665c8b6623ea8a7c05d331605d3728e82",
}

local ALLOWED_NICK_HASHES = {
    "96c38190233366a49a2cfbec525f0d8a8205a34bd428b1ff70c50bdf26842c91",
}

local ACCESS_GRANTED = false
local ACCESS_CHECKED = false

local str_sub, str_char, str_upper = string.sub, string.char, string.upper
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

local function cp1251Upper(s)
    if not s then return s end
    s = str_upper(s)
    local len, res = #s, {}
    for i = 1, len do
        local ch = str_sub(s, i, i)
        res[i] = lu_rus[ch] or ch
    end
    return tbl_concat(res)
end

local function normalizeAnswer(s)
    if not s then return "" end
    s = cp1251Upper(s)
    s = s:gsub("[%.%!%?]$", "")
    s = s:gsub("Ё", "Е")
    s = s:gsub("%s+", "")
    return s
end

local function getDefaultTexts()
    return {
        intro = { jingle = "...", lines = { "..." } },
        outro = { lines = { "..." } },
        rules = { math = { "..." }, anagram = { "..." }, vyshibaly = { "..." } },
        scores_intros = { "..." },
        advertisement = { jingle = "...", intros = { "..." }, blocks = { { "..." } } },
        system = {
            loaded_title    = "========== San Fierro News ==========",
            loaded_message  = "SFN Helper — скрипт успешно запущен!",
            loaded_greeting = "Приветствую, {NICK}!",
            loaded_help     = "Чтобы открыть меню — нажми F11 или введи /efir",
            loaded_bottom   = "=====================================",
            menu_opened = "[SFN] Меню открыто",
            menu_closed = "[SFN] Меню закрыто",
            screenshot_reminder = "[SFN] Пора сделать скриншот!",
            screenshot_done = "[SFN] Скриншот #{N} сделан",
            base_cleared = "[SFN] База баллов очищена",
            no_scores = "[SFN] Пока никто не набрал баллов",
            no_answer = "[SFN] Нет верного ответа для начисления",
            no_anagram_words = "[SFN] База слов для анаграмм пуста.",
        },
    }
end

local function loadTexts()
    local f = loadfile(TEXTS_PATH)
    if not f then logPrint("[SFN] texts.lua не найден.") return nil end
    local ok, result = pcall(f)
    if not ok or type(result) ~= "table" then return nil end
    if not result.intro or not result.intro.lines then return nil end
    return result
end

local TEXTS = loadTexts() or getDefaultTexts()

local ANAGRAMS = {}
local VYSHIBALY_WORDS = {}

local function loadWordList(path, label)
    local f = loadfile(path)
    if not f then return nil end
    local ok, result = pcall(f)
    if not ok or type(result) ~= "table" then return nil end
    local words = {}
    for _, word in ipairs(result) do
        if type(word) == "string" and #word > 0 then
            local cp = u8:decode(word)
            cp = cp1251Upper(cp)
            table.insert(words, u8:encode(cp))
        end
    end
    return words
end

local loadedWords = loadWordList(WORDS_PATH, "words.lua")
local loadedAnagrams = loadWordList(ANAGRAMS_PATH, "anagrams.lua")

if loadedWords then VYSHIBALY_WORDS = loadedWords else VYSHIBALY_WORDS = loadedAnagrams or {} end
if loadedAnagrams then ANAGRAMS = loadedAnagrams else ANAGRAMS = loadedWords or {} end

local WinState = new.bool(true)

local HOTKEY = DEFAULT_HOTKEY
local MAX_SCORE = 20
local PRIZE_FUND = 500000
local efirRunning = false
local efirStartTime = 0
local screenshots = 0
local lastScreenshotTime = 0
local screenshotNotified = false

local currentMode = "math"
local currentType = "Математика"

local mathQuestion = ""
local mathAnswer = 0
local mathQuestionSuffix = " = ?"

local MATH_TYPES = {
    "classic", "addsub", "multiply", "divide",
    "brackets", "mixed", "equation",
}
local lastMathType = nil

local anagramWord = ""
local anagramShuffled = ""
local vyshibalyWord = ""
local vyshibalyMasked = ""
local currentFirstAnswer = nil
local scores = {}
local genders = {}
local pendingGenderConfirm = nil
local genderWindowOpen = new.bool(false)

local myNick = "Unknown"
local myDisplayNick = "Unknown"
local myId = -1

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

imgui.OnInitialize(function() ApplyTheme() end)

local function say(msg) sampAddChatMessage(u8:decode(msg), -1) end
local function sendChat(msg) sampSendChat(u8:decode(msg)) end

local function sendPacked(items, prefixFirst, prefixRest)
    if not items or #items == 0 then return end
    prefixFirst = prefixFirst or ""
    prefixRest = prefixRest or prefixFirst
    local idx = 1
    local isFirstMsg = true
    while idx <= #items do
        local prefix = isFirstMsg and prefixFirst or prefixRest
        if #prefix + #items[idx] > CHAT_MAX_LEN and #prefix > #prefixRest then
            prefix = prefixRest
        end
        local current = prefix .. items[idx]
        local j = idx + 1
        while j <= #items do
            local candidate = current .. ", " .. items[j]
            if #candidate > CHAT_MAX_LEN then break end
            current = candidate
            j = j + 1
        end
        if current:sub(-1) ~= "." then current = current .. "." end
        sendChat(current)
        wait(3000)
        idx = j
        isFirstMsg = false
    end
end

local function formatNick(nick)
    if not nick then return "" end
    return (nick:gsub("_", " "))
end

local function formatAnagramDots(word)
    if not word or #word == 0 then return "" end
    local chars = {}
    local i = 1
    while i <= #word do
        local b = word:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        table.insert(chars, word:sub(i, i + len - 1))
        i = i + len
    end
    return table.concat(chars, ".")
end

local function formatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function pluralScore(n)
    local mod10 = n % 10
    local mod100 = n % 100
    if mod100 >= 11 and mod100 <= 14 then return "баллов" end
    if mod10 == 1 then return "балл" end
    if mod10 >= 2 and mod10 <= 4 then return "балла" end
    return "баллов"
end

local function getGender(nick)
    if not nick then return "m" end
    return genders[nick] or "m"
end

local function genderForms(nick)
    local g = getGender(nick)
    if g == "f" then
        return { heShe = "она", hisHer = "у неё", first = "первая", gave = "дала", won = "победила" }
    end
    return { heShe = "он", hisHer = "у него", first = "первый", gave = "дал", won = "победил" }
end

local function applyPlaceholders(str, extra)
    if not str then return "" end
    extra = extra or {}
    local result = str:gsub("{NICK}", myDisplayNick or "ведущий")
    result = result:gsub("{FRACTION}", "San Fierro News")
    result = result:gsub("{RANK}", "Ведущий")
    result = result:gsub("{TYPE}", currentType or "Математика")
    result = result:gsub("{N}", tostring(screenshots or 0))
    result = result:gsub("{ANSWER}", tostring(extra.answer or "?"))
    result = result:gsub("{MAX_SCORE}", tostring(MAX_SCORE or 20))
    result = result:gsub("{PRIZE_FUND}", tostring(PRIZE_FUND or 500000))
    return result
end

local ANSWER_REVEAL_PHRASES = {
    "Верный ответ был: {ANSWER}",
    "Правильным ответом был: {ANSWER}",
    "А вот и правильный ответ: {ANSWER}",
}

local function capitalizeWord(word)
    if not word or #word == 0 then return "" end
    local cp = u8:decode(word)
    if not cp or #cp == 0 then return word end
    local first = cp:sub(1, 1)
    local rest = cp:sub(2)
    first = cp1251Upper(first)
    local lowerRest = {}
    for i = 1, #rest do
        local ch = rest:sub(i, i)
        lowerRest[i] = ul_rus[ch] or ch
    end
    rest = tbl_concat(lowerRest)
    return u8:encode(first .. rest)
end

local function sendRevealAnswer(answer)
    if not answer then return end
    local ans = tostring(answer)
    if currentMode == "anagram" or currentMode == "vyshibaly" then
        ans = capitalizeWord(ans)
    end
    local phrase = ANSWER_REVEAL_PHRASES[math.random(1, #ANSWER_REVEAL_PHRASES)]
    phrase = phrase:gsub("{ANSWER}", ans)
    sendChat(phrase)
end

local function tryDetectNick()
    if myNick ~= "Unknown" then return true end
    local ok1, id1 = pcall(sampGetPlayerId)
    if ok1 and type(id1) == "number" and id1 >= 0 then
        local nick = sampGetPlayerNickname(id1)
        if nick and type(nick) == "string" and #nick > 0 then
            myNick = nick
            myDisplayNick = nick:gsub("_", " ")
            myId = id1
            logPrint("[SFN] Ваш ник: " .. myNick .. " (ID: " .. myId .. ")")
            -- ВРЕМЕННАЯ СТРОКА ДЛЯ ОТЛАДКИ:
            logPrint("[SFN] ВАШ ХЕШ: " .. sha256.hash(myNick .. AUTH_SALT))
            return true
        end
    end
    if PLAYER_PED and PLAYER_PED ~= -1 then
        local ok2, isSuccess, id2 = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
        if ok2 and isSuccess and type(id2) == "number" and id2 >= 0 then
            local nick = sampGetPlayerNickname(id2)
            if nick and type(nick) == "string" and #nick > 0 then
                myNick = nick
                myDisplayNick = nick:gsub("_", " ")
                myId = id2
                logPrint("[SFN] Ваш ник: " .. myNick .. " (ID: " .. myId .. ")")
                return true
            end
        end
    end
    return false
end

local function ensureDataDir()
    if not doesDirectoryExist(DATA_DIR) then createDirectory(DATA_DIR) end
end

local function writeFile(path, content)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(content); file:flush(); file:close()
    return true
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a"); file:close()
    return content
end

local function saveConfig()
    writeFile(CONFIG_PATH, encodeJson({
        hotkey = HOTKEY, max_score = MAX_SCORE, prize_fund = PRIZE_FUND,
        price_per_minute = PRICE_PER_MINUTE, screenshot_interval = SCREENSHOT_INTERVAL,
    }))
end

local function ensureConfig()
    if not doesFileExist(CONFIG_PATH) then saveConfig() return end
    local content = readFile(CONFIG_PATH)
    if content and #content > 0 then
        local ok, config = pcall(decodeJson, content)
        if ok and config then
            if type(config.hotkey) == "number" then HOTKEY = config.hotkey end
            if type(config.max_score) == "number" then MAX_SCORE = config.max_score end
            if type(config.prize_fund) == "number" then PRIZE_FUND = config.prize_fund end
            if type(config.price_per_minute) == "number" then PRICE_PER_MINUTE = config.price_per_minute end
            if type(config.screenshot_interval) == "number" then SCREENSHOT_INTERVAL = config.screenshot_interval end
        end
    end
end

local function saveScores() writeFile(SCORES_PATH, encodeJson(scores)) end

local function loadScores()
    local content = readFile(SCORES_PATH)
    if not content or #content == 0 then return {} end
    local ok, data = pcall(decodeJson, content)
    if not ok or not data then return {} end
    local result = {}
    for nick, info in pairs(data) do
        if type(info) == "table" then
            result[nick] = { id = tonumber(info.id) or 0, score = tonumber(info.score) or 0 }
        end
    end
    return result
end

local function ensureScores()
    if not doesFileExist(SCORES_PATH) then writeFile(SCORES_PATH, "{}") return end
    scores = loadScores()
end

local function resetScores() scores = {} saveScores() end

local function saveGenders() writeFile(GENDERS_PATH, encodeJson(genders)) end

local function loadGenders()
    local content = readFile(GENDERS_PATH)
    if not content or #content == 0 then return {} end
    local ok, data = pcall(decodeJson, content)
    if not ok or not data then return {} end
    local result = {}
    for nick, g in pairs(data) do
        if g == "m" or g == "f" then result[nick] = g end
    end
    return result
end

local function ensureGenders()
    if not doesFileExist(GENDERS_PATH) then writeFile(GENDERS_PATH, "{}") return end
    genders = loadGenders()
end

local function isAdmin(nick)
    if not nick or nick == "Unknown" then return false end
    local h = sha256.hash(nick .. AUTH_SALT)
    for _, adminHash in ipairs(ADMIN_NICK_HASHES) do
        if h == adminHash then return true end
    end
    return false
end

local function isAllowed(nick)
    if not nick or nick == "Unknown" then return false end
    local h = sha256.hash(nick .. AUTH_SALT)
    for _, allowed in ipairs(ALLOWED_NICK_HASHES) do
        if h == allowed then return true end
    end
    return false
end

local function grantAccess()
    ACCESS_GRANTED = true
    ACCESS_CHECKED = true
    logPrint("[SFN] Доступ разрешён.")
    say(TEXTS.system.loaded_title)
    say(TEXTS.system.loaded_message)
    say(applyPlaceholders(TEXTS.system.loaded_greeting))
    say(TEXTS.system.loaded_help)
    say(TEXTS.system.loaded_bottom)
end

local function checkAutoAccess()
    if ACCESS_GRANTED then return end
    if not myNick or myNick == "Unknown" then return end

    if isAdmin(myNick) then
        logPrint("[SFN] Доступ разрешён администратору.")
        grantAccess()
        return
    end

    if isAllowed(myNick) then
        logPrint("[SFN] Доступ разрешён (ник в списке).")
        grantAccess()
        return
    end

    ACCESS_CHECKED = true
    logPrint("[SFN] Доступ запрещён: ника нет в списке.")
    say("[SFN] У вас нет доступа к скрипту. Обратитесь к Jonny Wilde.")
end

local function makeScreenshot()
    logAction("Делаю скриншот...")
    local wasWindowOpen = WinState[0]
    WinState[0] = false
    wait(300)
    sampSendChat("/time")
    wait(1500)
    setVirtualKeyDown(0x77, true)
    wait(50)
    setVirtualKeyDown(0x77, false)
    wait(300)
    if wasWindowOpen then WinState[0] = true end
    screenshots = screenshots + 1
    lastScreenshotTime = os.clock()
    screenshotNotified = false
    say(applyPlaceholders(TEXTS.system.screenshot_done))
end

local function playIntro(efirType)
    local intro = TEXTS.intro
    lua_thread.create(function()
        sendChat(applyPlaceholders(intro.jingle))
        wait(SPEECH_DELAY * 1000)
        for _, line in ipairs(intro.lines) do
            sendChat(applyPlaceholders(line))
            wait(SPEECH_DELAY * 1000)
        end
    end)
end

local function playRules()
    local rulesBlock = TEXTS.rules
    if not rulesBlock then return end
    local lines
    if currentMode == "anagram" then lines = rulesBlock.anagram
    elseif currentMode == "vyshibaly" then lines = rulesBlock.vyshibaly
    else lines = rulesBlock.math end
    if not lines or #lines == 0 then return end
    lua_thread.create(function()
        for _, line in ipairs(lines) do
            sendChat(applyPlaceholders(line))
            wait(SPEECH_DELAY * 1000)
        end
    end)
end

local function playOutro()
    lua_thread.create(function()
        for _, line in ipairs(TEXTS.outro.lines) do
            sendChat(applyPlaceholders(line))
            wait(SPEECH_DELAY * 1000)
        end
    end)
end

local function autoStartEfir(mode)
    currentMode = mode
    if mode == "anagram" then currentType = "Анаграммы"
    elseif mode == "vyshibaly" then currentType = "Вышибалы"
    else currentType = "Математика" end
    currentFirstAnswer = nil
    screenshotNotified = false
    screenshots = 0
    lastScreenshotTime = os.clock()
    efirRunning = true
    efirStartTime = os.clock()
end

local function autoStopEfir()
    local totalTime = os.clock() - efirStartTime
    local minutes = math.floor(totalTime / 60)
    local payment = minutes * PRICE_PER_MINUTE
    logAction("Эфир завершён. Время: " .. formatTime(totalTime) .. ", выплата: " .. payment .. "$")
    efirRunning = false
    currentFirstAnswer = nil
    screenshotNotified = false
end

local function genClassic()
    local n1 = math.random(10, 50); local n2 = math.random(10, 50)
    local n3 = math.random(1, 10); local n4 = math.random(1, 10)
    local ops = {"+", "-"}
    local op1 = ops[math.random(1, 2)]; local op2 = ops[math.random(1, 2)]
    local q = n1 .. " " .. op1 .. " " .. n2 .. " " .. op2 .. " " .. n3 .. " * " .. n4
    local mult = n3 * n4
    local result = (op1 == "+") and (n1 + n2) or (n1 - n2)
    if op2 == "+" then result = result + mult else result = result - mult end
    return q, result
end

local function genAddSub()
    local a = math.random(20, 99); local b = math.random(10, 60)
    if math.random(1, 2) == 1 then return a .. " + " .. b, a + b
    else return a .. " - " .. b, a - b end
end

local function genMultiply()
    local a = math.random(3, 15); local b = math.random(3, 15)
    return a .. " * " .. b, a * b
end

local function genDivide()
    local b = math.random(2, 12); local result = math.random(3, 15)
    local a = b * result
    return a .. " / " .. b, result
end

local function genBrackets()
    local a = math.random(5, 30); local b = math.random(1, 15); local c = math.random(2, 9)
    if math.random(1, 2) == 1 then return "(" .. a .. " + " .. b .. ") * " .. c, (a + b) * c
    else if a < b then a, b = b, a end return "(" .. a .. " - " .. b .. ") * " .. c, (a - b) * c end
end

local function genMixed()
    local a = math.random(2, 12); local b = math.random(2, 12)
    local c = math.random(1, a * b - 1)
    return a .. " * " .. b .. " - " .. c, a * b - c
end

local function genEquation()
    local variant = math.random(1, 5)
    if variant == 1 then
        local x = math.random(2, 50); local a = math.random(2, 50)
        return "x + " .. a .. " = " .. (x + a), x, ", x = ?"
    elseif variant == 2 then
        local a = math.random(2, 30); local x = math.random(a + 1, a + 50)
        return "x - " .. a .. " = " .. (x - a), x, ", x = ?"
    elseif variant == 3 then
        local a = math.random(20, 80); local x = math.random(1, a - 1)
        return a .. " - x = " .. (a - x), x, ", x = ?"
    elseif variant == 4 then
        local a = math.random(2, 12); local x = math.random(2, 12)
        return a .. " * x = " .. (a * x), x, ", x = ?"
    else
        local a = math.random(2, 10); local b = math.random(2, 15)
        return "x / " .. a .. " = " .. b, a * b, ", x = ?"
    end
end

local function generateMath()
    local t
    repeat t = MATH_TYPES[math.random(1, #MATH_TYPES)]
    until t ~= lastMathType or #MATH_TYPES == 1
    lastMathType = t
    local q, a, suffix
    if t == "classic" then q, a = genClassic()
    elseif t == "addsub" then q, a = genAddSub()
    elseif t == "multiply" then q, a = genMultiply()
    elseif t == "divide" then q, a = genDivide()
    elseif t == "brackets" then q, a = genBrackets()
    elseif t == "mixed" then q, a = genMixed()
    elseif t == "equation" then q, a, suffix = genEquation()
    else q, a = genClassic() end
    mathQuestion = q; mathAnswer = a; mathQuestionSuffix = suffix or " = ?"
    currentFirstAnswer = nil
end

local function splitUtf8(str)
    local chars = {}
    local i = 1
    while i <= #str do
        local b = str:byte(i); local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        table.insert(chars, str:sub(i, i + len - 1))
        i = i + len
    end
    return chars
end

local function shuffleWord(word)
    local chars = splitUtf8(word)
    for i = #chars, 2, -1 do
        local j = math.random(1, i)
        chars[i], chars[j] = chars[j], chars[i]
    end
    return table.concat(chars)
end

local function generateAnagram()
    if #ANAGRAMS == 0 then return end
    anagramWord = ANAGRAMS[math.random(1, #ANAGRAMS)]
    local shuffled = anagramWord
    local attempts = 0
    repeat shuffled = shuffleWord(anagramWord); attempts = attempts + 1
    until shuffled ~= anagramWord or attempts > 20
    anagramShuffled = shuffled
    currentFirstAnswer = nil
end

local function maskWord(word)
    local chars = splitUtf8(word)
    local total = #chars
    if total < 3 then return word end
    local ratio = 0.40 + math.random() * 0.15
    local hideCount = math.floor(total * ratio)
    hideCount = math.max(hideCount, total >= 8 and 4 or 3)
    hideCount = math.min(hideCount, total - 1)
    local candidates = {}
    for i = 2, total - 2 do table.insert(candidates, i) end
    if #candidates < hideCount then
        candidates = {}
        for i = 1, total do table.insert(candidates, i) end
    end
    for i = #candidates, 2, -1 do
        local j = math.random(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end
    local maskSet = {}
    for i = 1, math.min(hideCount, #candidates) do
        maskSet[candidates[i]] = true
    end
    local placeholder = (math.random(1, 2) == 1) and "*" or "_"
    local result = {}
    for i = 1, total do
        if maskSet[i] then result[i] = placeholder
        else result[i] = chars[i] end
    end
    return table.concat(result)
end

local function generateVyshibaly()
    if #VYSHIBALY_WORDS == 0 then return end
    vyshibalyWord = VYSHIBALY_WORDS[math.random(1, #VYSHIBALY_WORDS)]
    local attempts = 0
    repeat vyshibalyMasked = maskWord(vyshibalyWord); attempts = attempts + 1
    until vyshibalyMasked ~= vyshibalyWord or attempts > 20
    currentFirstAnswer = nil
end

local function tryParseAnswer(text, source)
    if not text then return false end
    local utf8text = u8:encode(text) or text
    local bufNick, bufId = utf8text:match(PATTERN_NICK_WITH_ID)
    local cleaned = utf8text:gsub("%[%d+:%d+:%d+%]", ""):gsub("%[%d+%]", "")
    local pattern = (currentMode == "anagram" or currentMode == "vyshibaly")
        and PATTERN_ANAGRAM_MESSAGE or PATTERN_AIR_MESSAGE_SIGNED
    local answer = cleaned:match(pattern)
    if not answer or not bufNick then return false end
    if not efirRunning then return true end

    if currentMode == "math" then
        local cleanAnswer = answer:gsub("%s+", "")
        local numAnswer = tonumber(cleanAnswer)
        if numAnswer and numAnswer == mathAnswer and not currentFirstAnswer then
            currentFirstAnswer = { nick = bufNick, id = tonumber(bufId),
                answer = cleanAnswer, time = os.clock() }
        end
    elseif currentMode == "anagram" then
        if normalizeAnswer(u8:decode(answer)) == normalizeAnswer(u8:decode(anagramWord))
           and not currentFirstAnswer then
            currentFirstAnswer = { nick = bufNick, id = tonumber(bufId),
                answer = answer, time = os.clock() }
        end
    elseif currentMode == "vyshibaly" then
        if normalizeAnswer(u8:decode(answer)) == normalizeAnswer(u8:decode(vyshibalyWord))
           and not currentFirstAnswer then
            currentFirstAnswer = { nick = bufNick, id = tonumber(bufId),
                answer = answer, time = os.clock() }
        end
    end
    return true
end

local function handleChatText(text, source)
    if not text then return end
    if ACCESS_GRANTED then tryParseAnswer(text, source) end
end

if sampev_ok and sampev then
    function sampev.onServerMessage(color, text) handleChatText(text, "SE-SERVER") end
    function sampev.onChatMessage(playerId, text) handleChatText(text, "SE-CHAT") end
end

local function applyCorrectAnswer(nick, id)
    if not scores[nick] then scores[nick] = { id = id, score = 0 } end
    scores[nick].score = scores[nick].score + 1
    scores[nick].id = id
    saveScores()
    local sc = scores[nick].score
    local f = genderForms(nick)
    sendChat(string.format("%s %s %s правильный ответ и %s %d %s",
        formatNick(nick), f.first, f.gave, f.hisHer, sc, pluralScore(sc)))
    currentFirstAnswer = nil
    pendingGenderConfirm = nil
    local revealAnswer
    if currentMode == "anagram" then revealAnswer = anagramWord
    elseif currentMode == "vyshibaly" then revealAnswer = vyshibalyWord
    else revealAnswer = mathAnswer end
    lua_thread.create(function()
        wait(5000)
        if revealAnswer then sendRevealAnswer(revealAnswer) end
    end)
end

local function confirmCorrect()
    if not currentFirstAnswer then say(TEXTS.system.no_answer) return end
    local nick = currentFirstAnswer.nick
    local id = currentFirstAnswer.id
    if not genders[nick] then
        pendingGenderConfirm = { nick = nick, id = id }
        genderWindowOpen[0] = true
        return
    end
    applyCorrectAnswer(nick, id)
end

local function sendTopScores()
    local sorted = {}
    for nick, info in pairs(scores) do
        table.insert(sorted, { nick = nick, id = info.id, score = info.score })
    end
    if #sorted == 0 then say(TEXTS.system.no_scores) return end
    table.sort(sorted, function(a, b)
        if a.score == b.score then return a.nick < b.nick end
        return a.score > b.score
    end)
    local groups = {}; local currentGroup = nil
    for _, item in ipairs(sorted) do
        if not currentGroup or currentGroup.score ~= item.score then
            currentGroup = { score = item.score, players = { item }, rank = #groups + 1 }
            table.insert(groups, currentGroup)
        else
            table.insert(currentGroup.players, item)
        end
    end
    lua_thread.create(function()
        local intro = TEXTS.scores_intros[math.random(1, #TEXTS.scores_intros)]
        sendChat(applyPlaceholders(intro))
        wait(5000)
        local maxGroups = math.min(#groups, 3)
        for i = 1, maxGroups do
            local group = groups[i]
            local nicks = {}
            for _, player in ipairs(group.players) do
                table.insert(nicks, formatNick(player.nick))
            end
            local namesStr
            if #nicks == 1 then namesStr = nicks[1]
            elseif #nicks == 2 then namesStr = nicks[1] .. " и " .. nicks[2]
            else namesStr = table.concat(nicks, ", ", 1, #nicks - 1) .. " и " .. nicks[#nicks] end
            local msg
            if #group.players == 1 then
                local f = genderForms(group.players[1].nick)
                msg = string.format("На %s месте — %s, %s %d %s!",
                    tostring(group.rank), namesStr, f.hisHer, group.score, pluralScore(group.score))
            else
                msg = string.format("На %s месте — %s, у них по %d %s!",
                    tostring(group.rank), namesStr, group.score, pluralScore(group.score))
            end
            sendChat(msg)
            wait(5000)
        end
        if #groups > 3 then
            local restLines = {}
            for i = 4, #groups do
                local group = groups[i]
                local nicks = {}
                for _, player in ipairs(group.players) do
                    table.insert(nicks, formatNick(player.nick))
                end
                local namesStr
                if #nicks == 1 then namesStr = nicks[1]
                elseif #nicks == 2 then namesStr = nicks[1] .. " и " .. nicks[2]
                else namesStr = table.concat(nicks, ", ", 1, #nicks - 1) .. " и " .. nicks[#nicks] end
                table.insert(restLines, string.format("%s (%d %s)",
                    namesStr, group.score, pluralScore(group.score)))
            end
            sendPacked(restLines, "Также баллы набрали: ", "Также: ")
        end
    end)
end

local function sendAdvertisement()
    local adv = TEXTS.advertisement
    lua_thread.create(function()
        sendChat(adv.jingle); wait(5000)
        sendChat(applyPlaceholders(adv.intros[math.random(1, #adv.intros)])); wait(5000)
        for _, line in ipairs(adv.blocks[math.random(1, #adv.blocks)]) do
            sendChat(applyPlaceholders(line)); wait(5000)
        end
        sendChat(adv.jingle); wait(5000)
    end)
end

local BTN_START_W = 220

local function centeredButton(label, w, h)
    local avail = imgui.GetWindowWidth()
    imgui.SetCursorPosX((avail - w) / 2)
    return imgui.Button(label, imgui.ImVec2(w, h))
end

imgui.OnFrame(function() return WinState[0] and ACCESS_GRANTED end, function()
    imgui.SetNextWindowSizeConstraints(imgui.ImVec2(MIN_WINDOW_WIDTH, 100), imgui.ImVec2(10000, 10000))
    imgui.SetNextWindowSize(imgui.ImVec2(MIN_WINDOW_WIDTH, 0), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowBgAlpha(1.0)

    local isOpen, _ = imgui.Begin("SFN | Помощник эфира  —  by Jonny Wilde", WinState,
        imgui.WindowFlags.NoCollapse +
        imgui.WindowFlags.AlwaysAutoResize +
        imgui.WindowFlags.NoResize)

    if not isOpen then imgui.End() return end

    if efirRunning then
        local totalTime = os.clock() - efirStartTime
        local minutes = math.floor(totalTime / 60)
        local payment = minutes * PRICE_PER_MINUTE
        local timeSinceScreenshot = os.clock() - lastScreenshotTime
        local nextScreenshot = SCREENSHOT_INTERVAL - timeSinceScreenshot

        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.8, 0.3, 1))
        imgui.Text("[>] ЭФИР ИДЁТ: " .. currentType)
        imgui.PopStyleColor()
        imgui.Text("[T] Время: " .. formatTime(totalTime))
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.9, 0.7, 0.0, 1))
        imgui.Text("    [$] Выплата: " .. payment .. "$")
        imgui.PopStyleColor()
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.3, 0.6, 0.9, 1))
        imgui.Text("[C] Скринов: " .. screenshots)
        imgui.PopStyleColor()

        if nextScreenshot > 0 then
            imgui.SameLine()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1))
            imgui.Text("    [S] След. скрин через: " .. formatTime(nextScreenshot))
            imgui.PopStyleColor()
        else
            imgui.SameLine()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.5, 0.5, 1))
            imgui.Text("    [S] ПОРА СДЕЛАТЬ СКРИНШОТ")
            imgui.PopStyleColor()
        end
    else
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
        imgui.Text("[ ] ЭФИР НЕ ИДЁТ")
        imgui.PopStyleColor()
    end

    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 6))

    if not efirRunning then
        imgui.Text("Настройки эфира")
        imgui.Separator()
        imgui.Dummy(imgui.ImVec2(0, 6))

        imgui.Text("Максимум баллов:")
        imgui.SameLine()
        local labelW1 = imgui.CalcTextSize("Максимум баллов:").x
        imgui.SetNextItemWidth(imgui.GetWindowWidth() - labelW1 - imgui.GetStyle().ItemSpacing.x - 20)
        local maxScoreBuf = new.int(MAX_SCORE)
        if imgui.InputInt("##max_score", maxScoreBuf) then
            local newVal = maxScoreBuf[0]
            if newVal >= 1 and newVal <= 999 then MAX_SCORE = newVal; saveConfig() end
        end

        imgui.Dummy(imgui.ImVec2(0, 6))

        imgui.Text("Призовой фонд:")
        imgui.SameLine()
        local labelW2 = imgui.CalcTextSize("Призовой фонд:").x
        imgui.SetNextItemWidth(imgui.GetWindowWidth() - labelW2 - imgui.GetStyle().ItemSpacing.x - 20)
        local prizeFundBuf = new.int(PRIZE_FUND)
        if imgui.InputInt("##prize_fund", prizeFundBuf) then
            local newVal = prizeFundBuf[0]
            if newVal >= 0 and newVal <= 999999999 then PRIZE_FUND = newVal; saveConfig() end
        end

        imgui.Dummy(imgui.ImVec2(0, 12))

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.7, 0.3, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.8, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.6, 0.2, 1.0))
        if centeredButton("НАЧАТЬ ЭФИР (Математика)", BTN_START_W, 36) then
            autoStartEfir("math"); generateMath()
        end
        imgui.PopStyleColor(3)
        imgui.Dummy(imgui.ImVec2(0, 4))

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.6, 0.1, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.7, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.8, 0.5, 0.1, 1.0))
        if centeredButton("НАЧАТЬ ЭФИР (Анаграммы)", BTN_START_W, 36) then
            autoStartEfir("anagram"); generateAnagram()
        end
        imgui.PopStyleColor(3)
        imgui.Dummy(imgui.ImVec2(0, 4))

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.7, 0.3, 0.8, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.8, 0.4, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.2, 0.7, 1.0))
        if centeredButton("НАЧАТЬ ЭФИР (Вышибалы)", BTN_START_W, 36) then
            autoStartEfir("vyshibaly"); generateVyshibaly()
        end
        imgui.PopStyleColor(3)
    else
        if currentMode == "math" then
            imgui.Text("ТЕКУЩИЙ ПРИМЕР:")
            imgui.Dummy(imgui.ImVec2(0, 3))
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            imgui.BeginChild("CurrentMath", imgui.ImVec2(-1, 55), false)
            imgui.Dummy(imgui.ImVec2(0, 5))
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.9, 0.5, 0.0, 1))
            imgui.Text("   " .. mathQuestion .. mathQuestionSuffix)
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(0, 3))
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.7, 0.3, 1))
            imgui.Text("   Ответ: " .. mathAnswer)
            imgui.PopStyleColor()
            imgui.EndChild(); imgui.PopStyleColor()

            imgui.Dummy(imgui.ImVec2(0, 5))
            local btnW = (imgui.GetWindowWidth() - 40) / 2
            if imgui.Button("Новый", imgui.ImVec2(btnW, 30)) then generateMath() end
            imgui.SameLine()
            if imgui.Button("В чат", imgui.ImVec2(btnW, 30)) then
                sendChat("Следующий пример: " .. mathQuestion .. mathQuestionSuffix)
                currentFirstAnswer = nil
            end
        elseif currentMode == "anagram" then
            imgui.Text("ТЕКУЩАЯ АНАГРАММА:")
            imgui.Dummy(imgui.ImVec2(0, 3))
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            imgui.BeginChild("CurrentAnagram", imgui.ImVec2(-1, 55), false)
            imgui.Dummy(imgui.ImVec2(0, 5))
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.9, 0.5, 0.0, 1))
            imgui.Text("   " .. formatAnagramDots(anagramShuffled))
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(0, 3))
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.7, 0.3, 1))
            imgui.Text("   Ответ: " .. anagramWord)
            imgui.PopStyleColor()
            imgui.EndChild(); imgui.PopStyleColor()

            imgui.Dummy(imgui.ImVec2(0, 5))
            local btnW = (imgui.GetWindowWidth() - 40) / 2
            if imgui.Button("Новый", imgui.ImVec2(btnW, 30)) then generateAnagram() end
            imgui.SameLine()
            if imgui.Button("В чат", imgui.ImVec2(btnW, 30)) then
                sendChat("Новая Анаграмма: " .. formatAnagramDots(anagramShuffled))
                currentFirstAnswer = nil
            end
        elseif currentMode == "vyshibaly" then
            imgui.Text("ТЕКУЩЕЕ СЛОВО:")
            imgui.Dummy(imgui.ImVec2(0, 3))
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            imgui.BeginChild("CurrentVyshibaly", imgui.ImVec2(-1, 55), false)
            imgui.Dummy(imgui.ImVec2(0, 5))
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.9, 0.5, 0.0, 1))
            imgui.Text("   " .. vyshibalyMasked)
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(0, 3))
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.7, 0.3, 1))
            imgui.Text("   Ответ: " .. vyshibalyWord)
            imgui.PopStyleColor()
            imgui.EndChild(); imgui.PopStyleColor()

            imgui.Dummy(imgui.ImVec2(0, 5))
            local btnW = (imgui.GetWindowWidth() - 40) / 2
            if imgui.Button("Новый", imgui.ImVec2(btnW, 30)) then generateVyshibaly() end
            imgui.SameLine()
            if imgui.Button("В чат", imgui.ImVec2(btnW, 30)) then
                sendChat("Новое слово: " .. vyshibalyMasked)
                currentFirstAnswer = nil
            end
        end

        imgui.Dummy(imgui.ImVec2(0, 6)); imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 5))
        imgui.Text("ПЕРВЫЙ ОТВЕТ:"); imgui.Dummy(imgui.ImVec2(0, 3))

        if currentFirstAnswer then
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.7, 0.3, 1))
            imgui.Text("   " .. formatNick(currentFirstAnswer.nick) ..
                " - ответ: " .. currentFirstAnswer.answer)
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(0, 5))
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.7, 0.3, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.8, 0.4, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.6, 0.2, 1.0))
            if imgui.Button("Верный ответ", imgui.ImVec2(-1, 32)) then confirmCorrect() end
            imgui.PopStyleColor(3)
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1))
            imgui.Text("   Ожидание верного ответа...")
            imgui.PopStyleColor()
        end

        imgui.Dummy(imgui.ImVec2(0, 6)); imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 5))
        imgui.Text("ТАБЛИЦА БАЛЛОВ:")
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
        if imgui.Button("Очистить базу", imgui.ImVec2(140, 0)) then
            imgui.OpenPopup("confirm_clear_scores")
        end
        imgui.PopStyleColor(3)

        if imgui.BeginPopupModal("confirm_clear_scores", nil, imgui.WindowFlags.AlwaysAutoResize) then
            imgui.Text("Очистить базу баллов?")
            imgui.Text("Это действие нельзя отменить!")
            imgui.Dummy(imgui.ImVec2(0, 10))
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
            if imgui.Button("Да, очистить", imgui.ImVec2(140, 28)) then
                resetScores(); say(TEXTS.system.base_cleared); imgui.CloseCurrentPopup()
            end
            imgui.PopStyleColor(3); imgui.SameLine()
            if imgui.Button("Отмена", imgui.ImVec2(140, 28)) then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        imgui.Dummy(imgui.ImVec2(0, 5))

        local sorted = {}
        for nick, info in pairs(scores) do
            table.insert(sorted, { nick = nick, id = info.id, score = info.score })
        end
        table.sort(sorted, function(a, b)
            if a.score == b.score then return a.nick < b.nick end
            return a.score > b.score
        end)

        if #sorted == 0 then
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "Список пуст")
        else
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            local tableHeight = math.min(#sorted * 28 + 10, 300)
            imgui.BeginChild("ScoresTableInline", imgui.ImVec2(-1, tableHeight), true)
            for i, item in ipairs(sorted) do
                local prefix = (i == 1 and "1. ") or (i == 2 and "2. ") or (i == 3 and "3. ") or (i .. ". ")
                if i == 1 then imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.9, 0.7, 0.0, 1))
                elseif i == 2 then imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
                elseif i == 3 then imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.5, 0.2, 1))
                else imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.2, 0.2, 1)) end
                imgui.Text(string.format("%s%s - %d %s", prefix,
                    formatNick(item.nick), item.score, pluralScore(item.score)))
                imgui.PopStyleColor()
            end
            imgui.EndChild(); imgui.PopStyleColor()
        end

        imgui.Dummy(imgui.ImVec2(0, 6)); imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 5))
        local btnW2 = (imgui.GetWindowWidth() - 40) / 2

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.4, 0.7, 0.3, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.5, 0.8, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.3, 0.6, 0.2, 1.0))
        if imgui.Button("Стартовая Речь", imgui.ImVec2(btnW2, 32)) then playIntro(currentType) end
        imgui.PopStyleColor(3)
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.55, 0.75, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.65, 0.85, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.45, 0.65, 1.0))
        if imgui.Button("Повторить правила", imgui.ImVec2(btnW2, 32)) then playRules() end
        imgui.PopStyleColor(3)

        imgui.Dummy(imgui.ImVec2(0, 4))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.7, 0.4, 0.7, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.8, 0.5, 0.8, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.3, 0.6, 1.0))
        if centeredButton("Завершающая Речь", BTN_START_W, 32) then playOutro() end
        imgui.PopStyleColor(3)

        imgui.Dummy(imgui.ImVec2(0, 4))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 0.9, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.7, 1.0, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.5, 0.8, 1.0))
        if imgui.Button("Итоги в чат", imgui.ImVec2(btnW2, 32)) then sendTopScores() end
        imgui.PopStyleColor(3)
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.6, 0.1, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.7, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.8, 0.5, 0.1, 1.0))
        if imgui.Button("Реклама", imgui.ImVec2(btnW2, 32)) then sendAdvertisement() end
        imgui.PopStyleColor(3)

        imgui.Dummy(imgui.ImVec2(0, 4))
        if imgui.Button("Скриншот", imgui.ImVec2(btnW2, 32)) then
            lua_thread.create(function() makeScreenshot() end)
        end
        imgui.SameLine()
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
        if imgui.Button("Завершить", imgui.ImVec2(btnW2, 32)) then autoStopEfir() end
        imgui.PopStyleColor(3)
    end

    imgui.End()

    if genderWindowOpen[0] and pendingGenderConfirm then
        imgui.SetNextWindowSize(imgui.ImVec2(300, 140), imgui.Cond.Always)
        imgui.SetNextWindowBgAlpha(1.0)
        imgui.SetNextWindowPos(
            imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2 - 150,
                         imgui.GetIO().DisplaySize.y / 2 - 70),
            imgui.Cond.Always)

        local isOpenG, _ = imgui.Begin("Пол игрока", genderWindowOpen,
            imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)

        if isOpenG then
            imgui.Text("Укажите пол игрока:")
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.2, 0.5, 0.9, 1))
            imgui.Text("   " .. formatNick(pendingGenderConfirm.nick))
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(0, 10))

            local btnW = (imgui.GetWindowWidth() - 30) / 2

            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.55, 0.9, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.65, 1.0, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.1, 0.45, 0.8, 1.0))
            if imgui.Button("Парень", imgui.ImVec2(btnW, 34)) then
                genders[pendingGenderConfirm.nick] = "m"
                saveGenders()
                applyCorrectAnswer(pendingGenderConfirm.nick, pendingGenderConfirm.id)
                genderWindowOpen[0] = false
            end
            imgui.PopStyleColor(3)
            imgui.SameLine()
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.4, 0.7, 0.9))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.5, 0.8, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.8, 0.3, 0.6, 1.0))
            if imgui.Button("Девушка", imgui.ImVec2(btnW, 34)) then
                genders[pendingGenderConfirm.nick] = "f"
                saveGenders()
                applyCorrectAnswer(pendingGenderConfirm.nick, pendingGenderConfirm.id)
                genderWindowOpen[0] = false
            end
            imgui.PopStyleColor(3)

            imgui.Dummy(imgui.ImVec2(0, 6))
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1),
                "Пол сохранится в базу.")
        else
            pendingGenderConfirm = nil
        end
        imgui.End()
    end
end)

function cmd_efir()
    if not ACCESS_GRANTED then
        say("[SFN] У вас нет доступа к скрипту.")
        return
    end
    WinState[0] = not WinState[0]
    if WinState[0] then say(TEXTS.system.menu_opened)
    else say(TEXTS.system.menu_closed) end
end

function cmd_efirversion()
    if not isAdmin(myNick) then return end
    say("[SFN] Версия: " .. CURRENT_VERSION)
    if doesFileExist(UPDATE_TMP) then
        say("[SFN] Ожидает установки.")
    else
        say("[SFN] Обновлений не найдено.")
    end
end

function cmd_efirlist()
    if not isAdmin(myNick) then return end
    local total = #ALLOWED_NICK_HASHES
    say("[SFN] Разрешённых ников (кроме админов): " .. total)
end

function cmd_efirwhoami()
    if not isAdmin(myNick) then return end
    if not myNick or myNick == "Unknown" then return end
    local h = sha256.hash(myNick .. AUTH_SALT)
    say("[SFN] Ваш ник: " .. myNick)
    say("[SFN] SHA256: " .. h)
    say("[SFN] Роль: АДМИН")
end

function main()
    math.randomseed(os.time() + math.floor(os.clock() * 1000000))

    local wasUpdated = applyPendingUpdate()

    ensureDataDir()
    ensureConfig()
    ensureScores()
    ensureGenders()

    tryDetectNick()

    sampRegisterChatCommand("efir", cmd_efir)
    sampRegisterChatCommand("efirversion", cmd_efirversion)
    sampRegisterChatCommand("efirlist", cmd_efirlist)
    sampRegisterChatCommand("efirwhoami", cmd_efirwhoami)

    if wasUpdated then
        wait(3000)
        sampAddChatMessage("{66FF66}[SFN] Скрипт обновлён до v" .. CURRENT_VERSION .. ".", -1)
    end

    checkForUpdates()

    while true do
        wait(0)
        if myNick == "Unknown" then tryDetectNick() end
        if not ACCESS_CHECKED and myNick ~= "Unknown" then checkAutoAccess() end
        if ACCESS_GRANTED then
            if isKeyDown(HOTKEY) and not sampIsCursorActive() then
                WinState[0] = not WinState[0]
                wait(300)
            end
            if efirRunning then
                local timeSince = os.clock() - lastScreenshotTime
                if timeSince > SCREENSHOT_INTERVAL and not screenshotNotified then
                    say(TEXTS.system.screenshot_reminder)
                    screenshotNotified = true
                end
            end
        end
    end
end

function scriptUnload()
    saveScores()
    saveGenders()
end