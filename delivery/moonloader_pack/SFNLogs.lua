script_name('SFN Logs')
script_version('2.2.1')
script_author('San Fierro News')

-- Версия одна на весь файл и объявлена в самом верху.
--
-- Раньше она жила литералом в двух местах: script_version в шапке и локальная
-- переменная с тем же именем в ImGui-части, на ~2700 строк ниже. Раздел
-- автообновления вставлен ВЫШЕ того local - Lua резолвит имена лексически,
-- поэтому SFN_VERSION_STR читался там как глобальный nil, и любая проверка
-- обновления отвечала «версия не новее текущей nil». Теперь литерал ровно
-- один, и он обязан совпадать со script_version() (проверяется тестом).
SFN_VERSION_STR = '2.2.1'

--[[
    Журнал состава San Fierro News.

    По каждому игроку хранит: ник, кто принял, дату принятия, текущий ранг и
    дату последнего повышения. Считает дату следующего повышения по правилам
    редакции, следит за лимитами должностей старшего состава и минимальными
    уровнями.

    ДАННЫЕ: единственный внешний источник - Evolve Logs API
    (api.evolvelogs.ru), настроен только на San Fierro News: фракция 9,
    сервер saint-louis. Синхронизации через Google Sheets больше нет.

    Файлы (создаются в moonloader\SFNLogs\):
        config.ini      хоткей, настройки [api], [members] и [update]
        roster.json     журнал состава + кеш ответов API
        update.json     состояние автообновления (последняя проверка, версия)
        export.txt      результат экспорта (/sfnlogexport)
        api_N.json       временные файлы ответов (транспорт downloadUrlToFile)

    КОДИРОВКА: внутри скрипт везде работает в UTF-8 (файлы, окно, синхронизация).
    Границу с игрой он конвертирует сам: чат и ники SA-MP приходят в CP1251 и
    переводятся в UTF-8 на входе, а сообщения в чат и print - обратно в CP1251.
    Старые config.ini / roster.json в CP1251 распознаются и читаются сами.

    Команды:
        /sfnlog             открыть/закрыть окно
        /sfnlogsave         принудительно сохранить
        /sfnlogexport       выгрузить журнал в export.txt
        /sfnlogadd Ник [КтоПринял]   добавить стажёра с текущей датой
        /sfnlogmembers      отправить /members и перехватить онлайн-состав
        /sfnlogupdate       автообновление: check / install / url / статус
        /sfnlogapi          статус Evolve Logs API (для диагностики)
        /sfnlogui           диагностика интерфейса (DPI, метрики, ошибки)

    ОТКУДА БЕРЁТСЯ СОСТАВ (v2.1.0): перехвата чата по шаблонам больше нет -
    список сотрудников собирается из вывода серверной команды /members и из
    вкладки «Поиск» (кнопка «+ В состав»), плюс ручное /sfnlogadd. Ранг и даты
    событий добираются из Evolve Logs API. Команда /sfnlogcap и файл
    chat_dump.txt удалены вместе с секцией [patterns] в config.ini.

    СОСТАВ ИЗ /members: серверная команда /members печатает онлайн-состав
    фракции (ID, последний вход, ник, ранг, «На работе/Выходной», AFK).
    Формат строки разбирается свободно: после ника может идти «[248] (Voice)»,
    « (Voice)» или ничего - Evolve RP ID после ника не печатает.
    Скрипт перехватывает эти строки, добавляет сотрудников в журнал и ставит
    каждый ник в очередь Evolve Logs API. Ответ API проверяется: данные
    получены / «записей нет» (404 NOT_FOUND) — вопрос закрыт, сетевой сбой —
    повтор с растущей паузой (по умолчанию до 3 попыток), затем откат.

    ЛОГОТИП (v2.2.1): в сайдбаре — фирменный знак редакции (круг с брызгами и
    буквой E), восстановленный вектором по исходнику assets/logo_source.jpg;
    прежний знак (круг с микрофоном редакции) удалён.

    АВТООБНОВЛЕНИЕ (v2.2.0): скрипт сам берёт свежую версию из ветки main
    репозитория GitHub (raw-адрес, без ключей и без лимита API) и подменяет свой
    файл. Скачанное обязательно проверяется: компилируется ли текст, тот ли это
    скрипт (script_name, main(), разбор /members, метки PURE), новее ли версия и
    не обрезан ли файл; старая версия сохраняется рядом как SFNLogs.lua.bak.
    Проверка идёт в фоновом lua_thread, кадр игры не блокируется. Настройка -
    секция [update] в config.ini и раздел «Обновления» в окне, команда
    /sfnlogupdate. После установки нужен /reload или перезапуск игры.

    ИНТЕРФЕЙС (v2.1.0) — собственная дизайн-система «SFN On Air»:
        - размеры окна нет фиксированных: оно пересчитывается каждый кадр под
          содержимое активной вкладки и ограничивается размером экрана;
        - ширины колонок измеряются по фактическому тексту (CalcTextSize),
          а не назначаются числами, поэтому текст не наезжает на соседний;
        - все отступы масштабируются на imgui.GetDpiScale() — mimgui по
          умолчанию увеличивает шрифт и стиль под DPI, и без этого вёрстка
          разъезжалась на масштабе 125/150%;
        - вкладки: Журнал, Поиск, Настройки, О скрипте;
        - полосы разделов рисуются без значка «‹»: он выглядел как кнопка
          «назад», которой на самом деле не существует (v2.1.0);
        - в настройках нет технической диагностики API (транспорт, повторы,
          кеш) - только то, что нужно в игре: клавиша окна, состав из
          /members, состояние соединения и кнопки обновления/сохранения;
        - если в конкретной сборке mimgui чего-то из DrawList не окажется,
          окно деградирует до простого текстового вида и пишет об этом в чат
          (см. SFNLogs.lastUiError и /sfnlogui), а не роняет скрипт.
]]

local imgui    = require 'mimgui'
-- FontAwesome 6 для иконок дизайна Evolve Logs. Необязательная зависимость:
-- без неё иконки заменяются текстовыми метками, окно работает.
local fa, faErr = nil, nil
do
    local ok, mod = pcall(require, 'fAwesome6_solid')
    if ok then fa = mod else faErr = tostring(mod) end
end
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
    export    = DIR .. '\\export.txt',
    hotkey    = DIR .. '\\hotkey.json',
    update    = DIR .. '\\update.json',
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
-- Потолок редакции SFN - Программный директор (9). Генерального директора у нас
-- нет: Evolve Logs API по нашей фракции выше 9-го ранга не выдаёт, а если вдруг
-- пришлёт - число упрётся в потолок при применении ответа.
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
-- Для 9-го ранга (Программный директор) срока нет: это потолок редакции,
-- nextAt у него не считается, статус строки - «максимальный ранг».

-- Требования к ЦЕЛЕВОМУ рангу: минимальный уровень и потолок должностей.
-- Для 9-го ранга (потолок) требований нет: повышать уже некуда.
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

-- Первая буква заглавная, остальные не трогаем. Нужен для заголовков разделов
-- в окне: string.upper()/string.lower() в Lua знают только ASCII, поэтому
-- «данные из evolve logs» превращалось в «данные из EVOLVE LOGS» - латиница
-- заглавная, кириллица нет. Кириллическая заглавная собирается вручную из
-- кодовой точки (U+0410-U+042F, U+0401); остальные символы отдаются как есть.
function titleCase(s)
    if type(s) ~= 'string' or s == '' then return s end
    local b = s:byte(1)
    if b < 0x80 then return (s:sub(1, 1):upper()) .. s:sub(2) end
    local cp, len = utf8Seq(s, 1)
    if not cp then return s end
    if cp >= 0x0430 and cp <= 0x044F then cp = cp - 0x20        -- а-я -> А-Я
    elseif cp == 0x0451 then cp = 0x0401                        -- ё -> Ё
    else return s end                                           -- уже заглавная/не буква
    local nb = 0xD0
    if cp > 0x43F then nb = 0xD1; cp = cp - 0x40 end
    return string.char(nb, 0x80 + (cp % 0x40)) .. s:sub(len + 1)
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

-- ---------------------------------------------- ДАННЫЕ EVOLVE LOGS API -----
-- API возвращает ранги строками вида «Репортер [4]», «Гл.Редактор», а также
-- служебные «Invite» (приём) и «Uninvite» (увольнение). Названия сокращены и
-- пишутся без «ё», поэтому число берём из квадратных скобок, а без скобок —
-- по таблице алиасов.
API_RANK_ALIASES = {
    ['стажер'] = 1, ['стажёр'] = 1,
    ['звукооператор'] = 2,
    ['звукорежиссер'] = 3, ['звукорежиссёр'] = 3,
    ['репортер'] = 4, ['репортёр'] = 4,
    ['ведущий'] = 5,
    ['редактор'] = 6,
    ['гл.редактор'] = 7, ['главный редактор'] = 7,
    ['тех.директор'] = 8, ['технический директор'] = 8,
    ['программный директор'] = 9,
    -- генерального директора в SFN нет: такое имя схлопывается в потолок редакции
    ['ген.директор'] = 9, ['генеральный директор'] = 9,
}

-- Lower для кириллицы в UTF-8: string.lower() в Lua байтовый и трогает только
-- ASCII, а CP1251-трюк даёт строку в другой кодировке. Заглавные А..Я лежат в
-- D0 90..D0 AF, строчные — там же +0x20; Ё (D0 81) разбираем отдельно.
-- Заглавные А..Я в UTF-8 — это D0 90..D0 AF плюс Ё (D0 81). Байтовым сдвигом
-- их не взять (Р..Я уезжают в другой лид-байт), поэтому кодовая точка
-- пересчитывается честно: cp + 32 и обратная кодировка.
local UTF8_UPPER = string.char(0xD0) .. '(['
                 .. string.char(0x81) .. '-' .. string.char(0xAF) .. '])'
local function utf8Lower(s)
    return (s:gsub(UTF8_UPPER, function(second)
        local b = second:byte()
        local cp = 0x400 + (b - 0x80)              -- D0 xx -> U+04xx
        if cp == 0x401 then cp = 0x451             -- Ё -> ё
        elseif cp >= 0x410 and cp <= 0x42F then cp = cp + 0x20
        else return string.char(0xD0, b) end       -- не буква: не трогаем
        if cp < 0x480 then
            return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        end
        return string.char(0xD1, 0x80 + (cp - 0x4C0))
    end))
end

-- Возвращает вид ('invite' / 'uninvite' / 'number' / nil) и ранг.
function parseApiRank(str)
    if type(str) ~= 'string' then return nil end
    local s = trim(str)
    if s == '' then return nil end
    local low = utf8Lower(s):lower()
    if low == 'invite' then return 'invite' end
    if low == 'uninvite' then return 'uninvite' end
    local n = s:match('%[(%d+)%]')
    if n then return 'number', math.floor(tonumber(n)) end
    n = tonumber(s)
    if n then return 'number', math.floor(n) end
    local alias = API_RANK_ALIASES[low]
    if alias then return 'number', alias end
    return nil
end

-- Даты API приходят в двух видах: «10.06.26 14:32» и «29.11.2025 23:22».
-- Приводим к unix-time; без времени — к полуночи дня.
function parseApiDate(str)
    if type(str) ~= 'string' then return nil end
    local d, mo, y, h, mi = str:match('^(%d%d?)%.(%d%d?)%.(%d%d%d%d)%s+(%d%d?):(%d%d)')
    if not d then
        d, mo, y, h, mi = str:match('^(%d%d?)%.(%d%d?)%.(%d%d)%s+(%d%d?):(%d%d)')
        if d then y = tonumber(y) + (tonumber(y) < 70 and 2000 or 1900) end
    end
    if not d then
        d, mo, y = str:match('^(%d%d?)%.(%d%d?)%.(%d%d%d%d)')
        if not d then
            d, mo, y = str:match('^(%d%d?)%.(%d%d?)%.(%d%d)$')
            if d then y = tonumber(y) + (tonumber(y) < 70 and 2000 or 1900) end
        end
        h, mi = 0, 0
    end
    if not (d and mo and y) then return nil end
    local ok, t = pcall(os.time, { year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                                  hour = tonumber(h or 0), min = tonumber(mi or 0), sec = 0 })
    return ok and t or nil
end

-- ---------------------------------------------- РАЗБОР ВЫВОДА /members ----
--
-- Серверная команда /members печатает онлайн-состав фракции построчно.
-- Живой дамп Evolve RP (saint-louis, SF News, chat_dump.txt от 28.09.2026):
--   Члены организации Он-лайн:
--   ID: 248 | 19:23 06.09.2026 | Jonny_Wilde (Voice): Программный директор[9] - {008000}На работе{FFFFFF}
--   ID: 38 | 21:47 22.09.2026 | Aru_Traxer (Voice): Гл.Редактор[7] - {008000}На работе{FFFFFF}
--   ID: 68 | 23:32 03.09.2026 | Gabriela_Bradberry : Ведущий[5] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 360+ секунд
--   Всего: 11 человек
-- На других сборках после ника встречается ещё и ID в квадратных скобках
-- («Jonny_Wilde[248] (Voice):»), поэтому хвост между ником и двоеточием
-- разбирается свободно - см. MEMBERS_LINE_PATTERN.
--
-- Это единственный способ получить состав «списком»: Evolve Logs API
-- отвечает только по конкретному нику (player=...). Поэтому вывод ловится
-- построчно, ранг и ник берутся из строки, а каждый ник затем уходит в
-- очередь API за официальной историей (кто принял, когда повысили).

-- Цветовые теги SA-MP {RRGGBB} / {RRGGBBAA} мешают паттернам: срезаем их.
function stripColors(s)
    return (tostring(s or ''):gsub('{%x%x%x%x%x%x%x?%x?}', ''))
end

-- «19:23» + «06.09.2026» -> unix-time (в /members время идёт раньше даты).
function parseMembersTime(tm, dt)
    local h, mi = tostring(tm or ''):match('^(%d%d?):(%d%d)$')
    local d, mo, y = tostring(dt or ''):match('^(%d%d?)%.(%d%d?)%.(%d%d%d%d)$')
    if not (h and d) then return nil end
    local ok, t = pcall(os.time, { year = tonumber(y), month = tonumber(mo),
                                   day = tonumber(d), hour = tonumber(h),
                                   min = tonumber(mi), sec = 0 })
    if not ok or type(t) ~= 'number' then return nil end
    return t
end

-- Строка сотрудника. Возвращает таблицу или nil, если строка не того вида.
-- Ранг берётся числом из квадратных скобок (он достовернее названия),
-- название — только для контроля и алиасов.
-- Между ником и двоеточием сервер ставит разное: «[248] (Voice)», « (Voice)»,
-- «[248] » или просто « ». Раньше здесь требовался ОБЯЗАТЕЛЬНЫЙ [ID] - и на
-- Evolve RP, который ID после ника не печатает, не разбиралась ни одна строка:
-- в чате было «0 строк из 11». Теперь хвост ловится как (.-), а его состав
-- проверяет membersNickTailOk. Дефис перед статусом необязателен.
MEMBERS_LINE_PATTERN =
    'ID:%s*(%d+)%s*|%s*(%d%d?:%d%d)%s+(%d%d?%.%d%d?%.%d%d%d%d)%s*|%s*'
    .. '([%w_]+)(.-):%s*(.-)%s*%[(%d+)%]%s*%-?%s*(.*)$'

-- В хвосте между ником и двоеточием разрешены пробелы, цифры, квадратные
-- скобки (необязательный [ID]) и метки в круглых скобках («(Voice)»,
-- «(Голос)»). Всё остальное значит, что ник разрезан не по границе
-- (например «John.Smith» дал бы nick='John') - такую строку отвергаем.
function membersNickTailOk(mid)
    local residue = tostring(mid or ''):gsub('%b()', ''):gsub('[%s%[%]%d]', '')
    return residue == ''
end

function parseMembersLine(text)
    if type(text) ~= 'string' then return nil end
    local id, tm, dt, nick, mid, rname, rnum, tail =
        text:match(MEMBERS_LINE_PATTERN)
    if not nick then return nil end
    if not membersNickTailOk(mid) then return nil end
    nick = nickOf(nick)
    if nick == '' then return nil end
    tail = trim(tail or '')
    local duty = nil
    if tail:find('На работе', 1, true) then duty = true
    elseif tail:find('Выходной', 1, true) then duty = false end
    local rank = tonumber(rnum)
    if not rank then
        -- числа в скобках нет: пробуем узнать ранг по названию
        local kind, n = parseApiRank(rname)
        if kind == 'number' then rank = n end
    end
    if not rank then return nil end
    return {
        id       = tonumber(id),
        nick     = nick,
        rank     = rank,
        rankText = trim(rname or ''),
        loginAt  = parseMembersTime(tm, dt),
        voice    = tostring(mid or ''):find('Voice', 1, true) ~= nil,
        duty     = duty,
        afk      = tonumber(tail:match('%[AFK%]:%s*(%d+)')),
        tail     = tail,
    }
end

-- Заголовок блока и строка итога.
function membersHeadLine(text)
    return tostring(text or ''):find('Члены организации', 1, true) ~= nil
end

function membersTotalLine(text)
    return tonumber(tostring(text or ''):match('Всего:%s*(%d+)'))
end

-- ============================================ СОСТОЯНИЕ И ХРАНИЛИЩЕ =======

roster    = { members = {}, version = 1 }

cfg = {
    hotkey              = 0x77,     -- F8 (Win32 VK 0x77; см. HOTKEY_OPTIONS)
    showDismissed       = false,
    members = {
        enabled = true,             -- перехват вывода /members
    },
    update = {
        enabled = true,             -- проверять обновления при запуске игры
        auto    = true,             -- ставить новую версию сразу, без кнопки
        url     = UPDATE_URL_DEFAULT,
        every   = UPDATE_CHECK_EVERY,
    },
    api = {
        enabled = true,
        ttl     = 600,              -- секунд жизни кеша по сотруднику
        base    = 'https://api.evolvelogs.ru',
        requester = '',           -- пусто = подставлять ник текущего игрока
        transport = 'auto',       -- auto | download | requests (см. DEFAULT_INI)
        retries    = 3,           -- сколько раз повторять запрос без ответа
        retryPause = 4,           -- базовая пауза повтора, сек (удваивается)
        giveUp     = 600,         -- откат после исчерпания попыток, сек
    },
}

-- Evolve Logs API настроен только на San Fierro News:
-- фракция 9 в их классификации, сервер Saint-Louis.
API_FACTION = 9
API_SERVER  = 'saint-louis'

-- Ник текущего игрока: подставляется в updatedBy и в журнал изменений.
-- Выставляется из main() через detectLocalNick(); в тестах задаётся напрямую.
localNick = ''

-- ------------------------------------------------ горячая клавиша окна ----

-- Список клавиш для настройки: VK-коды Win32, имена - как в выпадающем списке.
-- Старая строка настройки держала перепутанные коды (кнопка с подписью «F8»
-- ставила 0x75 = F6, «F10» ставила 0x77 = F8): выбранная «F8» клавиша не
-- открывала окно, потому что игра ждала нажатия совсем другой (баг 26.09.2026).
HOTKEY_OPTIONS = {
    { name = 'F1',       code = 0x70 },
    { name = 'F2',       code = 0x71 },
    { name = 'F3',       code = 0x72 },
    { name = 'F4',       code = 0x73 },
    { name = 'F5',       code = 0x74 },
    { name = 'F6',       code = 0x75 },
    { name = 'F7',       code = 0x76 },
    { name = 'F8',       code = 0x77 },
    { name = 'F9',       code = 0x78 },
    { name = 'F10',      code = 0x79 },
    { name = 'F11',      code = 0x7A },
    { name = 'F12',      code = 0x7B },
    { name = 'Insert',   code = 0x2D },
    { name = 'Delete',   code = 0x2E },
    { name = 'Home',     code = 0x24 },
    { name = 'End',      code = 0x23 },
    { name = 'PageUp',   code = 0x21 },
    { name = 'PageDown', code = 0x22 },
}

-- VK-код -> читаемое имя; неизвестный код показываем как есть.
function vkToName(code)
    for _, hk in ipairs(HOTKEY_OPTIONS) do
        if hk.code == code then return hk.name end
    end
    return string.format('VK 0x%X', tonumber(code) or 0)
end

-- Миграция старых config.ini: прежний интерфейс предлагал кнопки с подписями
-- F8/F10/F1, но записывал коды 0x75/0x77/0x70 (F6/F8/F1). Переводим код в тот,
-- который человек реально нажимал, чтобы после обновления клавиша работала.
local HOTKEY_LEGACY = { [0x75] = 0x77, [0x77] = 0x79, [0x70] = 0x70 }

-- Нажатие клавиши: isKeyDown + детект фронта ( holding = одно срабатывание).
-- Не открываем окно поверх чужого курсора (диалог SAMP, кликабельный чат) и
-- не мешаем вводу в чат. Пока наше окно открыто, курсор принадлежит ему
-- (mimgui включает его сам), поэтому клавиша окно и закрывает.
local hotkeyPrevPressed = false
function checkHotkeyPress(winState)
    if type(isKeyDown) ~= 'function' then return false end
    if not isKeyDown(cfg.hotkey) then
        hotkeyPrevPressed = false
        return false
    end
    if hotkeyPrevPressed then return false end
    hotkeyPrevPressed = true
    if not winState[0] and type(sampIsCursorActive) == 'function' then
        local ok, v = pcall(sampIsCursorActive)
        if ok and v then return false end
    end
    if type(sampIsChatInputActive) == 'function' then
        local ok, v = pcall(sampIsChatInputActive)
        if ok and v then return false end
    end
    winState[0] = not winState[0]
    return true
end

-- Выбор клавиши в настройках сохраняется сразу: hotkey.json рядом с
-- roster.json, при загрузке имеет приоритет над config.ini.
function saveHotkey()
    writeFile(PATHS.hotkey, json.encode({ hotkey = cfg.hotkey }))
end

function loadHotkey()
    local raw = readFile(PATHS.hotkey)
    if not raw or raw == '' then return end
    local data = json.decode(raw)
    if type(data) == 'table' and type(data.hotkey) == 'number' then
        cfg.hotkey = math.floor(data.hotkey)
    end
end

-- Ник игрока, который пользуется скриптом: для requester (без него API
-- отвечает 422) и updatedBy. Два способа, оба под pcall:
--   1) ид локального игрока sampGetPlayerId -> sampGetPlayerNickname(ид);
--   2) хендл педа: sampGetPlayerIdByCharHandle возвращает ПАРУ (успех, ид) -
--      старый код брал только первое значение (логический «успех») и отдавал
--      его sampGetPlayerNickname, из-за чего requester получался неверным.
function detectLocalNick()
    if type(sampGetPlayerId) == 'function' then
        local ok, id = pcall(sampGetPlayerId)
        if ok and type(id) == 'number' and id >= 0 then
            local okN, n = pcall(sampGetPlayerNickname, id)
            if okN and type(n) == 'string' and #n > 0 then return cp1251ToUtf8(n) end
        end
    end
    if PLAYER_PED and PLAYER_PED ~= -1 and type(sampGetPlayerIdByCharHandle) == 'function' then
        local ok, success, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
        if ok and success and type(id) == 'number' and id >= 0 then
            local okN, n = pcall(sampGetPlayerNickname, id)
            if okN and type(n) == 'string' and #n > 0 then return cp1251ToUtf8(n) end
        end
    end
    return nil
end

DEFAULT_INI = [[; SFN Logs - конфигурация
; Файл читается в UTF-8 (как и этот скрипт). Старые версии конфига в CP1251
; распознаются автоматически и конвертируются на лету.

[main]
; VK-код клавиши окна: 0x77 = F8 (по умолчанию), 0x79 = F10, 0x70 = F1.
; Полный список клавиш - в настройках окна («Горячая клавиша»); выбор там
; сохраняется в hotkey.json и имеет приоритет над этим файлом.
hotkey = 0x77
; Показывать уволенных в общей таблице (0/1)
showDismissed = 0

[api]
; Evolve Logs API (api.evolvelogs.ru) - единственный внешний источник данных
; о рангах. Настроен только на San Fierro News: фракция 9, сервер saint-louis.
; Синхронизации через Google Sheets больше нет: официальные логи сервера
; уже содержат приёмы, повышения, понижения и увольнения.
enabled = 1
; Сколько секунд хранить ответ API по сотруднику, прежде чем обновить
ttl = 600
; Базовый URL - меняйте только если API переедет
base = https://api.evolvelogs.ru
; Кто запрашивает журнал (параметр requester): без него API отвечает 422.
; Пусто - подставляется ник текущего игрока (тот же, что в логах сервера).
requester =
; Транспорт HTTP-запросов:
;   auto     - фоновый downloadUrlToFile (рекомендуется: игра не блокируется);
;              requests подключается лишь как крайняя мера после 8 неудач
;              фона подряд (возможны подвисания кадра), и раз в 5 минут
;              скрипт сам пробует вернуться на фоновый транспорт;
;   download - только downloadUrlToFile;
;   requests - только requests (подмораживает кадр на каждый запрос, 1-6 с).
transport = auto
; Повторы запроса по нику: API может ответить не с первого раза (сеть,
; лимиты сервера, сбой транспорта). Ответ всегда проверяется:
;   получили данные / «записей нет» (404) - вопрос закрыт;
;   сетевая ошибка - повтор через retryPause сек (пауза удваивается),
;   после retries попыток ник уходит в откат на giveUp секунд.
retries = 3
retryPause = 4
giveUp = 600

[members]
; Перехват вывода серверной команды /members: онлайн-состав фракции
; (ID, последний вход, ник, ранг, «На работе/Выходной», AFK).
; Строки разбираются автоматически, ники уходят в очередь Evolve Logs API.
; /sfnlogmembers - отправить /members и начать перехват.
enabled = 1

[update]
; Автообновление: скрипт сам берёт свежую версию из репозитория на GitHub
; и подменяет свой файл (старый сохраняется как SFNLogs.lua.bak).
; Проверка идёт в фоновом потоке, кадр игры не блокируется.
enabled = 1
; Ставить обновление сразу (1) или только сообщить о нём в чат (0)
auto = 1
; Откуда брать файл. Меняйте, только если скрипт переехал или вы держите
; свою копию репозитория (например, форк с правками под свою редакцию).
url = https://raw.githubusercontent.com/Wereskkk/SFN_Logs/main/SFNLogs.lua
; Как часто спрашивать, секунд (по умолчанию 6 часов, минимум 10 минут)
every = 21600
]]

-- Запись roster.json - батчинг (фикс 2.0.13): раньше файл писался после
-- каждого ответа API, и массовое обновление давало десятки сериализаций и
-- дисковых записей подряд (микрофризы кадра). Теперь saveRoster() лишь
-- помечает журнал «грязным», главный цикл пишет не чаще раза в 5 секунд, а
-- saveRoster(true) - немедленная запись (кнопка «Сохранить», /sfnlogsave,
-- выгрузка скрипта).
local rosterDirty    = false
local lastRosterSave = os.time()
local ROSTER_SAVE_INTERVAL = 5   -- секунд

function saveRoster(force)
    if force == true then
        if writeFile(PATHS.roster, json.encode(roster)) then
            rosterDirty = false
        end
        lastRosterSave = os.time()
        return
    end
    rosterDirty = true
end

-- Вызывается из main() каждый кадр: пишет накопленные изменения, когда
-- интервал истёк. Возвращает true, если запись состоялась.
function tickRosterSave()
    if not rosterDirty then return false end
    if os.time() - lastRosterSave < ROSTER_SAVE_INTERVAL then return false end
    saveRoster(true)
    return true
end

-- Интервал батчинга, сек. Хук для тестов; в игре значение не меняется.
function rosterSaveInterval(v)
    if type(v) == 'number' and v >= 0 then ROSTER_SAVE_INTERVAL = v end
    return ROSTER_SAVE_INTERVAL
end

-- Запись настроек обратно в config.ini.
--
-- До 2.2.0 функции saveConfig не было вовсе: галочки окна («показывать
-- уволенных», «забирать состав из /members») жили только до перезапуска игры,
-- а hotkey приходилось держать отдельным hotkey.json. Теперь то, что
-- переключается в окне, сохраняется сразу.
--
-- Файл НЕ перезаписывается целиком: правятся только значения известных ключей
-- на месте, поэтому пользовательские комментарии и ручные настройки секции
-- [api] (transport, retries, base, requester) остаются нетронутыми. Ключ,
-- которого в файле ещё нет, дописывается в конец своей секции; секция [update]
-- создаётся, если конфиг совсем старый.
SAVE_CONFIG_KEYS = {
    main = {
        showDismissed = function() return cfg.showDismissed and '1' or '0' end,
    },
    members = {
        enabled = function() return (cfg.members and cfg.members.enabled) and '1' or '0' end,
    },
    update = {
        enabled = function() return (cfg.update and cfg.update.enabled) and '1' or '0' end,
        auto    = function() return (cfg.update and cfg.update.auto ~= false) and '1' or '0' end,
    },
}

function saveConfig()
    local raw = readFile(PATHS.config)
    if not raw or raw == '' then raw = DEFAULT_INI end
    -- переводим строки в таблицу; перевод строк определяем по файлу, чтобы не
    -- менять его формат (старые конфиги созданы в Windows с \r\n)
    local nl = raw:find('\r\n', 1, true) and '\r\n' or '\n'
    local lines = {}
    for line in (raw .. nl):gmatch('(.-)' .. nl) do lines[#lines + 1] = line end
    if #lines > 0 and lines[#lines] == '' then lines[#lines] = nil end

    local function split(line)
        local k, v = line:match('^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$')
        return k, v
    end

    -- первый проход: меняем существующие значения, запоминаем границы секций
    local seen = {}                      -- 'sec.key' -> true
    local bounds, order = {}, {}         -- sec -> { first, last }, порядок секций
    local cur = nil
    for i = 1, #lines do
        local sec = lines[i]:match('^%s*%[%s*([%w_]+)%s*%]')
        if sec then
            cur = sec
            if not bounds[sec] then bounds[sec] = { first = i, last = i }; order[#order + 1] = sec
            else bounds[sec].last = i end
        elseif cur then
            bounds[cur].last = i
            local key = split(lines[i])
            if key and SAVE_CONFIG_KEYS[cur] and SAVE_CONFIG_KEYS[cur][key] then
                local want = SAVE_CONFIG_KEYS[cur][key]()
                if lines[i] ~= (key .. ' = ' .. want) then
                    lines[i] = key .. ' = ' .. want
                end
                seen[cur .. '.' .. key] = true
            end
        end
    end

    -- второй проход: дописываем недостающие ключи в конец своих секций
    local addAt = {}                     -- sec -> { 'key = value', ... }
    for sec, keys in pairs(SAVE_CONFIG_KEYS) do
        for key, fn in pairs(keys) do
            if not seen[sec .. '.' .. key] then
                addAt[sec] = addAt[sec] or {}
                local list = addAt[sec]
                list[#list + 1] = key .. ' = ' .. fn()
            end
        end
    end
    if next(addAt) then
        local out, shift = {}, 0
        for i = 1, #lines do
            out[#out + 1] = lines[i]
            local sec = lines[i]:match('^%s*%[%s*([%w_]+)%s*%]')
            if sec and addAt[sec] then
                -- вставляем сразу после заголовка секции: её конец мог съехать
                for _, l in ipairs(addAt[sec]) do out[#out + 1] = l end
                addAt[sec] = nil
            end
        end
        -- старых конфигов может не хватать целых секций ([members] появился
        -- в 2.0.9, [update] - в 2.2.0): дописываем их в конец файла
        for _, sec in ipairs({ 'main', 'members', 'update' }) do
            if addAt[sec] then
                out[#out + 1] = ''
                out[#out + 1] = '[' .. sec .. ']'
                out[#out + 1] = '; добавлено скриптом при сохранении настроек'
                for _, l in ipairs(addAt[sec]) do out[#out + 1] = l end
            end
        end
        lines = out
    end

    local text = table.concat(lines, nl) .. nl
    if not writeFile(PATHS.config, text) then return false end
    return true
end

function loadConfig()
    local ini = loadIni(PATHS.config)
    if not next(ini) then
        writeFile(PATHS.config, DEFAULT_INI)
        ini = loadIni(PATHS.config)
    end
    local m = ini.main or {}
    local hk = tonumber(m.hotkey)
    if hk and HOTKEY_LEGACY[hk] then hk = HOTKEY_LEGACY[hk] end   -- старые перепутанные коды
    cfg.hotkey              = hk or 0x77
    cfg.showDismissed       = (m.showDismissed == '1' or m.showDismissed == 'true')

    local sy = ini.api or {}
    local function flag(v, default)
        if v == nil or v == '' then return default end
        return not (v == '0' or v == 'false')
    end
    cfg.api.enabled = flag(sy.enabled, true)
    cfg.api.ttl     = math.max(60, tonumber(sy.ttl) or 600)
    cfg.api.base    = trim(sy.base or '')
    if cfg.api.base == '' then cfg.api.base = 'https://api.evolvelogs.ru' end
    cfg.api.requester = trim(sy.requester or '')
    local tr = trim(sy.transport or ''):lower()
    if tr == 'downloadurltofile' or tr == 'download' or tr == 'dutf' then
        tr = 'download'
    end
    if tr == 'download' or tr == 'requests' then cfg.api.transport = tr
    else cfg.api.transport = 'auto' end
    cfg.api.retries    = math.max(0, math.min(10, math.floor(tonumber(sy.retries) or 3)))
    cfg.api.retryPause = math.max(1, math.min(60, tonumber(sy.retryPause) or 4))
    cfg.api.giveUp     = math.max(60, tonumber(sy.giveUp) or 600)

    local mm = ini.members or {}
    cfg.members = cfg.members or {}
    cfg.members.enabled = flag(mm.enabled, true)

    local up = ini.update or {}
    cfg.update = cfg.update or {}
    cfg.update.enabled = flag(up.enabled, true)
    cfg.update.auto    = flag(up.auto, true)
    cfg.update.url     = trim(up.url or '')
    if cfg.update.url == '' then cfg.update.url = UPDATE_URL_DEFAULT end
    cfg.update.every   = math.max(600, tonumber(up.every) or UPDATE_CHECK_EVERY)

    loadHotkey()   -- выбор из настроек (hotkey.json) важнее config.ini
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

function fmtDate(t)     return (t and t > 0) and os.date('%d.%m.%Y', t) or '--.--.----' end
function fmtDateTime(t) return (t and t > 0) and os.date('%d.%m.%Y %H:%M', t) or '-' end

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

-- Слияние состава больше не нужно: единственный внешний источник данных —
-- Evolve Logs API, он читается, но не пишется. Локальные правки рангов
-- остаются локальными и перетираются официальными данными при обновлении.
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

    -- Дата из /members — оценка снизу (последний вход всегда позже приёма),
    -- поэтому «МОЖНО ПОВЫШАТЬ» по ней не выдаём: ждём точных дат от API.
    if m.acceptedApprox and not m.apiFetchedAt and not m.apiMissing then
        return nextAt, false, 'дата приблизительная (/members)'
    end

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
    saveRoster()
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
    saveRoster()
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
    saveRoster()
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
    saveRoster()
    return m
end

-- ------------------------------------------------ СОСТАВ ИЗ /members ----

-- Слияние одной строки /members с журналом. Дата принятия из /members
-- неизвестна, поэтому вместо неё берётся последний вход — это оценка снизу
-- (сотрудник уже был во фракции, когда заходил). Флаг acceptedApprox не даёт
-- показывать «МОЖНО ПОВЫШАТЬ», пока API не вернёт точные даты.
-- Возвращает действие: 'added' | 'rank' | 'restored' | 'seen'.
function mergeMembersEntry(e, now)
    if type(e) ~= 'table' or not e.nick or e.nick == '' then return nil end
    now = now or os.time()
    local rank = math.max(1, math.min(MAX_RANK, math.floor(tonumber(e.rank) or 1)))
    local login = (e.loginAt and e.loginAt > 0) and e.loginAt or nil
    local m = roster.members[e.nick]
    local action
    if not m then
        m = addMember(e.nick, '', login or 0, rank, nil, now)
        if not m then return nil end
        m.acceptedApprox = login and true or false
        m.history = m.history or {}
        local h = m.history[#m.history]
        if h then
            h.note = login and 'состав из /members (дата приблизительная)'
                           or  'состав из /members (дата принятия неизвестна)'
        end
        action = 'added'
    else
        action = 'seen'
        if m.dismissed and restoreMember(e.nick, now) then
            m = roster.members[e.nick]
            action = 'restored'
        end
        if (m.rank or 0) ~= rank then
            -- Дату повышения не ухудшаем: если API уже дал точную — оставляем,
            -- иначе берём последний вход (повышение было не позже него).
            local at = now
            if m.apiFetchedAt or m.apiHistoryAt then at = m.promotedAt or now
            elseif login then at = math.max(m.promotedAt or 0, login) end
            changeRank(e.nick, rank, 'по /members', at)
            m = roster.members[e.nick]
            if action == 'seen' then action = 'rank' end
        end
    end
    m.online    = true
    m.lastSeen  = now
    m.lastLogin = login or m.lastLogin
    m.onDuty    = e.duty
    m.afk       = e.afk
    if e.voice ~= nil then m.voice = e.voice end
    m.memberId  = e.id or m.memberId
    return action, m
end

-- Состояние перехвата: от «Члены организации Он-лайн:» до «Всего: N человек».
membersCapture = {
    active = false, startedAt = 0, lastAt = 0,
    parsed = 0, added = 0, updated = 0, seen = 0, skipped = 0,
    total = nil, nicks = {}, queued = 0, at = 0, text = '',
}

-- Внешние крючки заполняет API-слой (очередь запросов) и игровой (чат):
-- в PURE-секции ни SAMP, ни сети нет.
MEMBERS_HOOKS = { refresh = nil, say = nil }
MEMBERS_TIMEOUT = 6      -- секунд без строк: блок считается оборванным

function membersReset()
    local c = membersCapture
    c.active, c.startedAt, c.lastAt = false, 0, 0
    c.parsed, c.added, c.updated, c.seen, c.skipped = 0, 0, 0, 0, 0
    c.total, c.nicks, c.queued = nil, {}, 0
end

-- Ручной старт: мы сами отправили /members и ждём строки сервера.
function membersStart(now)
    membersReset()
    local c = membersCapture
    now = now or os.time()
    c.active, c.startedAt, c.lastAt = true, now, now
end

function membersFinish(now, why)
    local c = membersCapture
    now = now or os.time()
    if not c.active and c.parsed == 0 then return end
    c.active = false
    c.at = now
    if c.parsed > 0 then saveRoster() end
    local queued = 0
    for _, it in ipairs(c.nicks) do
        if MEMBERS_HOOKS.refresh then
            pcall(MEMBERS_HOOKS.refresh, it.nick, it.wantHistory)
            queued = queued + 1
        end
    end
    c.queued = queued
    c.text = string.format('%d строк%s | новых %d | обновлено %d | в очередь API %d',
        c.parsed, c.total and (' из ' .. c.total) or '', c.added, c.updated, queued)
    if why then c.text = c.text .. ' (' .. why .. ')' end
    if MEMBERS_HOOKS.say and c.parsed > 0 then
        pcall(MEMBERS_HOOKS.say, '{66FF66}[SFN Logs] /members: ' .. c.text)
    end
end

-- Построчный перехват. text — одна строка чата в UTF-8; цветовые теги
-- сервера ({008000} и т.п.) и префикс времени [ЧЧ:ММ:СС] не мешают.
function membersFeedLine(text, now)
    if type(text) ~= 'string' then return nil end
    if not cfg.members or cfg.members.enabled == false then return nil end
    now = now or os.time()
    local c = membersCapture
    local clean = stripColors(text)
    -- блок оборвался (сервер не дослал строки): фиксируем то, что есть
    if c.active and now - c.lastAt > MEMBERS_TIMEOUT then
        membersFinish(now, 'обрыв')
    end
    if membersHeadLine(clean) then
        membersStart(now)
        return 'head'
    end
    if not c.active then return nil end
    c.lastAt = now
    local total = membersTotalLine(clean)
    if total then
        c.total = total
        membersFinish(now)
        return 'total'
    end
    local e = parseMembersLine(clean)
    if not e then
        if trim(clean) ~= '' then c.skipped = c.skipped + 1 end
        return nil
    end
    c.parsed = c.parsed + 1
    local action, m = mergeMembersEntry(e, now)
    if action == 'added' then c.added = c.added + 1
    elseif action == 'rank' or action == 'restored' then c.updated = c.updated + 1
    elseif action == 'seen' then c.seen = c.seen + 1 end
    if m then
        c.nicks[#c.nicks + 1] = { nick = m.nick, wantHistory = not m.apiHistory }
    end
    return action
end

-- Сервер присылает блок /members не построчно, а несколькими сообщениями,
-- внутри которых строки разделены \n (иначе в чате «0 строк из N»: заголовок
-- открывал перехват, а строки того же сообщения не разбирались). Режем текст
-- на строки и каждую кормим построчной логикой; для однострочных сообщений
-- поведение прежнее. Возвращаем последний содержательный вердикт.
function membersFeed(text, now)
    if type(text) ~= 'string' then return nil end
    if not cfg.members or cfg.members.enabled == false then return nil end
    if not text:find('[\r\n]') then return membersFeedLine(text, now) end
    now = now or os.time()
    local last
    for line in text:gmatch('[^\r\n]+') do
        local v = membersFeedLine(line, now)
        if v then last = v end
    end
    return last
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

-- ==================================================== АВТООБНОВЛЕНИЕ =======
--
-- Скрипт обновляет сам себя: берёт SFNLogs.lua из ветки main репозитория
-- GitHub по HTTPS (raw-адрес, без ключей и без лимита API), сравнивает версию
-- и, если она новее, проверяет скачанное и подменяет свой файл.
--
-- Пользователю больше не нужно ничего скачивать руками: достаточно перезапустить
-- игру или один раз ввести /reload.
--
-- Безопасность замены (важно: скрипт перезаписывает сам себя, испорченный файл
-- означает «MoonLoader больше не загрузит ничего»):
--   1. скачанный текст ОБЯЗАН компилироваться - load()/loadstring() без ошибки;
--   2. в нём должны быть script_name('SFN Logs'), function main(), разбор
--      /members и обе метки PURE LOGIC - иначе это не наш скрипт (например,
--      страница ошибки прокси или обрезанная загрузка);
--   3. версия в нём обязана быть строго новее текущей, а script_version()
--      в шапке и SFN_VERSION_STR внутри - совпадать: рассинхрон означает, что
--      файл собрали неправильно, и скрипт зациклился бы на обновлении;
--   4. размер не меньше UPDATE_MIN_BYTES (защита от обрезанного ответа);
--   5. старый файл сохраняется рядом как SFNLogs.lua.bak - откат одной
--      командой: удалить новый файл и переименовать .bak.
--
-- Файл подменяется НЕ на месте: сначала пишется SFNLogs\update.lua.new, и
-- только после всех проверок он переносится поверх рабочего файла.

UPDATE_URL_DEFAULT = 'https://raw.githubusercontent.com/Wereskkk/SFN_Logs/main/SFNLogs.lua'
UPDATE_MIN_BYTES   = 60000      -- текущий скрипт ~200 КБ: меньшее - обрезок
UPDATE_CHECK_EVERY = 6 * 3600   -- как часто спрашивать GitHub, секунд

updateState = {
    lastCheck    = 0,      -- unix-время последней проверки
    available    = '',     -- какая версия лежит в репозитории
    ready        = false,  -- скачано, проверено и сохранено - можно ставить
    pendingPath  = '',     -- где лежит проверенный новый файл
    lastError    = '',     -- текст последней неудачи (для настроек и /sfnlogupdate)
    installedAt  = 0,      -- когда была поставлена новая версия
    installedVer = '',     -- какая версия поставлена
    notified     = '',     -- о какой версии уже сообщили в чат (без повторов)
}

-- «2.1.0» -> { 2, 1, 0 }. Не числа и хвост вроде «2.1.0-beta» дают nil:
-- сравнивать строками нельзя («2.1.10» < «2.1.9» лексикографически).
function parseVersion(s)
    if type(s) ~= 'string' then return nil end
    local a, b, c = s:match('^%s*(%d+)%.(%d+)%.(%d+)%s*$')
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

-- a строго новее b. Одинаковые версии - не новее: иначе скрипт скачивал бы сам
-- себя бесконечно.
function isNewerVersion(a, b)
    local va, vb = parseVersion(a), parseVersion(b)
    if not va or not vb then return false end
    for i = 1, 3 do
        if va[i] ~= vb[i] then return va[i] > vb[i] end
    end
    return false
end

-- Версия из текста скрипта: script_version('X.Y.Z') в шапке.
function extractScriptVersion(text)
    if type(text) ~= 'string' then return nil end
    return text:match("script_version%s*%(%s*'([%d%.]+)'%s*%)")
end

-- Проверка скачанного текста. Возвращает версию (строка) или nil + причину.
-- Причина показывается пользователю, поэтому формулировки человеческие.
function validateScriptText(text, currentVersion)
    if type(text) ~= 'string' then return nil, 'пустой ответ' end
    local n = #text
    if n < UPDATE_MIN_BYTES then
        return nil, string.format('файл слишком короткий: %d байт (нужно не меньше %d) - загрузка оборвалась',
                                  n, UPDATE_MIN_BYTES)
    end
    local loader = loadstring or load
    if type(loader) ~= 'function' then return nil, 'нечем проверить синтаксис' end
    local chunk, serr = loader(text, 'update-check')
    if not chunk then
        return nil, 'файл не компилируется: ' .. tostring(serr):sub(1, 120)
    end
    if not text:find("script_name('SFN Logs')", 1, true) then
        return nil, 'это не SFN Logs: в файле нет script_name'
    end
    local ver = extractScriptVersion(text)
    if not ver then return nil, 'в файле не нашлось script_version' end
    if not parseVersion(ver) then
        return nil, 'версия в файле не разбирается: ' .. tostring(ver)
    end
    if not isNewerVersion(ver, currentVersion) then
        return nil, 'версия ' .. ver .. ' не новее текущей ' .. tostring(currentVersion)
    end
    -- критические куски: без них файл формально наш, но работать не будет.
    -- Метки PURE-секции СОБИРАЕМ ИЗ ЧАСТЕЙ: записанные в этом файле буквально,
    -- они обрывали бы извлечение PURE-секции в test_logic.lua (шаблон «.-»
    -- ленивый и заканчивал секцию на первой же встреченной метке).
    local markBegin = '-- >>> PURE LOGIC ' .. 'BEGIN'
    local markEnd   = '-- <<< PURE LOGIC ' .. 'END'
    for _, probe in ipairs({ { 'function main()', 'нет точки входа main()' },
                             { 'membersFeed(', 'нет разбора /members' },
                             { markBegin, 'нет PURE-секции' },
                             { markEnd, 'PURE-секция не закрыта' } }) do
        if not text:find(probe[1], 1, true) then return nil, probe[2] end
    end
    -- шапка и внутренний строковый литерал версии обязаны совпадать
    local inner = text:match("SFN_VERSION_STR%s*=%s*'([%d%.]+)'")
    if inner and inner ~= ver then
        return nil, 'рассинхрон версий в файле: script_version ' .. ver
            .. ', SFN_VERSION_STR ' .. inner
    end
    return ver
end

-- Состояние обновления живёт в update.json рядом с roster.json: проверка не
-- дёргает GitHub при каждом запуске игры, а готовая к установке версия не
-- теряется, если игру закрыли до /reload.
function loadUpdateState()
    local raw = readFile(PATHS.update)
    if raw and raw ~= '' then
        local d = json.decode(raw)
        if type(d) == 'table' then
            updateState.lastCheck    = tonumber(d.lastCheck) or 0
            updateState.available    = tostring(d.available or '')
            updateState.ready        = d.ready == true
            updateState.pendingPath  = tostring(d.pendingPath or '')
            updateState.lastError    = tostring(d.lastError or '')
            updateState.installedAt  = tonumber(d.installedAt) or 0
            updateState.installedVer = tostring(d.installedVer or '')
            updateState.notified     = tostring(d.notified or '')
            -- готовый файл мог быть удалён руками - не обещаем того, чего нет
            if updateState.ready and updateState.pendingPath ~= '' then
                local body = readFile(updateState.pendingPath)
                if not body or body == '' then
                    updateState.ready, updateState.pendingPath = false, ''
                end
            end
        end
    end
    return updateState
end

function saveUpdateState()
    return writeFile(PATHS.update, json.encode(updateState))
end

-- Пора ли спрашивать GitHub. force - всегда да (кнопка «Проверить обновления»).
function needUpdateCheck(now, force)
    if not cfg.update or not cfg.update.enabled then return false end
    if force then return true end
    if updateState.ready then return false end      -- уже скачано, ждём установки
    local last = updateState.lastCheck or 0
    -- ни одной проверки ещё не было (первый запуск, удалён update.json) -
    -- проверяем сразу, не дожидаясь истечения интервала
    if last <= 0 then return true end
    local every = tonumber(cfg.update and cfg.update.every) or UPDATE_CHECK_EVERY
    if every < 600 then every = 600 end             -- чаще раза в 10 минут не дёргаем GitHub
    return (now - last) >= every
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

-- ============================================ ПЕРЕХВАТ СООБЩЕНИЙ СЕРВЕРА ==
--
-- v2.1.0: перехвата чата по шаблонам больше нет. Раньше состав пополнялся
-- регулярными шаблонами из config.ini ([patterns] accept/promote/demote/
-- dismiss), а точные тексты сервера снимались дампом чата (/sfnlogcap ->
-- chat_dump.txt). На практике это требовало от пользователя править Lua-
-- паттерны в конфиге, а шаблоны всё равно расходились с формулировками
-- Evolve RP. Теперь список сотрудников берётся из двух понятных источников:
--   * вывод серверной команды /members  (онлайн-состав фракции);
--   * вкладка «Поиск» -> «+ В состав»    (любой игрок по нику, данные из API).
-- plus ручное добавление /sfnlogadd. Ранги и даты событий - из Evolve Logs API.

local function onServerMessage(color, text)
    if type(text) ~= 'string' then return end
    -- чат приходит байтами CP1251: дальше по скрипту всё живёт в UTF-8
    text = cp1251ToUtf8(text)
    -- единственное, что мы разбираем в чате, - блок строк /members
    pcall(membersFeed, text)
end

SFNLogs = SFNLogs or {}

-- ============================================ EVOLVE LOGS API =============
--
-- Единственный внешний источник данных о рангах — официальный журнал
-- Evolve Role Play (api.evolvelogs.ru). Синхронизации через Google Sheets
-- больше нет: серверные логи уже содержат приёмы, повышения, понижения
-- и увольнения, писать туда нечего и нельзя.
--
-- Настройка жёсткая и единственная: San Fierro News.
--   fraction = 9   (SF News в классификации API)
--   server   = saint-louis
-- Запрашивающий — ник текущего игрока: сервер журнала требует его явно
-- (без requester отвечает 422).
--
-- Ограничения API, которые учитывает клиент:
--   * списка состава фракции нет — есть только записи по конкретному нику,
--     поэтому индекс сотрудников ведётся локально (вывод /members, «Поиск»,
--     /sfnlogadd, roster.json), а API дополняет каждую запись официальными
--     данными;
--   * /v1/journal отдаёт последнюю запись, /v1/journal/history — всю историю;
--   * отсутствие данных — это 404 для journal и пустой массив для history;
--   * флуд-лимит сервера — 4 запроса в секунду, поэтому фоновый поток делает
--     не более одного запроса за 260 мс и только один одновременно.
--
-- Всё сетевое живёт в lua_thread: основной поток и отрисовку не блокируем.
-- Ответы кешируются в записи сотрудника (m.api*) и сохраняются в roster.json,
-- поэтому окно показывает данные и без сети, помечая их возраст.

local okRequests, requests = pcall(require, 'requests')

local api = {
    busy    = false,
    lastErr = nil,
    lastOk  = 0,
    fetched = 0,
    errors  = 0,
    queue   = {},          -- ники на обновление journal
    histQueue = {},        -- ники на загрузку полной истории
    queued  = {},          -- nick -> 1|2, чтобы не дублировать в очередях
    pref       = 'downloadUrlToFile',  -- текущий (эффективный) транспорт
    prefFails  = 0,        -- подряд неудач текущего транспорта
    failStreak = 0,        -- подряд неудач вообще (для паузы воркера)
    switched   = 0,        -- сколько раз сработало авто-переключение
    lastCode   = nil,      -- последний статус колбэка downloadUrlToFile
    lastCodes  = {},       -- статусы колбэка текущего запроса (последние 8)
    lastSwitchSay = 0,
    probeAt    = 0,        -- когда последней раз тихо проверяли фоновый транспорт
    quiet      = false,    -- идёт тихая проба: в чат об авто-переключении не пишем
    diag       = nil,      -- диагностика последнего запроса: колбэки/тишина
    attempt    = 0,        -- счётчик запросов: каждому свой временный файл
    -- Повторы: API может ответить не с первого раза, поэтому каждый исход
    -- запроса проверяется и классифицируется (см. refreshJournal).
    noData     = 0,        -- сколько раз API определённо ответил «записей нет»
    retried    = 0,        -- сколько раз запросы ставились на повтор
    gaveUpN    = 0,        -- сколько ников уходило в откат
    tries      = {},       -- nick -> номер попытки
    retryAt    = {},       -- nick -> unix-время следующей попытки
    retryKind  = {},       -- nick -> 'journal' | 'history'
    gaveUp     = {},       -- nick -> unix-время, до которого не дёргать
}

local function apiHasTransport(name)
    if name == 'downloadUrlToFile' then return downloadUrlToFile ~= nil end
    if name == 'requests' then return (okRequests and requests ~= nil) and true or false end
    return false
end

-- Транспорт выбираем по принципу «не блокирует игру». downloadUrlToFile качает
-- файл в фоновом потоке MoonLoader, а requests - блокирующая HTTP-библиотека:
-- её вызов в lua_thread останавливает кадр (и всю игру) на весь запрос -
-- DNS + TLS + тело ответа, легко на секунды. Поэтому requests только запасной.
-- Авто-переключение асимметричное (фикс 2.0.13): с блокирующего requests
-- возвращаемся на фоновый быстро (2 неудачи подряд), а уходим на него лишь
-- как на крайнюю меру - после 8 неудач downloadUrlToFile подряд и только с
-- предупреждением в чат. Раньше хватало 2 неудач: одна гонка «финальный
-- статус пришёл раньше, чем файл дочитался» уводила всю сессию на
-- блокирующие запросы - игра подвисала на каждом обращении к API.
-- В config.ini [api] transport можно закрепить один транспорт вручную.
local function apiTransport()
    local forced = cfg.api.transport
    if forced == 'download' and apiHasTransport('downloadUrlToFile') then
        return 'downloadUrlToFile'
    end
    if forced == 'requests' and apiHasTransport('requests') then
        return 'requests'
    end
    if apiHasTransport(api.pref) then return api.pref end
    local other = (api.pref == 'downloadUrlToFile') and 'requests' or 'downloadUrlToFile'
    if apiHasTransport(other) then return other end
    return 'нет транспорта'
end

-- Учёт исхода запроса: сброс/набор счётчиков и авто-переключение транспорта.
local function apiNoteOk()
    api.failStreak, api.prefFails = 0, 0
end

local function apiNoteFail(used, msg)
    api.failStreak = api.failStreak + 1
    api.prefFails = (used == api.pref) and (api.prefFails + 1) or 1
    -- Асимметричный гистерезис (фикс 2.0.13): с блокирующего requests уходим
    -- после 2 неудач, а на него - лишь крайняя мера, после 8 неудач фона.
    local limit = (used == 'downloadUrlToFile') and 8 or 2
    if api.prefFails >= limit and cfg.api.transport == 'auto' then
        local other = (used == 'downloadUrlToFile') and 'requests' or 'downloadUrlToFile'
        if apiHasTransport(other) and other ~= api.pref then
            api.pref, api.prefFails = other, 0
            if not api.quiet then
                api.switched = api.switched + 1
                if os.time() - api.lastSwitchSay > 60 then
                    api.lastSwitchSay = os.time()
                    local note = (other == 'requests')
                        and ' (крайняя мера: возможны подвисания кадра)'
                        or ' (кадр снова не блокируется)'
                    pcall(say, string.format(
                        '{FFCC44}[SFN Logs] API: %s не отвечает (%s) - переключился на %s%s',
                        used, tostring(msg), other, note))
                end
            end
        end
    end
    return nil, msg
end

-- Пауза воркера: 260 мс (серверный лимит 4 запроса/с) при здоровье и растущий
-- бэкофф при сериях неудач, чтобы не долбить сеть и не спамить ошибками.
-- На блокирующем requests (крайняя мера авто-режима) запросы дёргаем не чаще
-- раза в секунду: подвисания кадра становятся реже.
local function workerPauseMs()
    local n = api.failStreak
    local ms = (n < 2) and 260 or math.min(30000, 1000 * 2 ^ (n - 2))
    if ms < 1000 and cfg.api.transport == 'auto' and api.pref == 'requests' then
        ms = 1000
    end
    return ms
end

local function apiUrl(path, params)
    local parts = {}
    for k, v in pairs(params or {}) do
        if v ~= nil then parts[#parts + 1] = urlEncode(k) .. '=' .. urlEncode(v) end
    end
    table.sort(parts)
    local q = table.concat(parts, '&')
    return cfg.api.base .. path .. (q ~= '' and ('?' .. q) or '')
end

-- Кто запрашивает журнал: параметр requester обязателен, без него API отвечает
-- 422. По умолчанию подставляется ник текущего игрока; поменять можно в
-- config.ini: [api] requester = Ваш_Ник.
local function apiRequester()
    if cfg.api.requester and cfg.api.requester ~= '' then return cfg.api.requester end
    return (localNick and localNick ~= '') and localNick or 'SFNLogs'
end

-- Статусы колбэка downloadUrlToFile(id, status, ...) - коды таблицы
-- «moonloader».download_status, а не «успех/ошибка»: 1..56 - BINDSTATUS
-- (2 соединение, 4 начало данных, 5 данные идут, 6 конец данных), 57..60 -
-- расширенные STATUSEX: 57 STARTBINDING, 58 ENDDOWNLOAD, 59 LOWRESOURCE,
-- 60 DATAAVAILABLE. Код 58 (STATUSEX_ENDDOWNLOAD) - финальный сигнал
-- «загрузка окончена»: он приходит в конце каждой успешной загрузки.
-- До 2.0.13 финалом считались только 6 да то, что вернёт
-- require('moonloader').download_status: в сборках, где эта библиотека
-- недоступна, код 58 не распознавался, запрос висел до порога тишины, а
-- две такие неудачи подряд уводили транспорт на блокирующий requests
-- (баг-репорт «фризы 1-6 с: последний статус 58, переключений 1»). Поэтому
-- реальные коды зашиты явно, библиотека их лишь дополняет (сборки
-- отличаются), а готовность ответа дополнительно проверяется по содержимому
-- файла - независимо от словаря статусов. Промежуточные коды (включая 2)
-- ошибкой не считаются: настоящая ошибка здесь - тишина.
local DL_DONE = { [6] = true, [58] = true }              -- конец данных / конец загрузки
local DL_DATA = { [4] = true, [5] = true, [60] = true }  -- данные начались / идут / доступны
local DL_CODE_MAX = 60                                   -- выше - неизвестные коды
local dlWeirdLogged = {}                                 -- неизвестный код уже залогирован
pcall(function()
    local ds = require('moonloader').download_status
    if type(ds) == 'table' then
        for _, k in ipairs({ 'STATUS_ENDDOWNLOADDATA', 'STATUSEX_ENDDOWNLOAD' }) do
            if type(ds[k]) == 'number' then DL_DONE[ds[k]] = true end
        end
        for _, k in ipairs({ 'STATUS_BEGINDOWNLOADDATA', 'STATUS_DOWNLOADINGDATA',
                             'STATUSEX_DATAAVAILABLE' }) do
            if type(ds[k]) == 'number' then DL_DATA[ds[k]] = true end
        end
    end
end)

-- Ответ API об ошибке выглядит так:
--   {"errors":[{"code":"NOT_FOUND","message":"Данные отсутствуют"}], ...}
-- Для /v1/journal это ОТВЕТ, а не сбой сети: «у игрока нет записей». Важнее
-- всего это для downloadUrlToFile — транспорт не сообщает HTTP-коды вовсе,
-- поэтому 404 приходилось узнавать по телу. Раньше такое тело считалось
-- ошибкой запроса: failStreak рос, воркер уходил в бэкофф и переключал
-- транспорт, а ник дёргался вечно (баг-репорт «ошибок: 141»).
local function apiErrorIsNoData(data)
    if type(data) ~= 'table' or type(data.errors) ~= 'table' then return false end
    local e = data.errors[1]
    if type(e) ~= 'table' then return false end
    if tostring(e.code or ''):upper() == 'NOT_FOUND' then return true end
    return tostring(e.message or ''):find('Данные отсутствуют', 1, true) ~= nil
end

-- GET с таймаутом ~15 с. Вызывать только из lua_thread.
-- Основной путь - downloadUrlToFile: сама загрузка идёт в фоновом потоке
-- MoonLoader, а здесь мы лишь ждём статус короткими уступами wait(), не
-- блокируя кадр игры. requests оставлен запасным: он останавливает
-- вызывающий поток на весь запрос (DNS + TLS + тело ответа).
local function apiGetNow(path, params)
    local url = apiUrl(path, params)
    local used = apiTransport()
    if used == 'downloadUrlToFile' then
        -- каждому запросу свой временный файл: брошенная прошлая загрузка
        -- (после обрыва/таймаута) дописывает свой файл и не портит чужой ответ
        api.attempt = api.attempt + 1
        local tmp = DIR .. '\\api_' .. tostring(api.attempt) .. '.json'
        for old = 1, api.attempt - 1 do           -- подметаем следы прошлых попыток
            os.remove(DIR .. '\\api_' .. tostring(old) .. '.json')
        end
        os.remove(DIR .. '\\api_response.json')   -- legacy-имя до 2.0.5
        local state, lastCode, cbTick, seenData, cbFired = 'wait', nil, 0, false, false
        local cbCount = 0
        api.lastCodes = {}                 -- история статусов этого запроса
        local ok = pcall(downloadUrlToFile, url, tmp, function(_, st)
            api.lastCode = st
            lastCode = st
            cbFired = true
            cbCount = cbCount + 1
            local lc = api.lastCodes
            lc[#lc + 1] = st
            if #lc > 8 then table.remove(lc, 1) end
            if type(st) ~= 'number' or st < 1 or st > DL_CODE_MAX then
                local key = tostring(st)
                if not dlWeirdLogged[key] then
                    dlWeirdLogged[key] = true
                    pcall(logEvent, 'API: downloadUrlToFile прислал неизвестный статус '
                        .. key .. ' - готовность ответа проверяется по телу файла')
                end
            end
            if DL_DONE[st] then state = 'done'
            elseif DL_DATA[st] then seenData = true end
        end)
        if not ok then return apiNoteFail(used, 'downloadUrlToFile отказал') end
        -- Виток цикла ≈ 100 мс. Порог тишины ступенчатый (vitok-ов):
        --   колбэк ещё не приходил      - 100 (10 с): на старте игры WinINET,
        --     DNS и TLS греются медленно, первые статусы приходят с задержкой;
        --   статусы идут, но данных нет - 60 (6 с): маленький ответ может прийти
        --     без «данные идут», а рукопожатие с сервером может затянуться;
        --   данные пошли                - 40 (4 с): поток реально встал.
        -- Раньше всегда было 4 с: на холодном старте скрипт «не дослушивал»
        -- сеть до первого статуса и зря уходил на блокирующий requests.
        local function silenceLimit()
            if cbCount == 0 then return 100 end
            if not seenData then return 60 end
            return 40
        end
        local tries = 0
        -- Классификация тела ответа - общая для «загрузка дошла до конца» и
        -- «спасения» тела после таймаута:
        --   'ok'     - {"data": ...}             -> возвращаем таблицу;
        --   'nodata' - 404 «Данные отсутствуют»  -> полноценный ответ API;
        --   'apierr' - {"errors": ...}           -> ошибка API;
        --   'bad'    - пусто / не JSON / без полей -> транспортная неудача.
        local function classify(body)
            if not body or body == '' then return 'bad', nil, 'пустой ответ' end
            local d, derr = json.decode(body)
            if type(d) ~= 'table' then
                return 'bad', nil, 'ответ не JSON: ' .. tostring(derr)
            end
            if d.errors then
                -- 404 «Данные отсутствуют» — полноценный ответ: игрока нет в
                -- журнале, повторять запрос бессмысленно, транспорт здоров.
                if apiErrorIsNoData(d) then return 'nodata', d end
                return 'apierr', d,
                    tostring((d.errors[1] and d.errors[1].message) or 'ошибка API')
            end
            if d.data == nil then return 'bad', nil, 'ответ без data' end
            return 'ok', d
        end
        local function verdict(kind, d, err, fallbackMsg)
            if kind == 'ok'     then apiNoteOk(); return d end
            if kind == 'nodata' then apiNoteOk(); return nil, 'нет данных' end
            if kind == 'apierr' then return apiNoteFail(used, err) end
            return apiNoteFail(used, fallbackMsg or err)
        end
        -- Готовое тело на диске - главный признак конца запроса: словарь
        -- статусов отличается от сборки к сборке, а JSON Evolve Logs узнаваем
        -- всегда. Проверяем прямо в ожидании: незнакомые коды больше не
        -- держат запрос до порога тишины.
        local function bodyReady()
            local body = readFile(tmp)
            local kind, d, err = classify(body)
            if kind == 'ok' or kind == 'nodata' or kind == 'apierr' then
                return body, kind, d, err
            end
            return nil
        end
        -- Даже «неудачная» загрузка могла записать тело ответа в файл
        -- (WinINET сохраняет и тела HTTP-ошибок). Перед тем как объявить
        -- запрос проваленным, проверяем содержимое: это и есть проверка
        -- «получили мы информацию или нет».
        local function salvage(msg)
            local body = readFile(tmp)
            os.remove(tmp)
            local kind, d, err = classify(body)
            return verdict(kind, d, err, msg)
        end
        local contentBody, contentKind, contentData, contentErr
        while state == 'wait' and tries < 150 do
            local wok = pcall(wait, 100)
            if not wok then return apiNoteFail(used, 'ожидание вне потока') end
            tries = tries + 1
            if cbFired then cbFired = false; cbTick = tries end
            if cbCount > 0 then
                contentBody, contentKind, contentData, contentErr = bodyReady()
                if contentBody then state = 'done' end
            end
            if state == 'wait' and (tries - cbTick) > silenceLimit() then
                api.diag = { cb = cbCount, silence = tries - cbTick,
                             limit = silenceLimit() }
                return salvage(string.format(
                    'сеть молчит %d с после статуса %s',
                    silenceLimit() / 10, tostring(lastCode)))
            end
        end
        api.diag = { cb = cbCount, silence = tries - cbTick,
                     limit = silenceLimit() }
        if state == 'wait' then
            return salvage('таймаут 15 с (статус ' .. tostring(lastCode) .. ')')
        end
        local body, kind, data, err = contentBody, contentKind, contentData, contentErr
        if not body then
            -- Гонка финального статуса (6/58): он может прийти на пару сотен
            -- миллисекунд раньше, чем файл закроется и дочитается. Без
            -- дожидалки это выглядело как «пустой ответ», рвало failStreak и
            -- уводило транспорт на блокирующий requests (фризы игры).
            for _ = 1, 25 do
                body, kind, data, err = bodyReady()
                if body then break end
                local wok2 = pcall(wait, 100)
                if not wok2 then break end
            end
        end
        if not body then
            return salvage('тело ответа не получено (статус '
                .. tostring(lastCode) .. ')')
        end
        os.remove(tmp)
        return verdict(kind, data, err)
    end
    if used ~= 'requests' then return nil, 'нет транспорта для запроса' end
    -- timeout 6 с: requests блокирует кадр на весь запрос, поэтому в запасном
    -- режиме ограничиваем длину одной «подморозки» игры.
    local ok, res = pcall(requests.get, url, { timeout = 6 })
    if not ok or not res then
        return apiNoteFail(used, 'запрос не прошёл: ' .. tostring(res))
    end
    if res.status_code == 404 then apiNoteOk(); return nil, 'нет данных' end
    if res.status_code == 422 then
        return apiNoteFail(used, 'сервер ждёт requester')
    end
    if res.status_code ~= 200 then
        return apiNoteFail(used, 'HTTP ' .. tostring(res.status_code))
    end
    local data, err = json.decode(res.text or '')
    if not data then
        return apiNoteFail(used, 'ответ не JSON: ' .. tostring(err))
    end
    if data.errors then
        if apiErrorIsNoData(data) then apiNoteOk(); return nil, 'нет данных' end
        return apiNoteFail(used,
            tostring((data.errors[1] and data.errors[1].message) or 'ошибка API'))
    end
    apiNoteOk()
    return data
end

-- ------------------------------------------------ применение ответов ------

-- Последняя запись журнала: официальный ранг, дата и инициатор события.
local function applyJournal(m, d)
    if type(m) ~= 'table' or type(d) ~= 'table' then return false end
    local kind, rank = parseApiRank(d.new_rank)
    local at = parseApiDate(d.event_date)
    if kind == 'uninvite' then
        m.dismissed = true
        m.dismissedAt = at or m.dismissedAt
        m.dismissReason = d.reason or m.dismissReason
    elseif kind == 'number' then
        m.rank = math.max(1, math.min(MAX_RANK, rank))
        m.promotedAt = at or m.promotedAt
        if at then m.acceptedApprox = false end   -- точная дата из журнала
        if m.dismissed then m.dismissed = false; m.dismissedAt = nil end
    end
    m.lastInitiator = d.initiator_nickname or m.lastInitiator
    m.lastReason    = d.reason or m.lastReason
    m.apiEvent      = d.event_date or m.apiEvent
    m.apiFetchedAt  = os.time()
    return true
end

-- Полная история: дата/инициатор принятия и лента событий для карточки.
local function applyHistory(m, list)
    if type(m) ~= 'table' or type(list) ~= 'table' then return false end
    local ev = {}
    for _, d in ipairs(list) do
        if type(d) == 'table' then
            ev[#ev + 1] = {
                at     = parseApiDate(d.event_date),
                date   = d.event_date or '',
                prev   = d.previous_rank or '',
                new    = d.new_rank or '',
                by     = d.initiator_nickname or '',
                reason = d.reason or '',
            }
        end
    end
    table.sort(ev, function(a, b) return (a.at or 0) < (b.at or 0) end)
    m.apiHistory = ev
    for _, e in ipairs(ev) do
        local pkind = parseApiRank(e.prev)
        if pkind == 'invite' then
            if e.at and (not m.acceptedAt or m.acceptedAt == 0 or e.at < m.acceptedAt) then
                m.acceptedAt = e.at
                m.acceptedApprox = false          -- официальная дата принятия
                if e.by ~= '' then m.acceptedBy = e.by end
            end
        end
    end
    m.apiHistoryAt = os.time()
    return true
end

-- ------------------------------------------------ очереди и воркер --------

local function queueRefresh(nick, wantHistory)
    if not nick or nick == '' then return end
    api.gaveUp[nick] = nil        -- явный запрос отменяет откат после неудач
    if api.queued[nick] then return end
    api.queued[nick] = wantHistory and 2 or 1
    if wantHistory then
        api.histQueue[#api.histQueue + 1] = nick
    else
        api.queue[#api.queue + 1] = nick
    end
end

-- -------------------------------------------------- повторы запросов ------
-- Нюанс API: на один и тот же ник он может ответить и с первого раза, и с
-- третьего (сеть, лимиты, сбой транспорта), поэтому исход каждого запроса
-- проверяется и делится на три вида:
--   'ok'     - данные получены и применены;
--   'nodata' - сервер определённо ответил «записей нет» (404/пустая история):
--              повторять бессмысленно, ник помечается apiMissing;
--   'retry'  - ответа нет (сбой сети/транспорта): ник ставится на повтор
--              с удваивающейся паузой, после исчерпания попыток - откат.

local function retryDelay(n)
    local base = cfg.api.retryPause or 4
    return math.min(30, base * (2 ^ (math.max(n or 1, 1) - 1)))
end

local function retryClear(nick)
    api.tries[nick], api.retryAt[nick], api.retryKind[nick], api.gaveUp[nick] =
        nil, nil, nil, nil
end

local function retrySchedule(nick, kind)
    if (cfg.api.retries or 0) <= 0 then return false end
    local n = (api.tries[nick] or 0) + 1
    api.retried = api.retried + 1
    if n > cfg.api.retries then
        api.tries[nick], api.retryAt[nick], api.retryKind[nick] = nil, nil, nil
        api.gaveUp[nick] = os.time() + (cfg.api.giveUp or 600)
        api.gaveUpN = api.gaveUpN + 1
        pcall(logEvent, string.format(
            'API: %s - нет ответа после %d попыток, повтор через %d с',
            nick, cfg.api.retries, cfg.api.giveUp or 600))
        return false
    end
    api.tries[nick], api.retryKind[nick] = n, kind or 'journal'
    api.retryAt[nick] = os.time() + retryDelay(n)
    return true
end

-- Сколько ников ждут повтора и сколько в откате прямо сейчас.
local function retryPending()
    local n = 0
    for _ in pairs(api.retryAt) do n = n + 1 end
    return n
end

local function gaveUpPending(now)
    local n = 0
    for nick, untilAt in pairs(api.gaveUp) do
        if now and now < untilAt then n = n + 1 else api.gaveUp[nick] = nil end
    end
    return n
end

local function dequeue(list)
    local nick = list[1]
    if not nick then return nil end
    table.remove(list, 1)
    api.queued[nick] = nil
    return nick
end

-- Кто протух по TTL, если явных запросов нет. Ники с назначенным повтором,
-- в очереди или в откате после серии неудач не трогаем: у них свой график.
local function nextDueNick(now)
    local ttl = cfg.api.ttl
    local best, bestAge = nil, nil
    for nick, m in pairs(roster.members) do
        local giveUp = api.gaveUp[nick]
        if giveUp and now < giveUp then
            -- ещё в откате: пропускаем
        elseif not api.retryAt[nick] and not api.queued[nick] then
            if giveUp then api.gaveUp[nick] = nil end
            local age = now - (m.apiFetchedAt or 0)
            if age >= ttl and (bestAge == nil or age > bestAge) then
                best, bestAge = nick, age
            end
        end
    end
    return best
end

-- Чей повтор созрел (берём самый ранний по времени).
local function nextRetryNick(now)
    local best, bestAt = nil, nil
    for nick, at in pairs(api.retryAt) do
        if not roster.members[nick] then
            retryClear(nick)                 -- сотрудника уже нет в журнале
        elseif not api.queued[nick] and now >= at and (bestAt == nil or at < bestAt) then
            best, bestAt = nick, at
        end
    end
    return best
end

local function refreshJournal(nick)
    local m = roster.members[nick]
    if not m then retryClear(nick); return 'gone' end
    api.busy = true
    local data, err = apiGetNow('/v1/journal', {
        player = nick, fraction = API_FACTION, server = API_SERVER,
        requester = apiRequester(),
    })
    local verdict
    if data and data.data then
        applyJournal(m, data.data)
        api.fetched = api.fetched + 1
        api.lastOk = os.time()
        api.lastErr = nil
        if not m.apiHistory then queueRefresh(nick, true) end
        saveRoster()
        retryClear(nick)
        verdict = 'ok'
    elseif err == 'нет данных' then
        -- игрока нет в журнале: помечаем, чтобы не дёргать API зря
        m.apiFetchedAt = os.time()
        m.apiMissing = true
        api.noData = api.noData + 1
        api.lastErr = nil
        retryClear(nick)
        verdict = 'nodata'
    else
        api.errors = api.errors + 1
        api.lastErr = tostring(err or 'неизвестная ошибка')
        retrySchedule(nick, 'journal')
        verdict = 'retry'
    end
    api.busy = false
    return verdict
end

local function refreshHistory(nick)
    local m = roster.members[nick]
    if not m then retryClear(nick); return 'gone' end
    api.busy = true
    local data, err = apiGetNow('/v1/journal/history', {
        player = nick, fraction = API_FACTION, server = API_SERVER,
        requester = apiRequester(),
    })
    local verdict
    if data and data.data then
        applyHistory(m, data.data)
        api.fetched = api.fetched + 1
        api.lastOk = os.time()
        api.lastErr = nil
        saveRoster()
        retryClear(nick)
        verdict = 'ok'
    elseif err == 'нет данных' then
        api.noData = api.noData + 1
        api.lastErr = nil
        retryClear(nick)
        verdict = 'nodata'
    else
        api.errors = api.errors + 1
        api.lastErr = tostring(err or 'неизвестная ошибка')
        retrySchedule(nick, 'history')
        verdict = 'retry'
    end
    api.busy = false
    return verdict
end

-- Тихая проба фонового транспорта: один настоящий запрос через
-- downloadUrlToFile. Ожил (пришли данные или определённое «записей нет») -
-- возвращаемся на него: кадр снова не блокируется. Снова молчит - остаёмся
-- на requests без сообщения в чат. Исход пробы решаем по ответу, а не по
-- счётчику неудач: порог авто-переключения асимметричный (8), и старый трюк
-- «prefFails = 1, чтобы вторая неудача переключила» больше не работает.
local function probeDownloadTransport()
    if not apiHasTransport('downloadUrlToFile') then return end
    api.probeAt = os.time()
    api.quiet = true
    api.pref, api.prefFails = 'downloadUrlToFile', 0
    local pok, data, err = pcall(apiGetNow, '/v1/journal', {
        player = apiRequester(), fraction = API_FACTION, server = API_SERVER,
        requester = apiRequester(),
    })
    api.quiet = false
    local alive = pok and (data ~= nil or err == 'нет данных')
    if alive then
        api.pref, api.prefFails = 'downloadUrlToFile', 0
    else
        api.pref, api.prefFails = 'requests', 0
    end
end

local function startApiWorker()
    if not lua_thread then return end
    lua_thread.create(function()
        -- Прогрев: на старте игры/подключения к серверу WinINET, DNS и TLS
        -- ещё холодные, первые статусы downloadUrlToFile приходят с большой
        -- задержкой. Первые 5 с сеть вообще не трогаем, чтобы не принимать
        -- холодный старт за обрыв и не уходить на блокирующий requests.
        pcall(wait, 5000)
        while true do
            -- 260 мс - серверный лимит 4 запроса/с; при сериях неудач пауза
            -- растёт (бэкофф), чтобы не спамить ошибками и не дёргать сеть
            wait(workerPauseMs())
            if cfg.api.enabled and not api.busy and apiTransport() ~= 'нет транспорта' then
                -- Сидим на блокирующем requests (крайняя мера) - раз в 5 минут
                -- тихо проверяем, не ожил ли фоновый транспорт. До 2.0.13 проба
                -- ждала пустых очередей, а они из-за TTL почти никогда не
                -- пустуют: скрипт залипал на requests до конца сессии (фризы).
                if cfg.api.transport == 'auto' and api.pref == 'requests'
                    and os.time() - api.probeAt >= 300 then
                    probeDownloadTransport()
                end
                -- Приоритет: явные очереди -> созревшие повторы -> TTL.
                local nick, kind = dequeue(api.histQueue), nil
                if nick then kind = 'history'
                else
                    nick = dequeue(api.queue)
                    if nick then kind = 'journal' end
                end
                if not nick then
                    nick = nextRetryNick(os.time())
                    if nick then
                        kind = api.retryKind[nick] or 'journal'
                        api.retryAt[nick] = nil   -- при неудаче назначится снова
                    end
                end
                if not nick then
                    nick = nextDueNick(os.time())
                    if nick then kind = 'journal' end
                end
                if nick then
                    -- pcall: ошибка одного запроса не должна убивать воркер
                    local fn = (kind == 'history') and refreshHistory or refreshJournal
                    local ok, err = pcall(fn, nick)
                    if not ok then api.lastErr = tostring(err) end
                end
            end
        end
    end)
end

-- Перехват /members: найденные ники уходят в очередь API. Крючки объявлены
-- в PURE-секции, чтобы разбор состава был тестируем без сети и SAMP.
MEMBERS_HOOKS.refresh = function(nick, wantHistory) queueRefresh(nick, wantHistory) end
MEMBERS_HOOKS.say = function(text) pcall(say, text) end

-- Публичный доступ: команды, консоль MoonLoader и тесты.
SFNLogs.api = {
    state        = api,
    transport    = apiTransport,
    requester    = apiRequester,
    refresh      = queueRefresh,
    refreshAll   = function(withHistory)
        for nick in pairs(roster.members) do queueRefresh(nick, withHistory) end
    end,
    applyJournal = applyJournal,
    applyHistory = applyHistory,
    get          = apiGetNow,
    status       = function()
        return {
            busy = api.busy, err = api.lastErr, lastOk = api.lastOk,
            queue = #api.queue + #api.histQueue,
            fetched = api.fetched, errors = api.errors,
            transport = apiTransport(),
            transportCfg = cfg.api.transport,
            failStreak = api.failStreak, switched = api.switched,
            lastCode = api.lastCode,
            lastCodes = api.lastCodes,
            diag = api.diag, probeAt = api.probeAt,
            faction = API_FACTION, server = API_SERVER,
            noData = api.noData, retried = api.retried,
            retries = retryPending(), gaveUp = gaveUpPending(os.time()),
            maxRetries = cfg.api.retries, retryPause = cfg.api.retryPause,
        }
    end,
    pauseMs = workerPauseMs,
    probe = probeDownloadTransport,
    -- Повторы и ручной прогон одного ника (консоль MoonLoader, тесты).
    refreshNow   = refreshJournal,
    historyNow   = refreshHistory,
    retryDelay   = retryDelay,
    retryPending = retryPending,
    nextRetry    = nextRetryNick,
    dueNick      = nextDueNick,
}

-- ============================================== АВТООБНОВЛЕНИЕ (сеть) =====
--
-- Загрузка и установка живут вне PURE-секции: здесь downloadUrlToFile,
-- файловая система и lua_thread. Всё делается в фоновом потоке, поэтому кадр
-- игры не блокируется даже на запасном транспорте requests.

local update = {
    busy    = false,      -- идёт проверка/загрузка
    checked = 0,          -- сколько проверок сделано за сессию
    errors  = 0,          -- сколько из них закончились ошибкой
    lastAt  = 0,          -- когда последняя проверка завершилась
}

-- Путь к собственному файлу скрипта. MoonLoader даёт его через
-- thisScript().filename; если поля нет (старая сборка/тесты) - ищем SFNLogs.lua
-- в корне moonloader. Отдельный файл не пишем: путь нужен только для замены.
local function updateScriptPath()
    local ok, scr = pcall(thisScript)
    if ok and type(scr) == 'table' then
        local f = scr.filename
        if type(f) == 'string' and f ~= '' then return f end
    end
    local wd = (getWorkingDirectory and getWorkingDirectory()) or '.'
    return wd .. '\\SFNLogs.lua'
end

local function updateUrl()
    local u = cfg.update and cfg.update.url
    if type(u) == 'string' and u ~= '' then return u end
    return UPDATE_URL_DEFAULT
end

-- Скачать обновление. Возвращает текст файла или nil + причину.
-- Транспорт тот же, что у API: фоновый downloadUrlToFile, запасной -
-- блокирующий requests (в фоновом потоке он безопасен).
--
-- Готовность ответа определяется и по финальному статусу (6/58), и по телу на
-- диске - ровно как в API-слое (фикс 2.0.13): словарь статусов download_status
-- отличается от сборки к сборке, а текст скрипта узнаваем всегда.
--
-- ВАЖНО: временный файл НЕ удаляется здесь. Его путь попадает в
-- updateState.pendingPath, а читает и убирает его только установка - иначе
-- отложенная установка (обновление скачано в прошлой сессии, игрок ставит его
-- после перезапуска) не находила файл. На старте загрузки вчерашний остаток,
-- наоборот, стирается: без этого молчащая загрузка выглядела бы успешной.
local function updateDownload(url, tmp)
    if type(downloadUrlToFile) == 'function' then
        local state, fired, tick, count = 'wait', false, 0, 0
        local ok = pcall(downloadUrlToFile, url, tmp, function(st)
            fired = true; count = count + 1
            if DL_DONE[st] then state = 'done' end
        end)
        if not ok then return nil, 'downloadUrlToFile отказал' end
        local function ready()
            local body = readFile(tmp)
            if body and #body >= UPDATE_MIN_BYTES
               and body:find('script_version(', 1, true) then
                return body
            end
            return nil
        end
        local tries = 0
        while state == 'wait' and tries < 150 do
            if not pcall(wait, 100) then return nil, 'ожидание вне потока' end
            tries = tries + 1
            if fired then fired = false; tick = tries end
            if count > 0 and ready() then state = 'done'; break end
            if (tries - tick) > (count == 0 and 100 or 60) then
                break       -- сеть молчит: проверим, не записалось ли тело
            end
        end
        local body = ready()
        if body then return body end
        -- тело могло записаться частично (обрыв соединения) или оказаться
        -- страницей ошибки: говорим конкретно, что именно не так
        local got = readFile(tmp)
        if got and got ~= '' then
            if #got < UPDATE_MIN_BYTES then
                return nil, string.format(
                    'загрузка оборвалась: получено %d байт из нужных %d',
                    #got, UPDATE_MIN_BYTES)
            end
            return nil, 'скачанный файл не похож на скрипт (нет script_version)'
        end
        return nil, string.format('файл не скачался (статусов: %d, ждали %d с)',
                                  count, math.floor(tries / 10))
    end
    if okRequests and requests then
        local ok, res = pcall(requests.get, url, { timeout = 15 })
        if not ok or not res then return nil, 'запрос не прошёл: ' .. tostring(res) end
        if res.status_code ~= 200 then
            return nil, 'HTTP ' .. tostring(res.status_code)
        end
        local text = res.text or ''
        -- запасной транспорт отдаёт тело строкой: кладём его во временный файл,
        -- чтобы путь установки был одинаковым для обоих транспортов
        if writeFile(tmp, text) then return text end
        return nil, 'не удалось сохранить скачанный файл'
    end
    return nil, 'нет транспорта для загрузки'
end

-- Одна проверка: скачать, проверить, решить (поставить сразу или предложить).
-- Возвращает nil при успехе (сообщение в чат уже отправлено) или текст ошибки.
local updateInstall

local function updateCheck(force)
    if update.busy then return 'проверка уже идёт' end
    if not cfg.update or not cfg.update.enabled then
        return 'автообновление выключено (config.ini, [update] enabled = 1)'
    end
    update.busy = true
    update.checked = update.checked + 1
    local url = updateUrl()
    local tmp = DIR .. '\\update.lua.new'
    os.remove(tmp)                       -- вчерашний остаток не должен «выстрелить»
    local body, why = updateDownload(url, tmp)
    update.lastAt = os.time()
    updateState.lastCheck = update.lastAt
    if not body then
        os.remove(tmp)
        update.errors = update.errors + 1
        updateState.lastError = tostring(why)
        saveUpdateState()
        update.busy = false
        return updateState.lastError
    end
    local ver, verr = validateScriptText(body, SFN_VERSION_STR)
    if not ver then
        os.remove(tmp)
        update.errors = update.errors + 1
        updateState.lastError = tostring(verr)
        updateState.available, updateState.ready = '', false
        saveUpdateState()
        update.busy = false
        return updateState.lastError
    end
    -- файл скачан и прошёл все проверки: его можно ставить
    updateState.available   = ver
    updateState.ready       = true
    updateState.pendingPath = tmp
    updateState.lastError   = ''
    saveUpdateState()
    update.busy = false

    local auto = cfg.update.auto ~= false
    if not auto then
        if updateState.notified ~= ver then
            updateState.notified = ver
            saveUpdateState()
            pcall(say, string.format(
                '{66FF66}[SFN Logs] есть обновление %s -> %s. Поставить: «Настройки» -> «ПОСТАВИТЬ ОБНОВЛЕНИЕ» или /sfnlogupdate install',
                SFN_VERSION_STR, ver))
        end
        return nil
    end
    local ok, err = updateInstall()
    if not ok then return err end
    return nil
end

-- Установка: бэкап текущего файла -> проверка, что бэкап реально записался ->
-- перенос нового файла на его место. Возвращает true или nil + причину.
-- реализация присваивается forward-объявленному updateInstall ниже
local function updateDoInstall()
    if not updateState.ready or updateState.pendingPath == '' then
        return nil, 'нечего ставить: сначала проверьте обновления'
    end
    local body = readFile(updateState.pendingPath)
    if not body or body == '' then
        updateState.ready, updateState.pendingPath = false, ''
        saveUpdateState()
        return nil, 'файл обновления пропал - проверьте ещё раз'
    end
    -- проверяем второй раз: файл мог лежать на диске с прошлой сессии, а
    -- текущая версия за это время уже догнать его
    local ver, verr = validateScriptText(body, SFN_VERSION_STR)
    if not ver then
        os.remove(updateState.pendingPath)
        updateState.ready, updateState.pendingPath = false, ''
        updateState.lastError = tostring(verr)
        saveUpdateState()
        return nil, verr
    end
    local target = updateScriptPath()
    local bak = target .. '.bak'
    local cur = readFile(target)
    if cur and cur ~= '' then
        if not writeFile(bak, cur) then
            return nil, 'не удалось сохранить резервную копию ' .. bak
        end
        local back = readFile(bak)
        if not back or #back ~= #cur then
            return nil, 'резервная копия не записалась - замена отменена'
        end
    end
    if not writeFile(target, body) then
        return nil, 'не удалось записать ' .. target
            .. ' (файл занят или нет прав на запись)'
    end
    local written = readFile(target)
    if not written or #written ~= #body then
        -- откатываемся: без этого пользователь остался бы с обрезанным скриптом
        if cur and cur ~= '' then pcall(writeFile, target, cur) end
        return nil, 'файл записался не полностью - возвращена старая версия'
    end
    os.remove(updateState.pendingPath)
    updateState.ready, updateState.pendingPath = false, ''
    updateState.installedAt, updateState.installedVer = os.time(), ver
    updateState.notified = ver
    saveUpdateState()
    return true, ver
end

-- связываем forward-объявление с реализацией
updateInstall = updateDoInstall

-- Фоновый поток проверки обновлений. Пауза в 20 с на старте: пусть сначала
-- отработает API-воркер (он тоже греет WinINET/DNS/TLS) и прогрузится игра.
local function startUpdateWorker()
    if not lua_thread then return end
    lua_thread.create(function()
        pcall(wait, 20000)
        while true do
            if needUpdateCheck(os.time(), false) and not update.busy then
                local err = updateCheck(false)
                if err then pcall(logEvent, 'обновление: ' .. tostring(err)) end
            end
            pcall(wait, 60000)
        end
    end)
end

-- Публичный доступ: кнопки настроек, /sfnlogupdate и тесты.
SFNLogs.update = {
    state      = update,
    info       = updateState,
    url        = updateUrl,
    path       = updateScriptPath,
    check      = updateCheck,
    install    = updateDoInstall,
    needCheck  = needUpdateCheck,
    validate   = validateScriptText,
    loadState  = loadUpdateState,
    saveState  = saveUpdateState,
    status     = function()
        return {
            enabled = (cfg.update and cfg.update.enabled) and true or false,
            auto    = (cfg.update and cfg.update.auto ~= false),
            url     = updateUrl(),
            current = SFN_VERSION_STR,
            available = updateState.available,
            ready   = updateState.ready and true or false,
            pending = updateState.pendingPath,
            lastCheck = updateState.lastCheck,
            lastError = updateState.lastError,
            installedAt = updateState.installedAt,
            installedVer = updateState.installedVer,
            busy    = update.busy,
            checked = update.checked,
            errors  = update.errors,
            target  = updateScriptPath(),
        }
    end,
}

-- ===================================================== ImGui ОКНО ========
--
-- Оформление — визуальный язык Evolve Logs (скриншот v1.0.0 и исходники
-- modules/ui.lua): тёмный сайдбар 160 px с логотипом и градиентными кнопками
-- меню, малиновый акцент 0.725/0.180/0.263, полоса раздела с градиентом (без
-- значка «‹» — он читался как несуществующая кнопка «назад»), таблица с
-- тонкими вертикальными разделителями и центрированными
-- заголовками, шрифты arial 13 / arial 15.5 / trebucbd 20 и иконки
-- FontAwesome 6, влитые в дефолтный шрифт.
--
-- При этом раскладка остаётся на нашем движке, а не на их фиксированных
-- числах: ширины колонок измеряются по тексту, все размеры умножаются на
-- GetDpiScale(), окно пересчитывается под содержимое (но не меньше их
-- 1030x520). SetCursorScreenPos не используется: в ImGui он меняет X всей
-- следующей строки, из-за чего вёрстка «уезжает».
--
-- Если в сборке mimgui чего-то не окажется (шрифты, иконки, примитивы),
-- окно деградирует до текстового вида и пишет об этом в чат, а не падает.

local win = imgui.new.bool(false)

-- ---------------------------------------------------------- палитра -------
-- Значения взяты из modules/ui.lua их проекта (DarkTheme + drawSideMenu).

local function RGBf(r, g, b, a) return imgui.ImVec4(r, g, b, a or 1.0) end

local C = {
    text       = RGBf(1.00, 1.00, 1.00),
    textDim    = RGBf(0.60, 0.60, 0.60),   -- неактивные пункты меню
    textFaint  = RGBf(0.36, 0.42, 0.47),   -- TextDisabled из их темы
    bg         = RGBf(0.07, 0.07, 0.07),
    sidebar    = RGBf(0.094, 0.094, 0.102),
    frame      = RGBf(0.12, 0.12, 0.12),
    frameHov   = RGBf(0.25, 0.25, 0.26),
    border     = RGBf(0.25, 0.25, 0.26, 0.54),
    lineSoft   = RGBf(0.16, 0.16, 0.17),
    accent     = RGBf(0.725, 0.180, 0.263),-- малиновый акцент Evolve Logs
    accentText = RGBf(0.90, 0.30, 0.30),   -- текст полос раздела
    gradA1     = RGBf(0.90, 0.20, 0.30, 0.50),
    gradA2     = RGBf(1.00, 0.50, 0.60, 0.00),
    gradI1     = RGBf(0.60, 0.60, 0.60, 0.00),
    gradI2     = RGBf(0.40, 0.40, 0.40, 0.00),
    ready      = RGBf(0.20, 0.85, 0.45),
    soon       = RGBf(1.00, 0.77, 0.24),
    blocked    = RGBf(0.95, 0.35, 0.35),
    info       = RGBf(0.45, 0.65, 0.90),
    violet     = RGBf(0.66, 0.55, 1.00),
}

-- Цвет -> U32. ВАЖНО: в mimgui Vec4-перегрузкой является ColorConvertFloat4ToU32
-- (или GetColorU32Vec4), а imgui.GetColorU32 принимает только U32 и на ImVec4
-- бросает ошибку — из-за этого окно и деградировало в текстовый режим.
-- Рабочая функция определяется один раз при старте.
local colorToU32
do
    local probe = imgui.ImVec4(1, 1, 1, 1)
    for _, f in ipairs({ imgui.ColorConvertFloat4ToU32, imgui.GetColorU32Vec4, imgui.GetColorU32 }) do
        if f and pcall(f, probe) then colorToU32 = f break end
    end
end
local function CU(v)
    if type(v) == 'number' then return v end
    if not colorToU32 then return 0xFFFFFFFF end
    local ok, c = pcall(colorToU32, v)
    return ok and c or 0xFFFFFFFF
end
local function V(x, y) return imgui.ImVec2(x, y) end
local function withA(col, a) return imgui.ImVec4(col.x, col.y, col.z, a) end

-- Ранговые цвета для полоски слева от строки и цветных значений.
local function rankColor(r)
    if r >= 10 then return C.accent end
    if r >= 7 then return C.violet end
    if r >= 4 then return C.info end
    return C.textDim
end

-- --------------------------------------------------------- масштаб --------

local dpiScale = 1.0
local PADX_BASE = 8          -- горизонтальный паддинг из базового стиля
local PADX = 8               -- а это то, что реально запушено темой (S(5))
local textCache = {}
local function refreshScale()
    local s = imgui.GetDpiScale and imgui.GetDpiScale()
    if type(s) == 'number' and s >= 0.5 and s <= 8 and s ~= dpiScale then
        dpiScale = s
        textCache = {}
    end
    -- базовый паддинг читаем из стиля: он понадобится, если в сборке mimgui
    -- не окажется PushStyleVar(WindowPadding) и тема не сможет его задать
    local okst, st = pcall(imgui.GetStyle)
    if okst and st and st.WindowPadding then
        local px = st.WindowPadding.x
        if type(px) == 'number' and px >= 0 and px <= 64 then
            PADX_BASE = px
            PADX = px
        end
    end
end
local function S(v) return v * dpiScale end

local SPACING_Y = 5          -- ItemSpacing их темы (5,5)
local lineH, rowH, frameH = 16, 24, 23

-- ------------------------------------------------------- примитивы -------

local dl_ok = true
local function pdraw(f, ...)
    if not dl_ok or not f then return false end
    local ok = pcall(f, ...)
    if not ok then dl_ok = false end
    return ok
end

local function winDL() return imgui.GetWindowDrawList() end

local function textW(s)
    if s == nil or s == '' then return 0 end
    local c = textCache[s]
    if c then return c end
    local sz = imgui.CalcTextSize(s)
    local w = (sz and sz.x) or 0
    textCache[s] = w
    return w
end

local function fitText(s, maxW)
    s = tostring(s or '')
    if maxW <= 0 or textW(s) <= maxW then return s end
    local dots = '...'
    local wD = textW(dots)
    local lo, hi = 0, #s
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if textW(s:sub(1, mid)) + wD <= maxW then lo = mid else hi = mid - 1 end
    end
    return s:sub(1, lo) .. dots
end

local function drawText(dl, x, y, s, col)
    if not s or s == '' then return 0 end
    pdraw(dl.AddText, dl, V(x, y), CU(col or C.text), s)
    return textW(s)
end

local function drawTextClipped(dl, x, y, s, col, limitW)
    if not s or s == '' then return 0 end
    local w = textW(s)
    if limitW and limitW > 0 and w > limitW then
        --ClipRect режет глиф пополам, а соседняя колонка начинается вплотную.
        -- Поэтому сначала укорачиваем текст до «…», клип оставляем страховкой.
        s = fitText(s, limitW)
        pdraw(dl.PushClipRect, dl, V(x, y - 2), V(x + limitW, y + lineH + 2), true)
        pdraw(dl.AddText, dl, V(x, y), CU(col or C.text), s)
        pdraw(dl.PopClipRect, dl)
        return limitW
    end
    pdraw(dl.AddText, dl, V(x, y), CU(col or C.text), s)
    return w
end

-- Текст по центру отведённой ширины (как их CenterColumnText).
local function drawTextCentered(dl, x, y, s, col, w)
    local tw = textW(s)
    local ox = x + math.max(0, (w - tw) * 0.5)
    return drawTextClipped(dl, ox, y, s, col, w)
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
    pdraw(dl.AddCircleFilled, dl, V(cx, cy), r, CU(col), 16)
end

local function gradH(dl, x, y, w, h, c1, c2)
    if w <= 0 or h <= 0 then return end
    pdraw(dl.AddRectFilledMultiColor, dl, V(x, y), V(x + w, y + h),
          CU(c1), CU(c2), CU(c2), CU(c1))
end

local function cursorXY()
    local p = imgui.GetCursorScreenPos()
    return p.x, p.y
end

local function advance(dy) imgui.Dummy(V(1, dy)) end

-- Якорь строки: невидимая кнопка заданной высоты открывает строку, остальные
-- элементы ставятся в неё через SameLine. Высота блока после этого известна
-- точно и не зависит от реальных размеров виджетов (тема, DPI, шрифт).
local function anchoredRow(id, h)
    local x, y = cursorXY()
    imgui.InvisibleButton('##' .. id, V(1, h))
    return x, y
end

local function sameRow(gap) imgui.SameLine(nil, gap or 0) end
local function sameRowAt(off) imgui.SameLine(off) end

local function tip(lines)
    if not imgui.BeginTooltip or not imgui.EndTooltip then return end
    -- mimgui (cimgui): BeginTooltip возвращает НИЧЕГО -> в Lua nil. Проверка
    -- «if not imgui.BeginTooltip() then return» принимала nil за «тултип не
    -- открыт» и выходила, оставив окно тултипа ОТКРЫТЫМ: всё, что рисовалось
    -- дальше (следующая строка таблицы, кнопки, EndChild), падало в тултип,
    -- стек регионов съезжал — строки исчезали, кнопки прыгали внутрь
    -- таблицы, у мыши висела пустая рамка. Отказом считаем только явный false.
    local opened = imgui.BeginTooltip()
    if opened == false then return end
    local dl = winDL()
    local tx, ty = cursorXY()
    local wMax = 0
    for i, s in ipairs(lines) do
        wMax = math.max(wMax, drawText(dl, tx, ty + (i - 1) * lineH, s,
                                       i == 1 and C.text or C.textDim))
    end
    imgui.Dummy(V(wMax + S(4), #lines * lineH))
    imgui.EndTooltip()
end

-- ---------------------------------------------------------- иконки --------
-- FontAwesome 6 вливается в дефолтный шрифт (MergeMode в их fa.Init), поэтому
-- глифы рисуются обычным Text без PushFont — как в их коде.

local function I(name, fallback)
    local v = fa and fa[name]
    return (type(v) == 'string' and v ~= '') and v or (fallback or '')
end

-- ---------------------------------------------------------- шрифты --------

local fonts = { cum = nil, smal = nil, big = nil, ok = false }

local function pushFont(f) if f and imgui.PushFont then pcall(imgui.PushFont, f) end end
local function popFont(f) if f and imgui.PopFont then pcall(imgui.PopFont) end end

-- ------------------------------------------------------- состояние --------

local ui = {
    menu         = 1,             -- 1 Журнал, 2 Поиск, 3 Настройки, 4 О скрипте
    menuNick     = nil, openMenu  = false, menuOpenNick = nil,
    reasonDlg    = nil, openReason = false,
    historyNick  = nil, openHistory = false,
    addOpen      = imgui.new.bool(false),
    search       = '',
    apiNick      = imgui.new.char[64](),
    apiResults   = nil,            -- nil = не искали, table = строки ответа
    apiBusy      = false,
    apiErr       = nil,
    closeRect    = nil,          -- геометрия крестика закрытия (для тестов)
    closeClickedAt = nil,
}

local bufNick   = imgui.new.char[32]()
local bufBy     = imgui.new.char[32]()
local bufDay    = imgui.new.int(0)
local bufMonth  = imgui.new.int(0)
local bufYear   = imgui.new.int(0)
local bufHour   = imgui.new.int(0)
local bufMinute = imgui.new.int(0)
local bufRank   = imgui.new.int(1)
local bufReason = imgui.new.char[128]()
local refShowDismissed = imgui.new.bool(false)
local refMembersEnabled = imgui.new.bool(true)
local refAutoUpdate = imgui.new.bool(true)      -- v2.2.0: проверять обновления
local refAutoInstall = imgui.new.bool(true)     -- v2.2.0: ставить сразу

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

-- --------------------------------------------------- кнопки и меню --------

-- Кнопка в потоке: ImGui сам ведёт раскладку, графика дорисовывается в
-- координатах, снятых ДО виджета.
local function flowButton(id, label, col, onClick, w, h)
    w = w or (textW(label) + S(20))
    h = h or frameH
    local bx, by = cursorXY()
    imgui.PushStyleColor(imgui.Col.Button, C.frame)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, C.frameHov)
    imgui.PushStyleColor(imgui.Col.ButtonActive, RGBf(0.41, 0.41, 0.41))
    imgui.PushStyleColor(imgui.Col.Text, col or C.text)
    local clicked = imgui.Button(label .. '##' .. id, V(w, h))
    imgui.PopStyleColor(4)
    strokeRect(winDL(), bx, by, w, h, C.border, S(3), S(1))
    if clicked and onClick then onClick() end
    return w, clicked
end

-- Градиентная кнопка сайдбара — копия их DrawGradientButton: невидимая
-- кнопка задаёт раскладку, градиент и текст рисуются поверх.
local function gradientMenuButton(id, label, active, onClick, w, h)
    local dl = winDL()
    local x, y = cursorXY()
    local clicked = imgui.InvisibleButton('##' .. id, V(w, h))
    if active then
        gradH(dl, x, y, w, h, C.gradA1, C.gradA2)
    else
        if imgui.IsItemHovered() then
            gradH(dl, x, y, w, h, RGBf(0.25, 0.25, 0.26, 0.35), C.gradI2)
        end
    end
    pushFont(fonts.smal)
    drawTextCentered(dl, x, y + (h - S(15.5)) * 0.5, label,
                     active and C.text or C.textDim, w)
    popFont(fonts.smal)
    if active then
        -- малиновая планка справа от активного пункта (3x15, как у них)
        fillRect(dl, x + w - S(6), y + (h - S(15)) * 0.5, S(3), S(15), C.accent)
    end
    if clicked and onClick then onClick() end
    return clicked
end

-- Пункт контекстного меню строки.
local function menuItem(w, id, label, col, onClick)
    local dl = winDL()
    local h = lineH + S(8)
    local x, y = cursorXY()
    imgui.InvisibleButton('##mi' .. id, V(w, h))
    if imgui.IsItemHovered() then
        fillRect(dl, x, y, w, h, withA(C.accent, 0.18), S(3))
        fillRect(dl, x, y, S(2), h, C.accent)
    end
    drawTextClipped(dl, x + S(10), y + S(4), fitText(label, w - S(20)), col, w - S(20))
    if imgui.IsItemClicked() then onClick() end
    return h
end

-- ================================================== ДАННЫЕ ДЛЯ ТАБЛИЦ =====

local function rowCells(m, now)
    local nextAt, ready, why = promotionInfo(m, now)
    local rank = m.rank or 1
    local status, scol
    if m.dismissed then
        status, scol = 'уволен ' .. fmtDate(m.dismissedAt), C.textFaint
    elseif rank >= MAX_RANK then
        status, scol = 'макс. ранг', C.violet
    elseif ready then
        status, scol = 'МОЖНО ПОВЫШАТЬ', C.ready
    elseif why then
        status, scol = why, C.blocked
    else
        local left = (nextAt or now) - now
        status, scol = 'через ' .. fmtLeft(left), (left < 86400) and C.soon or C.textDim
    end
    local age = m.apiFetchedAt and (now - m.apiFetchedAt) or nil
    return {
        nick   = m.nick or '?',
        by     = (m.acceptedBy and m.acceptedBy ~= '') and m.acceptedBy or '—',
        rank   = string.format('%s [%d]', rankName(rank), rank),
        prom   = fmtDate(m.promotedAt),
        next   = m.dismissed and '—' or fmtDate(nextAt),
        lvl    = tostring(m.level or '—'),
        status = status,
        _m = m, _ready = ready and true or false,
        _rankCol = m.dismissed and C.textFaint or rankColor(rank),
        _statusCol = scol,
        _online = m.online and true or false,
        _age = age,
        _apiMissing = m.apiMissing and true or false,
    }
end

local JCOLS = {
    { key = 'nick',   head = 'Никнейм',          min = 130 },
    { key = 'by',     head = 'Кто принял',       min = 130 },
    { key = 'rank',   head = 'Ранг',             min = 120 },
    { key = 'prom',   head = 'Повышен',          min = 110 },
    { key = 'next',   head = 'След. повышение',  min = 140 },
    { key = 'lvl',    head = 'Ур.',              min = 46  },
    { key = 'status', head = 'Статус',           min = 140 },
}

local function measureCols(rows, cols)
    local widths = {}
    for i, c in ipairs(cols) do
        local w = textW(c.head) + S(14)
        for _, r in ipairs(rows) do
            local v = r[c.key]
            if type(v) == 'string' then
                local vw = textW(v) + S(14)
                if vw > w then w = vw end
            end
        end
        widths[i] = math.max(w, S(c.min))
    end
    return widths
end

local function rowsWidth(widths)
    local t = 0
    for _, w in ipairs(widths) do t = t + w end
    return t
end

-- Подгонка таблицы под ширину региона. Окно меряется по таблице, но внутренний
-- регион тела уже на паддинги/зазоры (~S(7)): из-за этого contentW оказывался
-- на пару пикселей шире w и включался HorizontalScrollbar — его чёрный граббер
-- выглядел как дефектная чёрная полоса под таблицей. Лишние пиксели снимаем с
-- колонок, у которых есть запас сверх минимума; настоящевой оверфлоу (сумма
-- минимумов шире региона — узкий экран) честно остаётся прокрутке.
local function fitTableWidths(widths, cols, w)
    local total = rowsWidth(widths)
    if total <= w + 0.5 then return widths, total end
    local slack, free = {}, 0
    for i, c in ipairs(cols) do
        slack[i] = math.max(0, widths[i] - S(c.min))
        free = free + slack[i]
    end
    if free <= 0.5 then return widths, total end
    local out, rem = {}, total - w
    for i = 1, #widths do out[i] = widths[i] end
    local order = {}
    for i = 1, #cols do order[#order + 1] = i end
    table.sort(order, function(a, b) return slack[a] > slack[b] end)
    for _, i in ipairs(order) do          -- срезаем с самых свободных колонок
        if rem <= 0.5 then break end
        local t = math.min(slack[i], rem)
        out[i] = out[i] - t
        rem = rem - t
    end
    return out, rowsWidth(out)
end

-- ------------------------------------------------------ полоса раздела ----

-- Полоса раздела тянется на ВСЮ ширину содержимого, как на скриншоте v1.0.0
-- (градиент гаснет вправо). Один невидимый ряд фиксированной высоты: без
-- двойного advance, из-за которого между полосой и следующим рядом зияла дыра.
--
-- v2.1.0: значок «‹» слева от подписи убран. Он достался из оформления
-- Evolve Logs, где это «назад», но у нас никакой кнопки за ним нет - значок
-- только провоцировал клик в пустое место. Подпись придвинута к левому краю.
local function sectionStrip(w, label)
    local dl = winDL()
    local x, y = cursorXY()
    gradH(dl, x, y, w, S(20), RGBf(0.9, 0.3, 0.3, 0.10), RGBf(0.4, 0.4, 0.4, 0))
    pushFont(fonts.smal)
    drawText(dl, x + S(8), y + S(2), label, C.accentText)
    popFont(fonts.smal)
    return S(20)
end

-- ================================================== САЙДБАР ==============

local SIDEBAR_W = 160
local MENU_W, MENU_H = 140, 30

-- Фирменный знак редакции (v2.2.1): векторная реконструкция логотипа —
-- малиновый круг с «брызгами» слева сверху и белой буквой E. Формы сняты
-- попиксельно с исходника assets/logo_source.jpg (800x800): подгонка круга по
-- правой/нижней дуге, связные компоненты для брызг, профили строк для буквы.
-- Координаты — в долях стороны квадрата логотипа, поэтому знак, как и раньше,
-- рисуется примитивами DrawList: масштабируется под DPI, не требует файлов в
-- moonloader и виден в SVG-превью и тестах.
local LOGO_PINK = RGBf(0.800, 0.196, 0.306)      -- фирменный малиновый (204,50,78)
local LOGO_CIRCLE = { 0.5316, 0.6000, 0.4000 }   -- cx, cy, r
-- брызги: { dx, dy, r }; первые две — доли, сросшиеся с кругом (выступы силуэта)
local LOGO_SPLASH = {
    { 0.4640, 0.2059, 0.0706 },
    { 0.1625, 0.6294, 0.0559 },
    { 0.2757, 0.3897, 0.0588 },
    { 0.3257, 0.2632, 0.0529 },
    { 0.1934, 0.5044, 0.0471 },
    { 0.3978, 0.0824, 0.0338 },
    { 0.1640, 0.3191, 0.0265 },
    { 0.2640, 0.0235, 0.0235 },
    { 0.2478, 0.0882, 0.0221 },
    { 0.0904, 0.4985, 0.0206 },
    { 0.1581, 0.2279, 0.0206 },
    { 0.0904, 0.3279, 0.0206 },
}
-- буква E: стойка и три перекладины со скруглёнными концами { dx, dy, w, h, r }
local LOGO_E = {
    { 0.4007, 0.4603, 0.1132, 0.3338, 0.0559 },
    { 0.4007, 0.4603, 0.2750, 0.0779, 0.0382 },
    { 0.4007, 0.5882, 0.2235, 0.0691, 0.0338 },
    { 0.4007, 0.7147, 0.2809, 0.0809, 0.0397 },
}

local function drawLogo(x, y)
    local dl = winDL()
    local s = S(46)
    dot(dl, x + LOGO_CIRCLE[1] * s, y + LOGO_CIRCLE[2] * s, LOGO_CIRCLE[3] * s, LOGO_PINK)
    for _, d in ipairs(LOGO_SPLASH) do
        dot(dl, x + d[1] * s, y + d[2] * s, d[3] * s, LOGO_PINK)
    end
    for _, r in ipairs(LOGO_E) do
        fillRect(dl, x + r[1] * s, y + r[2] * s, r[3] * s, r[4] * s, C.text, r[5] * s)
    end
    return s
end

local MENU_ITEMS = { 'Журнал', 'Поиск', 'Настройки', 'О скрипте' }

local function drawSidebar(h)
    local dl = winDL()
    local x, y = cursorXY()
    fillRect(dl, x, y, S(SIDEBAR_W), h, C.sidebar)

    -- строка логотипа: графика рисуется в её координатах, высота задана якорем
    local lx, ly = anchoredRow('logo', S(46))
    local ls = drawLogo(lx + S(8), ly)
    pushFont(fonts.big)
    drawTextClipped(dl, lx + S(8) + ls + S(8), ly + S(12), 'SFN Logs', C.text,
                    S(SIDEBAR_W) - ls - S(24))
    popFont(fonts.big)
    advance(S(16))

    for i, label in ipairs(MENU_ITEMS) do
        gradientMenuButton('menu' .. i, label, ui.menu == i,
                           function() ui.menu = i end, S(MENU_W), S(MENU_H))
        advance(S(6))
    end

    -- версия и состояние API внизу сайдбара (графика, поток не трогаем)
    local st = SFNLogs.api.status()
    local vy = y + h - S(40)
    drawTextClipped(dl, x + S(8), vy, 'v' .. SFN_VERSION_STR, C.textFaint, S(SIDEBAR_W) - S(16))
    local apiCol = (not cfg.api.enabled) and C.textFaint
                or (st.busy and C.soon)
                or (st.err and C.blocked)
                or C.ready
    drawTextClipped(dl, x + S(8), vy + lineH + S(2),
                    cfg.api.enabled and ('Данные: ' .. (st.busy and 'запрос...' or (st.err and 'ошибка' or 'ок')))
                                    or 'Данные: выкл',
                    apiCol, S(SIDEBAR_W) - S(16))
    return (vy + lineH * 2) - y
end

-- ================================================== ЖУРНАЛ ===============

-- «Состав из /members»: просим сервер напечатать онлайн-состав и ловим его
-- вывод построчно (membersFeed в PURE-секции). Найденные ники уйдут в
-- очередь Evolve Logs API автоматически, когда блок строк завершится.
local function sendMembersCommand()
    if not (cfg.members and cfg.members.enabled) then
        say('{FFAA00}[SFN Logs] состав из /members выключен: включите галочку в Настройках (или [members] enabled = 1 в config.ini)')
        return false
    end
    if not sampSendChat then
        say('{FF4444}[SFN Logs] sampSendChat недоступен - введите /members вручную')
        return false
    end
    if sampIsConnected and not sampIsConnected() then
        say('{FF4444}[SFN Logs] нет соединения с сервером - /members недоступен')
        return false
    end
    membersStart(os.time())
    pcall(sampSendChat, '/members')
    say('{AAAAAA}[SFN Logs] отправлен /members - слушаю ответ сервера...')
    return true
end

local function drawJournalBody(w, h, now, rows, widths)
    local dl = winDL()
    local topY = select(2, cursorXY())

    -- панель управления справа, как их поисковый ряд. Прижимаем невидимым
    -- Spacer-ом (Dummy), а не SameLine(offset): offset считается от края
    -- окна без паддингов, из-за чего подпись чекбокса резалась обрезкой.
    -- v2.0.12: кнопки «Экспорт», «+ Добавить сотрудника» и «Уровни из игры»
    -- из окна убраны по просьбе редакции: состав ведётся через API, перехват
    -- /members и команды /sfnlogadd, выгрузка - через /sfnlogexport.
    local btnW1 = textW(I('ROTATE', 'R') .. ' Обновить') + S(20)
    local btnW3 = textW(I('USERS', 'M') .. ' Состав из /members') + S(20)
    local checkW = textW('уволенные') + S(24)
    local totalW = btnW1 + S(5) + btnW3 + S(10) + checkW
    anchoredRow('jtools', frameH)
    sameRow(0)
    imgui.Dummy(V(math.max(S(4), w - totalW - S(12) - 1), 1))
    sameRow(S(6))
    flowButton('jrefresh', I('ROTATE', 'R') .. ' Обновить', C.text, function()
        SFNLogs.api.refreshAll(false)
        say('{66FF66}[SFN Logs] запрошено обновление состава из API')
    end, btnW1, frameH)
    sameRow(S(5))
    flowButton('jmembers', I('USERS', 'M') .. ' Состав из /members', C.textDim, function()
        sendMembersCommand()
    end, btnW3, frameH)
    sameRow(S(10))
    if imgui.Checkbox('уволенные', refShowDismissed) then
        cfg.showDismissed = refShowDismissed[0]
    end

    -- таблица: региону отдаём весь остаток высоты тела - ряда кнопок под
    -- таблицей больше нет (v2.0.12), список получил это место себе
    local contentW
    widths, contentW = fitTableWidths(widths, JCOLS, w)
    local headH = S(20)
    local visible = rows
    local bodyTop = select(2, cursorXY())
    local remainH = h - (bodyTop - topY)
    if remainH < S(60) then remainH = S(60) end

    local hscroll = contentW > w + 0.5 and (imgui.WindowFlags.HorizontalScrollbar or 0) or 0
    imgui.BeginChild('##jtable', V(w, remainH), false, hscroll)
    local hx, hy = cursorXY()
    local cx = hx
    for i, c in ipairs(JCOLS) do
        drawTextCentered(dl, cx, hy + S(3), c.head, C.textFaint, widths[i])
        cx = cx + widths[i]
    end
    hline(dl, hx, hy + headH, math.max(contentW, w), C.border, S(1))
    -- тонкие вертикальные разделители колонок, как в их Columns(..., true)
    cx = hx
    for i = 1, #JCOLS - 1 do
        cx = cx + widths[i]
        vline(dl, cx, hy, math.max(headH, S(20) + #visible * (rowH)), C.lineSoft, S(1))
    end
    advance(headH)

    if #visible == 0 then
        local ex, ey = cursorXY()
        imgui.Dummy(V(w, S(56)))
        drawText(dl, ex + S(6), ey + S(8), 'в журнале пока нет записей', C.textDim)
        drawText(dl, ex + S(6), ey + S(8) + lineH + S(4),
                 'нажмите «Состав из /members» - скрипт заберёт онлайн-состав фракции',
                 C.textFaint)
        drawText(dl, ex + S(6), ey + S(8) + (lineH + S(4)) * 2,
                 'игрока не в игре можно добавить во вкладке «Поиск» -> «+ В состав»',
                 C.textFaint)
    else
        for idx, r in ipairs(visible) do
            local rx, ry = cursorXY()
            imgui.InvisibleButton('##jrow' .. idx, V(math.max(contentW, w), rowH))
            local hovered = imgui.IsItemHovered()
            if hovered then fillRect(dl, rx, ry, math.max(contentW, w), rowH, RGBf(0.16, 0.16, 0.17)) end

            local cx2 = rx
            local ty = ry + (rowH - lineH) * 0.5
            pushFont(fonts.cum)
            for i, c in ipairs(JCOLS) do
                local val = tostring(r[c.key] or '')
                local col = (c.key == 'rank' and r._rankCol)
                         or (c.key == 'status' and r._statusCol)
                         or (r._m.dismissed and C.textDim) or C.text
                local tw = drawTextCentered(dl, cx2 + S(4), ty, fitText(val, widths[i] - S(8)), col, widths[i] - S(8))
                -- серый кружок «?» с подсказкой, как их CustomHint на скриншоте
                if c.key == 'status' and r._why then
                    local qx = cx2 + S(4) + tw + S(6)
                    dot(dl, qx + S(5), ty + lineH * 0.5, S(5.5), RGBf(0.5, 0.5, 0.5))
                    drawTextCentered(dl, qx, ty, '?', RGBf(0.15, 0.15, 0.15), S(10))
                end
                cx2 = cx2 + widths[i]
            end
            popFont(fonts.cum)
            if imgui.IsItemClicked() then ui.menuNick = r._m.nick; ui.openMenu = true end
            if hovered then
                local m = r._m
                local lines = { m.nick,
                    string.format('последнее событие: %s', m.apiEvent or 'нет данных'),
                    m.apiMissing and 'в журнале сервера записей нет' or
                        (r._age and ('данные обновлены ' .. fmtLeft(r._age) .. ' назад')
                                  or 'данные ещё не загружались') }
                if m.lastLogin and m.lastLogin > 0 then
                    lines[#lines + 1] = 'вход (/members): ' .. fmtDateTime(m.lastLogin)
                        .. (m.afk and ('  AFK ' .. fmtLeft(m.afk)) or '')
                end
                if m.note and m.note ~= '' then lines[#lines + 1] = 'заметка: ' .. m.note end
                lines[#lines + 1] = 'клик — меню сотрудника'
                tip(lines)
            end
        end
    end
    imgui.EndChild()
    -- v2.0.12: ряда «+ Добавить сотрудника / Уровни из игры» под таблицей нет.
    -- Добавление - /sfnlogadd и «Поиск -> В состав», уровни снимаются фоном
    -- каждые 30 секунд (refreshOnline в главном цикле).
end

-- ================================================== ПОИСК ================

local function doApiSearch()
    local nick = trim(readBuf(ui.apiNick, 64))
    if not nick:match('^[%w_]+$') then
        say('{FF4444}[SFN Logs] некорректный ник: нужны латиница, цифры, подчёркивание')
        return
    end
    if not lua_thread then say('{FF4444}[SFN Logs] lua_thread недоступен') return end
    ui.apiBusy, ui.apiErr, ui.apiResults = true, nil, nil
    lua_thread.create(function()
        local data, err = SFNLogs.api.get('/v1/journal/history', {
            player = nick, fraction = API_FACTION, server = API_SERVER,
            requester = apiRequester(),
        })
        ui.apiBusy = false
        if data and data.data then
            local list = {}
            for _, d in ipairs(data.data) do
                if type(d) == 'table' then
                    local k, rn = parseApiRank(d.new_rank)
                    local nxt = 'Неизвестно'
                    if k == 'number' and rn then
                        local need = SECONDS_TO_NEXT[rn]
                        local at = parseApiDate(d.event_date)
                        if need == 0 then nxt = '—'
                        elseif at then nxt = fmtDate(at + need) end
                    end
                    list[#list + 1] = {
                        nick = d.player_nickname or nick,
                        by   = d.initiator_nickname or '—',
                        prev = d.previous_rank or '—',
                        new  = d.new_rank or '—',
                        date = d.event_date or '—',
                        next = nxt,
                        reason = d.reason or '',
                    }
                end
            end
            ui.apiResults = list
            ui.apiErr = (#list == 0) and 'записей не найдено' or nil
        else
            ui.apiErr = tostring(err or 'ошибка запроса')
            ui.apiResults = {}
        end
    end)
end

-- Колонки как в их таблице журнала: причина события — не колонка, а подсказка
-- за серым кружком «?» у нового ранга (их CustomHint, см. скриншот v1.0.0).
local SCOLS = {
    { key = 'nick', head = 'Никнейм',             min = 130 },
    { key = 'by',   head = 'Инициатор',           min = 130 },
    { key = 'prev', head = 'Старый ранг',         min = 120 },
    { key = 'new',  head = 'Новый ранг',          min = 120 },
    { key = 'date', head = 'Последнее повышение', min = 145 },
    { key = 'next', head = 'Следующее повышение', min = 145 },
}

local function drawSearchBody(w, h)
    local dl = winDL()
    local topY = select(2, cursorXY())

    -- поисковый ряд прижат вправо, как на скриншоте v1.0.0; прижим через
    -- Spacer-Dummy, а не SameLine(offset) (offset не учитывает паддинги)
    local inputW, btnW = S(150), S(36)
    anchoredRow('srow', frameH)
    sameRow(0)
    imgui.Dummy(V(math.max(S(4), w - inputW - btnW - S(11) - 1), 1))
    sameRow(S(6))
    imgui.PushStyleColor(imgui.Col.FrameBg, C.frame)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, C.frameHov)
    imgui.PushStyleColor(imgui.Col.FrameBgActive, C.frameHov)
    imgui.PushStyleColor(imgui.Col.Text, C.text)
    pushFont(fonts.cum)
    imgui.PushItemWidth(inputW)
    local submitted = imgui.InputTextWithHint('##apinick', 'Введите никнейм', ui.apiNick, 64,
                                               imgui.InputTextFlags and (imgui.InputTextFlags.EnterReturnsTrue or 0) or 0)
    imgui.PopItemWidth()
    popFont(fonts.cum)
    imgui.PopStyleColor(4)
    sameRow(S(5))
    local _, clicked = flowButton('sbtn', I('MAGNIFYING_GLASS', '?'), C.text, nil, btnW, frameH)
    if clicked or submitted then doApiSearch() end

    local hx, hy = anchoredRow('shint', lineH + S(6))
    drawTextClipped(dl, hx, hy, 'официальный журнал Evolve RP: приёмы, повышения, понижения, увольнения',
                    C.textFaint, w)

    local list = ui.apiResults or {}

    -- найденного игрока можно сразу поставить в состав: API хранит журнал
    -- по никам, а список фракции ведёт сам скрипт
    if #list > 0 then
        local nick = list[1].nick or ''
        local inRoster = roster.members[nick] ~= nil
        local label = inRoster and ('Обновить из API: ' .. nick)
                                or ('+ В состав: ' .. nick)
        local _, clicked = flowButton('sadd', label,
                                      inRoster and C.textDim or C.accent,
                                      nil, textW(label) + S(24), frameH)
        if clicked and nick ~= '' then
            if not inRoster then
                local k, rn = parseApiRank(list[#list].new)
                local at = parseApiDate(list[1].date) or os.time()
                local by = (list[1].by and list[1].by ~= '—') and list[1].by or 'API'
                addMember(nick, by, at, (k == 'number' and rn) or 1, 0, os.time())
                say('{66FF66}[SFN Logs] ' .. nick .. ' добавлен в состав из журнала API')
            else
                say('{66FF66}[SFN Logs] ' .. nick .. ' поставлен в очередь API')
            end
            queueRefresh(nick, true)
            saveRoster()
        end
        advance(S(4))
    end

    local widths = measureCols(list, SCOLS)
    local contentW
    widths, contentW = fitTableWidths(widths, SCOLS, w)

    local stopY = select(2, cursorXY())
    local remainH = h - (stopY - topY)
    if remainH < S(60) then remainH = S(60) end
    local hscroll = contentW > w + 0.5 and (imgui.WindowFlags.HorizontalScrollbar or 0) or 0
    imgui.BeginChild('##stable', V(w, remainH), false, hscroll)
    local tx, ty = cursorXY()
    if ui.apiBusy then
        drawText(dl, tx, ty + S(6), I('CLOCK', '') .. ' запрашиваю журнал сервера...', C.soon)
        advance(lineH + S(10))
    elseif ui.apiErr then
        drawText(dl, tx, ty + S(6), ui.apiErr, C.blocked)
        advance(lineH + S(10))
    end

    local cx = tx
    for i, c in ipairs(SCOLS) do
        drawTextCentered(dl, cx, ty + S(3), c.head, C.textFaint, widths[i])
        cx = cx + widths[i]
    end
    hline(dl, tx, ty + S(20), math.max(contentW, w), C.border, S(1))
    cx = tx
    for i = 1, #SCOLS - 1 do
        cx = cx + widths[i]
        vline(dl, cx, ty, S(20) + #list * (rowH), C.lineSoft, S(1))
    end
    advance(S(20))

    for idx, r in ipairs(list) do
        local rx, ry = cursorXY()
        imgui.Dummy(V(math.max(contentW, w), rowH))
        if idx % 2 == 0 then fillRect(dl, rx, ry, math.max(contentW, w), rowH, RGBf(0.09, 0.09, 0.09)) end
        local cx2, ty2 = rx, ry + (rowH - lineH) * 0.5
        pushFont(fonts.cum)
        for i, c in ipairs(SCOLS) do
            local val = tostring(r[c.key] or '')
            local col = C.text
            if c.key == 'new' then
                local k, n = parseApiRank(val)
                col = (k == 'uninvite') and C.blocked or rankColor(n or 1)
            elseif c.key == 'date' or c.key == 'next' then
                col = (val == '' or val == '—' or val == 'Неизвестно') and C.textFaint or C.text
            end
            local tw = drawTextCentered(dl, cx2 + S(4), ty2, fitText(val, widths[i] - S(8)), col, widths[i] - S(8))
            if c.key == 'new' and (r.reason or '') ~= '' then
                local qx = cx2 + S(4) + tw + S(6)
                dot(dl, qx + S(5), ty2 + lineH * 0.5, S(5.5), RGBf(0.5, 0.5, 0.5))
                drawTextCentered(dl, qx, ty2, '?', RGBf(0.15, 0.15, 0.15), S(10))
            end
            cx2 = cx2 + widths[i]
        end
        popFont(fonts.cum)
    end
    if #list == 0 and not ui.apiBusy and not ui.apiErr then
        local ex, ey = cursorXY()
        drawText(dl, ex, ey + S(6), 'введите ник и нажмите лупу', C.textFaint)
        advance(lineH + S(10))
    end
    imgui.EndChild()
end

-- ================================================== НАСТРОЙКИ ============
--
-- v2.1.0: настройки упрощены до того, что реально нужно в игре. Убраны
-- раздел «перехват чата» (вместе с самой функцией), техническая диагностика
-- Evolve Logs API (транспорт, счётчики повторов, ожидание строк) и выбор
-- времени жизни кеша. Диагностика осталась в командах /sfnlogapi и /sfnlogui -
-- она нужна при разборе жалоб, а не каждый день.

local function settingsRows()
    local model = {}
    local function add(t, a, b, c) model[#model + 1] = { t = t, a = a, b = b, c = c } end

    add('section', 'окно')
    add('hotkey')
    add('checkbox', 'Показывать уволенных в журнале', refShowDismissed,
        function() cfg.showDismissed = refShowDismissed[0] end)

    add('section', 'состав из игры')
    add('checkbox', 'Забирать состав из ответа /members', refMembersEnabled,
        function() cfg.members.enabled = refMembersEnabled[0] end)
    add('hint', '   кнопка ниже отправляет /members, а скрипт разбирает ответ сервера:')
    add('hint', '   сотрудники попадают в журнал, ранги и даты добираются из Evolve Logs')
    local mc = membersCapture
    add('kv', 'последний состав',
        mc.active and 'слушаю ответ сервера...'
            or ((mc.at > 0 and mc.text ~= '') and mc.text or 'ещё не запрашивали'),
        mc.active and C.soon or ((mc.parsed > 0) and C.ready or C.textDim))
    add('button', I('USERS', '') .. ' ОБНОВИТЬ СОСТАВ ИЗ ИГРЫ', C.accent, function()
        sendMembersCommand()
    end)

    add('section', 'данные из Evolve Logs')
    local st = SFNLogs.api.status()
    add('kv', 'данные запрашиваются от имени',
        (localNick ~= '' and localNick) or 'ваш ник (подставится в игре)',
        localNick ~= '' and C.text or C.textDim)
    add('hint', '   журнал Evolve RP отдаёт данные только по нику игрока; если состав')
    add('hint', '   не обновляется - зайдите в игру и нажмите «Обновить данные всех»')
    if not cfg.api.enabled then
        add('kv', 'соединение', 'выключено в config.ini', C.blocked)
        add('hint', '   работают только локальные данные: включите [api] enabled = 1')
    else
        add('kv', 'соединение',
            st.busy and 'запрашиваю...' or (st.err and 'нет ответа' or 'есть'),
            st.busy and C.soon or (st.err and C.blocked or C.ready))
        if st.err then
            add('hint', '   сервер журнала не ответил; повторим сами. Подробности: /sfnlogapi')
        end
    end
    add('button', I('ROTATE', '') .. ' ОБНОВИТЬ ДАННЫЕ ВСЕХ', C.text, function()
        SFNLogs.api.refreshAll(true)
        say('{66FF66}[SFN Logs] весь состав поставлен в очередь обновления')
    end)
    add('button', 'СОХРАНИТЬ ЖУРНАЛ', C.text, function()
        saveRoster(true); say('{66FF66}[SFN Logs] сохранено')
    end)
    add('button', 'ВЫГРУЗИТЬ В ФАЙЛ', C.textDim, function()
        local path, n = exportText()
        say(string.format('{66FF66}[SFN Logs] выгружено %d записей -> %s', n, path))
    end)

    add('section', 'обновления')
    local us = SFNLogs.update.status()
    add('checkbox', 'Проверять обновления автоматически', refAutoUpdate, function()
        cfg.update.enabled = refAutoUpdate[0]
        saveConfig()
    end)
    add('checkbox', 'Ставить новую версию сразу', refAutoInstall, function()
        cfg.update.auto = refAutoInstall[0]
        saveConfig()
    end)
    add('hint', '   скрипт сам берёт свежую версию из репозитория и подменяет свой файл;')
    add('hint', '   старая версия сохраняется рядом как SFNLogs.lua.bak')
    if us.ready and us.available ~= '' then
        add('kv', 'доступна версия', us.available, C.ready)
        add('button', I('DOWNLOAD', '') .. ' ПОСТАВИТЬ ОБНОВЛЕНИЕ', C.accent, function()
            local ok, err = SFNLogs.update.install()
            if ok then
                say(string.format('{66FF66}[SFN Logs] установлена версия %s. Введите /reload или перезапустите игру',
                    tostring(err)))
            else
                say('{FF4444}[SFN Logs] ' .. tostring(err))
            end
        end)
    elseif us.busy then
        add('kv', 'проверка', 'идёт...', C.soon)
    else
        add('kv', 'обновлений', 'нет', C.textDim)
    end
    add('kv', 'последняя проверка',
        us.lastCheck > 0 and fmtDateTime(us.lastCheck) or 'ещё не проверяли',
        us.lastCheck > 0 and C.textDim or C.textFaint)
    if us.lastError ~= '' then
        add('hint', '   не получилось: ' .. us.lastError)
    end
    add('button', I('ROTATE', '') .. ' ПРОВЕРИТЬ ОБНОВЛЕНИЯ', C.text, function()
        if not lua_thread then
            say('{FF4444}[SFN Logs] lua_thread недоступен - обновление нельзя проверить')
            return
        end
        say('{AAAAAA}[SFN Logs] проверяю обновления...')
        lua_thread.create(function()
            local err = updateCheck(true)
            if err then say('{FF4444}[SFN Logs] обновление: ' .. tostring(err)) end
        end)
    end)

    add('section', 'служебное')
    add('hint', '   файл настроек: ' .. PATHS.config)
    add('button', 'ПЕРЕЧИТАТЬ config.ini', C.textDim, function()
        loadConfig(); refShowDismissed[0] = cfg.showDismissed
        refMembersEnabled[0] = cfg.members.enabled
        refAutoUpdate[0] = cfg.update.enabled
        refAutoInstall[0] = cfg.update.auto ~= false
        say('{66FF66}[SFN Logs] конфигурация перечитана')
    end)
    return model
end

local function measureSettings(model)
    local w = S(430)
    local nKv, nHint, nSection, nCheck, nBtn, nHot = 0, 0, 0, 0, 0, 0
    for _, r in ipairs(model) do
        if r.t == 'kv' then
            nKv = nKv + 1
            w = math.max(w, textW(r.a) + textW(r.b) + S(60))
        elseif r.t == 'hint' then
            nHint = nHint + 1
            w = math.max(w, textW(r.a) + S(30))
        elseif r.t == 'section' then nSection = nSection + 1
        elseif r.t == 'checkbox' then nCheck = nCheck + 1; w = math.max(w, textW(r.a) + S(60))
        elseif r.t == 'button' then nBtn = nBtn + 1; w = math.max(w, textW(r.a) + S(40))
        elseif r.t == 'hotkey' then nHot = nHot + 1
        end
    end
    local h = nSection * (S(20) + S(6) + SPACING_Y)
            + nKv * (lineH + S(10) + SPACING_Y)
            + nHint * (lineH + S(3) + SPACING_Y)
            + nCheck * (lineH + S(12) + SPACING_Y)
            + nHot * (frameH + S(6) + SPACING_Y)
            + nBtn * (S(26) + S(8) + 2 * SPACING_Y)
            + S(10)
    return w, h
end

local function drawSettingsBody(w, h)
    local dl = winDL()
    local model = settingsRows()
    local contentW = w   -- строки настроек тянутся на всю ширину тела, как у них
    local idx = 0
    for _, r in ipairs(model) do
        if r.t == 'section' then
            advance(sectionStrip(contentW, titleCase(r.a)) + S(6))
        elseif r.t == 'kv' then
            idx = idx + 1
            local x, y = anchoredRow('kv' .. idx, lineH + S(10))
            if imgui.IsItemHovered() then fillRect(dl, x, y, contentW, lineH + S(10), RGBf(0.14, 0.14, 0.15), S(3)) end
            drawTextClipped(dl, x + S(6), y + S(5), r.a, C.textDim, contentW * 0.45)
            local vFit = fitText(r.b, contentW * 0.5)
            drawText(dl, x + contentW - textW(vFit) - S(6), y + S(5), vFit, r.c or C.text)
            hline(dl, x + S(6), y + lineH + S(10), contentW - S(12), C.lineSoft, S(1))
        elseif r.t == 'hint' then
            local x, y = anchoredRow('hint' .. idx, lineH + S(3))
            idx = idx + 1
            drawTextClipped(dl, x + S(8), y, fitText(r.a, contentW - S(16)), C.textFaint, contentW - S(16))
        elseif r.t == 'checkbox' then
            local x, y = anchoredRow('cb', lineH + S(12))
            imgui.SameLine(nil, S(6))
            if imgui.Checkbox('##' .. r.a, r.b) then r.c() end
            drawTextClipped(dl, x + S(26), y + S(4), fitText(r.a, contentW - S(40)), C.textDim, contentW - S(40))
        elseif r.t == 'hotkey' then
            -- v2.0.12: выпадающий список всех клавиш (HOTKEY_OPTIONS) вместо
            -- трёх кнопок с перепутанными VK-кодами; выбор пишется в hotkey.json
            local x, y = anchoredRow('hk', frameH + S(6))
            drawText(dl, x + S(2), y + S(5), 'Горячая клавиша:', C.textDim)
            local off = textW('Горячая клавиша:') + S(12)
            sameRow(0)
            imgui.Dummy(V(math.max(S(2), off - 1), 1))
            sameRow(0)               -- Dummy сбрасывает cursor.x к краю региона
            local name = vkToName(cfg.hotkey)
            local nx, ny = cursorXY()
            drawText(dl, nx, y + S(5), name, C.accent)
            imgui.Dummy(V(textW(name), 1))
            sameRow(S(8))
            imgui.SetNextItemWidth(S(110))
            if imgui.BeginCombo('##hotkey_combo', name) then
                for _, hk in ipairs(HOTKEY_OPTIONS) do
                    local selected = (cfg.hotkey == hk.code)
                    if imgui.Selectable(hk.name, selected) then
                        cfg.hotkey = hk.code
                        saveHotkey()
                        say(string.format('{66FF66}[SFN Logs] клавиша окна: %s (сохранено в hotkey.json)',
                                          hk.name))
                    end
                    if selected then imgui.SetItemDefaultFocus() end
                end
                imgui.EndCombo()
            end
        elseif r.t == 'button' then
            flowButton('sb' .. idx, r.a, r.b, r.c, textW(r.a) + S(28), S(26))
            idx = idx + 1
            advance(S(8))
        end
    end
end

-- ================================================== О СКРИПТЕ ============

local function drawAboutBody(w, h)
    local dl = winDL()
    local x, y = cursorXY()
    pushFont(fonts.big)
    drawText(dl, x, y, 'SFN Logs', C.text)
    popFont(fonts.big)
    advance(S(26))
    local lines = {
        { 'версия ' .. SFN_VERSION_STR .. '   San Fierro News', C.text },
        { '', C.text },
        { 'Что делает скрипт', C.text },
        { '    Ведёт журнал состава редакции: кто принят, кем и когда, какой ранг,', C.textDim },
        { '    когда повышение уже можно давать. Следит за лимитом должностей', C.textDim },
        { '    старшего состава и минимальными уровнями.', C.textDim },
        { '', C.text },
        { 'Откуда берутся сотрудники', C.text },
        { '    «Журнал» -> «Состав из /members»: скрипт сам отправляет команду и', C.textDim },
        { '    разбирает ответ сервера (онлайн-состав фракции).', C.textDim },
        { '    «Поиск» -> «+ В состав»: любой игрок по нику, в том числе не в игре.', C.textDim },
        { '    /sfnlogadd Ник [КтоПринял]: добавить стажёра вручную.', C.textDim },
        { '', C.text },
        { 'Обновления', C.text },
        { '    Скрипт обновляет себя сам: раз в несколько часов смотрит, не появилась', C.textDim },
        { '    ли в репозитории версия новее, и ставит её. Старый файл сохраняется', C.textDim },
        { '    рядом как SFNLogs.lua.bak. После установки нужно ввести /reload или', C.textDim },
        { '    перезапустить игру. Отключается в «Настройках».', C.textDim },
        { '', C.text },
        { 'Откуда берутся ранги и даты', C.text },
        { '    Из официального журнала Evolve Role Play (' .. cfg.api.base .. ').', C.textDim },
        { '    Скрипт обновляет данные сам, в фоне, и не мешает игре.', C.textDim },
        { '', C.text },
        { 'Команды', C.text },
        { '    /sfnlog - окно (или клавиша из настроек, по умолчанию F8)', C.textDim },
        { '    /sfnlogmembers - запросить онлайн-состав у сервера', C.textDim },
        { '    /sfnlogadd Ник [КтоПринял] - добавить стажёра', C.textDim },
        { '    /sfnlogsave - сохранить журнал    /sfnlogexport - выгрузить в файл', C.textDim },
        { '    /sfnlogupdate - проверить и поставить обновление', C.textDim },
        { '    /sfnlogapi и /sfnlogui - диагностика (нужна только при неполадках)', C.textFaint },
        { '', C.text },
        { 'Оформление — визуальный язык Evolve Logs (Mary_Norton), воспроизведено', C.textFaint },
        { 'по исходникам modules/ui.lua с согласия владельцев журнала.', C.textFaint },
    }
    for _, l in ipairs(lines) do
        local lx, ly = cursorXY()
        imgui.Dummy(V(w, lineH + S(2)))
        drawTextClipped(dl, lx, ly, l[1], l[2], w)
    end
end

-- ================================================== МОДАЛКИ ==============

local function modalSize(w, h)
    imgui.SetNextWindowSize(V(S(w), S(h)), imgui.Cond.Always)
end

local function modalHeader(title, subtitle)
    local dl = winDL()
    local x, y = anchoredRow('mh', S(32))
    local w = imgui.GetContentRegionAvail().x
    fillRect(dl, x, y, w, S(32), C.sidebar, S(4))
    fillRect(dl, x, y, S(3), S(32), C.accent)
    pushFont(fonts.smal)
    local tw = drawText(dl, x + S(14), y + S(7), title:upper(), C.text)
    popFont(fonts.smal)
    if subtitle then
        drawTextClipped(dl, x + S(14) + tw + S(14), y + S(9), subtitle, C.textDim,
                        w - (S(28) + tw + S(14)))
    end
    advance(S(8))
end

local function fieldRow(label, labelW, availW, widget)
    local dl = winDL()
    local x, y = anchoredRow('fr', frameH)
    drawText(dl, x, y + S(5), label, C.textDim)
    -- виджет ставим через Spacer-Dummy: SameLine(offset) считает от края
    -- окна без паддингов и сдвигает поле влево поверх подписи
    sameRow(0)
    imgui.Dummy(V(math.max(S(2), labelW - 1), 1))
    sameRow(0)
    imgui.PushStyleColor(imgui.Col.FrameBg, C.frame)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, C.frameHov)
    imgui.PushStyleColor(imgui.Col.FrameBgActive, C.frameHov)
    imgui.PushStyleColor(imgui.Col.Text, C.text)
    imgui.PushItemWidth(math.max(S(60), availW - labelW))
    widget()
    imgui.PopItemWidth()
    imgui.PopStyleColor(4)
    advance(S(4))          -- небольшой зазор между полями
end

local ADD_W, ADD_H = 452, 540

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
    local labelW = math.max(textW('Кто принял'), textW('Дата принятия')) + S(18)

    fieldRow('Ник', labelW, avail, function() imgui.InputText('##nick', bufNick, 32) end)
    fieldRow('Кто принял', labelW, avail, function() imgui.InputText('##by', bufBy, 32) end)
    advance(S(4))
    advance(sectionStrip(avail, 'дата принятия') + S(6))
    do
        local function fieldLine(id, parts)
            local ax, ay = anchoredRow(id, frameH)
            local off = 0
            for i, p in ipairs(parts) do
                if i > 1 then off = off + S(10) end
                drawText(dl, ax + off, ay + S(5), p[1], C.textFaint)
                off = off + textW(p[1]) + S(6)
                if i == 1 then
                    sameRow(0)
                    imgui.Dummy(V(math.max(S(2), off + S(12) - 1), 1))
                    sameRow(0)
                else
                    sameRow(S(28) + textW(p[1]))
                end
                imgui.PushStyleColor(imgui.Col.FrameBg, C.frame)
                imgui.PushStyleColor(imgui.Col.Text, C.text)
                imgui.PushItemWidth(p[3])
                imgui.InputInt('##' .. p[1], p[2], 0)
                imgui.PopItemWidth()
                imgui.PopStyleColor(2)
                off = off + S(12) + p[3]
            end
            advance(S(6))
        end
        fieldLine('date', { { 'день', bufDay, S(52) }, { 'месяц', bufMonth, S(58) }, { 'год', bufYear, S(66) } })
        fieldLine('time', { { 'час', bufHour, S(46) }, { 'минута', bufMinute, S(52) } })
    end
    advance(sectionStrip(avail, 'ранг') + S(6))
    do
        local ax, ay = anchoredRow('rankrow', S(26))
        local label = string.format('%s [%d]', rankName(bufRank[0]), bufRank[0])
        local bw = textW(label) + S(36)
        flowButton('rk', label, C.violet, function() imgui.OpenPopup('rankpick') end, bw, S(26))
        sameRow(S(12))
        drawTextClipped(dl, ax + bw + S(12), ay + S(6), 'у стажёра дата повышения = дата принятия',
                        C.textFaint, avail - bw - S(24))
        advance(S(6))
        if imgui.BeginPopup('rankpick') then
            for r = 1, MAX_RANK do
                if imgui.Selectable(string.format('%s [%d]', rankName(r), r), bufRank[0] == r) then
                    bufRank[0] = r
                end
            end
            imgui.EndPopup()
        end
    end

    local errText
    do
        local ax, ay = anchoredRow('addbtns', S(26))
        local w1 = textW('ДОБАВИТЬ') + S(36)
        local _, clicked = flowButton('ok', 'ДОБАВИТЬ', C.accent, nil, w1, S(26))
        sameRow(S(8))
        flowButton('cancel', 'ОТМЕНА', C.textDim, function() ui.addOpen[0] = false end,
                   textW('ОТМЕНА') + S(36), S(26))
        advance(S(6))
        if clicked then
            local nick = trim(readBuf(bufNick, 32))
            local by   = trim(readBuf(bufBy, 32))
            local at   = composeTime()
            if nick == '' then errText = 'Ник не может быть пустым'
            elseif not at then errText = 'Некорректная дата'
            else
                local m, err = addMember(nick, by, at, bufRank[0], levelOf(nick))
                if m then
                    logEvent('добавлен ' .. nick)
                    SFNLogs.api.refresh(nick, true)     -- сразу тянем официальные данные
                    ui.addOpen[0] = false
                else errText = tostring(err) end
            end
        end
        advance(S(30))
    end
    if errText then
        local ex, ey = anchoredRow('adderr', lineH)
        drawText(dl, ex, ey, errText, C.blocked)
    end
    imgui.EndPopup()
end

local REASON_W, REASON_H = 430, 210

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
    local labelW = textW('Причина') + S(18)
    fieldRow('Причина', labelW, avail, function() imgui.InputText('##reason', bufReason, 128) end)
    advance(S(6))
    local bx, by = anchoredRow('rsnbtns', S(26))
    local w1 = textW('ПОДТВЕРДИТЬ') + S(32)
    flowButton('disok', 'ПОДТВЕРДИТЬ', C.accent, function()
        dismissMember(dlg.nick, trim(readBuf(bufReason, 128)))
        logEvent('уволен ' .. dlg.nick)
        SFNLogs.api.refresh(dlg.nick, false)   -- API подтвердит увольнение журналом
        bufReason[0] = 0
        ui.reasonDlg = nil
        imgui.CloseCurrentPopup()
    end, w1, S(26))
    sameRow(S(8))
    flowButton('discancel', 'ОТМЕНА', C.textDim, function()
        bufReason[0] = 0; ui.reasonDlg = nil; imgui.CloseCurrentPopup()
    end, textW('ОТМЕНА') + S(32), S(26))
    imgui.EndPopup()
end

local HISTDLG_W, HISTDLG_H = 620, 430

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
    local x, y = anchoredRow('hinfo', lineH + S(8))
    local info = string.format('принял: %s    ранг: %s    уровень: %s',
                      (m.acceptedBy ~= '' and m.acceptedBy) or '—',
                      rankName(m.rank or 1), tostring(m.level or '?'))
    if m.lastLogin and m.lastLogin > 0 then
        info = info .. '    вход: ' .. fmtDateTime(m.lastLogin)
    end
    if m.acceptedApprox and not m.apiFetchedAt and not m.apiMissing then
        info = info .. '  (дата приблизительная)'
    end
    drawTextClipped(dl, x, y, info, C.textDim, avail)

    -- лента: сначала официальная история API, затем локальные события
    imgui.BeginChild('##histbody', V(avail, S(240)), false)
    local wTime = textW('00.00.0000 00:00') + S(16)
    local wRank = S(150)
    local i = 0
    for _, e in ipairs(m.apiHistory or {}) do
        i = i + 1
        local ex, ey = anchoredRow('ah' .. i, S(20))
        if i % 2 == 0 then fillRect(dl, ex, ey, avail, S(20), RGBf(0.09, 0.09, 0.09)) end
        fillRect(dl, ex, ey, S(2), S(20), C.accent)
        local ty = ey + (S(20) - lineH) * 0.5
        drawTextClipped(dl, ex + S(9), ty, e.date, C.textFaint, wTime - S(12))
        local k, n = parseApiRank(e.new)
        local newTxt = (k == 'uninvite') and 'уволен (Uninvite)'
                                            or (e.new ~= '' and e.new or '—')
        drawTextClipped(dl, ex + wTime, ty, newTxt,
                        (k == 'uninvite') and C.blocked or rankColor(n or 1), wRank - S(12))
        drawTextClipped(dl, ex + wTime + wRank, ty,
                        fitText((e.by ~= '' and (e.by .. '  ') or '') .. (e.reason or ''), avail - wTime - wRank - S(16)),
                        C.textDim, avail - wTime - wRank - S(16))
    end
    for _, hh in ipairs(m.history or {}) do
        i = i + 1
        local ex, ey = anchoredRow('lh' .. i, S(20))
        if i % 2 == 0 then fillRect(dl, ex, ey, avail, S(20), RGBf(0.09, 0.09, 0.09)) end
        fillRect(dl, ex, ey, S(2), S(20), rankColor(hh.rank or 1))
        local ty = ey + (S(20) - lineH) * 0.5
        drawTextClipped(dl, ex + S(9), ty, fmtDateTime(hh.at), C.textFaint, wTime - S(12))
        drawTextClipped(dl, ex + wTime, ty, rankName(hh.rank or 1), rankColor(hh.rank or 1), wRank - S(12))
        drawTextClipped(dl, ex + wTime + wRank, ty, fitText(hh.note or '', avail - wTime - wRank - S(16)),
                        C.textDim, avail - wTime - wRank - S(16))
    end
    if i == 0 then
        local ex, ey = anchoredRow('hempty', lineH)
        drawText(dl, ex, ey, 'событий пока нет', C.textFaint)
        advance(lineH + S(4))
    end
    imgui.EndChild()
    local bx, by = anchoredRow('hclose', S(26))
    flowButton('hrefresh', I('ROTATE', 'R') .. ' Обновить из API', C.textDim, function()
        SFNLogs.api.refresh(nick, true)
    end, textW(I('ROTATE', 'R') .. ' Обновить из API') + S(24), S(26))
    sameRow(S(8))
    flowButton('hclosebtn', 'ЗАКРЫТЬ', C.text, function()
        ui.historyNick = nil; imgui.CloseCurrentPopup()
    end, textW('ЗАКРЫТЬ') + S(32), S(26))
    imgui.EndPopup()
end

-- ================================================== МЕНЮ СТРОКИ ===========

local function rowMenuWidth(m)
    local w = textW(m.nick) + S(28)
    if not m.dismissed and (m.rank or 1) < MAX_RANK then
        w = math.max(w, textW(string.format('Повысить до: %s [%d]',
                                            rankName(m.rank + 1), m.rank + 1)) + S(30))
    end
    w = math.max(w, textW('История изменений') + S(30), S(230))
    return w
end

local function drawRowMenu(m)
    local dl = winDL()
    local x, y = cursorXY()
    local w = imgui.GetContentRegionAvail().x
    local headH = lineH * 2 + S(14)
    anchoredRow('rmhead', headH)
    fillRect(dl, x, y, w, headH, C.sidebar, S(4))
    fillRect(dl, x, y, S(3), headH, rankColor(m.rank or 1))
    drawTextClipped(dl, x + S(12), y + S(7), m.nick, C.text, w - S(24))
    local rl = string.format('%s [%d]', rankName(m.rank or 1), m.rank or 1)
    drawTextClipped(dl, x + S(12), y + S(7) + lineH + S(2), rl, rankColor(m.rank or 1), w - S(24))
    advance(S(6))

    if not m.dismissed then
        if (m.rank or 1) < MAX_RANK then
            local nextAt, ready, why = promotionInfo(m)
            local mh = menuItem(w, 'up', string.format('Повысить до: %s [%d]', rankName(m.rank + 1), m.rank + 1),
                                C.ready, function()
                changeRank(m.nick, m.rank + 1, 'повышен вручную')
                logEvent(string.format('%s повышен до %s', m.nick, rankName(m.rank + 1)))
                SFNLogs.api.refresh(m.nick, false)
                ui.menuNick = nil; imgui.CloseCurrentPopup()
            end)
            advance(mh)
            if imgui.IsItemHovered() then
                tip({ ready and 'срок вышел, ограничений нет' or 'ещё не срок или есть ограничения',
                      'ближайший срок: ' .. fmtDate(nextAt), why or 'можно повышать' })
            end
        else
            local mx, my = anchoredRow('rmax', lineH + S(6))
            drawText(dl, mx + S(10), my, 'максимальный ранг', C.violet)
        end
        if (m.rank or 1) > 1 then
            advance(menuItem(w, 'down', 'Понизить на ранг', C.soon, function()
                changeRank(m.nick, m.rank - 1, 'понижен вручную')
                SFNLogs.api.refresh(m.nick, false)
                ui.menuNick = nil; imgui.CloseCurrentPopup()
            end))
        end
        advance(menuItem(w, 'hist', 'История изменений', C.info, function()
            ui.historyNick = m.nick; ui.openHistory = true
            SFNLogs.api.refresh(m.nick, true)
            ui.menuNick = nil; imgui.CloseCurrentPopup()
        end))
        advance(menuItem(w, 'api', 'Обновить из API', C.textDim, function()
            SFNLogs.api.refresh(m.nick, true)
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
            SFNLogs.api.refresh(m.nick, false)
            ui.menuNick = nil; imgui.CloseCurrentPopup()
        end))
    end
end

local function drawPopups()
    if ui.openMenu and ui.menuNick then
        ui.menuOpenNick = ui.menuNick
        imgui.OpenPopup('rowmenu')
        ui.openMenu = false
    end
    -- v2.0.8: SetNextWindowSize — СТРОГО ДО BeginPopup. ImGui держит размер в
    -- NextWindowData и Begin съедает его при входе; вызов внутри уже открытого
    -- попапа отдаёт размер СЛЕДУЮЩЕМУ окну, а само меню автосайзится по
    -- содержимому. Ширина содержимого берётся из GetContentRegionAvail(), то
    -- есть попап сам себя не расширяет и вырождается в тонкую вертикальную
    -- полоску в точке клика (баг-репорт 26.09.2026).
    local m = ui.menuNick and roster.members[ui.menuNick]
    if m then imgui.SetNextWindowSize(V(rowMenuWidth(m), 0), imgui.Cond.Always) end
    if imgui.BeginPopup('rowmenu') then
        if m then
            drawRowMenu(m)
        else
            ui.menuOpenNick = nil
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    else
        ui.menuOpenNick = nil
    end
    if ui.openReason and ui.reasonDlg then
        imgui.OpenPopup('Уволить##rsn'); ui.openReason = false
    end
    drawReasonDialog()
    if ui.openHistory and ui.historyNick then
        imgui.OpenPopup('История##hist'); ui.openHistory = false
    end
    drawHistoryDialog()
    drawAddDialog()
end

-- ================================================== ТЕМА И КАРКАС =========

-- Точные значения их DarkTheme, но применённые скоупом на кадр: глобальный
-- стиль контекста ImGui не трогаем, чужие скрипты не страдают.
local THEME_COLORS = {
    { 'Text',                  C.text },      { 'TextDisabled',        C.textFaint },
    { 'WindowBg',              C.bg },        { 'ChildBg',             C.bg },
    { 'PopupBg',               C.bg },        { 'Border',              C.border },
    { 'FrameBg',               C.frame },     { 'FrameBgHovered',      C.frameHov },
    { 'FrameBgActive',         C.frameHov },  { 'TitleBg',             C.frame },
    { 'TitleBgActive',         C.frame },     { 'TitleBgCollapsed',    C.frame },
    { 'Button',                C.frame },     { 'ButtonHovered',       RGBf(0.21, 0.20, 0.20) },
    { 'ButtonActive',          RGBf(0.41, 0.41, 0.41) },
    { 'Header',                C.frame },     { 'HeaderHovered',       RGBf(0.20, 0.20, 0.20) },
    { 'HeaderActive',          RGBf(0.47, 0.47, 0.47) },
    { 'Separator',             C.frame },     { 'SeparatorHovered',    C.accent },
    { 'CheckMark',             C.text },      { 'SliderGrab',          RGBf(0.21, 0.20, 0.20) },
    { 'SliderGrabActive',      RGBf(0.21, 0.20, 0.20) },
    { 'ScrollbarBg',           C.frame },     { 'ScrollbarGrab',       RGBf(0, 0, 0) },
    { 'ScrollbarGrabHovered',  RGBf(0.41, 0.41, 0.41) },
    { 'ScrollbarGrabActive',   RGBf(0.51, 0.51, 0.51) },
    { 'Tab',                   C.frame },     { 'TabHovered',          RGBf(0.28, 0.28, 0.28) },
    { 'TabActive',             RGBf(0.30, 0.30, 0.30) },
}

local pushedColors, pushedVars = 0, 0

local function pushTheme()
    pushedColors, pushedVars = 0, 0
    for _, pair in ipairs(THEME_COLORS) do
        local idx = imgui.Col and imgui.Col[pair[1]]
        if idx and imgui.PushStyleColor then
            imgui.PushStyleColor(idx, pair[2]); pushedColors = pushedColors + 1
        end
    end
    local function var(name, a, b)
        local idx = imgui.StyleVar and imgui.StyleVar[name]
        if not idx then return false end
        local ok = (b ~= nil) and pcall(imgui.PushStyleVar, idx, a, b)
                            or  pcall(imgui.PushStyleVar, idx, a)
        if ok then pushedVars = pushedVars + 1 end
        return ok and true or false
    end
    -- паддинг важен для расчёта ширины содержимого (innerW): если в сборке
    -- mimgui нет PushStyleVar для WindowPadding, честно считаем дефолтный
    local padOk = var('WindowPadding', S(5), S(5))
    PADX = padOk and S(5) or PADX_BASE
    var('FramePadding', S(5), S(5))
    var('ItemSpacing', S(5), S(5))
    var('ItemInnerSpacing', S(2), S(2))
    var('IndentSpacing', 0)
    var('ScrollbarSize', S(10))
    var('GrabMinSize', S(10))
    var('WindowBorderSize', S(1))
    var('ChildBorderSize', S(1))
    var('PopupBorderSize', S(1))
    var('FrameBorderSize', S(1))
    var('WindowRounding', S(5))
    var('ChildRounding', S(5))
    var('FrameRounding', S(5))
    var('PopupRounding', S(5))
    var('ScrollbarRounding', S(5))
    var('GrabRounding', S(5))
    var('TabRounding', S(5))
end

local function popTheme()
    if pushedColors > 0 then pcall(imgui.PopStyleColor, pushedColors); pushedColors = 0 end
    if pushedVars > 0 then pcall(imgui.PopStyleVar, pushedVars); pushedVars = 0 end
end

-- --------------------------------------------------- расчёт размера -------

local chromeMeasured, windowOverhead, heightCorrection = 0, 0, 0

local function bodyDesired(now, rows, widths)
    -- полоса раздела есть у каждой секции
    local strip = S(20) + S(8) + SPACING_Y
    if ui.menu == 1 then
        local visible = math.min(#rows, 16)
        local head = S(20) + SPACING_Y
        local tools = frameH + SPACING_Y
        local tableH = head + (visible > 0 and visible * rowH or S(56) + 3 * lineH + S(16))
        local btns = frameH + SPACING_Y
        return strip + tools + tableH + btns + S(16)
    elseif ui.menu == 2 then
        local n = ui.apiResults and #ui.apiResults or 0
        return strip + frameH + SPACING_Y + lineH + S(6) + SPACING_Y + S(20) + SPACING_Y
             + (n > 0 and (frameH + S(4) + SPACING_Y) or 0)
             + math.max(n, 1) * rowH + S(30)
    elseif ui.menu == 3 then
        local _, sh = measureSettings(settingsRows())
        return strip + sh + S(24)
    end
    return strip + S(330)
end

local function computeLayout(now)
    local rows = {}
    for _, m in ipairs(sortedMembers(cfg.showDismissed, ui.search)) do
        rows[#rows + 1] = rowCells(m, now)
    end
    local widths = measureCols(rows, JCOLS)
    local tableW = rowsWidth(widths)

    local bodyW
    if ui.menu == 1 then
        bodyW = math.max(tableW, S(860))
    elseif ui.menu == 2 then
        local srows = {}
        for _, r in ipairs(ui.apiResults or {}) do srows[#srows + 1] = r end
        local sw = rowsWidth(measureCols(srows, SCOLS))
        bodyW = math.max(sw, S(860))
    elseif ui.menu == 3 then
        bodyW = math.max(measureSettings(settingsRows()), S(560))
    else
        bodyW = S(620)
    end

    local bodyH = bodyDesired(now, rows, widths)
    local sideH = S(46 + 16 + 8) + #MENU_ITEMS * (S(MENU_H) + S(6)) + S(60)

    local winW = S(SIDEBAR_W) + bodyW + S(30)
    local winH = math.max(S(520), math.max(sideH, bodyH) + S(40)
               + math.max(windowOverhead, 0) + heightCorrection)
    heightCorrection = 0

    local disp = imgui.GetIO().DisplaySize
    local maxW = ((disp and disp.x) or 1920) - S(40)
    local maxH = ((disp and disp.y) or 1080) - S(60)
    if winW > maxW then winW = maxW end
    if winH > maxH then winH = maxH end
    if winW < S(1030) then winW = S(1030) end
    if winH < S(520) then winH = S(520) end

    ui.lastRows = #rows
    return winW, winH, rows, widths, bodyH
end

-- -------------------------------------------------- крестик закрытия -----
-- Окно живёт без титульной панели (NoTitleBar), поэтому кнопку закрытия рисуем
-- сами в правом верхнем углу и ловим клик ручным hit-test'ом: курсор не трогаем
-- (SetCursorScreenPos запрещён требованиями к вёрстке), а клик защищаем
-- проверкой IsAnyItemHovered, чтобы не съесть нажатие, попавшее в элемент
-- под крестиком.
local function drawCloseButton()
    local dl = winDL()
    if not dl then return end
    if not imgui.GetWindowPos or not imgui.GetWindowSize then return end
    local wp  = imgui.GetWindowPos()
    local wsz = imgui.GetWindowSize()
    local bw, bh = S(18), S(16)
    local x2 = wp.x + wsz.x - S(6)
    local x1 = x2 - bw
    local y1 = wp.y + S(6)
    local y2 = y1 + bh
    ui.closeRect = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }

    local hovered = false
    if imgui.GetMousePos then
        local mp = imgui.GetMousePos()
        hovered = mp.x >= x1 and mp.x <= x2 and mp.y >= y1 and mp.y <= y2
    end
    if hovered then
        fillRect(dl, x1, y1, bw, bh, RGBf(1, 1, 1, 0.12), S(3))
    end
    -- сам крестик - две диагонали: никаких шрифтовых зависимостей
    local col = hovered and C.text or C.textFaint
    local ins = S(4.5)
    pdraw(dl.AddLine, dl, V(x1 + ins, y1 + ins), V(x2 - ins, y2 - ins), CU(col), S(1.6))
    pdraw(dl.AddLine, dl, V(x2 - ins, y1 + ins), V(x1 + ins, y2 - ins), CU(col), S(1.6))

    if hovered and imgui.IsMouseClicked and imgui.IsMouseClicked(0)
       and not (imgui.IsAnyItemHovered and imgui.IsAnyItemHovered()) then
        win[0] = false
        ui.closeClickedAt = os.time()
    end
end

local function drawFrame(now)
    local winW, winH, rows, widths, desiredBody = computeLayout(now)
    imgui.SetNextWindowSize(V(winW, winH), imgui.Cond.Always)

    -- как у них: без титульной панели, без ресайза, без сворачивания
    if not imgui.Begin('SFN Logs — журнал состава', win,
                       imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar
                       + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar) then
        imgui.End()
        return
    end

    local frameTop = select(2, cursorXY())
    local avail0 = imgui.GetContentRegionAvail()

    -- сайдбар и тело — два дочерних региона в один ряд
    imgui.BeginChild('##side', V(S(SIDEBAR_W), avail0.y), false)
    drawSidebar(avail0.y)
    imgui.EndChild()
    imgui.SameLine(0, 0)

    local bodyW = avail0.x - S(SIDEBAR_W) - S(5)
    imgui.BeginChild('##body', V(bodyW, avail0.y), false)
    -- содержимое рисуем в ширину минус паддинги child: всё, что меряется по
    -- w (полосы, таблицы, правое прижимание), не должно залезать под обрезку
    local innerW = bodyW - 2 * PADX
    if innerW < S(200) then innerW = S(200) end
    local bx, by = cursorXY()

    local stripLabel = ({ 'Журнал состава', 'Поиск по игроку', 'Настройки', 'О скрипте' })[ui.menu]
    advance(sectionStrip(innerW, stripLabel) + S(8))

    local contentH = avail0.y - (select(2, cursorXY()) - by) - S(6)
    if contentH < S(60) then contentH = S(60) end

    if ui.menu == 1 then
        drawJournalBody(innerW, contentH, now, rows, widths)
    elseif ui.menu == 2 then
        drawSearchBody(innerW, contentH)
    elseif ui.menu == 3 then
        drawSettingsBody(innerW, contentH)
    else
        drawAboutBody(innerW, contentH)
    end
    imgui.EndChild()

    -- фактическая геометрия: накладные расходы окна и высота хрома
    local oh = winH - avail0.y
    if oh > 0 and oh < S(200) then windowOverhead = oh end
    local contentBottom = select(2, cursorXY())
    local overflow = contentBottom - (frameTop + avail0.y)
    if overflow > 0 then heightCorrection = overflow end

    drawCloseButton()
    drawPopups()
    imgui.End()
end

-- Аварийная раскладка: если в сборке mimgui не хватит примитивов, окно
-- остаётся рабочим на обычном тексте.
local function drawFallback(now)
    imgui.SetNextWindowSize(V(S(900), S(480)), imgui.Cond.FirstUseEver)
    if not imgui.Begin('SFN Logs', win) then imgui.End(); return end
    imgui.TextColored(C.accent, 'SFN Logs — журнал состава San Fierro News')
    local st = SFNLogs.api.status()
    imgui.TextColored(C.textDim, string.format('API: %s  очередь: %d  транспорт: %s',
        st.err or 'ок', st.queue, st.transport))
    imgui.Separator()
    if imgui.Button('+ Добавить') then
        resetAddForm(); ui.addOpen[0] = true; imgui.OpenPopup('Добавить игрока')
    end
    imgui.SameLine()
    if imgui.Button('Обновить из API') then SFNLogs.api.refreshAll(false) end
    imgui.SameLine()
    if imgui.Button('Состав из /members') then sendMembersCommand() end
    imgui.SameLine()
    if imgui.Button('Экспорт') then
        local path, n = exportText()
        say(string.format('{66FF66}[SFN Logs] выгружено %d записей -> %s', n, path))
    end
    imgui.Separator()
    imgui.BeginChild('##fb', V(0, 0), false)
    for _, m in ipairs(sortedMembers(cfg.showDismissed, ui.search)) do
        local r = rowCells(m, now)
        imgui.TextColored(r._statusCol, string.format('%s | %s | %s | %s',
            fitText(r.nick, S(140)), fitText(r.rank, S(150)), r.prom, fitText(r.status, S(180))))
        if imgui.IsItemClicked() then ui.menuNick = m.nick; ui.openMenu = true end
    end
    imgui.EndChild()
    drawPopups()
    imgui.End()
end

local uiBroken = false

-- Отладочный доступ: тесты и консоль MoonLoader.
SFNLogs.ui = ui
SFNLogs.paths = PATHS
SFNLogs.readfile = readFile
function SFNLogs.setVisible(v) win[0] = v and true or false end
function SFNLogs.isOpen() return win[0] end
function SFNLogs.isVisible() return win[0] end
function SFNLogs.setMenu(i) ui.menu = i; return true end
function SFNLogs.openAddDialog()
    resetAddForm(); ui.addOpen[0] = true; imgui.OpenPopup('Добавить игрока')
end
function SFNLogs.openReasonDialog(nick)
    ui.reasonDlg = { nick = nick }; ui.openReason = true; imgui.OpenPopup('Уволить##rsn')
end
function SFNLogs.openHistoryDialog(nick)
    ui.historyNick = nick; ui.openHistory = true; imgui.OpenPopup('История##hist')
end
function SFNLogs.openRowMenu(nick) ui.menuNick = nick; ui.openMenu = true end
function SFNLogs.layoutInfo()
    return { menu = ui.menu, rows = ui.lastRows, search = ui.search, dpi = dpiScale,
             drawListOk = dl_ok, lineH = lineH, rowH = rowH, fontsOk = fonts.ok }
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    -- иконки FontAwesome 6 вливаются в дефолтный шрифт (MergeMode внутри fa.Init)
    if fa and fa.Init then pcall(fa.Init, S(14)) end
    local okFonts = pcall(function()
        local io = imgui.GetIO()
        local dir = getFolderPath and (getFolderPath(0x14) .. '\\') or ''
        local cyr = io.Fonts:GetGlyphRangesCyrillic()
        fonts.cum  = io.Fonts:AddFontFromFileTTF(dir .. 'arial.ttf', S(13), nil, cyr)
        fonts.smal = io.Fonts:AddFontFromFileTTF(dir .. 'arial.ttf', S(15.5), nil, cyr)
        fonts.big  = io.Fonts:AddFontFromFileTTF(dir .. 'trebucbd.ttf', S(20), nil, cyr)
        fonts.ok = true
    end)
    if not okFonts then fonts.ok = false end
end)

imgui.OnFrame(function() return win[0] end, function(self)
    refreshScale()
    lineH  = (imgui.CalcTextSize('Ay').y) or S(14)
    rowH   = math.floor(lineH + S(8))
    frameH = math.floor(lineH + S(9))

    pushTheme()
    if uiBroken or not dl_ok then
        local ok = pcall(drawFallback, os.time())
        if not ok then uiBroken = true end
    else
        local ok, err = pcall(drawFrame, os.time())
        if not ok then
            dl_ok = false
            SFNLogs.lastUiError = tostring(err)
            logEvent('интерфейс переключён в упрощённый режим: ' .. tostring(err))
            pcall(drawFallback, os.time())
        end
    end
    popTheme()
end)

-- ============================================================ КОМАНДЫ =====

local function registerCommands()
    sampRegisterChatCommand('sfnlog', function() win[0] = not win[0] end)
    -- v2.1.0: /sfnlogcap (дамп чата для снятия шаблонов) удалён вместе с
    -- перехватом чата. Выгрузка журнала, наоборот, возвращена командой:
    -- в 2.0.12 кнопку «Экспорт» из окна убрали, а команду не зарегистрировали,
    -- поэтому export.txt обычному пользователю стал недоступен вовсе.
    sampRegisterChatCommand('sfnlogexport', function()
        local path, n = exportText()
        say(string.format('{66FF66}[SFN Logs] выгружено %d записей -> %s', n, path))
    end)
    sampRegisterChatCommand('sfnlogapi', function(param)
        if tostring(param or ''):match('all') then
            SFNLogs.api.refreshAll(true)
            say('{66FF66}[SFN Logs] весь состав поставлен в очередь API')
            return
        end
        local st = SFNLogs.api.status()
        say(string.format('{66FF66}[SFN Logs] API: %s | очередь: %d | запросов: %d | ошибок: %d',
            st.err or (st.busy and 'запрос...' or 'ок'), st.queue, st.fetched, st.errors))
        say(string.format('{AAAAAA}[SFN Logs] SF News [9] @ %s | транспорт: %s%s | кеш: %d с',
            st.server, st.transport,
            st.transportCfg ~= 'auto'
                and (' (закреплено в config.ini: ' .. st.transportCfg .. ')')
                or ' (авто)',
            cfg.api.ttl))
        if st.diag then
            say(string.format('{AAAAAA}[SFN Logs] последний запрос: колбэков %d, тишина %d с (порог %d с)',
                st.diag.cb, st.diag.silence / 10, st.diag.limit / 10))
            if st.lastCodes and #st.lastCodes > 0 then
                local codes = {}
                for _, c in ipairs(st.lastCodes) do codes[#codes + 1] = tostring(c) end
                say('{AAAAAA}[SFN Logs] статусы загрузки: ' .. table.concat(codes, ', ')
                    .. '  (58 = STATUSEX_ENDDOWNLOAD, конец загрузки)')
            end
        end
        if st.failStreak > 0 or st.switched > 0 then
            say(string.format('{AAAAAA}[SFN Logs] подряд неудач: %d | переключений: %d | последний статус: %s | пауза: %d мс',
                st.failStreak, st.switched, tostring(st.lastCode), SFNLogs.api.pauseMs()))
        end
        if st.retries > 0 or st.gaveUp > 0 or st.retried > 0 or st.noData > 0 then
            say(string.format('{AAAAAA}[SFN Logs] повторы: ждут %d | в откате %d | назначено %d | «записей нет» %d',
                st.retries, st.gaveUp, st.retried, st.noData))
        end
        if st.lastOk > 0 then
            say('{AAAAAA}[SFN Logs] последнее обновление: ' .. os.date('%H:%M:%S', st.lastOk))
        end
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
        saveRoster(true)
        say('{66FF66}[SFN Logs] сохранено')
    end)
    sampRegisterChatCommand('sfnlogmembers', function()
        sendMembersCommand()
    end)
    -- v2.2.0: автообновление. Без аргумента - статус, check - проверить,
    -- install - поставить скачанное, url - показать, откуда берётся файл.
    sampRegisterChatCommand('sfnlogupdate', function(param)
        local st = SFNLogs.update.status()
        local arg = tostring(param or ''):lower():match('^%s*(%S*)')
        if arg == 'check' then
            if not lua_thread then
                say('{FF4444}[SFN Logs] lua_thread недоступен - обновление нельзя проверить')
                return
            end
            say('{AAAAAA}[SFN Logs] проверяю обновления...')
            lua_thread.create(function()
                local err = updateCheck(true)
                if err then say('{FF4444}[SFN Logs] обновление: ' .. tostring(err)) end
            end)
            return
        end
        if arg == 'install' then
            local ok, err = updateDoInstall()
            if ok then
                say(string.format('{66FF66}[SFN Logs] установлена версия %s. Введите /reload или перезапустите игру', tostring(err)))
            else
                say('{FF4444}[SFN Logs] ' .. tostring(err))
            end
            return
        end
        if arg == 'url' then
            say('{AAAAAA}[SFN Logs] источник обновлений: ' .. st.url)
            say('{AAAAAA}[SFN Logs] заменяемый файл: ' .. st.target)
            return
        end
        say(string.format('{66FF66}[SFN Logs] версия %s%s', st.current,
            st.ready and (' -> доступна ' .. st.available) or ''))
        if st.busy then
            say('{AAAAAA}[SFN Logs] сейчас идёт проверка обновлений')
        elseif st.ready then
            say('{AAAAAA}[SFN Logs] новая версия скачана и проверена: /sfnlogupdate install')
        elseif st.lastCheck > 0 then
            say('{AAAAAA}[SFN Logs] последняя проверка: ' .. fmtDateTime(st.lastCheck)
                .. (st.lastError ~= '' and (' | ошибка: ' .. st.lastError) or ' | обновлений нет'))
        else
            say('{AAAAAA}[SFN Logs] обновлений ещё не проверяли: /sfnlogupdate check')
        end
        say(string.format('{AAAAAA}[SFN Logs] автообновление: %s, ставить сразу: %s, проверок за сессию: %d (ошибок %d)',
            st.enabled and 'вкл' or 'выкл', st.auto and 'да' or 'нет', st.checked, st.errors))
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
                 ') - вывод /members не перехватывается, журнал работает в ручном режиме')
    end
    loadConfig()
    loadRoster()
    loadUpdateState()
    resetAddForm()
    refShowDismissed[0] = cfg.showDismissed
    refMembersEnabled[0] = cfg.members and cfg.members.enabled or true
    refAutoUpdate[0] = cfg.update and cfg.update.enabled or true
    refAutoInstall[0] = cfg.update and cfg.update.auto ~= false
    registerCommands()

    -- свой ник нужен для requester и updatedBy: два способа под pcall,
    -- в главном цикле повторяем, пока не определится (спавн не мгновенный)
    localNick = detectLocalNick() or ''

    wait(1000)
    refreshOnline()
    startApiWorker()
    startUpdateWorker()

    local lastOnline, lastNick = os.time(), os.time()
    say(string.format('{66FF66}[SFN Logs] v%s загружен. /sfnlog - окно, /sfnlogmembers - состав из игры', SFN_VERSION_STR))
    if cfg.api.enabled then
        -- v2.1.0: без имени транспорта в чате - это внутренняя деталь, она
        -- нужна только при диагностике и видна в /sfnlogapi.
        say(string.format('{AAAAAA}[SFN Logs] данные о рангах: журнал Evolve RP, SF News [9] @ %s', API_SERVER))
        SFNLogs.api.refreshAll(false)      -- первый прогон по составу
    else
        say('{FFAA00}[SFN Logs] обновление из журнала Evolve RP выключено в config.ini [api] - работаем по локальным данным')
    end
    if not sampev then
        say('{FFAA00}[SFN Logs] нет samp.events - состав из /members не перехватывается, добавляйте сотрудников вручную')
    end
    if cfg.update and cfg.update.enabled then
        -- сообщаем только если обновление уже скачано и ждёт установки:
        -- обычная проверка идёт молча в фоне и напишет сама, когда найдёт
        if updateState.ready and updateState.available ~= '' then
            say(string.format('{66FF66}[SFN Logs] скачана версия %s - ставлю (старый файл сохраню как .bak)',
                updateState.available))
            local ok, err = updateDoInstall()
            if ok then
                say(string.format('{66FF66}[SFN Logs] установлена версия %s: введите /reload или перезапустите игру',
                    tostring(err)))
            else
                say('{FF4444}[SFN Logs] не удалось поставить обновление: ' .. tostring(err))
            end
        end
    else
        say('{FFAA00}[SFN Logs] автообновление выключено в config.ini [update]')
    end

    while true do
        wait(0)

        -- клавиша окна: фронт isKeyDown, без мёртвых wasKeyPressed/
        -- isChatInputActive, которых в MoonLoader нет (цикл падал на 1-м кадре)
        checkHotkeyPress(win)

        local now = os.time()
        if now - lastOnline >= 30 then
            lastOnline = now
            pcall(refreshOnline)
        end
        pcall(tickRosterSave)      -- отложенная запись roster.json (батчинг)
        if localNick == '' and now - lastNick >= 10 then
            lastNick = now
            localNick = detectLocalNick() or ''
            if localNick ~= '' then
                say(string.format('{66FF66}[SFN Logs] запрашивающий: %s (ваш ник в игре)', localNick))
            end
        end
    end
end

-- публикуется здесь, а не в шве выше: registerCommands определён позже
SFNLogs.registerCommands = registerCommands

function onScriptTerminate(scr)
    if scr ~= thisScript() then return end
    pcall(saveRoster, true)       -- принудительная запись перед выгрузкой
    pcall(saveUpdateState)        -- чтобы не потерять готовое обновление
end