script_name('SFN Logs')
script_version('1.1.0')
script_author('San Fierro News')

--[[
    Журнал состава San Fierro News.

    По каждому игроку хранит: ник, кто принял, дату принятия, текущий ранг и
    дату последнего повышения. Считает дату следующего повышения по правилам
    редакции, следит за лимитами должностей старшего состава и минимальными
    уровнями.

    Файлы (создаются в moonloader\SFNLogs\):
        config.ini      шаблоны перехвата чата, хоткей, настройки
        roster.json     журнал состава
        chat_dump.txt   дамп чата в режиме ловли шаблонов
        export.txt      результат экспорта

    КОДИРОВКА: внутри скрипт везде работает в UTF-8 (файлы, окно, синхронизация).
    Границу с игрой он конвертирует сам: чат и ники SA-MP приходят в CP1251 и
    переводятся в UTF-8 на входе, а сообщения в чат и print - обратно в CP1251.
    Старые config.ini / roster.json в CP1251 распознаются и читаются сами.

    Команды:
        /sfnlog             открыть/закрыть окно
        /sfnlogcap          включить/выключить дамп чата (снятие шаблонов)
        /sfnlogsave         принудительно сохранить
        /sfnlogadd Ник [КтоПринял]   добавить стажёра с текущей датой
]]

local imgui    = require 'mimgui'
-- Конвертацию CP1251 <-> UTF-8 скрипт делает сам (см. PURE-секцию): внешняя
-- библиотека encoding не нужна, а всё поведение покрыто тестами.

-- samp.events нужен только для автоперехвата чата. Без него скрипт остаётся
-- полностью рабочим в ручном режиме, поэтому не роняем загрузку.
local sampev, sampevErr = nil, nil
do
    local ok, mod = pcall(require, 'samp.events')
    if ok then sampev = mod else sampevErr = tostring(mod) end
end

-- >>> PURE LOGIC BEGIN
-- Всё, что ниже до метки PURE LOGIC END, не трогает ImGui и SAMP API и может
-- быть протестировано отдельно (см. test_logic.lua).

-- ============================================================ ПУТИ ========

local DIR = (getWorkingDirectory and getWorkingDirectory() or '.') .. '\\SFNLogs'

local PATHS = {
    config    = DIR .. '\\config.ini',
    roster    = DIR .. '\\roster.json',
    chatdump  = DIR .. '\\chat_dump.txt',
    export    = DIR .. '\\export.txt',
}

local function ensureDir()
    if doesDirectoryExist and not doesDirectoryExist(DIR) then
        if createDirectory then pcall(createDirectory, DIR) end
        if not (doesDirectoryExist and doesDirectoryExist(DIR)) then
            os.execute('mkdir "' .. DIR .. '" 2>nul')
        end
    end
end

-- ============================================== МИНИМАЛЬНЫЙ JSON КОДЕК ====
-- Свой, чтобы не зависеть от наличия cjson/dkjson в конкретной сборке.

local json = {}
json.null = setmetatable({}, { __tostring = function() return 'null' end })

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
              ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }

local function isSequence(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    return n == #t and n > 0
end

function json.encode(v)
    if v == nil or v == json.null then return 'null' end
    local tv = type(v)
    if tv == 'boolean' then
        return v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format('%d', v) end
        return string.format('%.14g', v)
    elseif tv == 'string' then
        local out = { '"' }
        for i = 1, #v do
            local c = v:sub(i, i)
            local e = ESC[c]
            if e then out[#out + 1] = e
            elseif c:byte() < 0x20 then out[#out + 1] = string.format('\\u%04x', c:byte())
            else out[#out + 1] = c end          -- UTF-8 байты проходят как есть
        end
        out[#out + 1] = '"'
        return table.concat(out)
    elseif tv == 'table' then
        local out = {}
        if isSequence(v) then
            out[#out + 1] = '['
            for i = 1, #v do
                if i > 1 then out[#out + 1] = ',' end
                out[#out + 1] = json.encode(v[i])
            end
            out[#out + 1] = ']'
        else
            out[#out + 1] = '{'
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for i, k in ipairs(keys) do
                local val = v[k]
                if val ~= nil then
                    if i > 1 then out[#out + 1] = ',' end
                    out[#out + 1] = json.encode(k)
                    out[#out + 1] = ':'
                    out[#out + 1] = json.encode(val)
                end
            end
            out[#out + 1] = '}'
        end
        return table.concat(out)
    end
    return 'null'
end

local function utf8FromCodepoint(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
                       0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
end

local function skipWs(s, i)
    while i <= #s do
        local c = s:sub(i, i)
        if c == ' ' or c == '\t' or c == '\n' or c == '\r' then i = i + 1 else break end
    end
    return i
end

local parseValue

local function parseString(s, i)
    local out, n = {}, #s
    i = i + 1
    while i <= n do
        local c = s:sub(i, i)
        if c == '"' then return table.concat(out), i + 1
        elseif c == '\\' then
            i = i + 1
            local e = s:sub(i, i)
            if e == 'n' then out[#out + 1] = '\n'
            elseif e == 'r' then out[#out + 1] = '\r'
            elseif e == 't' then out[#out + 1] = '\t'
            elseif e == 'b' then out[#out + 1] = '\b'
            elseif e == 'f' then out[#out + 1] = '\f'
            elseif e == 'u' then
                out[#out + 1] = utf8FromCodepoint(tonumber(s:sub(i + 1, i + 4), 16) or 63)
                i = i + 4
            else out[#out + 1] = e end
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    error('unterminated string')
end

local function parseNumber(s, i)
    local j = i
    while j <= #s and s:sub(j, j):find('[%d%+%-eE%.]') do j = j + 1 end
    return tonumber(s:sub(i, j - 1)), j
end

parseValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == '{' then
        local obj = {}
        i = skipWs(s, i + 1)
        if s:sub(i, i) == '}' then return obj, i + 1 end
        while true do
            local key
            key, i = parseString(s, skipWs(s, i))
            i = skipWs(s, i)
            if s:sub(i, i) ~= ':' then error('expected ":" at ' .. i) end
            local val
            val, i = parseValue(s, i + 1)
            if val ~= json.null then obj[key] = val end
            i = skipWs(s, i)
            local d = s:sub(i, i)
            if d == ',' then i = i + 1
            elseif d == '}' then return obj, i + 1
            else error('expected "," or "}" at ' .. i) end
        end
    elseif c == '[' then
        local arr = {}
        i = skipWs(s, i + 1)
        if s:sub(i, i) == ']' then return arr, i + 1 end
        while true do
            local val
            val, i = parseValue(s, i)
            arr[#arr + 1] = (val == json.null) and false or val
            i = skipWs(s, i)
            local d = s:sub(i, i)
            if d == ',' then i = i + 1
            elseif d == ']' then return arr, i + 1
            else error('expected "," or "]" at ' .. i) end
        end
    elseif c == '"' then
        return parseString(s, i)
    elseif c == '-' or c:find('%d') then
        return parseNumber(s, i)
    elseif s:sub(i, i + 3) == 'true' then return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then return json.null, i + 4
    end
    error('unexpected token at ' .. i .. ': ' .. s:sub(i, i + 12))
end

function json.decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, val = pcall(parseValue, s, 1)
    if not ok then return nil, val end
    return val
end

-- =============================================================== ФАЙЛЫ ====

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function writeFile(path, data)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function appendFile(path, data)
    local f = io.open(path, 'a')
    if not f then return end
    f:write(data)
    f:close()
end

-- ================================================================ INI =====

local function loadIni(path)
    local out, section = {}, nil
    local raw = readFile(path)
    if not raw then return out end
    -- Конфиги, сохранённые до перехода на UTF-8, лежат в CP1251: такой файл
    -- не является валидным UTF-8, поэтому конвертируется на лету.
    if not isUtf8(raw) then raw = cp1251ToUtf8(raw) end
    for line in raw:gmatch('[^\r\n]+') do
        local t = line:gsub('^%s+', ''):gsub('%s+$', '')
        if t ~= '' and not t:match('^[;#]') then
            local sec = t:match('^%[(.-)%]$')
            if sec then
                section = sec
                out[section] = out[section] or {}
            elseif section then
                -- значение берём дословно после первого "=": в Lua-паттернах
                -- может встречаться что угодно, кроме перевода строки
                local k, v = t:match('^([^=]-)=(.*)$')
                if k then out[section][k:gsub('%s+$', '')] = v:gsub('^%s+', '') end
            end
        end
    end
    return out
end

-- ==================================================== ПРАВИЛА РЕДАКЦИИ ====

RANK_NAMES = {
    [1] = 'Стажёр',
    [2] = 'Звукооператор',
    [3] = 'Звукорежиссёр',
    [4] = 'Репортёр',
    [5] = 'Ведущий',
    [6] = 'Редактор',
    [7] = 'Главный редактор',
    [8] = 'Технический директор',
    [9] = 'Программный директор',
}
MAX_RANK = 9

-- Сколько нужно отработать на ранге N, чтобы перейти на N+1 (секунды).
SECONDS_TO_NEXT = {
    [1] = 24 * 3600,      -- Стажёр -> Звукооператор: минимум 24 часа
    [2] = 2 * 86400,      -- Звукооператор -> Звукорежиссёр
    [3] = 2 * 86400,      -- Звукорежиссёр -> Репортёр
    [4] = 3 * 86400,      -- Репортёр -> Ведущий
    [5] = 5 * 86400,      -- Ведущий -> Редактор
    [6] = 7 * 86400,      -- Редактор -> Главный редактор
    [7] = 7 * 86400,      -- Главный редактор -> Технический директор
    [8] = 10 * 86400,     -- Технический директор -> Программный директор
}

-- Требования к ЦЕЛЕВОМУ рангу: минимальный уровень и потолок должностей.
PROMOTE_REQ = {
    [7] = { minLevel = 8,  cap = 4 },
    [8] = { minLevel = 9,  cap = 4 },
    [9] = { minLevel = 10, cap = 3 },
}

-- Длина строки в символах, а не в байтах: Lua считает %-Ns по байтам, и
-- кириллица в UTF-8 занимает по два байта, из-за чего колонки разъезжаются.
function utf8len(s)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end

function pad(s, w)
    s = tostring(s or '')
    local n = utf8len(s)
    return n >= w and s or (s .. string.rep(' ', w - n))
end

-- Поиск ранга по названию. Чат на входе переводится в UTF-8 (см.
-- onServerMessage), поэтому основные ключи - UTF-8; CP1251-варианты держим
-- как страховку для строк, пришедших в обход входного конвертера.
-- string.lower() в Lua байтовый и кириллицу не трогает - для ASCII складываем
-- ещё и lower-вариант.

-- Lowercase для CP1251-строки: переводит заглавные кириллические байты
-- (0xC0-0xDF) в строчные (0xE0-0xFF), остальные байты не трогает. Диапазон
-- ОБЯЗАТЕЛЬНО собирается из реальных байтов через string.char: запись
-- '[%C0-%DF]' в Lua-паттернах означает класс '%C' ("не управляющий символ")
-- и '%D' ("не цифра"), а не байтовый диапазон, и сматчила бы почти все байты
-- 0x20-0xFF, из-за чего string.char(b + 0x20) падал на b >= 0xE0 (256 > 255).
local CP1251_UPPER_RANGE = '[' .. string.char(0xC0) .. '-' .. string.char(0xDF) .. ']'
function cp1251Lower(s)
    return (s:gsub(CP1251_UPPER_RANGE, function(c)
        return string.char(c:byte() + 0x20)
    end))
end

-- ------------------------------------------ CP1251 <-> UTF-8 --------------
-- Игра (SA-MP/MoonLoader) говорит в CP1251: текст чата, ники и аргументы
-- команд приходят байтами CP1251, и чат/print ждут CP1251 обратно. ImGui и
-- этот файл - UTF-8. Поэтому ВНУТРИ скрипта всё хранится в UTF-8, а
-- конвертация происходит только на границе с игрой:
--   cp1251ToUtf8 - на входе (onServerMessage, ники, аргументы команд);
--   utf8ToCp1251 - на выходе (say, logEvent).
-- Таблицы самодостаточны (без require 'encoding'), поэтому в игре и в тестах
-- поведение одинаковое. Байт 0x98 в CP1251 не определён - идёт в U+FFFD.

-- Кодовые точки Unicode для байтов CP1251 0x80-0xFF (таблица unicode.org).
local CP1251_HI_CODE = {
    [128]=0x0402, [129]=0x0403, [130]=0x201A, [131]=0x0453, [132]=0x201E, [133]=0x2026,
    [134]=0x2020, [135]=0x2021, [136]=0x20AC, [137]=0x2030, [138]=0x0409, [139]=0x2039,
    [140]=0x040A, [141]=0x040C, [142]=0x040B, [143]=0x040F, [144]=0x0452, [145]=0x2018,
    [146]=0x2019, [147]=0x201C, [148]=0x201D, [149]=0x2022, [150]=0x2013, [151]=0x2014,
    [152]=0xFFFD, [153]=0x2122, [154]=0x0459, [155]=0x203A, [156]=0x045A, [157]=0x045C,
    [158]=0x045B, [159]=0x045F, [160]=0x00A0, [161]=0x040E, [162]=0x045E, [163]=0x0408,
    [164]=0x00A4, [165]=0x0490, [166]=0x00A6, [167]=0x00A7, [168]=0x0401, [169]=0x00A9,
    [170]=0x0404, [171]=0x00AB, [172]=0x00AC, [173]=0x00AD, [174]=0x00AE, [175]=0x0407,
    [176]=0x00B0, [177]=0x00B1, [178]=0x0406, [179]=0x0456, [180]=0x0491, [181]=0x00B5,
    [182]=0x00B6, [183]=0x00B7, [184]=0x0451, [185]=0x2116, [186]=0x0454, [187]=0x00BB,
    [188]=0x0458, [189]=0x0405, [190]=0x0455, [191]=0x0457, [192]=0x0410, [193]=0x0411,
    [194]=0x0412, [195]=0x0413, [196]=0x0414, [197]=0x0415, [198]=0x0416, [199]=0x0417,
    [200]=0x0418, [201]=0x0419, [202]=0x041A, [203]=0x041B, [204]=0x041C, [205]=0x041D,
    [206]=0x041E, [207]=0x041F, [208]=0x0420, [209]=0x0421, [210]=0x0422, [211]=0x0423,
    [212]=0x0424, [213]=0x0425, [214]=0x0426, [215]=0x0427, [216]=0x0428, [217]=0x0429,
    [218]=0x042A, [219]=0x042B, [220]=0x042C, [221]=0x042D, [222]=0x042E, [223]=0x042F,
    [224]=0x0430, [225]=0x0431, [226]=0x0432, [227]=0x0433, [228]=0x0434, [229]=0x0435,
    [230]=0x0436, [231]=0x0437, [232]=0x0438, [233]=0x0439, [234]=0x043A, [235]=0x043B,
    [236]=0x043C, [237]=0x043D, [238]=0x043E, [239]=0x043F, [240]=0x0440, [241]=0x0441,
    [242]=0x0442, [243]=0x0443, [244]=0x0444, [245]=0x0445, [246]=0x0446, [247]=0x0447,
    [248]=0x0448, [249]=0x0449, [250]=0x044A, [251]=0x044B, [252]=0x044C, [253]=0x044D,
    [254]=0x044E, [255]=0x044F,
}

local UTF8_HI_BYTE = {}          -- кодовая точка -> байт CP1251 (обратная)
for b = 0x80, 0xFF do UTF8_HI_BYTE[CP1251_HI_CODE[b]] = b end

local CP1251_HI_RANGE = '[' .. string.char(0x80) .. '-' .. string.char(0xFF) .. ']'

local function utf8Char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40),
                           0x80 + (cp % 0x40))
    end
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + math.floor(cp % 0x1000 / 0x40),
                       0x80 + (cp % 0x40))
end

function cp1251ToUtf8(s)
    if type(s) ~= 'string' then return s end
    return (s:gsub(CP1251_HI_RANGE, function(c)
        return utf8Char(CP1251_HI_CODE[c:byte()])
    end))
end

-- Первая UTF-8-последовательность с позиции i: возвращает cp, len или nil.
local function utf8Seq(s, i)
    local b = s:byte(i)
    local len, cp
    if b >= 0xC2 and b <= 0xDF then len, cp = 2, b - 0xC0
    elseif b >= 0xE0 and b <= 0xEF then len, cp = 3, b - 0xE0
    elseif b >= 0xF0 and b <= 0xF4 then len, cp = 4, b - 0xF0
    else return nil end
    if i + len - 1 > #s then return nil end
    for j = 2, len do
        local c = s:byte(i + j - 1)
        if c < 0x80 or c > 0xBF then return nil end
        cp = cp * 0x40 + (c - 0x80)
    end
    return cp, len
end

function utf8ToCp1251(s)
    if type(s) ~= 'string' then return s end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        else
            local cp, len = utf8Seq(s, i)
            if not cp then
                -- не UTF-8: байт уже похож на CP1251, пропускаем как есть
                out[#out + 1] = s:sub(i, i)
                i = i + 1
            else
                local cb = UTF8_HI_BYTE[cp]
                out[#out + 1] = cb and string.char(cb) or '?'
                i = i + len
            end
        end
    end
    return table.concat(out)
end

-- Корректна ли строка как UTF-8. Используем, чтобы отличить старые файлы в
-- CP1251 от новых в UTF-8 при чтении config.ini и roster.json.
function isUtf8(s)
    if type(s) ~= 'string' then return false end
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if b >= 0x80 then
            local cp, len = utf8Seq(s, i)
            if not cp then return false end
            i = i + len
        else
            i = i + 1
        end
    end
    return true
end

RANK_BY_NAME = {}
do
    local CP1251_LOWER = setmetatable({}, { __index = function(t, k)
        return cp1251Lower(k)
    end })
    for i, name in pairs(RANK_NAMES) do
        RANK_BY_NAME[name] = i
        RANK_BY_NAME[name:lower()] = i
        local cp = utf8ToCp1251(name)
        if cp ~= name then
            RANK_BY_NAME[cp] = i
            RANK_BY_NAME[CP1251_LOWER[cp]] = i
        end
    end
end

function rankName(r)
    return RANK_NAMES[r] or ('Ранг ' .. tostring(r))
end

-- ============================================ СОСТОЯНИЕ И ХРАНИЛИЩЕ =======

-- Вызывается после любой мутации. В чистой логике - пустая; сетевой слой
-- переопределяет её, чтобы триггерить немедленный пуш при pushOnEdit.
function onRosterChanged(nick, kind) end

roster    = { members = {}, version = 1 }

cfg = {
    hotkey              = 0x75,     -- F8
    captureChat         = false,
    showDismissed       = false,
    patterns            = { accept = {}, promote = {}, demote = {}, dismiss = {} },
    sync = {
        enabled      = false,
        url          = '',          -- https://script.google.com/macros/s/.../exec
        token        = '',
        interval     = 120,         -- секунд между автосинхронизациями
        pushOnEdit   = true,        -- пушить сразу после правки
        usePost      = false,       -- POST вместо GET (нужен модуль requests)
    },
}

-- Ник текущего игрока: подставляется в updatedBy и в журнал изменений.
-- Выставляется из main(); в тестах задаётся напрямую.
localNick = ''

DEFAULT_INI = [[; SFN Logs - конфигурация
; Файл читается в UTF-8 (как и этот скрипт). Старые версии конфига в CP1251
; распознаются автоматически и конвертируются на лету.

[main]
; VK-код клавиши окна. 0x75 = F8, 0x77 = F10, 0x70 = F1
hotkey = 0x75
; Показывать уволенных в общей таблице (0/1)
showDismissed = 0

[sync]
; Синхронизация состава через Google Sheets (Apps Script Web App).
; URL и токен берутся из развёртывания Apps Script - см. GoogleAppsScript.gs.
enabled = 0
url =
token =
; Секунд между автосинхронизациями в фоне
interval = 120
; Пушить правку сразу, не дожидаясь фонового цикла
pushOnEdit = 1
; POST вместо GET: тело запроса не попадает в логи хостинга, но требует
; модуль requests (LuaSocket + LuaSec). Без него скрипт сам вернётся на GET.
usePost = 0

[patterns]
; Шаблон - обычный Lua-паттерн. Захваты (скобки) перечисляются в строке
; .fields через запятую, в том же порядке. Допустимые имена:
;   nick      ник игрока
;   by        ник того, кто совершил действие (принял / повысил)
;   rank      новый ранг цифрой
;   rankname  новый ранг названием
;
; Вариантов одного события может быть несколько: accept.1, accept.2, ...
; Пустой шаблон просто пропускается.
;
; Как снять точные тексты своего сервера:
;   1) /sfnlogcap           - включится дамп в SFNLogs\chat_dump.txt
;   2) примите и повысьте кого-нибудь на тестовом аккаунте
;   3) /sfnlogcap ещё раз, скопируйте строки из chat_dump.txt сюда
;   4) в окне вкладка "Настройки" -> "Перечитать config.ini"

; Приём во фракцию: кто принял + кого приняли
accept.1 =
accept.1.fields = by,nick

; Повышение: кого повысили + до какого ранга (цифрой или названием)
promote.1 =
promote.1.fields = nick,rank

; Понижение (необязательно)
demote.1 =
demote.1.fields = nick,rank

; Увольнение / выход из фракции (нужно для авто-ЧС)
dismiss.1 =
dismiss.1.fields = nick
]]

function saveRoster()    writeFile(PATHS.roster,    json.encode(roster))    end

function loadPatternsFromIni(ini)
    local p = ini.patterns or {}
    for _, kind in ipairs({ 'accept', 'promote', 'demote', 'dismiss' }) do
        cfg.patterns[kind] = {}
        for i = 1, 16 do
            local raw = p[kind .. '.' .. i]
            if raw and raw ~= '' then
                local fields = {}
                for name in (p[kind .. '.' .. i .. '.fields'] or ''):gmatch('[^,%s]+') do
                    fields[#fields + 1] = name
                end
                cfg.patterns[kind][#cfg.patterns[kind] + 1] = { pattern = raw, fields = fields }
            end
        end
    end
end

function loadConfig()
    local ini = loadIni(PATHS.config)
    if not next(ini) then
        writeFile(PATHS.config, DEFAULT_INI)
        ini = loadIni(PATHS.config)
    end
    local m = ini.main or {}
    cfg.hotkey              = tonumber(m.hotkey) or 0x75
    cfg.showDismissed       = (m.showDismissed == '1' or m.showDismissed == 'true')

    local sy = ini.sync or {}
    local function flag(v, default)
        if v == nil or v == '' then return default end
        return not (v == '0' or v == 'false')
    end
    cfg.sync.enabled    = flag(sy.enabled, false)
    cfg.sync.url        = trim(sy.url or '')
    cfg.sync.token      = trim(sy.token or '')
    cfg.sync.interval   = math.max(15, tonumber(sy.interval) or 120)
    cfg.sync.pushOnEdit = flag(sy.pushOnEdit, true)
    cfg.sync.usePost    = flag(sy.usePost, false)
    -- синхронизация без URL бессмысленна: не даём ей молча «работать»
    if cfg.sync.enabled and cfg.sync.url == '' then cfg.sync.enabled = false end

    loadPatternsFromIni(ini)
end

function loadRoster()
    local raw = readFile(PATHS.roster)
    if raw and raw ~= '' then
        -- старый roster.json мог быть сохранён в CP1251
        if not isUtf8(raw) then raw = cp1251ToUtf8(raw) end
        local data, err = json.decode(raw)
        if type(data) == 'table' and type(data.members) == 'table' then
            roster = data
            return true
        end
        print(utf8ToCp1251('[SFN Logs] roster.json не разобрался: ' .. tostring(err)))
    end
    roster = { members = {}, version = 1 }
    return false
end

-- ==================================================== ВРЕМЯ И ФОРМАТ =====

function fmtDate(t)     return t and os.date('%d.%m.%Y', t) or '--.--.----' end
function fmtDateTime(t) return t and os.date('%d.%m.%Y %H:%M', t) or '-' end

function fmtLeft(sec)
    if sec == nil then return '-' end
    if sec <= 0 then return 'готово' end
    local d = math.floor(sec / 86400)
    local h = math.floor(sec % 86400 / 3600)
    if d > 0 then return string.format('%dд %dч', d, h) end
    return string.format('%dч %02dм', h, math.floor(sec % 3600 / 60))
end

function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

function nickOf(s)
    -- Ник в SA-MP: латиница, цифры и подчёркивание. Вырезаем его из любого
    -- окружающего текста сообщения.
    return trim(s):match('([%w_]+)') or trim(s)
end

-- ============================================ URL И СИНХРОНИЗАЦИЯ ========

-- Процентное кодирование для параметров запроса. Пробел кодируем как %20,
-- а не как "+": Apps Script в doGet разбирает query сам и плюс не раскрывает.
function urlEncode(str)
    return (tostring(str or ''):gsub('([^%w%-%.%_%~])', function(c)
        return string.format('%%%02X', c:byte())
    end))
end

function buildQuery(params)
    local parts = {}
    for k, v in pairs(params) do
        if v ~= nil then parts[#parts + 1] = urlEncode(k) .. '=' .. urlEncode(v) end
    end
    table.sort(parts)          -- детерминированный порядок: проще сравнивать в тестах
    return table.concat(parts, '&')
end

-- Помечает запись изменённой. Все мутации состава обязаны проходить через неё,
-- иначе правка не уедет в общую таблицу.
function touch(m, by, now)
    if type(m) ~= 'table' then return m end
    m.updatedAt = now or os.time()
    m.updatedBy = by or localNick or m.updatedBy or ''
    m.dirty = true
    return m
end

-- Записи, которые нужно отправить. Порядок детерминирован - по нику.
function pendingRecords()
    local out = {}
    local nicks = {}
    for nick, m in pairs(roster.members) do
        if m.dirty then nicks[#nicks + 1] = nick end
    end
    table.sort(nicks)
    for _, nick in ipairs(nicks) do
        local m = roster.members[nick]
        out[#out + 1] = {
            kind = 'member', nick = nick,
            params = {
                action      = 'push',
                nick        = nick,
                acceptedBy  = m.acceptedBy or '',
                acceptedAt  = tostring(m.acceptedAt or 0),
                rank        = tostring(m.rank or 1),
                promotedAt  = tostring(m.promotedAt or m.acceptedAt or 0),
                level       = tostring(m.level or 0),
                dismissed   = m.dismissed and '1' or '0',
                dismissedAt = tostring(m.dismissedAt or ''),
                note        = m.note or '',
                updatedAt   = tostring(m.updatedAt or 0),
                updatedBy   = m.updatedBy or '',
            },
        }
    end

    return out
end

-- Слияние состава. Побеждает запись с большим updatedAt; локальная правка,
-- которая новее серверной, остаётся dirty и уйдёт следующим пушем.
-- Ничего не удаляет: увольнение - это флаг dismissed, он же и «могила» записи.
function mergeRoster(remote, now)
    local stat = { added = 0, updated = 0, kept = 0, unchanged = 0, skipped = 0 }
    now = now or os.time()
    local FIELDS = { 'acceptedBy', 'acceptedAt', 'rank', 'promotedAt',
                     'level', 'dismissedAt', 'note' }
    for _, r in ipairs(remote or {}) do
        if type(r) ~= 'table' then stat.skipped = stat.skipped + 1
        else
            local nick = nickOf(r.nick)
            if nick == '' then stat.skipped = stat.skipped + 1
            else
                local m = roster.members[nick]
                local rUpdated = tonumber(r.updatedAt) or 0
                if not m then
                    roster.members[nick] = {
                        nick        = nick,
                        acceptedBy  = r.acceptedBy or '',
                        acceptedAt  = tonumber(r.acceptedAt) or now,
                        rank        = tonumber(r.rank) or 1,
                        promotedAt  = tonumber(r.promotedAt) or tonumber(r.acceptedAt) or now,
                        level       = tonumber(r.level) or 0,
                        dismissed   = r.dismissed and true or false,
                        dismissedAt = tonumber(r.dismissedAt),
                        note        = r.note or '',
                        updatedAt   = rUpdated,
                        updatedBy   = r.updatedBy or '',
                        dirty       = false,
                        history     = { { rank = tonumber(r.rank) or 1,
                                          at = tonumber(r.acceptedAt) or now,
                                          note = 'из общей таблицы' } },
                    }
                    stat.added = stat.added + 1
                elseif rUpdated > (m.updatedAt or 0) then
                    for _, f in ipairs(FIELDS) do
                        if r[f] ~= nil then
                            m[f] = (f == 'acceptedAt' or f == 'promotedAt' or f == 'dismissedAt')
                                   and tonumber(r[f]) or r[f]
                        end
                    end
                    m.rank      = tonumber(r.rank) or m.rank or 1
                    m.level     = tonumber(r.level) or 0
                    m.dismissed = r.dismissed and true or false
                    m.updatedAt = rUpdated
                    m.updatedBy = r.updatedBy or ''
                    m.dirty     = false
                    m.history   = m.history or {}
                    m.history[#m.history + 1] = {
                        rank = m.rank, at = rUpdated,
                        note = 'синхронизация: правка ' .. (r.updatedBy ~= '' and r.updatedBy or '?'),
                    }
                    stat.updated = stat.updated + 1
                elseif (m.updatedAt or 0) > rUpdated then
                    m.dirty = true            -- наша правка новее - отправим
                    stat.kept = stat.kept + 1
                else
                    m.dirty = m.dirty or false
                    stat.unchanged = stat.unchanged + 1
                end
            end
        end
    end
    return stat
end

-- Сервер ответил conflict и прислал свою версию - принимаем её целиком.
function applyRemoteRecord(r, now)
    if type(r) ~= 'table' then return nil end
    local nick = nickOf(r.nick)
    if nick == '' then return nil end
    now = now or os.time()
    local m = roster.members[nick] or { nick = nick, history = {} }
    m.nick        = nick
    m.acceptedBy  = r.acceptedBy or m.acceptedBy or ''
    m.acceptedAt  = tonumber(r.acceptedAt) or m.acceptedAt or now
    m.rank        = tonumber(r.rank) or m.rank or 1
    m.promotedAt  = tonumber(r.promotedAt) or m.promotedAt or m.acceptedAt
    m.level       = tonumber(r.level) or 0
    m.dismissed   = r.dismissed and true or false
    m.dismissedAt = tonumber(r.dismissedAt)
    m.note        = r.note or m.note or ''
    m.updatedAt   = tonumber(r.updatedAt) or now
    m.updatedBy   = r.updatedBy or ''
    m.dirty       = false
    m.history     = m.history or {}
    m.history[#m.history + 1] = { rank = m.rank, at = m.updatedAt,
        note = 'конфликт: принята версия ' .. (m.updatedBy ~= '' and m.updatedBy or '?') }
    roster.members[nick] = m
    return m
end

-- ============================================== ЛОГИКА ПРАВИЛ ============

function countAtRank(rank)
    local n = 0
    for _, m in pairs(roster.members) do
        if not m.dismissed and m.rank == rank then n = n + 1 end
    end
    return n
end

-- Возвращает nextAt, ready, reason.
function promotionInfo(m, now)
    now = now or os.time()
    if not m or m.dismissed then return nil, false, 'уволен' end
    local rank = m.rank or 1
    if rank >= MAX_RANK then return nil, true, 'максимальный ранг' end

    local need = SECONDS_TO_NEXT[rank]
    if not need then return nil, false, 'нет данных о сроке' end

    local base = m.promotedAt or m.acceptedAt or now
    local nextAt = base + need

    local req = PROMOTE_REQ[rank + 1]
    if req then
        if req.minLevel and (m.level or 0) < req.minLevel then
            return nextAt, false, string.format('нужен %d ур. (сейчас %s)',
                req.minLevel, tostring(m.level or '?'))
        end
        local have = countAtRank(rank + 1)
        if have >= req.cap then
            return nextAt, false, string.format('нет мест: %d из %d', have, req.cap)
        end
    end

    if now < nextAt then return nextAt, false, nil end
    return nextAt, true, nil
end

function addMember(nick, acceptedBy, acceptedAt, rank, level, now)
    nick  = nickOf(nick)
    now   = now or os.time()
    if nick == '' then return nil, 'пустой ник' end
    if roster.members[nick] then return nil, 'уже в журнале' end
    acceptedAt = acceptedAt or now
    rank = math.max(1, math.min(MAX_RANK, math.floor(rank or 1)))
    roster.members[nick] = {
        nick       = nick,
        acceptedBy = trim(acceptedBy or ''),
        acceptedAt = acceptedAt,
        rank       = rank,
        promotedAt = acceptedAt,        -- у стажёра дата повышения = дата принятия
        level      = level or 0,
        dismissed  = false,
        note       = '',
        history    = { { rank = rank, at = acceptedAt, note = 'принят' } },
    }
    touch(roster.members[nick], nil, now)
    saveRoster()
    onRosterChanged(nick, 'add')
    return roster.members[nick]
end

function changeRank(nick, newRank, note, now)
    local m = roster.members[nick]
    if not m then return nil, 'нет в журнале' end
    newRank = math.floor(newRank or 0)
    if newRank < 1 or newRank > MAX_RANK then return nil, 'неверный ранг' end
    now = now or os.time()
    m.rank = newRank
    m.promotedAt = now
    m.history = m.history or {}
    m.history[#m.history + 1] = { rank = newRank, at = now, note = note or '' }
    touch(m, nil, now)
    saveRoster()
    onRosterChanged(nick, 'rank')
    return m
end

function dismissMember(nick, reason, now)
    local m = roster.members[nick]
    if not m then return nil, 'нет в журнале' end
    now = now or os.time()
    m.dismissed   = true
    m.dismissedAt = now
    m.history = m.history or {}
    m.history[#m.history + 1] = { rank = m.rank, at = now, note = 'уволен: ' .. (reason or '') }
    touch(m, nil, now)
    saveRoster()
    onRosterChanged(nick, 'dismiss')
    return m
end

function restoreMember(nick, now)
    local m = roster.members[nick]
    if not m then return nil, 'нет в журнале' end
    now = now or os.time()
    m.dismissed   = false
    m.dismissedAt = nil
    m.promotedAt  = now          -- срок идёт заново с момента возвращения
    m.history = m.history or {}
    m.history[#m.history + 1] = { rank = m.rank, at = now, note = 'возвращён в состав' }
    touch(m, nil, now)
    saveRoster()
    onRosterChanged(nick, 'restore')
    return m
end

-- ==================================================== ЭКСПОРТ ============

function sortedMembers(includeDismissed, filter)
    local list = {}
    filter = (filter or ''):lower()
    for _, m in pairs(roster.members) do
        if (not m.dismissed or includeDismissed)
           and (filter == '' or m.nick:lower():find(filter, 1, true)) then
            list[#list + 1] = m
        end
    end
    table.sort(list, function(a, b)
        if a.dismissed ~= b.dismissed then return not a.dismissed end
        if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
        return (a.acceptedAt or 0) < (b.acceptedAt or 0)
    end)
    return list
end

function buildExport(now)
    now = now or os.time()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end

    add('San Fierro News - журнал состава на ' .. os.date('%d.%m.%Y %H:%M', now))
    add(string.rep('-', 118))
    add(pad('Ник', 24) .. pad('Кто принял', 22) .. pad('Принят', 12)
        .. pad('Ранг', 24) .. pad('Повышен', 12) .. pad('След. повыш.', 14)
        .. pad('Ур.', 6) .. 'Статус')
    add(string.rep('-', 118))

    for _, m in ipairs(sortedMembers(cfg.showDismissed)) do
        local nextAt, ready, why = promotionInfo(m, now)
        local status
        if m.dismissed then
            status = 'уволен ' .. fmtDate(m.dismissedAt)
        elseif (m.rank or 1) >= MAX_RANK then
            status = 'максимальный ранг'
        elseif ready then
            status = 'МОЖНО ПОВЫШАТЬ'
        elseif why then
            status = why
        else
            status = 'через ' .. fmtLeft((nextAt or now) - now)
        end
        add(pad(m.nick or '?', 24)
            .. pad((m.acceptedBy and m.acceptedBy ~= '') and m.acceptedBy or '-', 22)
            .. pad(fmtDate(m.acceptedAt), 12)
            .. pad(string.format('%s [%d]', rankName(m.rank or 1), m.rank or 1), 24)
            .. pad(fmtDate(m.promotedAt), 12)
            .. pad(fmtDate(nextAt), 14)
            .. pad(tostring(m.level or '?'), 6)
            .. status)
    end

    add(string.rep('-', 118))
    add('Занято мест старшего состава:')
    for r = 7, 9 do
        add('  ' .. pad(rankName(r), 24)
            .. string.format('%d из %d', countAtRank(r), PROMOTE_REQ[r].cap))
    end

    return table.concat(lines, '\r\n'), #sortedMembers(cfg.showDismissed)
end

function exportText()
    local body, n = buildExport()
    -- BOM, чтобы Блокнот и Excel открывали файл именно как UTF-8
    writeFile(PATHS.export, string.char(0xEF, 0xBB, 0xBF) .. body)
    return PATHS.export, n
end

-- <<< PURE LOGIC END

-- ============================================ ОНЛАЙН-ДАННЫЕ ИГРОКОВ =======

local online = {}          -- nick -> { id, level }

local function refreshOnline()
    online = {}
    if sampIsPlayerConnected then
        for id = 0, 999 do
            if sampIsPlayerConnected(id) then
                local nick = cp1251ToUtf8(sampGetPlayerNickname(id))
                if nick then online[nick] = { id = id, level = sampGetPlayerScore(id) or 0 } end
            end
        end
    end
    for nick, m in pairs(roster.members) do
        local o = online[nick]
        if o then m.level = o.level; m.online = true
        else m.online = false end
    end
end

local function levelOf(nick)
    local o = online[nick]
    return o and o.level or 0
end

local function say(text)
    if sampAddChatMessage then sampAddChatMessage(utf8ToCp1251(text), -1) end
end

-- print в MoonLoader печатает в чат игры, а чат живёт в CP1251
local function logEvent(text)
    print(utf8ToCp1251('[SFN Logs] ' .. text))
end

-- ============================================ ПЕРЕХВАТ ЧАТА ==============

local function extractFields(pat, text)
    local caps = { text:match(pat.pattern) }
    if #caps == 0 then return nil end
    local out = {}
    for i, field in ipairs(pat.fields or {}) do out[field] = caps[i] end
    if not next(out) and caps[1] then out.nick = caps[1] end
    return out
end

local function resolveRank(f)
    if f.rank then
        local n = tonumber(f.rank)
        if n then return math.floor(n) end
    end
    if f.rankname then
        local key = trim(f.rankname)
        local n = RANK_BY_NAME[key] or RANK_BY_NAME[key:lower()]
        if n then return n end
    end
    return nil
end

local function matchPattern(kind, text)
    for _, p in ipairs(cfg.patterns[kind] or {}) do
        local ok, f = pcall(extractFields, p, text)
        if ok and f and (f.nick or f.by or f.rank or f.rankname) then return f end
    end
    return nil
end

local function onAccept(text)
    local f = matchPattern('accept', text)
    if not f or not f.nick then return end
    local nick = nickOf(f.nick)
    local existing = roster.members[nick]
    if existing then
        if f.by and trim(existing.acceptedBy or '') == '' then
            existing.acceptedBy = nickOf(f.by)
            saveRoster()
            logEvent('уточнено, кто принял: ' .. nick .. ' <- ' .. existing.acceptedBy)
        end
        return
    end
    local by = f.by and nickOf(f.by) or ''
    local m, err = addMember(nick, by, os.time(), 1, levelOf(nick))
    if m then logEvent(string.format('принят %s (принял: %s)', nick, by ~= '' and by or '?'))
    else logEvent('не удалось добавить ' .. nick .. ': ' .. tostring(err)) end
end

local function onRankChange(text, demote)
    local f = matchPattern(demote and 'demote' or 'promote', text)
    if not f or not f.nick then return end
    local nick = nickOf(f.nick)
    local newRank = resolveRank(f)
    if not newRank then return end
    local m = roster.members[nick]
    if not m then
        logEvent(string.format('%s %s до %d, но игрока нет в журнале',
            nick, demote and 'понижен' or 'повышен', newRank))
        return
    end
    if changeRank(nick, newRank, demote and 'понижен (чат)' or 'повышен (чат)') then
        logEvent(string.format('%s -> %s [%d]', nick, rankName(newRank), newRank))
    end
end

local function onDismiss(text)
    local f = matchPattern('dismiss', text)
    if not f or not f.nick then return end
    local nick = nickOf(f.nick)
    local m = roster.members[nick]
    if m and not m.dismissed then
        dismissMember(nick, 'по сообщению в чате')
        logEvent('уволен ' .. nick)
    end
end

local function onServerMessage(color, text)
    if type(text) ~= 'string' then return end
    -- чат приходит байтами CP1251: дальше по скрипту всё живёт в UTF-8
    text = cp1251ToUtf8(text)
    if cfg.captureChat then
        appendFile(PATHS.chatdump, os.date('[%d.%m.%Y %H:%M:%S] ') .. text .. '\n')
    end
    pcall(onAccept, text)
    pcall(onRankChange, text, false)
    pcall(onRankChange, text, true)
    pcall(onDismiss, text)
end

if sampev then
    function sampev.onServerMessage(color, text) onServerMessage(color, text) end
end

-- ================================== ТРАНСПОРТ И СИНХРОНИЗАЦИЯ ============

local HTTP_TMP = DIR .. '\\sync_response.json'

-- requests (LuaSocket+LuaSec) предпочтительнее: умеет POST и не требует
-- временного файла. Если его нет - уходим на встроенный downloadUrlToFile.
local okRequests, requests = pcall(require, 'requests')

local function transportName()
    if okRequests and requests then return cfg.sync.usePost and 'requests/POST' or 'requests/GET' end
    if downloadUrlToFile then return 'downloadUrlToFile' end
    return 'нет транспорта'
end

-- Блокирующая. Вызывать только из lua_thread.
local function httpViaDownload(url)
    if not downloadUrlToFile then
        return nil, 'нет ни requests, ни downloadUrlToFile'
    end
    os.remove(HTTP_TMP)
    local state = 'wait'
    local ok = pcall(downloadUrlToFile, url, HTTP_TMP, function(_, status)
        if status == 5 then return end                    -- прогресс
        if status == 6 then state = 'done'                -- готово
        else state = 'fail:' .. tostring(status) end      -- 64 и прочее
    end)
    if not ok then return nil, 'downloadUrlToFile отказал' end

    -- os.clock() в Lua считает процессорное время и в ожидании почти не идёт,
    -- поэтому ограничиваем число итераций, а не секунды.
    local tries = 0
    while state == 'wait' and tries < 400 do wait(100); tries = tries + 1 end
    if state == 'wait' then return nil, 'timeout' end
    if state ~= 'done' then return nil, state end

    local body = readFile(HTTP_TMP)
    os.remove(HTTP_TMP)
    if not body or body == '' then return nil, 'пустой ответ' end
    return body
end

-- Возвращает разобранный ответ (таблицу) либо nil и текст ошибки.
local function httpCall(params)
    -- Токен добавляется здесь, а не в каждом вызове: иначе его легко забыть
    -- в новом месте, и сервер молча ответит bad_token.
    local p = {}
    for k, v in pairs(params or {}) do p[k] = v end
    if cfg.sync.token ~= '' then p.token = cfg.sync.token end
    local q = buildQuery(p)
    if okRequests and requests then
        local ok, res
        if cfg.sync.usePost then
            ok, res = pcall(requests.post, cfg.sync.url, {
                data = q,
                headers = { ['Content-Type'] = 'application/x-www-form-urlencoded' },
                timeout = 25,
            })
        else
            local sep = cfg.sync.url:find('?', 1, true) and '&' or '?'
            ok, res = pcall(requests.get, cfg.sync.url .. sep .. q, { timeout = 25 })
        end
        if not ok or not res then return nil, 'запрос не прошёл: ' .. tostring(res) end
        if res.status_code ~= 200 then return nil, 'HTTP ' .. tostring(res.status_code) end
        local data, derr = json.decode(res.text or '')
        if not data then return nil, 'ответ не JSON: ' .. tostring(derr) end
        return data
    end

    local sep = cfg.sync.url:find('?', 1, true) and '&' or '?'
    local body, err = httpViaDownload(cfg.sync.url .. sep .. q)
    if not body then return nil, err end
    local data, derr = json.decode(body)
    if not data then return nil, 'ответ не JSON: ' .. tostring(derr) end
    return data
end

local sync = {
    busy = false, last = 0, lastErr = nil, lastStat = nil,
    wantPush = false, needPull = false, totalPushed = 0, totalErrors = 0,
}

local function pendingCount()
    local n = 0
    for _, m in pairs(roster.members) do if m.dirty then n = n + 1 end end
    return n
end

local function clearDirty(rec)
    if rec.kind == 'member' then
        local m = roster.members[rec.nick]
        if m then m.dirty = false end
    end
end

-- Полный цикл: сначала отдаём свои правки, потом забираем чужие. Порядок важен:
-- отправленное первым получает свежий updatedAt и при слиянии побеждает.
local function doSync()
    if not cfg.sync.enabled or cfg.sync.url == '' then return false, 'синхронизация выключена' end
    if sync.busy then return false, 'уже идёт' end
    sync.busy = true

    local pushed, conflicts, errs = 0, 0, 0
    for _, rec in ipairs(pendingRecords()) do
        local data, err = httpCall(rec.params)
        if data and data.ok then
            clearDirty(rec)
            pushed = pushed + 1
        elseif data and data.error == 'conflict' and data.server then
            -- серверная версия новее: принимаем её и снимаем dirty
            applyRemoteRecord(data.server)
            conflicts = conflicts + 1
        else
            errs = errs + 1
            sync.lastErr = tostring(err or (data and data.error) or 'unknown')
        end
    end
    if pushed > 0 or conflicts > 0 then saveRoster() end

    local stat
    local data, err = httpCall({ action = 'pull' })
    if data and data.ok then
        stat = mergeRoster(data.roster)
        saveRoster()
        if errs == 0 then sync.lastErr = nil end
        sync.last = os.time()
    else
        errs = errs + 1
        sync.lastErr = tostring(err or (data and data.error) or 'pull failed')
    end

    sync.lastStat = stat
    sync.totalPushed = sync.totalPushed + pushed
    sync.totalErrors = sync.totalErrors + errs
    sync.busy = false
    return errs == 0, string.format('отправлено %d, конфликтов %d, ошибок %d',
                                    pushed, conflicts, errs)
end

local function startSyncWorker()
    if not lua_thread then return end
    lua_thread.create(function()
        while true do
            wait(1000)
            if cfg.sync.enabled and cfg.sync.url ~= '' and not sync.busy then
                local now = os.time()
                local due = sync.wantPush or sync.needPull
                            or (now - sync.last) >= cfg.sync.interval
                if due then
                    sync.wantPush, sync.needPull = false, false
                    local ok, info = doSync()
                    if not ok then logEvent('sync: ' .. tostring(info)) end
                end
            end
        end
    end)
end

-- Переопределяем хук из чистой логики: любая правка просит немедленный пуш.
onRosterChanged = function(nick, kind)
    if not cfg.sync.enabled then return end
    sync.wantPush = true
end

local function syncNow(manual)
    if not cfg.sync.enabled or cfg.sync.url == '' then
        if manual then say('{FFAA00}[SFN Logs] синхронизация выключена (см. [sync] в config.ini)') end
        return
    end
    if not lua_thread then
        if manual then say('{FF4444}[SFN Logs] lua_thread недоступен') end
        return
    end
    if sync.busy then
        if manual then say('{FFAA00}[SFN Logs] синхронизация уже идёт') end
        return
    end
    lua_thread.create(function()
        local ok, info = doSync()
        if manual then
            say((ok and '{66FF66}' or '{FFAA00}') .. '[SFN Logs] ' .. tostring(info))
            if sync.lastErr then say('{FFAA00}[SFN Logs] последняя ошибка: ' .. sync.lastErr) end
        end
    end)
end

-- Отладочный/тестовый доступ к внутренностям синхронизации. В игре полезен
-- тем, что состояние можно посмотреть из консоли MoonLoader; в тестах через
-- него прогоняется сквозной обмен с сервером.
SFNLogs = {
    doSync         = doSync,
    httpCall       = httpCall,
    syncNow        = syncNow,
    sync           = sync,
    pendingCount   = pendingCount,
    transportName  = transportName,
}

-- ===================================================== ImGui ОКНО ========

local win = imgui.new.bool(false)

-- Состояние попапов: OpenPopup вызываем ровно один раз, BeginPopup держим,
-- пока открыт. Отдельные флаги "нужно открыть" - иначе ImGui переоткрывает
-- попап каждый кадр и его невозможно закрыть.
local ui = {
    menuNick    = nil, openMenu    = false,
    reasonDlg   = nil, openReason  = false,
    historyNick = nil, openHistory = false,
    addOpen     = imgui.new.bool(false),
    search      = '',
}

local bufNick   = imgui.new.char[32]()
local bufBy     = imgui.new.char[32]()
local bufDay    = imgui.new.int(0)
local bufMonth  = imgui.new.int(0)
local bufYear   = imgui.new.int(0)
local bufHour   = imgui.new.int(0)
local bufMinute = imgui.new.int(0)
local bufRank   = imgui.new.int(1)
local bufSearch = imgui.new.char[32]()
local bufReason = imgui.new.char[128]()
local refShowDismissed = imgui.new.bool(false)

local function readBuf(b, n)
    local t = {}
    for i = 0, n - 1 do
        local c = b[i]
        if c == 0 then break end
        t[#t + 1] = string.char(c)
    end
    return table.concat(t)
end

local function writeBuf(b, n, s)
    s = tostring(s or '')
    for i = 0, n - 1 do b[i] = 0 end
    for i = 1, math.min(#s, n - 1) do b[i - 1] = s:byte(i) end
end

local function resetAddForm()
    local t = os.date('*t')
    bufNick[0], bufBy[0], bufReason[0] = 0, 0, 0
    bufDay[0], bufMonth[0], bufYear[0] = t.day, t.month, t.year
    bufHour[0], bufMinute[0] = t.hour, t.min
    bufRank[0] = 1
end

local function composeTime()
    local ok, t = pcall(os.time, {
        year = bufYear[0], month = bufMonth[0], day = bufDay[0],
        hour = bufHour[0], min = bufMinute[0], sec = 0,
    })
    if not ok or type(t) ~= 'number' then return nil end
    return t
end

local COL = {
    ready   = imgui.ImVec4(0.35, 0.95, 0.40, 1.0),
    soon    = imgui.ImVec4(1.00, 0.85, 0.30, 1.0),
    blocked = imgui.ImVec4(1.00, 0.45, 0.35, 1.0),
    dim     = imgui.ImVec4(0.62, 0.62, 0.66, 1.0),
    top     = imgui.ImVec4(0.78, 0.64, 1.00, 1.0),
    white   = imgui.ImVec4(1.00, 1.00, 1.00, 1.0),
}

local function rankColor(r)
    if r >= 7 then return COL.top end
    if r >= 4 then return COL.soon end
    return nil
end

local function drawSyncBar(now)
    if not cfg.sync.enabled then
        imgui.TextColored(COL.dim, 'Синхронизация выключена - данные только локальные')
        return
    end
    local pending = pendingCount()

    if sync.busy then
        imgui.TextColored(COL.soon, 'Синхронизация...')
    elseif sync.lastErr then
        imgui.TextColored(COL.blocked, 'Ошибка связи: ' .. sync.lastErr)
    elseif sync.last > 0 then
        imgui.TextColored(COL.ready, string.format('Синхронизировано %s',
            os.date('%H:%M:%S', sync.last)))
    else
        imgui.TextColored(COL.dim, 'Ещё не синхронизировано')
    end

    imgui.SameLine(16)
    imgui.TextColored(pending > 0 and COL.soon or COL.dim,
        'к отправке: ' .. pending)
    imgui.SameLine(16)
    imgui.TextColored(COL.dim, transportName())
    imgui.SameLine(16)
    if imgui.Button('Синхронизировать', imgui.ImVec2(150, 0)) then syncNow(true) end

    if sync.lastStat and imgui.IsItemHovered() then
        local st = sync.lastStat
        imgui.SetTooltip(string.format(
            'последний pull:\n  новых с сервера: %d\n  обновлено: %d\n  наши правки остались: %d\n  без изменений: %d',
            st.added or 0, st.updated or 0, st.kept or 0, st.unchanged or 0))
    end
end

local function drawStats(now)
    local total, readyN = 0, 0
    for _, m in pairs(roster.members) do
        if not m.dismissed then
            total = total + 1
            local _, ready = promotionInfo(m, now)
            if ready and (m.rank or 1) < MAX_RANK then readyN = readyN + 1 end
        end
    end
    imgui.TextColored(COL.white, 'В составе: ' .. total)
    imgui.SameLine()
    imgui.TextColored(COL.ready, 'Готовы к повышению: ' .. readyN)
    imgui.SameLine(28)
    for r = 7, 9 do
        local req, have = PROMOTE_REQ[r], countAtRank(r)
        imgui.TextColored(have >= req.cap and COL.blocked or COL.dim,
            string.format('%s: %d/%d', rankName(r), have, req.cap))
        if r < 9 then imgui.SameLine(14) end
    end
end

local function drawRowMenu(m)
    imgui.Text(m.nick)
    imgui.TextColored(COL.dim, string.format('%s [%d]', rankName(m.rank or 1), m.rank or 1))
    imgui.Separator()

    if not m.dismissed then
        if (m.rank or 1) < MAX_RANK then
            local nextAt, ready, why = promotionInfo(m)
            local label = string.format('Повысить до: %s [%d]', rankName(m.rank + 1), m.rank + 1)
            if imgui.Selectable(label) then
                changeRank(m.nick, m.rank + 1, 'повышен вручную')
                logEvent(string.format('%s повышен до %s', m.nick, rankName(m.rank + 1)))
                ui.menuNick = nil
                imgui.CloseCurrentPopup()
                return
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(ready and 'Срок вышел, ограничений нет'
                    or ('Ближайший срок: ' .. fmtDate(nextAt) .. (why and ('\n' .. why) or '')))
            end
        else
            imgui.TextColored(COL.top, 'максимальный ранг')
        end

        if (m.rank or 1) > 1 and imgui.Selectable('Понизить на ранг') then
            changeRank(m.nick, m.rank - 1, 'понижен вручную')
            ui.menuNick = nil
            imgui.CloseCurrentPopup()
            return
        end
        if imgui.Selectable('История') then
            ui.historyNick = m.nick; ui.openHistory = true
            ui.menuNick = nil; imgui.CloseCurrentPopup()
            return
        end
        imgui.Separator()
        if imgui.Selectable('Уволить') then
            ui.reasonDlg = { nick = m.nick }; ui.openReason = true
            ui.menuNick = nil; imgui.CloseCurrentPopup()
            return
        end
    else
        if imgui.Selectable('Вернуть в состав') then
            restoreMember(m.nick)
            ui.menuNick = nil; imgui.CloseCurrentPopup()
            return
        end
    end
end

local function drawTable(now)
    local list = sortedMembers(cfg.showDismissed, ui.search)
    imgui.BeginChild('##roster', imgui.ImVec2(0, 0), true)
    imgui.Columns(8, 'rostercols', false)
    imgui.SetColumnWidth(0, 168)
    imgui.SetColumnWidth(1, 148)
    imgui.SetColumnWidth(2, 92)
    imgui.SetColumnWidth(3, 168)
    imgui.SetColumnWidth(4, 92)
    imgui.SetColumnWidth(5, 96)
    imgui.SetColumnWidth(6, 170)

    local heads = { 'Ник', 'Кто принял', 'Принят', 'Ранг', 'Повышен', 'След. повыш.', 'Статус', '' }
    for i = 1, 8 do
        if heads[i] ~= '' then imgui.TextColored(COL.dim, heads[i]) end
        imgui.NextColumn()
    end
    imgui.Separator()

    for _, m in ipairs(list) do
        local nextAt, ready, why = promotionInfo(m, now)

        if m.dismissed then imgui.TextColored(COL.dim, m.nick)
        else
            local c = rankColor(m.rank or 1)
            if c then imgui.TextColored(c, m.nick) else imgui.Text(m.nick) end
        end
        if m.online then imgui.SameLine(); imgui.TextColored(COL.ready, '*') end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(string.format('уровень %s\nпринят %s\n%s',
                tostring(m.level or '?'), fmtDateTime(m.acceptedAt),
                (m.note and m.note ~= '') and ('заметка: ' .. m.note) or 'ЛКМ - меню'))
        end
        if imgui.IsItemClicked() then ui.menuNick = m.nick; ui.openMenu = true end
        imgui.NextColumn()

        imgui.Text((m.acceptedBy and m.acceptedBy ~= '') and m.acceptedBy or '-')
        imgui.NextColumn()
        imgui.Text(fmtDate(m.acceptedAt));        imgui.NextColumn()
        imgui.Text(string.format('%s [%d]', rankName(m.rank or 1), m.rank or 1)); imgui.NextColumn()
        imgui.Text(fmtDate(m.promotedAt));        imgui.NextColumn()
        imgui.Text(fmtDate(nextAt));              imgui.NextColumn()

        local status, col
        if m.dismissed then
            status, col = 'уволен ' .. fmtDate(m.dismissedAt), COL.dim
        elseif (m.rank or 1) >= MAX_RANK then
            status, col = 'максимальный ранг', COL.top
        elseif ready then
            status, col = 'МОЖНО ПОВЫШАТЬ', COL.ready
        elseif why then
            status, col = why, COL.blocked
        else
            local left = (nextAt or now) - now
            status, col = 'через ' .. fmtLeft(left), (left < 86400) and COL.soon or COL.dim
        end
        imgui.TextColored(col, status); imgui.NextColumn()

        if imgui.SmallButton('...##' .. m.nick) then ui.menuNick = m.nick; ui.openMenu = true end
        imgui.NextColumn()
        imgui.Separator()
    end

    imgui.Columns(1)
    imgui.EndChild()
end

local function drawAddDialog()
    if not ui.addOpen[0] then return end
    if not imgui.BeginPopupModal('Добавить игрока', ui.addOpen, imgui.WindowFlags.NoResize) then
        return
    end

    imgui.Text('Ник');        imgui.SameLine(120); imgui.InputText('##nick', bufNick, 32)
    imgui.Text('Кто принял'); imgui.SameLine(120); imgui.InputText('##by', bufBy, 32)

    imgui.Separator()
    imgui.Text('Дата принятия')
    imgui.InputInt('день##d', bufDay);     imgui.SameLine()
    imgui.InputInt('месяц##m', bufMonth);  imgui.SameLine()
    imgui.InputInt('год##y', bufYear)
    imgui.InputInt('час##h', bufHour);     imgui.SameLine()
    imgui.InputInt('минута##mi', bufMinute)

    imgui.Separator()
    imgui.Text('Ранг'); imgui.SameLine(120)
    if imgui.SmallButton(rankName(bufRank[0]) .. ' [' .. bufRank[0] .. '] ##rk') then
        imgui.OpenPopup('rankpick')
    end
    if imgui.BeginPopup('rankpick') then
        for r = 1, MAX_RANK do
            if imgui.Selectable(string.format('%s [%d]', rankName(r), r), bufRank[0] == r) then
                bufRank[0] = r
            end
        end
        imgui.EndPopup()
    end
    imgui.SameLine()
    imgui.TextColored(COL.dim, '(у стажёра дата повышения = дата принятия)')

    local errText
    imgui.Separator()
    if imgui.Button('Добавить', imgui.ImVec2(140, 0)) then
        local nick = trim(readBuf(bufNick, 32))
        local by   = trim(readBuf(bufBy, 32))
        local at   = composeTime()
        if nick == '' then errText = 'Ник не может быть пустым'
        elseif not at then errText = 'Некорректная дата'
        else
            local m, err = addMember(nick, by, at, bufRank[0], levelOf(nick))
            if m then logEvent('добавлен ' .. nick); ui.addOpen[0] = false
            else errText = tostring(err) end
        end
    end
    imgui.SameLine()
    if imgui.Button('Отмена', imgui.ImVec2(110, 0)) then ui.addOpen[0] = false end
    if errText then imgui.TextColored(COL.blocked, errText) end

    imgui.EndPopup()
end

local function drawReasonDialog()
    local dlg = ui.reasonDlg
    if not dlg then return end

    if not imgui.BeginPopupModal('Уволить##rsn', nil, imgui.WindowFlags.NoResize) then
        ui.reasonDlg = nil
        return
    end

    imgui.Text('Игрок: ' .. dlg.nick)
    imgui.Text('Причина'); imgui.SameLine()
    imgui.InputText('##reason', bufReason, 128)
    imgui.Spacing()

    if imgui.Button('Подтвердить', imgui.ImVec2(140, 0)) then
        local reason = trim(readBuf(bufReason, 128))
        dismissMember(dlg.nick, reason)
        logEvent('уволен ' .. dlg.nick)
        bufReason[0] = 0
        ui.reasonDlg = nil
        imgui.CloseCurrentPopup()
    end
    imgui.SameLine()
    if imgui.Button('Отмена', imgui.ImVec2(110, 0)) then
        bufReason[0] = 0; ui.reasonDlg = nil; imgui.CloseCurrentPopup()
    end

    imgui.EndPopup()
end

local function drawHistory()
    local nick = ui.historyNick
    if not nick then return end
    local m = roster.members[nick]
    if not m then ui.historyNick = nil; return end

    if not imgui.BeginPopupModal('История##hist', nil, imgui.WindowFlags.NoResize) then
        ui.historyNick = nil
        return
    end
    imgui.Text(string.format('%s   |   принят %s   |   принял: %s',
        m.nick, fmtDateTime(m.acceptedAt), (m.acceptedBy ~= '' and m.acceptedBy) or '-'))
    imgui.Separator()
    imgui.BeginChild('##histbody', imgui.ImVec2(440, 200), true)
    for _, h in ipairs(m.history or {}) do
        imgui.Text(string.format('%s   %-24s %s',
            fmtDateTime(h.at), rankName(h.rank or 1), h.note or ''))
    end
    imgui.EndChild()
    if imgui.Button('Закрыть', imgui.ImVec2(120, 0)) then
        ui.historyNick = nil; imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
end

local function drawSettingsTab()
    imgui.Text(string.format('Клавиша окна: 0x%02X', cfg.hotkey))
    imgui.SameLine(); if imgui.SmallButton('F8')  then cfg.hotkey = 0x75 end
    imgui.SameLine(); if imgui.SmallButton('F10') then cfg.hotkey = 0x77 end
    imgui.SameLine(); if imgui.SmallButton('F1')  then cfg.hotkey = 0x70 end

    imgui.Separator()
    if imgui.Checkbox('Показывать уволенных', refShowDismissed) then
        cfg.showDismissed = refShowDismissed[0]
    end

    imgui.Separator()
    imgui.Text('Перехват чата')
    imgui.TextColored(COL.dim, 'Шаблоны задаются в ' .. PATHS.config)
    imgui.TextColored(COL.dim, 'Файл читается в UTF-8; старый CP1251 конвертируется сам.')
    for _, kind in ipairs({ 'accept', 'promote', 'demote', 'dismiss' }) do
        local n = #(cfg.patterns[kind] or {})
        imgui.TextColored(n > 0 and COL.ready or COL.blocked,
            string.format('   %-9s шаблонов: %d', kind, n))
        for _, p in ipairs(cfg.patterns[kind] or {}) do
            imgui.TextColored(COL.dim, '       ' .. p.pattern)
        end
    end

    imgui.Spacing()
    if imgui.Button(cfg.captureChat and 'Дамп чата: ВКЛ' or 'Дамп чата: выкл',
                    imgui.ImVec2(200, 0)) then
        cfg.captureChat = not cfg.captureChat
        say(cfg.captureChat
            and '{66FF66}[SFN Logs] дамп чата включён -> SFNLogs\\chat_dump.txt'
            or  '{FFAA00}[SFN Logs] дамп чата выключен')
    end
    imgui.SameLine()
    imgui.TextColored(COL.dim, 'или /sfnlogcap')

    imgui.Separator()
    imgui.Text('Синхронизация (Google Sheets)')
    imgui.TextColored(COL.dim, '  url:   ' .. (cfg.sync.url ~= '' and cfg.sync.url or '(не задан)'))
    imgui.TextColored(COL.dim, '  token: ' .. (cfg.sync.token ~= '' and 'задан' or '(не задан)'))
    imgui.TextColored(COL.dim, '  интервал: ' .. cfg.sync.interval .. ' с   транспорт: ' .. transportName())
    if imgui.Button('Проверить связь', imgui.ImVec2(150, 0)) then
        if not lua_thread then say('{FF4444}[SFN Logs] lua_thread недоступен')
        else
            lua_thread.create(function()
                local data, err = httpCall({ action = 'ping', token = cfg.sync.token })
                if data and data.ok then
                    say('{66FF66}[SFN Logs] связь есть, токен принят')
                else
                    say('{FF4444}[SFN Logs] ' .. tostring(err or (data and data.error) or 'нет ответа'))
                end
            end)
        end
    end
    imgui.SameLine()
    if imgui.Button('Синхронизировать сейчас', imgui.ImVec2(190, 0)) then syncNow(true) end

    imgui.Separator()
    if imgui.Button('Перечитать config.ini', imgui.ImVec2(200, 0)) then
        loadConfig()
        refShowDismissed[0] = cfg.showDismissed
        say('{66FF66}[SFN Logs] конфигурация перечитана')
    end
    imgui.SameLine()
    if imgui.Button('Сохранить', imgui.ImVec2(110, 0)) then
        saveRoster()
        say('{66FF66}[SFN Logs] сохранено')
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
end)

imgui.OnFrame(function() return win[0] end, function(self)
    local now = os.time()
    imgui.SetNextWindowSize(imgui.ImVec2(1140, 620), imgui.Cond.FirstUseEver)
    imgui.Begin('San Fierro News - журнал состава', win)

    drawSyncBar(now)
    imgui.Separator()
    drawStats(now)
    imgui.Separator()

    if imgui.Button('Добавить', imgui.ImVec2(110, 0)) then
        resetAddForm(); ui.addOpen[0] = true; imgui.OpenPopup('Добавить игрока')
    end
    imgui.SameLine()
    if imgui.Button('Обновить уровни', imgui.ImVec2(150, 0)) then
        refreshOnline(); saveRoster()
    end
    imgui.SameLine()
    if imgui.Button('Экспорт', imgui.ImVec2(100, 0)) then
        local path, n = exportText()
        say(string.format('{66FF66}[SFN Logs] выгружено %d записей -> %s', n, path))
    end
    imgui.SameLine()
    imgui.Text('Поиск'); imgui.SameLine()
    imgui.InputText('##search', bufSearch, 32)
    ui.search = trim(readBuf(bufSearch, 32)):lower()

    imgui.SameLine(18)
    if imgui.Checkbox('уволенные', refShowDismissed) then
        cfg.showDismissed = refShowDismissed[0]
    end

    imgui.Separator()

    if imgui.BeginTabBar('sfntabs') then
        if imgui.BeginTabItem('Состав') then drawTable(now); imgui.EndTabItem() end
        if imgui.BeginTabItem('Настройки') then drawSettingsTab(); imgui.EndTabItem() end
        imgui.EndTabBar()
    end

    -- Попапы рисуем в конце кадра: OpenPopup один раз, BeginPopup пока открыт.
    if ui.openMenu and ui.menuNick then imgui.OpenPopup('rowmenu'); ui.openMenu = false end
    if imgui.BeginPopup('rowmenu') then
        local m = ui.menuNick and roster.members[ui.menuNick]
        if m then drawRowMenu(m) end
        imgui.EndPopup()
    end

    if ui.openReason and ui.reasonDlg then
        imgui.OpenPopup('Уволить##rsn')
        ui.openReason = false
    end
    drawReasonDialog()

    if ui.openHistory and ui.historyNick then
        imgui.OpenPopup('История##hist'); ui.openHistory = false
    end
    drawHistory()

    drawAddDialog()

    imgui.End()
end)

-- ============================================================ КОМАНДЫ =====

local function toggleCapture()
    cfg.captureChat = not cfg.captureChat
    say(cfg.captureChat
        and '{66FF66}[SFN Logs] дамп чата включён -> SFNLogs\\chat_dump.txt'
        or  '{FFAA00}[SFN Logs] дамп чата выключен')
end

local function registerCommands()
    sampRegisterChatCommand('sfnlog', function() win[0] = not win[0] end)
    sampRegisterChatCommand('sfnlogcap', toggleCapture)
    sampRegisterChatCommand('sfnlogsync', function() syncNow(true) end)

    sampRegisterChatCommand('sfnlogsyncstatus', function()
        if not cfg.sync.enabled then
            say('{FFAA00}[SFN Logs] синхронизация выключена')
            return
        end
        say(string.format('{66FF66}[SFN Logs] транспорт: %s | к отправке: %d | последний обмен: %s',
            transportName(), pendingCount(),
            sync.last > 0 and os.date('%H:%M:%S', sync.last) or 'не было'))
        if sync.lastErr then say('{FFAA00}[SFN Logs] ошибка: ' .. sync.lastErr) end
    end)

    sampRegisterChatCommand('sfnlogsave', function()
        saveRoster()
        say('{66FF66}[SFN Logs] сохранено')
    end)
    sampRegisterChatCommand('sfnlogadd', function(param)
        -- аргументы команд приходят из чата в CP1251
        local nick, by = cp1251ToUtf8(tostring(param or '')):match('^(%S+)%s*(%S*)')
        if not nick then
            say('{FF4444}[SFN Logs] использование: /sfnlogadd Ник [КтоПринял]')
            return
        end
        local m, err = addMember(nick, by or '', os.time(), 1, levelOf(nickOf(nick)))
        say(m and ('{66FF66}[SFN Logs] добавлен ' .. nick)
              or  ('{FF4444}[SFN Logs] ' .. tostring(err)))
    end)
end

-- ============================================================== main ======

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    ensureDir()
    if not sampev then
        logEvent('samp.events не загрузился (' .. tostring(sampevErr) ..
                 ') - автоперехват чата отключён, журнал работает в ручном режиме')
    end
    loadConfig()
    loadRoster()
    resetAddForm()
    refShowDismissed[0] = cfg.showDismissed
    registerCommands()

    -- свой ник нужен для updatedBy: по нему в общей таблице видно, кто правил
    pcall(function()
        local id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if id then localNick = cp1251ToUtf8(sampGetPlayerNickname(id) or '') end
    end)

    wait(1000)
    refreshOnline()
    startSyncWorker()

    if cfg.sync.enabled and cfg.sync.url ~= '' then
        say(string.format('{66FF66}[SFN Logs] синхронизация включена (%s), игрок: %s',
            transportName(), localNick ~= '' and localNick or '?'))
        sync.needPull = true       -- первый обмен выполнит фоновый поток
    end

    local lastOnline, lastSave = os.time(), os.time()
    say('{66FF66}[SFN Logs] загружен. /sfnlog - окно, /sfnlogsync - обмен')
    if not sampev then
        say('{FFAA00}[SFN Logs] нет samp.events - автоперехват чата выключен, вносите состав вручную')
    end

    while true do
        wait(0)

        if wasKeyPressed(cfg.hotkey)
           and not isChatInputActive() and not isPauseMenuActive() then
            win[0] = not win[0]
        end

        local now = os.time()
        if now - lastOnline >= 30 then
            lastOnline = now
            pcall(refreshOnline)
        end
        if now - lastSave >= 300 then
            lastSave = now
            pcall(saveRoster)
        end
    end
end

-- публикуется здесь, а не в шве выше: registerCommands определён позже
SFNLogs.registerCommands = registerCommands

function onScriptTerminate(scr)
    if scr ~= thisScript() then return end
    pcall(saveRoster)
end