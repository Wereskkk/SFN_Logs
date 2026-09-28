script_name('SFN Logs')
script_version('1.2.0')
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
        /sfnlogsync         обменяться с общей таблицей сейчас
        /sfnlogsyncstatus   транспорт, очередь, время последнего обмена
        /sfnlogui           диагностика интерфейса (DPI, метрики, ошибки)

    ИНТЕРФЕЙС (v1.2.0) — собственная дизайн-система «SFN On Air»:
        - размеры окна нет фиксированных: оно пересчитывается каждый кадр под
          содержимое активной вкладки и ограничивается размером экрана;
        - ширины колонок измеряются по фактическому тексту (CalcTextSize),
          а не назначаются числами, поэтому текст не наезжает на соседний;
        - все отступы масштабируются на imgui.GetDpiScale() — mimgui по
          умолчанию увеличивает шрифт и стиль под DPI, и без этого вёрстка
          разъезжалась на масштабе 125/150%;
        - вкладки: Состав, История (лента событий журнала), Настройки;
        - если в конкретной сборке mimgui чего-то из DrawList не окажется,
          окно деградирует до простого текстового вида и пишет об этом в чат
          (см. SFNLogs.lastUiError и /sfnlogui), а не роняет скрипт.
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
--
-- Дизайн — собственная система «SFN On Air»: тёмная студийная палитра,
-- сигнальный индикатор эфира, карточки показателей, строки состава своей
-- отрисовки вместо устаревшего imgui.Columns.
--
-- ТРЕБУЙ, КОТОРЫЕ ЗАКРЫТЫ КОНСТРУКТИВНО
--
-- 1. ТЕКСТ НЕ НАЕЗЖАЕТ ДРУГ НА ДРУГА.
--    Ширины колонок не назначаются, а ИЗМЕРЯЮТСЯ по фактическому тексту
--    (imgui.CalcTextSize), позиция колонки — накопительная сумма ширин.
--    Всё, что может оказаться длиннее отведённого места (заметка, URL, текст
--    ошибки), сокращается через fitText() или обрезается клипом
--    (drawTextClipped). Налезть нечему физически.
--
-- 2. DPI.
--    mimgui по умолчанию работает в dpi_scaling_mode = 3: шрифт и стиль
--    масштабируются под DPI, а захардкоженные пиксели — нет. Именно поэтому
--    старая вёрстка с SetColumnWidth(168) и SameLine(120) разъезжалась на
--    125/150%. Здесь каждый размер проходит через S() = px * GetDpiScale().
--
-- 3. РАЗМЕР ОКНА ПОД СОДЕРЖИМОЕ.
--    Окно не фиксировано: computeLayout() измеряет содержимое активной
--    вкладки и задаёт размер через SetNextWindowSize(..., Cond.Always),
--    ограничивая его размером экрана. Пустой журнал — компактное окно,
--    40 сотрудников — окно под список (дальше прокрутка), вкладка настроек —
--    окно нужной высоты.
--
-- ПРАВИЛО РАСКЛАДКИ (главное, его нарушение и давало «уехавший» интерфейс)
--
--    SetCursorScreenPos НЕ используется вообще.
--
-- В Dear ImGui любой элемент потока сбрасывает CursorPos.x к левому полю, а
-- SetCursorScreenPos к тому же переопределяет CursorPosPrevLine.x — то есть
-- X ВСЕЙ СЛЕДУЮЩЕЙ СТРОКИ. Стоит один раз спозиционировать элемент абсолютно,
-- и остальные строки уезжают вправо (ровно это и происходило: каждая строка
-- состава начиналась на ширину предыдущей).
--
-- Поэтому: раскладку ведут только виджеты ImGui (Button, InvisibleButton,
-- Dummy, InputText, SameLine), а графика рисуется в координатах, снятых
-- ДО элемента. Каждый блок возвращает свою высоту и двигает курсор ровно
-- на неё — следующий блок гарантированно начинается ниже, а не поверх.
--
-- mimgui 1.7.1 собран на Dear ImGui 1.76: таблиц (BeginTable) там ещё нет,
-- поэтому сетка своя. Все вызовы примитивов обёрнуты в pdraw(): если в
-- конкретной сборке чего-то не окажется, интерфейс деградирует до текстового
-- drawFallback(), но скрипт не упадёт и не оставит ImGui с незакрытым окном.

local win = imgui.new.bool(false)

-- Версия для подписи в подвале. Держим синхронно со script_version().
local SFN_VERSION_STR = '1.2.0'

-- ---------------------------------------------- палитра «SFN On Air» -------

local function RGB(r, g, b, a) return imgui.ImVec4(r / 255, g / 255, b / 255, (a or 255) / 255) end

local C = {
    bg         = RGB(0x11, 0x14, 0x1B),   -- фон окна
    panel      = RGB(0x17, 0x1B, 0x24),   -- шапка, карточки
    panelAlt   = RGB(0x1C, 0x21, 0x2C),   -- кнопки, заголовки таблиц
    rowAlt     = RGB(0x15, 0x19, 0x22),   -- зебра строк
    rowHover   = RGB(0x25, 0x2C, 0x3B),
    rowSel     = RGB(0x2C, 0x34, 0x45),
    line       = RGB(0x25, 0x2B, 0x38),   -- разделители, рамки
    lineSoft   = RGB(0x1E, 0x24, 0x30),
    text       = RGB(0xE9, 0xEC, 0xF3),
    textDim    = RGB(0x8C, 0x95, 0xA8),   -- подписи, второстепенное
    textFaint  = RGB(0x5C, 0x65, 0x77),
    accent     = RGB(0xFF, 0x3B, 0x30),   -- сигнальный красный эфира
    brand      = RGB(0xE8, 0xB4, 0x4C),   -- золото новостей
    ready      = RGB(0x2E, 0xE6, 0xA6),   -- можно повышать
    soon       = RGB(0xFF, 0xC5, 0x3D),   -- скоро / внимание
    blocked    = RGB(0xFF, 0x5C, 0x5C),   -- нет мест, нет уровня
    info       = RGB(0x5A, 0xA9, 0xE6),   -- справочное
    violet     = RGB(0xA9, 0x8C, 0xFF),   -- старший состав
    field      = RGB(0x0E, 0x11, 0x17),   -- поля ввода
}

local function CU(v) return imgui.GetColorU32(v) end
local function V(x, y) return imgui.ImVec2(x, y) end
local function withA(col, a) return imgui.ImVec4(col.x, col.y, col.z, a) end

-- Ранговые цвета: младшие нейтральные, дальше теплее, верх — золото и сигнал.
local RANK_COLOR = {
    [1] = C.textDim, [2] = C.textDim, [3] = C.info,
    [4] = C.info,     [5] = C.ready,   [6] = C.violet,
    [7] = C.brand,    [8] = C.brand,   [9] = C.accent,
}
local function rankColor(r) return RANK_COLOR[r or 1] or C.text end

-- ------------------------------------------------------ масштаб DPI -------

local dpiScale = 1.0
local textCache = {}
local function refreshScale()
    local s = imgui.GetDpiScale and imgui.GetDpiScale()
    if type(s) == 'number' and s >= 0.5 and s <= 8 and s ~= dpiScale then
        dpiScale = s
        textCache = {}          -- ширины текста зависят от размера шрифта
    end
end
local function S(v) return v * dpiScale end

-- WindowPadding нашей темы. SameLine(offset) в ImGui считает offset ОТ ВНЕШНЕЙ
-- границы окна, а содержимое начинается на padding дальше — поэтому для
-- точного позиционирования в строке отступ нужно брать с учётом padding.
local PAD_X = 12
local function padX() return S(PAD_X) end

-- ItemSpacing.y нашей темы (см. pushStyle). ImGui добавляет его после
-- КАЖДОГО элемента потока, поэтому он обязан участвовать в бюджете высоты:
-- иначе содержимое не влезает в окно ровно на сумму этих отступов.
local SPACING_Y = 6

-- Метрики пересчитываются в первом кадре по реальному шрифту.
local lineH  = 16      -- высота строки текста
local rowH   = 24      -- высота строки таблицы
local frameH = 24      -- высота виджета: кнопка, поле ввода

-- --------------------------------------- примитивы отрисовки (DrawList) ---

local dl_ok = true          -- примитивы доступны; иначе рисуем только текст
local function pdraw(f, ...)
    if not dl_ok or not f then return false end
    local ok = pcall(f, ...)
    if not ok then dl_ok = false end
    return ok
end

local function winDL() return imgui.GetWindowDrawList() end

-- Измерение текста с кешем: CalcTextSize вызывается сотни раз за кадр,
-- а набор строк почти не меняется.
local function textW(s)
    if s == nil or s == '' then return 0 end
    local c = textCache[s]
    if c then return c end
    local sz = imgui.CalcTextSize(s)
    local w = (sz and sz.x) or 0
    textCache[s] = w
    return w
end

local function textHeight()
    local sz = imgui.CalcTextSize('Ay')
    return (sz and sz.y) or 16
end

-- Укорачивает строку до maxW пикселей, добавляя «...» вместо хвоста.
-- Нужно там, где значение бывает сколь угодно длинным (URL, текст ошибки):
-- честное сокращение вместо наложения на соседний текст.
local function fitText(s, maxW)
    s = tostring(s or '')
    if maxW <= 0 or textW(s) <= maxW then return s end
    local dots = '...'
    local wDots = textW(dots)
    local lo, hi = 0, #s
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if textW(s:sub(1, mid)) + wDots <= maxW then lo = mid else hi = mid - 1 end
    end
    return s:sub(1, lo) .. dots
end

local function drawText(dl, x, y, s, col)
    if not s or s == '' then return 0 end
    pdraw(dl.AddText, dl, V(x, y), CU(col or C.text), s)
    return textW(s)
end

-- Текст с обрезкой клипом по границе колонки: даже если ширина где-то
-- посчитана с запасом, соседняя колонка не будет перекрыта.
local function drawTextClipped(dl, x, y, s, col, limitW)
    if not s or s == '' then return 0 end
    local w = textW(s)
    if limitW and limitW > 0 and w > limitW then
        pdraw(dl.PushClipRect, dl, V(x, y - 2), V(x + limitW, y + lineH + 2), true)
        pdraw(dl.AddText, dl, V(x, y), CU(col or C.text), s)
        pdraw(dl.PopClipRect, dl)
        return limitW
    end
    pdraw(dl.AddText, dl, V(x, y), CU(col or C.text), s)
    return w
end

local function fillRect(dl, x, y, w, h, col, rounding)
    if w <= 0 or h <= 0 then return end
    pdraw(dl.AddRectFilled, dl, V(x, y), V(x + w, y + h), CU(col), rounding or 0)
end

local function strokeRect(dl, x, y, w, h, col, rounding, thick)
    if w <= 1 or h <= 1 then return end
    pdraw(dl.AddRect, dl, V(x + 0.5, y + 0.5), V(x + w - 0.5, y + h - 0.5),
          CU(col), rounding or 0, 0, thick or S(1))
end

local function hline(dl, x, y, w, col, thick)
    if w <= 0 then return end
    pdraw(dl.AddLine, dl, V(x, y), V(x + w, y), CU(col), thick or S(1))
end

local function vline(dl, x, y, h, col, thick)
    if h <= 0 then return end
    pdraw(dl.AddLine, dl, V(x, y), V(x, y + h), CU(col), thick or S(1))
end

local function dot(dl, cx, cy, r, col)
    pdraw(dl.AddCircleFilled, dl, V(cx, cy), r, CU(col), 12)
end

local function gradH(dl, x, y, w, h, c1, c2)
    if w <= 0 or h <= 0 then return end
    pdraw(dl.AddRectFilledMultiColor, dl, V(x, y), V(x + w, y + h),
          CU(c1), CU(c2), CU(c2), CU(c1))
end

-- Позиция, в которой ImGui поставит СЛЕДУЮЩИЙ элемент. Снимаем её до
-- виджета — это единственная точка привязки для графики.
local function cursorXY()
    local p = imgui.GetCursorScreenPos()
    return p.x, p.y
end

-- Резервирование вертикального места: Dummy двигает курсор вниз, поэтому
-- следующий блок никогда не встанет поверх предыдущего.
local function advance(dy) imgui.Dummy(V(1, dy)) end

-- ==================================================== СОСТОЯНИЕ UI ========

local ui = {
    menuNick     = nil, openMenu    = false,
    reasonDlg    = nil, openReason  = false,
    historyNick  = nil, openHistory = false,
    addOpen      = imgui.new.bool(false),
    search       = '',
    tab          = 'Состав',
    menuOpenNick = nil,
    lastRows     = 0,
}

local bufNick   = imgui.new.char[32]()
local bufBy     = imgui.new.char[32]()
local bufDay    = imgui.new.int(0)
local bufMonth  = imgui.new.int(0)
local bufYear   = imgui.new.int(0)
local bufHour   = imgui.new.int(0)
local bufMinute = imgui.new.int(0)
local bufRank   = imgui.new.int(1)
local bufSearch = imgui.new.char[40]()
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

-- --------------------------------------------------- мелкие элементы ------

-- Пилюля-чип: подпись в скруглённой плашке. Возвращает ширину.
local function chip(dl, x, y, label, col, h)
    h = h or S(18)
    local w = textW(label) + S(18)
    fillRect(dl, x, y, w, h, withA(col, 0.14), h * 0.5)
    strokeRect(dl, x, y, w, h, withA(col, 0.55), h * 0.5, S(1))
    drawText(dl, x + (w - textW(label)) * 0.5, y + (h - lineH) * 0.5, label, col)
    return w
end

-- Индикатор эфира: сигнальная точка с пульсирующим ореолом.
local function liveDot(dl, x, y, on)
    local r = S(on and 4 or 3)
    if on then
        local pulse = 0.18 + 0.14 * math.sin(os.clock() * 3.2)
        dot(dl, x + r, y + r, r * 2.6, withA(C.accent, pulse))
    end
    dot(dl, x + r, y + r, r, on and C.accent or C.textFaint)
    return r * 2
end

-- Значок микрофона: капсула, держатель и ножка. Рисуем, а не берём глифом —
-- шрифт mimgui содержит кириллицу и базовую латиницу, пиктограмм в нём нет.
local function micIcon(dl, x, y, h, col)
    local bw, bh = S(7), h * 0.44
    local bx = x + (h - bw) * 0.5
    fillRect(dl, bx, y, bw, bh, col, bw * 0.5)
    local cx, cy, r = x + h * 0.5, y + bh, bw * 0.5 + S(4)
    pdraw(dl.AddCircle, dl, V(cx, cy + r * 0.1), r, CU(col), 12)
    local footY = y + h - S(1.5)
    vline(dl, cx, cy + r + S(1), footY - (cy + r + S(1)), col, S(1.4))
    hline(dl, cx - S(4), footY, S(8), col, S(1.4))
end

-- Собственный тултип: позицию и фон даёт BeginTooltip, содержимое рисуем сами.
local function tip(lines)
    if not imgui.BeginTooltip then return end
    if not imgui.BeginTooltip() then return end
    local dl = winDL()
    local wMax = 0
    for _, s in ipairs(lines) do wMax = math.max(wMax, textW(s)) end
    local tx, ty = cursorXY()
    for i, s in ipairs(lines) do
        drawText(dl, tx, ty + (i - 1) * lineH, s, i == 1 and C.text or C.textDim)
    end
    imgui.Dummy(V(wMax + S(4), #lines * lineH))
    imgui.EndTooltip()
end

-- Кнопка как элемент ПОТОКА: ImGui сам двигает курсор, поэтому соседние
-- элементы на неё не наедут. Графика рисуется в координатах, снятых ДО
-- виджета. Возвращает ширину и факт нажатия.
local function flowButton(id, label, col, onClick, w, h)
    w = w or (textW(label) + S(28))
    h = h or frameH
    local bx, by = cursorXY()
    imgui.PushStyleColor(imgui.Col.Button, withA(col, 0.14))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, withA(col, 0.27))
    imgui.PushStyleColor(imgui.Col.ButtonActive, withA(col, 0.40))
    imgui.PushStyleColor(imgui.Col.Text, col)
    local clicked = imgui.Button(label .. '##' .. id, V(w, h))
    imgui.PopStyleColor(4)
    strokeRect(winDL(), bx, by, w, h, withA(col, 0.55), S(5), S(1))
    if clicked and onClick then onClick() end
    return w, clicked
end

-- Кнопка-переключатель: активное состояние залито фирменным цветом.
local function flowToggleButton(id, label, active, onClick, w, h)
    w = w or (textW(label) + S(22))
    h = h or frameH
    local bx, by = cursorXY()
    imgui.PushStyleColor(imgui.Col.Button, active and C.brand or C.panelAlt)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, C.brand)
    imgui.PushStyleColor(imgui.Col.ButtonActive, C.brand)
    imgui.PushStyleColor(imgui.Col.Text, active and C.bg or C.textDim)
    local clicked = imgui.Button(label .. '##' .. id, V(w, h))
    imgui.PopStyleColor(4)
    if clicked and onClick then onClick() end
    return w
end

-- ЯКОРЬ СТРОКИ — основа всей раскладки.
--
-- Высота виджета ImGui (поле ввода, чекбокс, кнопка) зависит от FramePadding
-- и размера шрифта, то есть от DPI и темы. Если бюджет высоты окна считать из
-- констант, а рисовать настоящими виджетами, числа неизбежно разойдутся и
-- содержимое вылезет за край окна.
--
-- Якорь это исключает: невидимая кнопка ЗАДАННОЙ высоты становится первым
-- элементом строки, остальные элементы ставятся в неё же через SameLine.
-- Высота блока после этого известна точно (h + ItemSpacing) и совпадает с
-- бюджетом в computeLayout.
local function anchoredRow(id, h)
    local x, y = cursorXY()
    imgui.InvisibleButton('##' .. id, V(1, h))
    return x, y
end

-- Элемент в той же строке, что и якорь: gap — отступ от правого края
-- предыдущего элемента. Первый аргумент НЕ передаём: SameLine(0, ...) в ImGui
-- означает «offset_from_start_x = 0», то есть прижало бы элемент к левой
-- границе окна, а не поставило в ряд.
local function sameRow(gap) imgui.SameLine(nil, gap or 0) end

-- Элемент в той же строке на заданном расстоянии от левого края СОДЕРЖИМОГО.
local function sameRowAt(offFromContent) imgui.SameLine(offFromContent) end

-- Невидимая hit-зона во всю ширину строки: единственный элемент потока,
-- поверх которого рисуется всё оформление строки.
local function rowHit(id, w, h)
    local x, y = cursorXY()
    imgui.InvisibleButton('##' .. id, V(w, h))
    return x, y, imgui.IsItemHovered(), imgui.IsItemClicked(0), imgui.IsItemClicked(1)
end

-- ============================================== СТРОКИ И КОЛОНКИ ==========

-- Состав колонок: поле, заголовок и признак «обрезать по границе».
local COLS = {
    { key = 'nick',   head = 'НИК',          clip = true  },
    { key = 'by',     head = 'КТО ПРИНЯЛ'                  },
    { key = 'acc',    head = 'ПРИНЯТ'                      },
    { key = 'rank',   head = 'РАНГ'                        },
    { key = 'prom',   head = 'ПОВЫШЕН'                     },
    { key = 'next',   head = 'СЛЕД. ПОВЫШ.'                },
    { key = 'lvl',    head = 'УР.'                         },
    { key = 'status', head = 'СТАТУС',       clip = true   },
}
local MENU_COL_W = 26      -- последняя колонка: кнопка меню строки

-- Значения строки готовятся одним проходом: и для измерения ширины колонок,
-- и для отрисовки. Цвета лежат рядом со значениями, чтобы правила повышения
-- не пересчитывались дважды за кадр.
local function rowCells(m, now)
    local nextAt, ready, why = promotionInfo(m, now)
    local rank = m.rank or 1
    local status, scol
    if m.dismissed then
        status, scol = 'уволен ' .. fmtDate(m.dismissedAt), C.textFaint
    elseif rank >= MAX_RANK then
        status, scol = 'максимальный ранг', C.violet
    elseif ready then
        status, scol = 'МОЖНО ПОВЫШАТЬ', C.ready
    elseif why then
        status, scol = why, C.blocked
    else
        local left = (nextAt or now) - now
        status, scol = 'через ' .. fmtLeft(left), (left < 86400) and C.soon or C.textDim
    end
    return {
        nick   = m.nick or '?',
        by     = (m.acceptedBy and m.acceptedBy ~= '') and m.acceptedBy or '—',
        acc    = fmtDate(m.acceptedAt),
        rank   = string.format('%s [%d]', rankName(rank), rank),
        prom   = fmtDate(m.promotedAt),
        next   = m.dismissed and '—' or fmtDate(nextAt),
        lvl    = tostring(m.level or '—'),
        status = status,
        _m         = m,
        _nextAt    = nextAt,
        _why       = why,
        _ready     = ready and true or false,
        _online    = m.online and true or false,
        _nickCol   = m.dismissed and C.textFaint or rankColor(rank),
        _rankCol   = m.dismissed and C.textDim or rankColor(rank),
        _statusCol = scol,
    }
end

-- Ширины колонок измеряются по фактическому тексту: заголовок против самого
-- длинного значения плюс отступ. Итог — таблица без наложений на любом DPI
-- и при любых никах, причинах увольнения и текстах блокировок.
local function measureCols(rows)
    local widths = {}
    for i, c in ipairs(COLS) do
        -- заголовок учитывается всегда: даже при пустом журнале колонки
        -- остаются читаемыми, а окно не схлопывается в нечитаемую полоску
        local w = textW(c.head)
        for _, r in ipairs(rows) do
            local v = r[c.key]
            if type(v) == 'string' then
                local vw = textW(v)
                if vw > w then w = vw end
            end
        end
        if c.key == 'nick' then w = w + S(22) end       -- точка «онлайн»
        widths[i] = w + S(c.key == 'status' and 6 or 16)
    end
    widths[#widths + 1] = S(MENU_COL_W)
    return widths
end

local function rowsWidth(widths)
    local total = 0
    for _, w in ipairs(widths) do total = total + w end
    return total
end

local function buildRows(now)
    local list = sortedMembers(cfg.showDismissed, ui.search)
    local rows = {}
    for _, m in ipairs(list) do rows[#rows + 1] = rowCells(m, now) end
    return rows
end

-- ================================================== ШАПКА «ON AIR» ========

local HEADER_H = 54

local function drawHeader(w)
    local dl = winDL()
    local h = S(HEADER_H)
    local x, y = anchoredRow('header', h)
    fillRect(dl, x, y, w, h, C.panel, S(7))
    strokeRect(dl, x, y, w, h, C.line, S(7), S(1))
    gradH(dl, x, y + h - S(3), w, S(3), C.accent, C.brand)

    -- логотип: микрофон в сигнальном квадрате
    local logoS = h - S(22)
    local logoX, logoY = x + S(11), y + S(11)
    fillRect(dl, logoX, logoY, logoS, logoS, withA(C.accent, 0.16), S(6))
    strokeRect(dl, logoX, logoY, logoS, logoS, C.accent, S(6), S(1))
    local iconS = S(17)
    micIcon(dl, logoX + (logoS - iconS) * 0.5, logoY + (logoS - iconS) * 0.5, iconS, C.accent)

    -- название и назначение журнала
    local tx = logoX + logoS + S(12)
    drawText(dl, tx, y + S(9), 'SAN FIERRO NEWS', C.text)
    drawText(dl, tx, y + S(9) + lineH, 'ЖУРНАЛ СОСТАВА РЕДАКЦИИ', C.textDim)

    -- справа: индикатор эфира и кто ведёт журнал. Считаем справа налево,
    -- поэтому правые элементы никогда не наедут на заголовок.
    local who = (localNick and localNick ~= '') and localNick or 'гость'
    local whoW = textW(who) + S(20)
    local liveW = textW('В ЭФИРЕ') + S(32)
    local rx = x + w - S(11) - whoW
    drawText(dl, rx + S(10), y + (h - lineH) * 0.5, fitText(who, whoW - S(14)), C.textDim)
    rx = rx - S(8) - liveW
    fillRect(dl, rx, y + (h - S(20)) * 0.5, liveW, S(20), withA(C.accent, 0.13), S(10))
    liveDot(dl, rx + S(8), y + (h - S(8)) * 0.5, true)
    drawText(dl, rx + S(21), y + (h - lineH) * 0.5, 'В ЭФИРЕ', C.accent)

    return h
end

-- ================================================== ПОЛОСА СИНХРОНИЗАЦИИ ==

-- Полная строка статуса и её укороченный вариант для панели: длинный текст
-- ошибки не должен растягивать окно — его всегда можно прочитать в тултипе.
local function syncStatus()
    if not cfg.sync.enabled then
        return 'СИНХРОНИЗАЦИЯ ВЫКЛЮЧЕНА — ДАННЫЕ ЛОКАЛЬНЫЕ', C.textFaint
    end
    if sync.busy then return 'ИДЁТ ОБМЕН С ОБЩЕЙ ТАБЛИЦЕЙ...', C.soon end
    if sync.lastErr then return 'ОШИБКА СВЯЗИ: ' .. tostring(sync.lastErr), C.blocked end
    if sync.last > 0 then return 'ОБМЕН ' .. os.date('%H:%M:%S', sync.last), C.ready end
    return 'ОБМЕНА ЕЩЁ НЕ БЫЛО', C.textDim
end

local SYNC_LABEL_MAX_W = 380

local function drawSyncBar(w)
    local dl = winDL()
    local h = S(22)
    local labelFull, col = syncStatus()
    local label = fitText(labelFull, S(SYNC_LABEL_MAX_W))
    local bw = textW('СИНХРОНИЗИРОВАТЬ') + S(28)

    -- Якорь задаёт строку и её высоту, кнопка встаёт в неё же справа.
    local x, y = anchoredRow('syncrow', h)
    -- sameRowAt ставит элемент на нужное расстояние от левого края содержимого
    sameRowAt(padX() + math.max(S(8) + 1, w - bw))
    flowButton('syncnow', 'СИНХРОНИЗИРОВАТЬ', C.brand, function() syncNow(true) end, bw, h)
    local btnHover = imgui.IsItemHovered()

    -- графика строки: индикатор, статус, чипы
    liveDot(dl, x, y + (h - S(8)) * 0.5, cfg.sync.enabled and not sync.lastErr)
    local tx = x + S(15)
    tx = tx + drawText(dl, tx, y + (h - lineH) * 0.5, label, col) + S(16)
    local pending = pendingCount()
    tx = tx + chip(dl, tx, y + (h - S(18)) * 0.5, 'К ОТПРАВКЕ: ' .. pending,
                   pending > 0 and C.soon or C.textFaint) + S(8)
    chip(dl, tx, y + (h - S(18)) * 0.5, transportName():upper(), C.info)

    if label ~= labelFull and imgui.IsMouseHoveringRect
       and imgui.IsMouseHoveringRect(V(x + S(15), y), V(x + S(15) + textW(label), y + h)) then
        tip({ labelFull })
    end
    if btnHover and sync.lastStat then
        local st = sync.lastStat
        tip({ 'последний pull',
              'новых с сервера: ' .. (st.added or 0),
              'обновлено: ' .. (st.updated or 0),
              'наши правки остались: ' .. (st.kept or 0),
              'без изменений: ' .. (st.unchanged or 0) })
    end
    return h
end

-- ================================================== КАРТОЧКИ ПОКАЗАТЕЛЕЙ ==

local STATS_H = 50

local function collectStats(now)
    local total, readyN, onlineN = 0, 0, 0
    for _, m in pairs(roster.members) do
        if not m.dismissed then
            total = total + 1
            if m.online then onlineN = onlineN + 1 end
            local _, ready = promotionInfo(m, now)
            if ready and (m.rank or 1) < MAX_RANK then readyN = readyN + 1 end
        end
    end
    local caps = {}
    for r = 7, 9 do
        caps[#caps + 1] = { rank = r, have = countAtRank(r), cap = PROMOTE_REQ[r].cap }
    end
    return total, readyN, onlineN, caps
end

local STAT_NAMES = { 'В СОСТАВЕ', 'ГОТОВЫ К ПОВЫШЕНИЮ', 'СЕЙЧАС В ИГРЕ' }
local STAT_COLS  = { C.info, C.ready, C.brand }
local function capsText(c) return string.format('%d-й', c.rank) end

local function statsWidth(total, readyN, onlineN, caps)
    local vals = { tostring(total), tostring(readyN), tostring(onlineN) }
    local w = {}
    for i = 1, 3 do
        w[i] = math.max(textW(STAT_NAMES[i]), textW(vals[i]) + S(10)) + S(30)
    end
    local cw = textW('СТАРШИЙ СОСТАВ')
    for _, c in ipairs(caps) do
        cw = cw + textW(capsText(c)) + textW(string.format('%d/%d', c.have, c.cap)) + S(50)
    end
    w[4] = cw + S(30)
    return w, vals
end

local function drawStatCard(x, y, cw, h, col, name, value)
    local dl = winDL()
    fillRect(dl, x, y, cw, h, C.panel, S(6))
    strokeRect(dl, x, y, cw, h, C.line, S(6), S(1))
    fillRect(dl, x, y, S(3), h, col)
    drawTextClipped(dl, x + S(14), y + S(8), name, C.textDim, cw - S(20))
    drawTextClipped(dl, x + S(14), y + S(8) + lineH, value, col, cw - S(20))
end

local function drawStats(w, now)
    local total, readyN, onlineN, caps = collectStats(now)
    local widths, vals = statsWidth(total, readyN, onlineN, caps)
    local dl = winDL()
    local h = S(STATS_H)
    local gap = S(8)
    local need = widths[1] + widths[2] + widths[3] + widths[4] + gap * 3
    local k = need > w and (w - gap * 3) / (need - gap * 3) or 1
    if k < 0.6 then k = 0.6 end

    -- Якорь задаёт строку карточек, дальше карточки идут в неё же через
    -- SameLine: раскладку по X ведут невидимые кнопки, графика — поверх них.
    anchoredRow('statsrow', h)
    local xs = {}
    for i = 1, 3 do
        sameRow(i == 1 and 0 or gap)   -- SameLine нужен и первому элементу
        local cw = widths[i] * k
        local x, y = cursorXY()
        imgui.InvisibleButton('##card' .. i, V(cw, h))
        xs[i] = x
        drawStatCard(x, y, cw, h, STAT_COLS[i], STAT_NAMES[i], vals[i])
    end

    -- карточка лимитов старшего состава с полосками заполненности
    sameRow(gap)
    local cw = widths[4] * k
    local x, y = cursorXY()
    imgui.InvisibleButton('##card4', V(cw, h))
    fillRect(dl, x, y, cw, h, C.panel, S(6))
    strokeRect(dl, x, y, cw, h, C.line, S(6), S(1))
    fillRect(dl, x, y, S(3), h, C.violet)
    drawTextClipped(dl, x + S(14), y + S(8), 'СТАРШИЙ СОСТАВ', C.textDim, cw - S(20))
    local bx, by = x + S(14), y + S(8) + lineH
    for _, c in ipairs(caps) do
        local full = c.have >= c.cap
        local col = full and C.blocked or C.violet
        bx = bx + drawText(dl, bx, by, capsText(c), full and C.blocked or C.text) + S(6)
        local bw = S(26)
        fillRect(dl, bx, by + lineH * 0.5 - S(2.5), bw, S(5), C.lineSoft, S(2.5))
        local frac = (c.cap > 0 and c.have / c.cap) or 0
        if frac > 1 then frac = 1 end
        fillRect(dl, bx, by + lineH * 0.5 - S(2.5), math.max(S(2), bw * frac), S(5), col, S(2.5))
        bx = bx + bw + S(5)
        bx = bx + drawText(dl, bx, by, string.format('%d/%d', c.have, c.cap),
                           full and C.blocked or C.textDim) + S(16)
    end
    if xs and xs[1] and imgui.IsItemHovered() then
        tip({ 'лимит должностей старшего состава',
              'повышение блокируется, когда все места заняты' })
    end
    return h
end

-- ================================================== ПАНЕЛЬ ИНСТРУМЕНТОВ ===

local TOOLBAR_H = 26
local SEARCH_W  = 180

-- Панель в два ряда: кнопки, затем поиск с фильтром. Высота нужна только для
-- предварительного расчёта размера окна; фактическую drawFrame измеряет сам.
local function toolbarHeight()
    local h = S(TOOLBAR_H)
    return h + SPACING_Y + h + SPACING_Y
end

local function drawToolbar(w)
    local h = S(TOOLBAR_H)

    -- Ряд 1: кнопки действий. Якорь задаёт высоту ряда.
    anchoredRow('tbrow1', h)
    sameRow(0)
    flowButton('add', '+ ДОБАВИТЬ', C.ready, function()
        resetAddForm(); ui.addOpen[0] = true; imgui.OpenPopup('Добавить игрока')
    end, nil, h)
    sameRow(S(8))
    flowButton('lvl', 'ОБНОВИТЬ УРОВНИ', C.info, function()
        refreshOnline(); saveRoster()
    end, nil, h)
    sameRow(S(8))
    flowButton('exp', 'ЭКСПОРТ', C.brand, function()
        local path, n = exportText()
        say(string.format('{66FF66}[SFN Logs] выгружено %d записей -> %s', n, path))
    end, nil, h)

    -- Ряд 2: поиск и фильтр уволенных. Отдельный ряд — чтобы поиск
    -- гарантированно не наезжал на кнопки ни на узком окне, ни на крупном DPI.
    anchoredRow('tbrow2', h)
    sameRow(0)
    local sw = S(SEARCH_W)
    imgui.PushStyleColor(imgui.Col.FrameBg, C.field)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, withA(C.brand, 0.12))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, withA(C.brand, 0.20))
    imgui.PushStyleColor(imgui.Col.Text, C.text)
    imgui.PushItemWidth(sw)
    if imgui.InputTextWithHint then
        imgui.InputTextWithHint('##search', 'поиск по нику', bufSearch, 40)
    else
        imgui.InputText('##search', bufSearch, 40)
    end
    imgui.PopItemWidth()
    imgui.PopStyleColor(4)
    ui.search = trim(readBuf(bufSearch, 40)):lower()

    sameRow(S(14))
    if imgui.Checkbox('показывать уволенных', refShowDismissed) then
        cfg.showDismissed = refShowDismissed[0]
    end
    return toolbarHeight()
end

-- ================================================== ВКЛАДКИ ===============

local TABS = { 'Состав', 'История', 'Настройки' }
local TAB_H = 26

local function drawTabs()
    local dl = winDL()
    local h = S(TAB_H)
    anchoredRow('tabrow', h)
    for i, t in ipairs(TABS) do
        sameRow(i == 1 and 0 or S(4))
        local active = ui.tab == t
        local w = textW(t) + S(26)
        local x, y = cursorXY()
        if imgui.InvisibleButton('##tab_' .. t, V(w, h)) then ui.tab = t end
        if active then
            fillRect(dl, x, y, w, h, withA(C.brand, 0.10), S(5))
            fillRect(dl, x + S(6), y + h - S(2.5), w - S(12), S(2.5), C.brand, S(1.5))
            drawText(dl, x + S(13), y + (h - lineH) * 0.5, t, C.brand)
        else
            if imgui.IsItemHovered() then fillRect(dl, x, y, w, h, C.rowHover, S(5)) end
            drawText(dl, x + S(13), y + (h - lineH) * 0.5, t, C.textDim)
        end
    end
    return h
end

-- ================================================== ТАБЛИЦА СОСТАВА =======

local function drawRow(r, widths, w, idx)
    local dl = winDL()
    local h = rowH
    -- Единственный элемент потока на строку — невидимая кнопка во всю ширину.
    -- Она задаёт высоту строки и служит hit-зоной; оформление рисуется поверх.
    local x, y, hovered, clickedL, clickedR = rowHit('row' .. idx, w, h)
    if clickedL or clickedR then ui.menuNick = r.nick; ui.openMenu = true end

    fillRect(dl, x, y, w, h, hovered and C.rowHover or (idx % 2 == 0 and C.rowAlt or C.bg))
    if r._ready then fillRect(dl, x, y, w, h, withA(C.ready, 0.05)) end
    if ui.menuOpenNick == r.nick then fillRect(dl, x, y, w, h, withA(C.brand, 0.10)) end
    fillRect(dl, x, y, S(2.5), h, hovered and C.brand or rankColor(r._m.rank or 1))

    local cx, ty = x, y + (h - lineH) * 0.5
    for i, c in ipairs(COLS) do
        local v = tostring(r[c.key] or '')
        local col = r['_' .. c.key .. 'Col'] or C.text
        local inner = widths[i] - S(c.key == 'nick' and 24 or 12)
        if c.key == 'nick' then
            drawTextClipped(dl, cx + S(9), ty, v, col, inner)
            if r._online then dot(dl, cx + widths[i] - S(13), y + h * 0.5, S(2.6), C.ready) end
        else
            drawTextClipped(dl, cx + S(6), ty, v, col, inner)
        end
        cx = cx + widths[i]
    end

    -- Кнопка меню строки рисуется графикой: настоящий виджет здесь сдвинул бы
    -- курсор потока и следующая строка ушла бы вправо. Hit-зона уже есть —
    -- это невидимая кнопка всей строки, поэтому отдельная не нужна.
    local mbW, mbH = S(20), S(15)
    local mbX, mbY = x + w - mbW - S(4), y + (h - mbH) * 0.5
    fillRect(dl, mbX, mbY, mbW, mbH, hovered and C.brand or C.panelAlt, S(4))
    local dotsY = mbY + mbH * 0.5
    for k = 0, 2 do
        dot(dl, mbX + mbW * 0.5 + (k - 1) * S(4), dotsY, S(1.2),
            hovered and C.bg or C.textDim)
    end

    if hovered then
        local m = r._m
        tip({ m.nick,
              string.format('уровень %s    принят %s', tostring(m.level or '?'), fmtDateTime(m.acceptedAt)),
              (m.note and m.note ~= '') and ('заметка: ' .. m.note) or 'клик — меню игрока' })
    end
    return h
end

local function drawRoster(w, h, now, rows, widths)
    local dl = winDL()
    local contentW = math.max(rowsWidth(widths), w)
    local headH = S(20)

    imgui.BeginChild('##roster', V(w, h), false)
    local hx, hy = cursorXY()
    fillRect(dl, hx, hy, contentW, headH, C.panelAlt)
    local cx = hx
    for i, c in ipairs(COLS) do
        drawText(dl, cx + S(9), hy + (headH - lineH) * 0.5, c.head, C.textFaint)
        cx = cx + widths[i]
    end
    hline(dl, hx, hy + headH, contentW, C.line, S(1))
    advance(headH)

    if #rows == 0 then
        local ex, ey = cursorXY()
        local msg = (ui.search ~= '') and 'ничего не найдено по запросу'
                                    or  'в журнале пока нет записей'
        local hint = (ui.search ~= '') and 'очистите поле поиска'
                     or 'нажмите «+ ДОБАВИТЬ» или включите перехват чата в настройках'
        local ox = ex + math.max(S(8), (w - math.max(textW(msg), textW(hint))) * 0.5)
        imgui.Dummy(V(w, S(60)))
        drawText(dl, ox, ey + S(14), msg, C.textDim)
        drawText(dl, ox, ey + S(14) + lineH + S(2), hint, C.textFaint)
    else
        for i, r in ipairs(rows) do
            drawRow(r, widths, contentW, i)
        end
    end
    imgui.EndChild()
end

-- ================================================== ИСТОРИЯ СОБЫТИЙ =======

local HISTORY_LIMIT = 300
local HIST_ROW_H = 21

local function collectEvents(limit)
    local ev = {}
    for nick, m in pairs(roster.members) do
        for _, hh in ipairs(m.history or {}) do
            ev[#ev + 1] = { nick = nick, at = hh.at or 0, rank = hh.rank or 1, note = hh.note or '' }
        end
    end
    table.sort(ev, function(a, b) return a.at > b.at end)
    local total = #ev
    if limit and total > limit then
        local cut = {}
        for i = 1, limit do cut[i] = ev[i] end
        return cut, total
    end
    return ev, total
end

-- Ширина колонки ранга: максимум по всем названиям, а не «на глаз».
local function histRankColW()
    local w = 0
    for r = 1, MAX_RANK do
        local rw = textW(rankName(r))
        if rw > w then w = rw end
    end
    return w + S(20)
end

local HIST_NICK_W = 150
local HIST_NOTE_W = 240

local function histLayout()
    local wTime = textW('00.00.0000 00:00') + S(18)
    return wTime, S(HIST_NICK_W), histRankColW(), S(HIST_NOTE_W)
end

local function drawHistoryTab(w, h)
    local dl = winDL()
    local ev, total = collectEvents(HISTORY_LIMIT)
    local wTime, wNick, wRank, wNote = histLayout()

    imgui.BeginChild('##histlist', V(w, h), false)
    local hx, hy = cursorXY()
    drawText(dl, hx, hy, string.format('СОБЫТИЯ ЖУРНАЛА — %d', total), C.textDim)
    advance(lineH + S(8))

    if #ev == 0 then
        local ex, ey = cursorXY()
        drawText(dl, ex, ey, 'событий пока нет', C.textFaint)
        advance(lineH + S(8))
    end
    for i, e in ipairs(ev) do
        local rh = S(HIST_ROW_H)
        -- строка истории неинтерактивна: место резервируем Dummy
        local ex, ey = cursorXY()
        imgui.Dummy(V(w, rh))
        fillRect(dl, ex, ey, S(2), rh, rankColor(e.rank))
        local ty = ey + (rh - lineH) * 0.5
        drawTextClipped(dl, ex + S(9), ty, fmtDateTime(e.at), C.textFaint, wTime - S(12))
        drawTextClipped(dl, ex + wTime, ty, e.nick, C.text, wNick - S(14))
        drawTextClipped(dl, ex + wTime + wNick, ty, rankName(e.rank), rankColor(e.rank), wRank - S(14))
        drawTextClipped(dl, ex + wTime + wNick + wRank, ty, e.note, C.textDim, wNote - S(14))
    end
    imgui.EndChild()
end

-- ================================================== НАСТРОЙКИ =============
--
-- Вкладка описывается данными (settingsModel), а не рисуется «в лоб»: одна и
-- та же модель используется и для измерения размера окна, и для отрисовки,
-- поэтому содержимое вкладки не может оказаться больше самого окна.

local SETTINGS_MIN_W = 430
local BTN_H = 26

local function syncButtons()
    return {
        { label = 'ПРОВЕРИТЬ СВЯЗЬ', col = C.info, act = function()
            if not lua_thread then say('{FF4444}[SFN Logs] lua_thread недоступен') return end
            lua_thread.create(function()
                local data, err = httpCall({ action = 'ping' })
                if data and data.ok then
                    say('{66FF66}[SFN Logs] связь есть, токен принят')
                else
                    say('{FF4444}[SFN Logs] ' .. tostring(err or (data and data.error) or 'нет ответа'))
                end
            end)
        end },
        { label = 'СИНХРОНИЗИРОВАТЬ СЕЙЧАС', col = C.brand, act = function() syncNow(true) end },
        { label = 'ПЕРЕЧИТАТЬ config.ini', col = C.textDim, act = function()
            loadConfig()
            refShowDismissed[0] = cfg.showDismissed
            say('{66FF66}[SFN Logs] конфигурация перечитана')
        end },
        { label = 'СОХРАНИТЬ', col = C.ready, act = function()
            saveRoster()
            say('{66FF66}[SFN Logs] сохранено')
        end },
    }
end

local function settingsModel()
    local model = {}
    local function add(t, a, b, c) model[#model + 1] = { t = t, a = a, b = b, c = c } end

    add('section', 'окно')
    add('hotkey')
    add('checkbox', 'Показывать уволенных в общей таблице', refShowDismissed,
        function() cfg.showDismissed = refShowDismissed[0] end)

    add('section', 'перехват чата')
    for _, kind in ipairs({ 'accept', 'promote', 'demote', 'dismiss' }) do
        local n = #(cfg.patterns[kind] or {})
        add('kv', kind, n > 0 and ('шаблонов: ' .. n) or 'не задан',
            n > 0 and C.ready or C.blocked)
        for _, p in ipairs(cfg.patterns[kind] or {}) do
            add('hint', '   ' .. p.pattern)
        end
    end
    add('button', cfg.captureChat and 'ДАМП ЧАТА: ВКЛ' or 'ДАМП ЧАТА: ВЫКЛ', C.accent,
        function()
            cfg.captureChat = not cfg.captureChat
            say(cfg.captureChat
                and '{66FF66}[SFN Logs] дамп чата включён -> SFNLogs\\chat_dump.txt'
                or  '{FFAA00}[SFN Logs] дамп чата выключен')
        end)
    add('hint', 'или /sfnlogcap   файл: ' .. PATHS.chatdump)

    add('section', 'синхронизация (google sheets)')
    add('kv', 'url', cfg.sync.url ~= '' and cfg.sync.url or '(не задан)',
        cfg.sync.url ~= '' and C.text or C.blocked)
    add('kv', 'token', cfg.sync.token ~= '' and 'задан' or '(не задан)',
        cfg.sync.token ~= '' and C.ready or C.blocked)
    add('kv', 'интервал', cfg.sync.interval .. ' с', C.text)
    add('kv', 'транспорт', transportName(), C.info)
    local stLabel, stCol = syncStatus()
    add('kv', 'состояние', stLabel, stCol)
    add('buttons')
    return model
end

-- Ширина группы кнопок и число рядов при переносе.
local function buttonsRowWidth()
    local total = 0
    for _, b in ipairs(syncButtons()) do total = total + textW(b.label) + S(28) + S(8) end
    return total
end

local function measureSettings(model)
    local w = S(SETTINGS_MIN_W)
    local nKv, nHint, nSection, nCheck, nBtnRow, nHotkey = 0, 0, 0, 0, 0, 0
    for _, r in ipairs(model) do
        if r.t == 'kv' then
            nKv = nKv + 1
            w = math.max(w, textW(r.a) + textW(r.b) + S(46))
        elseif r.t == 'hint' then
            nHint = nHint + 1
            w = math.max(w, textW(r.a) + S(24))
        elseif r.t == 'section' then
            nSection = nSection + 1
            w = math.max(w, textW(r.a:upper()) + S(40))
        elseif r.t == 'checkbox' then
            nCheck = nCheck + 1
            w = math.max(w, textW(r.a) + S(60))
        elseif r.t == 'button' then
            nBtnRow = nBtnRow + 1
            w = math.max(w, textW(r.a) + S(40))
        elseif r.t == 'hotkey' then
            nHotkey = nHotkey + 1
            w = math.max(w, textW('Клавиша открытия окна') + S(60)
                            + (textW('F10') + S(22)) * 3)
        end
    end
    local btnTotal = buttonsRowWidth()
    w = math.max(w, btnTotal + S(12))
    local btnRows = (btnTotal > w - S(24)) and 2 or 1

    -- Каждая строка вкладки — элемент потока, поэтому к её высоте добавляется
    -- ItemSpacing.y. Без этого содержимое вкладки выше окна на сумму отступов.
    local h = nSection * (lineH + S(10) + SPACING_Y)
            + nKv      * (lineH + S(10) + SPACING_Y)
            + nHint    * (lineH + S(3)  + SPACING_Y)
            + nCheck   * (lineH + S(16) + SPACING_Y)
            + nHotkey  * (lineH + S(16) + SPACING_Y)
            + nBtnRow  * (S(BTN_H) + S(8) + SPACING_Y)
            + btnRows  * (S(BTN_H) + S(6) + SPACING_Y)
            + S(10)
    return w, h
end

-- Заголовок раздела: золотая засечка, текст и линия вправо до края.
local function drawSectionTitle(w, s)
    local dl = winDL()
    local x, y = cursorXY()
    local up = s:upper()
    fillRect(dl, x, y + S(3), S(3), lineH - S(6), C.brand)
    local tw = drawText(dl, x + S(10), y, up, C.text)
    hline(dl, x + S(10) + tw + S(10), y + lineH * 0.5,
          w - (S(20) + tw + S(10)), C.lineSoft, S(1))
    return lineH + S(10)
end

-- Строка «параметр — значение». Подписи отводится не больше половины строки,
-- значение сокращается под остаток: наложение исключено при любой длине.
local function drawKvRow(w, id, k, v, col)
    local dl = winDL()
    local h = lineH + S(10)
    local x, y, hovered = rowHit('kv' .. id, w, h)
    if hovered then fillRect(dl, x, y, w, h, C.rowHover, S(4)) end
    local keyMax = math.max(S(60), (w - S(24)) * 0.5)
    local valMax = w - S(24) - keyMax
    local vFit = fitText(v, valMax)
    local vw = textW(vFit)
    drawTextClipped(dl, x + S(6), y + S(5), fitText(k, keyMax), C.textDim, keyMax)
    drawTextClipped(dl, x + w - vw - S(6), y + S(5), vFit, col or C.text, vw + S(6))
    hline(dl, x + S(6), y + h, w - S(12), C.lineSoft, S(1))
    if hovered and textW(v) > valMax then tip({ v }) end
    return h
end

local function drawSettingsTab(w, h)
    local dl = winDL()
    local model = settingsModel()
    local contentW = math.min(w, measureSettings(model))

    imgui.BeginChild('##settings', V(w, h), false)
    local idx = 0
    for _, r in ipairs(model) do
        if r.t == 'section' then
            advance(drawSectionTitle(contentW, r.a))
        elseif r.t == 'kv' then
            idx = idx + 1
            advance(drawKvRow(contentW, idx, r.a, r.b, r.c))
        elseif r.t == 'hint' then
            local x, y = cursorXY()
            imgui.Dummy(V(contentW, lineH + S(3)))
            drawTextClipped(dl, x + S(8), y, fitText(r.a, contentW - S(16)), C.textFaint,
                            contentW - S(16))
        elseif r.t == 'checkbox' then
            local x, y = cursorXY()
            imgui.Checkbox('##cb', r.b)
            local cbW = lineH + S(10)
            imgui.Dummy(V(0, 0))
            drawTextClipped(dl, x + cbW, y + S(4), fitText(r.a, contentW - cbW - S(12)),
                            C.textDim, contentW - cbW - S(12))
            advance(lineH + S(10))
        elseif r.t == 'hotkey' then
            local x, y = cursorXY()
            drawText(dl, x + S(2), y + S(5), 'Клавиша открытия окна', C.textDim)
            local labels, codes = { 'F8', 'F10', 'F1' }, { 0x75, 0x77, 0x70 }
            local off = textW('Клавиша открытия окна') + S(24)
            for i = 1, 3 do
                imgui.SameLine(off)
                off = off + flowToggleButton('hk' .. i, labels[i], cfg.hotkey == codes[i],
                                             function() cfg.hotkey = codes[i] end,
                                             textW(labels[i]) + S(22), lineH + S(6)) + S(5)
            end
            advance(lineH + S(10))
        elseif r.t == 'button' then
            flowButton('sbtn', r.a, r.b, r.c, nil, S(BTN_H))
            advance(S(BTN_H) + S(2))
        elseif r.t == 'buttons' then
            local btns = syncButtons()
            local cx = cursorXY()
            local rowW, used = contentW, 0
            for j, b in ipairs(btns) do
                local bw = textW(b.label) + S(28)
                if used > 0 and used + bw > rowW then
                    advance(S(BTN_H) + S(6))
                    cx = cursorXY(); used = 0
                elseif used > 0 then
                    imgui.SameLine(0, S(8))
                end
                flowButton('sb' .. j, b.label, b.col, b.act, bw, S(BTN_H))
                used = used + bw + S(8)
            end
            advance(S(BTN_H) + S(2))
        end
    end
    imgui.EndChild()
end

-- ================================================ МЕНЮ СТРОКИ ==============

-- Пункт меню: невидимая кнопка задаёт раскладку, текст и подсветка рисуются
-- поверх в её же прямоугольнике.
local function menuItem(w, id, label, col, onClick)
    local dl = winDL()
    local h = lineH + S(8)
    local x, y, hovered, clicked = rowHit('mi' .. id, w, h)
    if hovered then
        fillRect(dl, x, y, w, h, withA(col, 0.16), S(4))
        fillRect(dl, x, y, S(2), h, col)
    end
    drawTextClipped(dl, x + S(10), y + S(4), fitText(label, w - S(20)), col, w - S(20))
    if clicked then onClick() end
    return h, hovered
end

-- Ширина меню строки: по самому широкому элементу (заголовок или пункт).
local function rowMenuWidth(m)
    local w = textW(m.nick) + S(28)
    if not m.dismissed and (m.rank or 1) < MAX_RANK then
        w = math.max(w, textW(string.format('Повысить до: %s [%d]',
                                            rankName(m.rank + 1), m.rank + 1)) + S(30))
    end
    w = math.max(w, textW('История изменений') + S(30))
    return math.max(w, S(230))
end

local function drawRowMenu(m)
    local dl = winDL()
    local x, y = cursorXY()
    local w = imgui.GetContentRegionAvail().x
    -- Заголовок в две строки: ник, под ним ранг. В одну строку их ставить
    -- нельзя — ширина попапа в ImGui определяется по содержимому, то есть
    -- становится известна только после отрисовки, и правый край «плавает».
    local headH = lineH * 2 + S(14)
    imgui.Dummy(V(w, headH))
    fillRect(dl, x, y, w, headH, C.panelAlt, S(5))
    fillRect(dl, x, y, S(3), headH, rankColor(m.rank or 1))
    drawTextClipped(dl, x + S(12), y + S(7), m.nick, C.text, w - S(24))
    local rl = string.format('%s [%d]', rankName(m.rank or 1), m.rank or 1)
    drawTextClipped(dl, x + S(12), y + S(7) + lineH + S(2), rl,
                    rankColor(m.rank or 1), w - S(24))
    advance(headH + S(6))

    if not m.dismissed then
        if (m.rank or 1) < MAX_RANK then
            local nextAt, ready, why = promotionInfo(m)
            local label = string.format('Повысить до: %s [%d]', rankName(m.rank + 1), m.rank + 1)
            local mh, hov = menuItem(w, 'up', label, C.ready, function()
                changeRank(m.nick, m.rank + 1, 'повышен вручную')
                logEvent(string.format('%s повышен до %s', m.nick, rankName(m.rank + 1)))
                ui.menuNick = nil
                imgui.CloseCurrentPopup()
            end)
            advance(mh)
            if hov then
                tip({ ready and 'срок вышел, ограничений нет' or 'ещё не срок или есть ограничения',
                      'ближайший срок: ' .. fmtDate(nextAt),
                      why or 'можно повышать' })
            end
        else
            local mx, my = cursorXY()
            imgui.Dummy(V(w, lineH + S(6)))
            drawText(dl, mx + S(10), my, 'максимальный ранг', C.violet)
            advance(lineH + S(6))
        end
        if (m.rank or 1) > 1 then
            advance(menuItem(w, 'down', 'Понизить на ранг', C.soon, function()
                changeRank(m.nick, m.rank - 1, 'понижен вручную')
                ui.menuNick = nil
                imgui.CloseCurrentPopup()
            end))
        end
        advance(menuItem(w, 'hist', 'История изменений', C.info, function()
            ui.historyNick = m.nick; ui.openHistory = true
            ui.menuNick = nil; imgui.CloseCurrentPopup()
        end))
        advance(S(4))
        advance(menuItem(w, 'dis', 'Уволить', C.blocked, function()
            ui.reasonDlg = { nick = m.nick }; ui.openReason = true
            ui.menuNick = nil; imgui.CloseCurrentPopup()
        end))
    else
        advance(menuItem(w, 'res', 'Вернуть в состав', C.ready, function()
            restoreMember(m.nick)
            ui.menuNick = nil; imgui.CloseCurrentPopup()
        end))
    end
end

-- ================================================ МОДАЛЬНЫЕ ОКНА ===========

local function modalSize(w, h)
    imgui.SetNextWindowSize(V(S(w), S(h)), imgui.Cond.Always)
end

local function modalHeader(title, subtitle)
    local dl = winDL()
    local x, y = cursorXY()
    local w = imgui.GetContentRegionAvail().x
    imgui.Dummy(V(w, S(32)))
    fillRect(dl, x, y, w, S(32), C.panel, S(6))
    fillRect(dl, x, y, S(3), S(32), C.accent)
    local tw = drawText(dl, x + S(14), y + S(8), title:upper(), C.text)
    if subtitle then
        drawTextClipped(dl, x + S(14) + tw + S(14), y + S(9), subtitle, C.textDim,
                        w - (S(28) + tw + S(14)))
    end
    advance(S(42))
end

local function pushFieldColors(accent)
    imgui.PushStyleColor(imgui.Col.FrameBg, C.field)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, withA(accent, 0.13))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, withA(accent, 0.22))
    imgui.PushStyleColor(imgui.Col.Text, C.text)
end

-- Подпись слева, поле справа. Ширина подписи ИЗМЕРЯЕТСЯ, а ширина поля
-- считается от неё, поэтому поле не может наехать на текст — в отличие от
-- прежнего SameLine(120), который ломался на любой подписи длиннее 120 px.
local function fieldRow(label, labelW, availW, widget)
    local dl = winDL()
    local x, y = cursorXY()
    -- подпись — графика в координатах строки; SameLine ниже сбросит курсор
    -- в начало строки, поэтому рисовать подпись ПОСЛЕ него нельзя
    drawText(dl, x, y + S(5), label, C.textDim)
    imgui.SameLine(labelW)
    imgui.PushItemWidth(math.max(S(60), availW - labelW))
    widget()
    imgui.PopItemWidth()
    -- строка должна быть не ниже самого виджета, иначе следующая подпись
    -- встанет поверх предыдущего поля
    return math.max(frameH, lineH + S(10)) + S(4)
end

local ADD_W, ADD_H = 452, 486

local function drawAddDialog()
    if not ui.addOpen[0] then return end
    modalSize(ADD_W, ADD_H)
    if not imgui.BeginPopupModal('Добавить игрока', ui.addOpen,
                                 imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
        return
    end
    modalHeader('новый сотрудник', 'приём в редакцию')

    local dl = winDL()
    local avail = imgui.GetContentRegionAvail().x
    local labelW = math.max(textW('Кто принял'), textW('Дата принятия')) + S(16)

    pushFieldColors(C.brand)
    advance(fieldRow('Ник', labelW, avail, function() imgui.InputText('##nick', bufNick, 32) end))
    advance(fieldRow('Кто принял', labelW, avail, function() imgui.InputText('##by', bufBy, 32) end))
    advance(S(6))

    advance(drawSectionTitle(avail, 'дата принятия'))
    -- Подписи полей — графика, сами поля — виджеты в потоке. Строку открывает
    -- якорь заданной высоты: без него SameLine возьмёт Y предыдущей строки
    -- (заголовка раздела) и поля лягут прямо на него.
    local function fieldLine(id, parts)
        local ax, ay = anchoredRow(id, frameH)
        local off = 0
        for i, p in ipairs(parts) do
            if i > 1 then off = off + S(10) end
            drawText(dl, ax + off, ay + S(5), p[1], C.textFaint)
            off = off + textW(p[1]) + S(6)
            sameRowAt(off + S(12))
            imgui.PushItemWidth(p[3])
            imgui.InputInt('##' .. p[1], p[2], 0)
            imgui.PopItemWidth()
            off = off + p[3]
        end
        advance(frameH + S(6))
    end
    fieldLine('date', { { 'день', bufDay, S(52) }, { 'месяц', bufMonth, S(58) },
                        { 'год', bufYear, S(66) } })
    fieldLine('time', { { 'час', bufHour, S(46) }, { 'минута', bufMinute, S(52) } })

    advance(drawSectionTitle(avail, 'ранг'))
    do
        local label = string.format('%s [%d]', rankName(bufRank[0]), bufRank[0])
        local bw = textW(label) + S(44)
        local bx, by = cursorXY()          -- координаты снимаем ДО виджета
        flowButton('rk', label .. ' ', C.violet, function() imgui.OpenPopup('rankpick') end, bw, S(26))
        imgui.SameLine(0, S(12))           -- подсказка в том же ряду
        drawTextClipped(dl, bx + bw + S(12), by + S(6), 'у стажёра дата повышения = дата принятия',
                        C.textFaint, avail - bw - S(24))
        if imgui.BeginPopup('rankpick') then
            for r = 1, MAX_RANK do
                if imgui.Selectable(string.format('%s [%d]', rankName(r), r), bufRank[0] == r) then
                    bufRank[0] = r
                end
            end
            imgui.EndPopup()
        end
        advance(S(30))
    end
    imgui.PopStyleColor(4)

    local errText
    do
        local w1 = textW('ДОБАВИТЬ') + S(40)
        local _, clicked = flowButton('ok', 'ДОБАВИТЬ', C.ready, nil, w1, S(26))
        imgui.SameLine(0, S(8))
        flowButton('cancel', 'ОТМЕНА', C.textDim, function() ui.addOpen[0] = false end,
                   textW('ОТМЕНА') + S(40), S(26))
        if clicked then
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
        advance(S(30))
    end
    if errText then
        local ex, ey = cursorXY()
        imgui.Dummy(V(avail, lineH))
        drawText(dl, ex, ey, errText, C.blocked)
        advance(lineH + S(4))
    end
    imgui.EndPopup()
end

local REASON_W, REASON_H = 430, 196

local function drawReasonDialog()
    local dlg = ui.reasonDlg
    if not dlg then return end
    modalSize(REASON_W, REASON_H)
    if not imgui.BeginPopupModal('Уволить##rsn', nil,
                                 imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
        ui.reasonDlg = nil
        return
    end
    modalHeader('увольнение', dlg.nick)

    local avail = imgui.GetContentRegionAvail().x
    local labelW = textW('Причина') + S(16)
    pushFieldColors(C.accent)
    advance(fieldRow('Причина', labelW, avail, function()
        imgui.InputText('##reason', bufReason, 128)
    end))
    imgui.PopStyleColor(4)
    advance(S(8))

    flowButton('disok', 'ПОДТВЕРДИТЬ', C.accent, function()
        dismissMember(dlg.nick, trim(readBuf(bufReason, 128)))
        logEvent('уволен ' .. dlg.nick)
        bufReason[0] = 0
        ui.reasonDlg = nil
        imgui.CloseCurrentPopup()
    end, textW('ПОДТВЕРДИТЬ') + S(36), S(26))
    imgui.SameLine(0, S(8))
    flowButton('discancel', 'ОТМЕНА', C.textDim, function()
        bufReason[0] = 0; ui.reasonDlg = nil; imgui.CloseCurrentPopup()
    end, textW('ОТМЕНА') + S(36), S(26))
    imgui.EndPopup()
end

local HISTDLG_W, HISTDLG_H = 560, 400

-- История конкретного игрока: открывается из меню строки.
local function drawHistoryDialog()
    local nick = ui.historyNick
    if not nick then return end
    local m = roster.members[nick]
    if not m then ui.historyNick = nil; return end
    modalSize(HISTDLG_W, HISTDLG_H)
    if not imgui.BeginPopupModal('История##hist', nil,
                                 imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
        ui.historyNick = nil
        return
    end
    modalHeader('история: ' .. m.nick, 'принят ' .. fmtDateTime(m.acceptedAt))

    local dl = winDL()
    local avail = imgui.GetContentRegionAvail().x
    local x, y = cursorXY()
    imgui.Dummy(V(avail, lineH))
    drawTextClipped(dl, x, y,
        string.format('принял: %s    уровень: %s    ранг: %s',
                      (m.acceptedBy ~= '' and m.acceptedBy) or '—',
                      tostring(m.level or '?'), rankName(m.rank or 1)),
        C.textDim, avail)
    advance(lineH + S(10))

    imgui.BeginChild('##histbody', V(avail, S(180)), false)
    local wTime, wRank = textW('00.00.0000 00:00') + S(18), histRankColW()
    local i = 0
    for _, hh in ipairs(m.history or {}) do
        i = i + 1
        local rh = S(HIST_ROW_H)
        local ex, ey = cursorXY()
        imgui.Dummy(V(avail, rh))
        if i % 2 == 0 then fillRect(dl, ex, ey, avail, rh, C.rowAlt) end
        fillRect(dl, ex, ey, S(2), rh, rankColor(hh.rank or 1))
        local ty = ey + (rh - lineH) * 0.5
        drawTextClipped(dl, ex + S(9), ty, fmtDateTime(hh.at), C.textFaint, wTime - S(12))
        drawTextClipped(dl, ex + wTime, ty, rankName(hh.rank or 1), rankColor(hh.rank or 1), wRank - S(14))
        drawTextClipped(dl, ex + wTime + wRank, ty, hh.note or '', C.textDim,
                        avail - (wTime + wRank) - S(12))
    end
    if i == 0 then
        local ex, ey = cursorXY()
        imgui.Dummy(V(avail, lineH))
        drawText(dl, ex, ey, 'записей нет', C.textFaint)
        advance(lineH + S(4))
    end
    imgui.EndChild()
    advance(S(10))

    flowButton('histclose', 'ЗАКРЫТЬ', C.textDim, function()
        ui.historyNick = nil; imgui.CloseCurrentPopup()
    end, textW('ЗАКРЫТЬ') + S(40), S(26))
    imgui.EndPopup()
end

-- ================================================ ПОДВАЛ ===================

local FOOTER_PAD = 12

-- Подвал: Dummy резервирует РОВНО столько, сколько занимает графика
-- (lineH + FOOTER_PAD), поэтому блок не выпирает за отведённое место —
-- иначе последняя строка таблицы оказывалась под подписью версии.
local function footerHeight() return lineH + S(FOOTER_PAD) end

local function drawFooter(w, h)
    local dl = winDL()
    local x, y = cursorXY()
    h = h or footerHeight()
    imgui.Dummy(V(w, h))
    hline(dl, x, y + S(2), w, C.lineSoft, S(1))
    local fy = y + S(6)
    drawText(dl, x, fy, 'SFN LOGS ' .. SFN_VERSION_STR, C.textFaint)
    local hint = 'клик по строке — меню    F8 — окно'
    drawText(dl, x + w - textW(hint), fy, hint, C.textFaint)
    return h
end

-- ================================================ СТИЛЬ И КАРКАС ===========

-- Палитра и геометрия применяются скоупом на кадр (Push/Pop), а не правкой
-- глобального стиля: другие скрипты на том же контексте ImGui не страдают.
local STYLE_COLORS = {
    { 'Text',                C.text      }, { 'TextDisabled',       C.textDim   },
    { 'WindowBg',            C.bg        }, { 'ChildBg',            C.bg        },
    { 'PopupBg',             C.panel     }, { 'Border',             C.line      },
    { 'FrameBg',             C.field     }, { 'FrameBgHovered',     C.panelAlt  },
    { 'FrameBgActive',       C.rowSel    }, { 'TitleBg',            C.panel     },
    { 'TitleBgActive',       C.panelAlt  }, { 'TitleBgCollapsed',   C.panel     },
    { 'Button',              C.panelAlt  }, { 'ButtonHovered',      C.rowHover  },
    { 'ButtonActive',        C.rowSel    }, { 'Header',             C.panelAlt  },
    { 'HeaderHovered',       C.rowHover  }, { 'HeaderActive',       C.rowSel    },
    { 'Separator',           C.line      }, { 'SeparatorHovered',   C.brand     },
    { 'CheckMark',           C.brand     }, { 'SliderGrab',         C.brand     },
    { 'SliderGrabActive',    C.brand     }, { 'ScrollbarBg',        C.bg        },
    { 'ScrollbarGrab',       C.line      }, { 'ScrollbarGrabHovered', C.textFaint },
    { 'ScrollbarGrabActive', C.textDim   }, { 'Tab',                C.panelAlt  },
    { 'TabHovered',          C.brand     }, { 'TabActive',          C.brand     },
}

local pushedColors, pushedVars = 0, 0

local function pushStyle()
    pushedColors, pushedVars = 0, 0
    for _, pair in ipairs(STYLE_COLORS) do
        local idx = imgui.Col and imgui.Col[pair[1]]
        if idx and imgui.PushStyleColor then
            imgui.PushStyleColor(idx, pair[2])
            pushedColors = pushedColors + 1
        end
    end
    local function var(name, a, b)
        local idx = imgui.StyleVar and imgui.StyleVar[name]
        if not idx then return end
        local ok = (b ~= nil) and pcall(imgui.PushStyleVar, idx, a, b)
                            or  pcall(imgui.PushStyleVar, idx, a)
        if ok then pushedVars = pushedVars + 1 end
    end
    var('WindowPadding', S(12), S(12))
    var('FramePadding', S(8), S(4))
    var('ItemSpacing', S(8), SPACING_Y)
    var('ItemInnerSpacing', S(6), S(4))
    var('WindowRounding', S(9))
    var('FrameRounding', S(5))
    var('GrabRounding', S(4))
    var('ChildRounding', S(6))
    var('PopupRounding', S(7))
    var('ScrollbarSize', S(10))
    var('WindowBorderSize', S(1))
end

local function popStyle()
    if pushedColors > 0 then pcall(imgui.PopStyleColor, pushedColors); pushedColors = 0 end
    if pushedVars > 0 then pcall(imgui.PopStyleVar, pushedVars); pushedVars = 0 end
end

-- ================================================== РАСЧЁТ РАЗМЕРА ОКНА ===
--
-- Окно не имеет фиксированного размера: каждый кадр измеряем содержимое
-- АКТИВНОЙ вкладки — колонки таблицы, текст настроек, число событий истории —
-- и задаём размер ровно под него в пределах экрана.

local MAX_VISIBLE_ROWS = 14

-- Оценка высоты «хрома» (всё, кроме тела вкладки) нужна только для первого
-- кадра. Дальше работает chromeMeasured — фактическое измерение предыдущего
-- кадра: константы могут разъехаться с реальными размерами виджетов (они
-- зависят от FramePadding и размера шрифта), а измерение — не может.
local function chromeEstimate()
    return S(HEADER_H) + S(10)          -- шапка
         + S(22) + S(10)                -- полоса синхронизации
         + S(STATS_H) + S(10)           -- карточки показателей
         + toolbarHeight() + S(10)      -- панель инструментов в два ряда
         + S(TAB_H) + S(8)              -- вкладки
         + SPACING_Y * 5                -- ItemSpacing после блоков
end

local chromeMeasured = 0

local function chromeHeight()
    return chromeMeasured > 0 and chromeMeasured or chromeEstimate()
end

-- Накладные расходы окна: полоса заголовка и WindowPadding. На первом кадре
-- значение неизвестно, поэтому берётся оценка для нашей темы (заголовок
-- lineH + 2*FramePadding.y сверху и WindowPadding снизу), а со второго кадра —
-- фактическое измерение. Без этой величины окно оказывалось на 42 px ниже
-- содержимого, и подвал уходил за нижний край.
local windowOverhead = 0

-- Накладные расходы окна = полоса заголовка + WindowPadding сверху и снизу.
-- Величина чисто геометрическая: расстояние от верха окна до начала области
-- содержимого плюс нижний отступ. От наполнения окна она не зависит, поэтому
-- измеряется один раз и дальше используется в расчёте размера.
local function measureWindowChrome(frameTop, availY)
    if windowOverhead > 0 then return windowOverhead end
    local est = lineH + S(20)
    if imgui.GetWindowPos then
        local wp = imgui.GetWindowPos()
        if wp and frameTop > wp.y then
            windowOverhead = (frameTop - wp.y) + S(12)
            return windowOverhead
        end
    end
    return est
end

-- Накладные расходы окна (полоса заголовка + WindowPadding) заранее неизвестны:
-- они зависят от темы, DPI и версии mimgui. Поэтому первый кадр строится по
-- оценке, а со второго используется фактическое измерение.
local heightCorrection = 0

-- Высота тела активной вкладки: ровно то, что будет нарисовано. Одна функция
-- и для расчёта размера окна, и для проверки — поэтому они не могут разойтись.
local function bodyHeight(rows, evCount, setH, histH)
    if ui.tab == 'Состав' then
        local head = S(20) + SPACING_Y                 -- строка заголовков таблицы
        local visible = math.min(#rows, MAX_VISIBLE_ROWS)
        if visible == 0 then
            return head + S(60) + SPACING_Y            -- пустое состояние с подсказкой
        end
        return head + visible * (rowH + SPACING_Y)
    elseif ui.tab == 'История' then
        return histH
    end
    -- Небольшой запас: строки вкладки состоят из настоящих виджетов, чья
    -- высота зависит от FramePadding и размера шрифта. Если содержимое чуть
    -- выше оценки, оно прокручивается внутри вкладки, а не вылезает из окна.
    return setH + S(24)
end

local function computeLayout(now)
    local rows = buildRows(now)
    local widths = measureCols(rows)

    local setW, setH = measureSettings(settingsModel())
    local ev = collectEvents(HISTORY_LIMIT)
    local wTime, wNick, wRank, wNote = histLayout()
    local histW = wTime + wNick + wRank + wNote
    local histRows = math.min(#ev, 18)
    local histH = (lineH + S(8) + SPACING_Y)                 -- заголовок вкладки
                + (histRows > 0 and histRows * (S(HIST_ROW_H) + SPACING_Y)
                                  or (lineH + S(8) + SPACING_Y))
                + S(6)

    local label = syncStatus()
    local syncW = math.min(textW(label), S(SYNC_LABEL_MAX_W)) + S(31)
              + textW('К ОТПРАВКЕ: 000') + S(26)
              + textW(transportName():upper()) + S(18)
              + textW('СИНХРОНИЗИРОВАТЬ') + S(40)

    local toolbarW = textW('+ ДОБАВИТЬ') + textW('ОБНОВИТЬ УРОВНИ') + textW('ЭКСПОРТ')
                   + S(28 * 3 + 8 * 2)
    local searchW = S(SEARCH_W) + textW('показывать уволенных') + S(26 + 12 + 20)
    toolbarW = math.max(toolbarW, searchW)

    -- База одинакова для всех вкладок, ширина тела — только у активной:
    -- окно подстраивается под то, что реально показано на экране.
    local baseW = math.max(syncW, toolbarW, searchW, S(460))
    local tabW = (ui.tab == 'Состав') and rowsWidth(widths)
              or (ui.tab == 'История') and histW
              or setW
    local contentW = math.max(baseW, tabW)

    local bodyH = bodyHeight(rows, #ev, setH, histH)
    -- Окно = хром + тело + подвал. Хром берётся из измерения предыдущего кадра,
    -- поэтому высота окна всегда соответствует фактическим размерам виджетов
    -- (они зависят от FramePadding и размера шрифта, то есть от DPI и темы).
    local winH = chromeHeight() + bodyH + footerHeight() + SPACING_Y
               + math.max(measureWindowChrome(0, 0), 0)
    local winW = contentW + S(24)

    local disp = imgui.GetIO().DisplaySize
    local maxW = ((disp and disp.x) or 1920) - S(60)
    local maxH = ((disp and disp.y) or 1080) - S(80)
    if winW > maxW then winW = maxW end
    if winH > maxH then winH = maxH end
    if winW < S(440) then winW = S(440) end
    if winH < S(300) then winH = S(300) end

    -- Если окно упёрлось в потолок экрана, тело вкладки урезается под остаток:
    -- дальше оно прокручивается внутри себя, а не вылезает за край окна.
    local room = winH - chromeHeight() - footerHeight() - SPACING_Y
               - math.max(measureWindowChrome(0, 0), 0)
    if room < S(60) then room = S(60) end
    if bodyH > room then bodyH = room end

    ui.lastRows = #rows
    return winW, winH, rows, widths, bodyH
end

-- ================================================== КАРКАС КАДРА =========

local function drawPopups()
    if ui.openMenu and ui.menuNick then
        ui.menuOpenNick = ui.menuNick
        imgui.OpenPopup('rowmenu')
        ui.openMenu = false
    end
    if imgui.BeginPopup('rowmenu') then
        local m = ui.menuNick and roster.members[ui.menuNick]
        if m then
            -- попап в ImGui автосized: ширину задаём по содержимому, иначе
            -- длинное название ранга не поместится и встретится с ником
            imgui.SetNextWindowSize(V(rowMenuWidth(m), 0), imgui.Cond.Always)
            drawRowMenu(m)
        else
            ui.menuOpenNick = nil
        end
        imgui.EndPopup()
    else
        ui.menuOpenNick = nil
    end

    if ui.openReason and ui.reasonDlg then
        imgui.OpenPopup('Уволить##rsn')
        ui.openReason = false
    end
    drawReasonDialog()

    if ui.openHistory and ui.historyNick then
        imgui.OpenPopup('История##hist')
        ui.openHistory = false
    end
    drawHistoryDialog()

    drawAddDialog()
end

local function drawFrame(now)
    -- computeLayout вызывается РОВНО один раз за кадр: он заодно снимает
    -- накопленную поправку высоты. При повторном вызове в том же кадре
    -- поправка обнулилась бы, не дойдя до окна, и размер не сходился бы.
    local winW, winH, rows, widths, desiredBodyH = computeLayout(now)
    imgui.SetNextWindowSize(V(winW, winH), imgui.Cond.Always)

    if not imgui.Begin('SFN Logs — журнал состава', win,
                       imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
                       + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse) then
        imgui.End()
        return
    end

    local w = imgui.GetContentRegionAvail().x
    local frameTop = select(2, cursorXY())

    -- Высота каждого блока измеряется по реальному сдвигу курсора, а не
    -- предсказывается формулой: виджеты ImGui добавляют ItemSpacing сами, и
    -- любая арифметика рано или поздно разойдётся с фактом на несколько
    -- пикселей — именно так в старой вёрстке появлялись наложения.
    local function block(name, fn, gap)
        local ya = select(2, cursorXY())
        local h = fn() or 0
        local yb = select(2, cursorXY())
        advance(math.max(h, yb - ya) + gap)
    end

    block('header',  function() return drawHeader(w) end,     S(10))
    block('sync',    function() return drawSyncBar(w) end,    S(10))
    block('stats',   function() return drawStats(w, now) end, S(10))
    block('toolbar', function() return drawToolbar(w) end,    S(10))
    block('tabs',    function() return drawTabs() end,        S(8))

    local avail = imgui.GetContentRegionAvail()
    local footerH = footerHeight()

    -- Фактическая высота хрома: следующий кадр построит окно точно по
    -- содержимому. Расхождение возможно максимум на один кадр.
    chromeMeasured = select(2, cursorXY()) - frameTop

    -- Уточняем накладные расходы окна по фактической геометрии.
    measureWindowChrome(frameTop, avail.y)

    -- Телу отдаём ровно ту высоту, которая заложена в размер окна. Если окно
    -- упёрлось в потолок экрана, тело ограничивается остатком места и
    -- прокручивается внутри себя — содержимое при этом не вылезает наружу.
    local bodyH = desiredBodyH or (avail.y - footerH - SPACING_Y)
    local room = avail.y - footerH - SPACING_Y
    if bodyH > room then bodyH = room end
    if bodyH < S(60) then bodyH = S(60) end


    if ui.tab == 'Состав' then
        drawRoster(avail.x, bodyH, now, rows, widths)
    elseif ui.tab == 'История' then
        drawHistoryTab(avail.x, bodyH)
    else
        drawSettingsTab(avail.x, bodyH)
    end

    drawFooter(w, footerH)

    -- Прямое измерение: если содержимое всё же вышло за область окна,
    -- следующий кадр добавит ровно столько, сколько не хватило. Обратная связь
    -- по факту, а не по формуле, поэтому размер сходится за пару кадров
    -- независимо от темы, DPI и версии mimgui.
    local contentBottom = select(2, cursorXY())
    local overflow = contentBottom - (frameTop + avail.y)
    if overflow > 0 then heightCorrection = overflow end

    drawPopups()
    imgui.End()
end

-- Аварийная раскладка: если в конкретной сборке mimgui чего-то из DrawList не
-- окажется (dl_ok = false), окно остаётся полностью рабочим на обычном тексте.
local function drawFallback(now)
    imgui.SetNextWindowSize(V(S(760), S(420)), imgui.Cond.FirstUseEver)
    if not imgui.Begin('SFN Logs — журнал состава', win) then imgui.End(); return end

    imgui.TextColored(C.brand, 'SAN FIERRO NEWS — журнал состава редакции')
    local label, col = syncStatus()
    imgui.TextColored(col, label)
    imgui.SameLine()
    if imgui.Button('Синхронизировать') then syncNow(true) end
    imgui.Separator()

    local total, readyN, onlineN = collectStats(now)
    imgui.TextColored(C.text, string.format('В составе: %d    Готовы к повышению: %d    В игре: %d',
                                            total, readyN, onlineN))
    imgui.Separator()
    if imgui.Button('+ Добавить') then
        resetAddForm(); ui.addOpen[0] = true; imgui.OpenPopup('Добавить игрока')
    end
    imgui.SameLine()
    if imgui.Button('Обновить уровни') then refreshOnline(); saveRoster() end
    imgui.SameLine()
    if imgui.Button('Экспорт') then
        local path, n = exportText()
        say(string.format('{66FF66}[SFN Logs] выгружено %d записей -> %s', n, path))
    end
    imgui.Separator()
    imgui.PushItemWidth(S(220))
    imgui.InputText('##search2', bufSearch, 40)
    imgui.PopItemWidth()
    ui.search = trim(readBuf(bufSearch, 40)):lower()
    imgui.SameLine()
    if imgui.Checkbox('уволенные', refShowDismissed) then cfg.showDismissed = refShowDismissed[0] end
    imgui.Separator()

    local rows = buildRows(now)
    imgui.BeginChild('##rosterfb', V(0, 0), false)
    for _, r in ipairs(rows) do
        -- в аварийном режиме важнее компактность, чем выравнивание колонок
        imgui.TextColored(r._statusCol, string.format('%s | %s | %s | %s',
            fitText(r.nick, S(140)), fitText(r.rank, S(150)),
            r.acc, fitText(r.status, S(180))))
        if imgui.IsItemClicked() then ui.menuNick = r.nick; ui.openMenu = true end
    end
    if #rows == 0 then imgui.TextColored(C.textFaint, 'в журнале пока нет записей') end
    imgui.EndChild()

    drawPopups()
    imgui.End()
end

local uiBroken = false

-- Отладочный доступ к состоянию окна: полезно в тестах и когда нужно открыть
-- конкретную вкладку или диалог из консоли MoonLoader.
SFNLogs.ui = ui
function SFNLogs.setTab(name)
    for _, t in ipairs(TABS) do if t == name then ui.tab = name; return true end end
    return false
end
function SFNLogs.setVisible(v) win[0] = v and true or false end
function SFNLogs.isVisible() return win[0] end
function SFNLogs.openAddDialog()
    resetAddForm(); ui.addOpen[0] = true; imgui.OpenPopup('Добавить игрока')
end
function SFNLogs.openReasonDialog(nick)
    ui.reasonDlg = { nick = nick }; ui.openReason = true; imgui.OpenPopup('Уволить##rsn')
end
function SFNLogs.openHistoryDialog(nick)
    ui.historyNick = nick; ui.openHistory = true; imgui.OpenPopup('История##hist')
end
function SFNLogs.openRowMenu(nick)
    ui.menuNick = nick; ui.openMenu = true
end
function SFNLogs.layoutInfo()
    return { tab = ui.tab, rows = ui.lastRows, search = ui.search, dpi = dpiScale,
             drawListOk = dl_ok, lineH = lineH, rowH = rowH }
end
-- Что нужно прислать при проблеме с вёрсткой: масштаб DPI, метрики шрифта,
-- состояние DrawList, размер окна и текст последней ошибки отрисовки.
function SFNLogs.uiReport()
    local t = SFNLogs.layoutInfo()
    local lines = {
        string.format('dpi=%.2f  lineH=%.1f  rowH=%.1f  frameH=%.1f',
                      t.dpi or 0, t.lineH or 0, t.rowH or 0, t.frameH or 0),
        string.format('drawlist=%s  строк=%s  вкладка=%s',
                      tostring(t.drawListOk), tostring(t.rows), tostring(t.tab)),
    }
    if SFNLogs.lastUiError then lines[#lines + 1] = 'ошибка: ' .. SFNLogs.lastUiError end
    return lines
end

function SFNLogs.uiSelfTest()
    local now = os.time()
    local winW, winH, rows, widths = computeLayout(now)
    local setW, setH = measureSettings(settingsModel())
    return { winW = winW, winH = winH, rows = #rows, cols = rowsWidth(widths),
             settingsW = setW, settingsH = setH, dpi = dpiScale, drawListOk = dl_ok,
             lineH = lineH, rowH = rowH, frameH = frameH, chrome = chromeHeight() }
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
end)

imgui.OnFrame(function() return win[0] end, function(self)
    refreshScale()
    lineH  = textHeight()
    rowH   = math.floor(lineH + S(8))
    frameH = math.floor(lineH + S(9))

    pushStyle()
    if uiBroken or not dl_ok then
        local ok = pcall(drawFallback, os.time())
        if not ok then uiBroken = true end
    else
        -- pcall вокруг кадра: ошибка отрисовки не должна ронять скрипт и
        -- оставлять ImGui с незакрытым окном.
        local ok, err = pcall(drawFrame, os.time())
        if not ok then
            dl_ok = false
            SFNLogs.lastUiError = tostring(err)
            logEvent('интерфейс переключён в упрощённый режим: ' .. tostring(err))
            pcall(drawFallback, os.time())
        end
    end
    popStyle()
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

    sampRegisterChatCommand('sfnlogui', function()
        say('{66FF66}[SFN Logs] диагностика интерфейса:')
        for _, line in ipairs(SFNLogs.uiReport()) do
            say('{AAAAAA}[SFN Logs]   ' .. line)
        end
        say('{AAAAAA}[SFN Logs] mimgui ' .. tostring(imgui._VERSION or '?') ..
            ', транспорт: ' .. transportName())
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