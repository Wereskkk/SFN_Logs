-- sfn_photo_helper.lua
-- Помощник фотографа для SFN (San Fierro News)
-- v13.4.1: фикс кодировки в onShowDialog, удалена линия до цели
-- ВАЖНО: файл должен быть сохранён в UTF-8 (без BOM).

---@diagnostic disable: undefined-global
---@diagnostic disable: lowercase-global

-- ============================================
-- ПОДКЛЮЧЕНИЕ БИБЛИОТЕК
-- ============================================
local imgui = require('mimgui')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new
local ffi = require('ffi')

local sampev_ok, sampev = pcall(require, 'samp.events')

-- ============================================
-- ПУТИ И НАСТРОЙКИ
-- ============================================
local DATA_DIR = getWorkingDirectory() .. "\\sfn_photo_data"
local CONFIG_PATH = DATA_DIR .. "\\config.json"
local PHOTOS_PATH = DATA_DIR .. "\\photos.json"

local LIMIT_PLAYERS = 25
local LIMIT_PLACES  = 15

-- ID диалога Папарации
local PAPARAZZI_DIALOG_ID = 32700
local PAPARAZZI_STYLE = 5

-- ============================================
-- ЛОГГЕР
-- ============================================
local function logPrint(msg)
    print(u8:decode(tostring(msg)))
end

-- ============================================
-- ВЫВОД В ЧАТ
-- ============================================
local function say(msg)
    sampAddChatMessage(u8:decode(msg), -1)
end

local function sayRed(msg)
    sampAddChatMessage("{FF3333}" .. u8:decode(msg), -1)
end

local function sayGreen(msg)
    sampAddChatMessage("{66FF66}" .. u8:decode(msg), -1)
end

local function sayYellow(msg)
    sampAddChatMessage("{FFD700}" .. u8:decode(msg), -1)
end

-- ============================================
-- КРАСИВЫЙ JSON
-- ============================================
local function prettyJson(t, indent)
    indent = indent or 0
    local spaces = string.rep("    ", indent)
    local spaces2 = string.rep("    ", indent + 1)

    if type(t) ~= "table" then
        if type(t) == "string" then
            return '"' .. t:gsub('"', '\\"') .. '"'
        elseif type(t) == "number" or type(t) == "boolean" then
            return tostring(t)
        else
            return "null"
        end
    end

    local isArray = true
    local maxIndex = 0
    for k, _ in pairs(t) do
        if type(k) ~= "number" then isArray = false; break end
        if k > maxIndex then maxIndex = k end
    end

    if next(t) == nil then return isArray and "[]" or "{}" end

    local parts = {}
    if isArray then
        for i = 1, maxIndex do
            table.insert(parts, spaces2 .. prettyJson(t[i], indent + 1))
        end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. spaces .. "]"
    else
        local keys = {}
        for k, _ in pairs(t) do table.insert(keys, k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            table.insert(parts, spaces2 .. '"' .. tostring(k) .. '": ' .. prettyJson(t[k], indent + 1))
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. spaces .. "}"
    end
end

-- ============================================
-- ПЕРЕМЕННЫЕ
-- ============================================
local photos = {
    players = {},
    places  = {},
}

local currentOrder = nil
local photoTaken = false
local lastSuccessOrder = nil

-- ============================================
-- ОКНО (привязано к диалогу)
-- ============================================
local PaparazziWindowState = new.bool(false)
local lastDialogId = nil
local overlayShownTime = nil

-- ============================================
-- ПРЕДВАРИТЕЛЬНО СКОНВЕРТИРОВАННЫЕ РУССКИЕ ПАТТЕРНЫ (CP1251)
-- onShowDialog приходит в CP1251, поэтому искать русские слова надо в CP1251
-- ============================================
local P_HEADER_PLACES  = u8:decode("Название")
local P_HEADER_CITY    = u8:decode("Город")
local P_HEADER_PLAYERS = u8:decode("Игрок")
local P_HEADER_ORG     = u8:decode("Организация")
local P_HEADER_PHOTO   = u8:decode("Фото")

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
    ApplyTheme()
end)

-- ============================================
-- ФАЙЛЫ
-- ============================================
local function ensureDataDir()
    if not doesDirectoryExist(DATA_DIR) then
        createDirectory(DATA_DIR)
    end
end

local function writeFile(path, content)
    local file = io.open(path, "w")
    if not file then return false end
    file:write(content)
    file:flush()
    file:close()
    return true
end

local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function savePhotos()
    writeFile(PHOTOS_PATH, prettyJson(photos))
end

local function loadPhotos()
    local content = readFile(PHOTOS_PATH)
    if not content or #content == 0 then
        photos = { players = {}, places = {} }
        return
    end
    local ok, data = pcall(decodeJson, content)
    if not ok or type(data) ~= "table" then
        photos = { players = {}, places = {} }
        return
    end
    photos.players = data.players or {}
    photos.places  = data.places  or {}
end

local function ensurePhotos()
    if not doesFileExist(PHOTOS_PATH) then
        writeFile(PHOTOS_PATH, prettyJson({ players = {}, places = {} }))
        return
    end
    loadPhotos()
end

-- ============================================
-- ПОДСЧЁТ
-- ============================================
local function countPlayers()
    local n = 0
    for _ in pairs(photos.players) do n = n + 1 end
    return n
end

local function countPlaces()
    local n = 0
    for _ in pairs(photos.places) do n = n + 1 end
    return n
end

local function today()
    return os.date("%Y-%m-%d")
end

-- ============================================
-- УТИЛИТЫ
-- ============================================
local function firstColumn(line)
    return ((line:match("^([^\t]*)") or ""):gsub("{%x%x%x%x%x%x}", ""))
end

local function getColumns(line)
    local cols = {}
    for c in line:gmatch("([^\t]+)") do
        table.insert(cols, (c:gsub("{%x%x%x%x%x%x}", "")))
    end
    return cols
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ============================================
-- МОДИФИКАЦИЯ ДИАЛОГА (ИГРОКИ + МЕСТА)
-- text приходит в CP1251
-- ============================================
if sampev_ok and sampev then
    function sampev.onShowDialog(id, style, title, b1, b2, text)
        if id ~= PAPARAZZI_DIALOG_ID then return end
        if style ~= PAPARAZZI_STYLE then return end
        if not text then return end

        -- Все проверки в CP1251 (как приходит text)
        local hasNickAny        = text:find("%a[%w]*_%w+") ~= nil
        local hasPlacesHeader   = text:find(P_HEADER_PLACES, 1, true) ~= nil
        local hasPlayersHeader  = text:find(P_HEADER_PLAYERS, 1, true) ~= nil

        if not (hasPlacesHeader or hasPlayersHeader or hasNickAny) then
            return -- чужой диалог
        end

        local mode
        if hasPlacesHeader then mode = "places"
        elseif hasPlayersHeader then mode = "players"
        else mode = "players" end

        -- Открываем окно
        PaparazziWindowState[0] = true
        overlayShownTime = os.clock()
        lastDialogId = id

        local out = {}
        local n = 0

        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1

            -- Определяем, шапка ли это
            local isHeader = false
            if line:find(P_HEADER_PLACES, 1, true)
            or line:find(P_HEADER_CITY, 1, true)
            or line:find(P_HEADER_PLAYERS, 1, true)
            or line:find(P_HEADER_ORG, 1, true) then
                isHeader = true
            end

            if isHeader then
                -- Шапка. Добавляем колонку "Фото" если её ещё нет.
                if line:find(P_HEADER_PHOTO, 1, true) then
                    out[#out + 1] = line
                else
                    out[#out + 1] = line .. "\t" .. P_HEADER_PHOTO
                end
            elseif line == "" then
                out[#out + 1] = line
            elseif mode == "places" then
                -- Строка места: колонка 1 = место, колонка 2 = город
                local cols = getColumns(line)
                local place = trim(cols[1] or "")
                local city  = trim(cols[2] or "")
                if place ~= "" and city ~= "" then
                    -- Ключ должен совпадать с тем, что формируется в handleServerMessage (UTF-8)
                    local placeU8 = u8:encode(place)
                    local cityU8  = u8:encode(city)
                    if placeU8 and cityU8 then
                        local key = placeU8 .. "|" .. cityU8
                        local mark = photos.places[key] and "{FF3333}[X]" or "{33FF33}[V]"
                        out[#out + 1] = line .. "\t" .. mark
                    else
                        out[#out + 1] = line
                    end
                else
                    out[#out + 1] = line
                end
            else
                -- mode == "players"
                local nick = firstColumn(line)
                if nick ~= "" and nick:find("_") then
                    local mark = photos.players[nick] and "{FF3333}[X]" or "{33FF33}[V]"
                    out[#out + 1] = line .. "\t" .. mark
                else
                    out[#out + 1] = line
                end
            end
        end

        return { id, style, title, b1, b2, table.concat(out, "\n") }
    end
end

-- ============================================
-- ОБРАБОТКА ЗАКАЗОВ
-- ============================================
local function applyOrder()
    if not currentOrder then return end

    if currentOrder.type == "player" then
        local nick = currentOrder.nick
        if photos.players[nick] then
            sayRed("[Фото] Заказ на «" .. nick:gsub("_", " ") ..
                   "» уже выполнен на этой неделе! (" .. photos.players[nick].date .. ")")
        else
            photos.players[nick] = { date = today() }
            savePhotos()
            local cnt = countPlayers()
            sayGreen("[Фото] ✔ Зачтено фото игрока " .. nick:gsub("_", " ") ..
                     " (" .. cnt .. "/" .. LIMIT_PLAYERS .. ")")
            if cnt >= LIMIT_PLAYERS then
                sayYellow("[Фото] ⚠ Лимит фото игроков исчерпан (" .. LIMIT_PLAYERS .. "/нед.)")
            end
        end

    elseif currentOrder.type == "place" then
        local key = currentOrder.place .. "|" .. currentOrder.city
        if photos.places[key] then
            sayRed("[Фото] Заказ на локацию «" .. currentOrder.place .. "» (" ..
                   currentOrder.city .. ") уже выполнен на этой неделе! (" ..
                   photos.places[key].date .. ")")
        else
            photos.places[key] = { date = today() }
            savePhotos()
            local cnt = countPlaces()
            sayGreen("[Фото] ✔ Зачтено фото локации «" .. currentOrder.place .. "» (" ..
                     currentOrder.city .. ") (" .. cnt .. "/" .. LIMIT_PLACES .. ")")
            if cnt >= LIMIT_PLACES then
                sayYellow("[Фото] ⚠ Лимит фото локаций исчерпан (" .. LIMIT_PLACES .. "/нед.)")
            end
        end
    end

    currentOrder = nil
    photoTaken = false
end

-- ============================================
-- ПАРСИНГ ЧАТА
-- ============================================
local PATTERN_ORDER_PLAYER_ID   = 'Вам нужно сделать фотографию%s+"([^"%[%]]+)%[%d+%]"'
local PATTERN_ORDER_PLAYER_NOID = 'Вам нужно сделать фотографию%s+"([^"%[%]]+)"'
local PATTERN_ORDER_PLACE       = 'Вам нужно сделать фотографию%s+"([^"]+)"%s+в городе%s+"([^"]+)"'

local PATTERN_PHOTO_OK   = "Снимок вышел удачным"
local PATTERN_PHOTO_FAIL = "Снимок вышел неудачным"
local PATTERN_REWARD     = "Ваша награда"

local function handleServerMessage(text)
    if not text then return end

    local utf8text = u8:encode(text)
    if not utf8text then utf8text = text end

    local clean = utf8text:gsub("{%x%x%x%x%x%x}", "")

    -- 1. СНАЧАЛА проверяем МЕСТО
    local ordPlace, ordCity = clean:match(PATTERN_ORDER_PLACE)
    if ordPlace and ordCity then
        currentOrder = { type = "place", place = ordPlace, city = ordCity }
        photoTaken = false
        lastSuccessOrder = nil
        local key = ordPlace .. "|" .. ordCity
        if photos.places[key] then
            sayRed("[Фото] ⚠ Заказ на локацию «" .. ordPlace .. "» (" .. ordCity ..
                   ") уже выполнен на этой неделе! (" .. photos.places[key].date .. ")")
        end
        return
    end

    -- 2. ПОТОМ ИГРОКА
    local ordNick = clean:match(PATTERN_ORDER_PLAYER_ID) or clean:match(PATTERN_ORDER_PLAYER_NOID)
    if ordNick then
        if not ordNick:find("_") then
            return
        end

        currentOrder = { type = "player", nick = ordNick }
        photoTaken = false
        lastSuccessOrder = nil
        if photos.players[ordNick] then
            sayRed("[Фото] ⚠ Заказ на «" .. ordNick:gsub("_", " ") ..
                   "» уже выполнен на этой неделе! (" .. photos.players[ordNick].date .. ")")
        end
        return
    end

    if clean:find(PATTERN_PHOTO_OK, 1, true) then
        if currentOrder then
            photoTaken = true
            lastSuccessOrder = currentOrder
            currentOrder = nil
        end
        return
    end

    if clean:find(PATTERN_PHOTO_FAIL, 1, true) then
        photoTaken = false
        lastSuccessOrder = nil
        return
    end

    if clean:find(PATTERN_REWARD, 1, true) then
        if photoTaken and lastSuccessOrder then
            currentOrder = lastSuccessOrder
            applyOrder()
            lastSuccessOrder = nil
        end
        return
    end
end

-- ============================================
-- ПОДПИСКА НА СОБЫТИЯ
-- ============================================
if sampev_ok and sampev then
    function sampev.onServerMessage(color, text)
        if not text then return end
        handleServerMessage(text)
    end

    function sampev.onChatMessage(playerId, text)
        if not text then return end
        handleServerMessage(text)
    end
end

-- ============================================
-- ОКНО (ПРИВЯЗАНО К ДИАЛОГУ)
-- ============================================
imgui.OnFrame(function() return PaparazziWindowState[0] end, function()
    local io = imgui.GetIO()
    local sw = io.DisplaySize.x

    imgui.SetNextWindowPos(imgui.ImVec2(sw - 320, 100), imgui.Cond.Appearing)
    imgui.SetNextWindowSizeConstraints(
        imgui.ImVec2(340, 100),
        imgui.ImVec2(700, 1200)
    )
    imgui.SetNextWindowBgAlpha(1.0)

    local isOpen = imgui.Begin("SFN | База фотографа", PaparazziWindowState,
        imgui.WindowFlags.NoCollapse +
        imgui.WindowFlags.AlwaysAutoResize)

    if not isOpen then imgui.End() return end

    local cntP = countPlayers()
    local cntL = countPlaces()

    local valueColorP = cntP >= LIMIT_PLAYERS and imgui.ImVec4(0.9, 0.2, 0.2, 1) or imgui.ImVec4(0.2, 0.6, 0.9, 1)
    local valueColorL = cntL >= LIMIT_PLACES and imgui.ImVec4(0.9, 0.2, 0.2, 1) or imgui.ImVec4(0.9, 0.5, 0.1, 1)

    imgui.Text("Фото людей: ")
    imgui.SameLine()
    imgui.TextColored(valueColorP, string.format("%d / %d", cntP, LIMIT_PLAYERS))

    imgui.Dummy(imgui.ImVec2(0, 2))

    imgui.Text("Фото мест: ")
    imgui.SameLine()
    imgui.TextColored(valueColorL, string.format("%d / %d", cntL, LIMIT_PLACES))

    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    if imgui.CollapsingHeader("Список фотографий людей (" .. cntP .. ")") then
        if cntP == 0 then
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "   Пока пусто")
        else
            local sorted = {}
            for nick, info in pairs(photos.players) do
                table.insert(sorted, { nick = nick, date = info.date })
            end
            table.sort(sorted, function(a, b) return a.nick < b.nick end)

            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            local h = math.min(#sorted * 18 + 6, 200)
            imgui.BeginChild("players_list", imgui.ImVec2(-1, h), true)

            for i, item in ipairs(sorted) do
                imgui.Text(string.format("%d. %s", i, item.nick:gsub("_", " ")))
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), "  (" .. item.date .. ")")
            end

            imgui.EndChild()
            imgui.PopStyleColor()
        end
    end

    if imgui.CollapsingHeader("Список фотографий мест (" .. cntL .. ")") then
        if cntL == 0 then
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "   Пока пусто")
        else
            local sorted = {}
            for key, info in pairs(photos.places) do
                local place, city = key:match("^(.-)|(.+)$")
                table.insert(sorted, { place = place or key, city = city or "?", date = info.date })
            end
            table.sort(sorted, function(a, b)
                if a.place == b.place then return a.city < b.city end
                return a.place < b.place
            end)

            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            local h = math.min(#sorted * 18 + 6, 200)
            imgui.BeginChild("places_list", imgui.ImVec2(-1, h), true)

            for i, item in ipairs(sorted) do
                imgui.Text(string.format("%d. %s", i, item.place))
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.4, 0.5, 0.7, 1), "  (" .. item.city .. ")")
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), "  " .. item.date)
            end

            imgui.EndChild()
            imgui.PopStyleColor()
        end
    end

    imgui.Dummy(imgui.ImVec2(0, 6))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 4))

    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
    if imgui.Button("Очистить список", imgui.ImVec2(-1, 26)) then
        imgui.OpenPopup("confirm_clear_photos")
    end
    imgui.PopStyleColor(3)

    if imgui.BeginPopupModal("confirm_clear_photos", nil, imgui.WindowFlags.AlwaysAutoResize) then
        imgui.Text("Очистить весь список фотографий?")
        imgui.Text("Это сбросит счётчики недели!")
        imgui.Dummy(imgui.ImVec2(0, 10))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.9))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.1, 0.1, 1.0))
        if imgui.Button("Да, очистить", imgui.ImVec2(140, 28)) then
            photos = { players = {}, places = {} }
            savePhotos()
            sayYellow("[Фото] Список фотографий очищен.")
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
end)

-- ============================================
-- MAIN
-- ============================================
function main()
    while not isSampAvailable() do wait(0) end

    ensureDataDir()
    ensurePhotos()

    while true do
        wait(0)

        if PaparazziWindowState[0] then
            if overlayShownTime and (os.clock() - overlayShownTime) > 0.5 then
                if not sampIsDialogActive() or lastDialogId ~= PAPARAZZI_DIALOG_ID then
                    PaparazziWindowState[0] = false
                    overlayShownTime = nil
                    lastDialogId = nil
                end
            end
        else
            overlayShownTime = nil
        end
    end
end

function scriptUnload()
    savePhotos()
    logPrint("[SFN-Photo] Помощник фотографа выгружен.")
end