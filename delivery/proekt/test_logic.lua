-- Тесты чистой логики SFN Logs: JSON-кодек, правила повышений, лимиты,
-- экспорт. Не требует SA-MP, MoonLoader и ImGui.
--
-- Запуск:  luajit test_logic.lua
--
-- Берёт из SFNLogs.lua участок между метками PURE LOGIC и выполняет его
-- с заглушками вместо MoonLoader-глобалов.

local SRC = arg[1] or 'SFNLogs.lua'
local H = 3600
local D = 24 * H

-- ------------------------------------------------------------ заглушки ----
local TMP = '/tmp/sfntest'
os.execute('mkdir -p ' .. TMP)
getWorkingDirectory  = function() return TMP end
doesDirectoryExist   = function() return true end
createDirectory      = function() return true end

local src = assert(io.open(SRC, 'r')):read('*a')
-- Якорь к началу строки и жадный поиск конца: в 2.2.0 строки-метки PURE
-- встречаются и внутри кода (validateScriptText собирает их из частей), а
-- ленивый шаблон «.-» обрезал бы секцию на первой же из них.
local body = src:match('\n%-%- >>> PURE LOGIC BEGIN(.-)\n%-%- <<< PURE LOGIC END\n')
assert(body, 'метки PURE LOGIC не найдены')

-- Чанк возвращает свои локальные сущности, чтобы тест мог их проверить:
-- глобалами в скрипте сделаны только те, что нужны ImGui/SAMP-частям.
body = body .. [[

return { json = json, PATHS = PATHS, loadIni = loadIni,
         readFile = readFile, writeFile = writeFile, ensureDir = ensureDir }
]]
local chunk, err = loadstring(body, 'purelogic')
assert(chunk, err)
local exposed = assert(chunk())
local json       = exposed.json
local PATHS      = exposed.PATHS
local loadIni    = exposed.loadIni
local readFile   = exposed.readFile
local writeFile  = exposed.writeFile

-- ------------------------------------------------------------ ассерты ----
local passed, failed = 0, 0
local function eq(name, got, want)
    if got == want then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-46s got=%s want=%s', name, tostring(got), tostring(want)))
    end
end
local function ok(name, cond) eq(name, cond and true or false, true) end
local function section(t) print('\n== ' .. t) end

-- ============================================================ JSON =======
section('JSON codec')
local samples = {
    { members = { A = { nick = 'A', rank = 3, level = 0, dismissed = false,
                       history = { { rank = 1, at = 100, note = 'принят' },
                                   { rank = 3, at = 200, note = 'повышен' } } } },
      version = 1 },
    { s = 'кавычки " и \\ слэш', n = -17, f = 1.5, b = true, arr = { 1, 2, 3 }, e = {} },
    { utf = 'Стажёр Звукооператор', nested = { a = { b = { c = 'deep' } } } },
}
for i, v in ipairs(samples) do
    local enc = json.encode(v)
    local dec = json.decode(enc)
    ok('roundtrip sample ' .. i, dec ~= nil)
    if i == 1 then
        eq('  nested string', dec.members.A.nick, 'A')
        eq('  nested number', dec.members.A.rank, 3)
        eq('  history len',   #dec.members.A.history, 2)
        eq('  history note',  dec.members.A.history[2].note, 'повышен')
        eq('  boolean false', dec.members.A.dismissed, false)
    elseif i == 2 then
        eq('  escapes',  dec.s, 'кавычки " и \\ слэш')
        eq('  negative', dec.n, -17)
        eq('  float',    dec.f, 1.5)
        eq('  bool',     dec.b, true)
        eq('  array len', #dec.arr, 3)
        eq('  array[2]',  dec.arr[2], 2)
    elseif i == 3 then
        eq('  utf8 string', dec.utf, 'Стажёр Звукооператор')
        eq('  deep',        dec.nested.a.b.c, 'deep')
    end
end
eq('decode null in object', (json.decode('{"a":null,"b":1}')).b, 1)
eq('decode invalid -> nil', json.decode('{not json'), nil)
eq('decode empty -> nil',   json.decode(''), nil)
eq('encode nil -> null',    json.encode(nil), 'null')
eq('encode inf -> null',    json.encode(math.huge), 'null')

-- ======================================================= ПРАВИЛА =========
section('Rank table')
eq('MAX_RANK', MAX_RANK, 9)
eq('rank 1', RANK_NAMES[1], 'Стажёр')
eq('rank 9', RANK_NAMES[9], 'Программный директор')
eq('1->2 is 24 hours', SECONDS_TO_NEXT[1], D)
eq('2->3 is 2 days',   SECONDS_TO_NEXT[2], 2 * D)
eq('3->4 is 2 days',   SECONDS_TO_NEXT[3], 2 * D)
eq('4->5 is 3 days',   SECONDS_TO_NEXT[4], 3 * D)
eq('5->6 is 5 days',   SECONDS_TO_NEXT[5], 5 * D)
eq('6->7 is 7 days',   SECONDS_TO_NEXT[6], 7 * D)
eq('7->8 is 7 days',   SECONDS_TO_NEXT[7], 7 * D)
eq('8->9 is 10 days',  SECONDS_TO_NEXT[8], 10 * D)
eq('9 is ceiling: no tenure', SECONDS_TO_NEXT[9], nil)
eq('7 needs level 8 cap 4', PROMOTE_REQ[7].minLevel .. '/' .. PROMOTE_REQ[7].cap, '8/4')
eq('8 needs level 9 cap 4', PROMOTE_REQ[8].minLevel .. '/' .. PROMOTE_REQ[8].cap, '9/4')
eq('9 needs level 10 cap 3', PROMOTE_REQ[9].minLevel .. '/' .. PROMOTE_REQ[9].cap, '10/3')
eq('rank by name utf8', RANK_BY_NAME['Репортёр'], 4)
eq('rank by name ascii-folded', RANK_BY_NAME['репортёр'] or RANK_BY_NAME['Репортёр'], 4)

-- Регрессия: старый паттерн '[%C0-%DF]' матчил почти все байты 0x20-0xFF и
-- string.char(b + 0x20) падал с "invalid value" на b >= 0xE0 (в игре - при
-- построении RANK_BY_NAME из CP1251-названий рангов, скрипт умирал на старте).
section('CP1251 lowercase (regression: [%C0-%DF] crash)')
do
    local up, lo = {}, {}
    for b = 0xC0, 0xDF do up[#up + 1] = string.char(b); lo[#lo + 1] = string.char(b + 0x20) end
    eq('  full А-Я range folds', cp1251Lower(table.concat(up)), table.concat(lo))
end
eq('  single 0xC0 -> 0xE0', cp1251Lower(string.char(0xC0)), string.char(0xE0))
eq('  0xE0 stays (no +0x20 overflow)', cp1251Lower(string.char(0xE0)), string.char(0xE0))
eq('  0xFF stays', cp1251Lower(string.char(0xFF)), string.char(0xFF))
eq('  ascii untouched', cp1251Lower('Report 007'), 'Report 007')
eq('  ё (0xA8) untouched', cp1251Lower(string.char(0xA8)), string.char(0xA8))
do
    -- 'Репортёр' и 'репортёр' в CP1251 (Р=0xD0 -> р=0xF0, ё=0xB8)
    local upCp = string.char(0xD0, 0xE5, 0xEF, 0xEE, 0xF0, 0xF2, 0xB8, 0xF0)
    local loCp = string.char(0xF0, 0xE5, 0xEF, 0xEE, 0xF0, 0xF2, 0xB8, 0xF0)
    eq('  Репортёр cp1251 -> lowercase', cp1251Lower(upCp), loCp)
end


-- ======================================================= ЖУРНАЛ ==========
section('Roster operations')
roster    = { members = {}, version = 1 }

local NOW = 1750000000

local m = addMember('Ivan_Petrov', 'Leader_Name', NOW - 30 * D, 1, 5, NOW)
ok('member added', m ~= nil)
eq('  acceptedBy',  m.acceptedBy, 'Leader_Name')
eq('  rank',        m.rank, 1)
eq('  promotedAt == acceptedAt for intern', m.promotedAt, m.acceptedAt)
eq('  history has 1 entry', #m.history, 1)
eq('duplicate rejected', (addMember('Ivan_Petrov', '', NOW, 1, 0, NOW)), nil)
eq('empty nick rejected', (addMember('   ', '', NOW, 1, 0, NOW)), nil)

-- стажёр, принят 30 дней назад -> давно готов ко второму рангу
local nextAt, ready, why = promotionInfo(m, NOW)
eq('intern next = accepted+24h', nextAt, m.acceptedAt + D)
eq('intern ready', ready, true)
eq('intern no blocker', why, nil)

-- только что принятый стажёр -> ещё рано
addMember('New_Guy', 'Leader_Name', NOW - 3 * H, 1, 3, NOW)
local n2 = roster.members['New_Guy']
local a2, r2 = promotionInfo(n2, NOW)
eq('fresh intern not ready', r2, false)
eq('fresh intern left ~21h', fmtLeft(a2 - NOW), '21ч 00м')

-- повышение двигает дату
changeRank('New_Guy', 2, 'повышен', NOW)
eq('after promote rank', roster.members['New_Guy'].rank, 2)
eq('after promote promotedAt', roster.members['New_Guy'].promotedAt, NOW)
eq('after promote next = +2d', (promotionInfo(roster.members['New_Guy'], NOW)), NOW + 2 * D)
eq('history grew', #roster.members['New_Guy'].history, 2)

section('Senior ranks: level and cap limits')
roster = { members = {}, version = 1 }
-- редактор с 7 уровнем: срок вышел, но не хватает уровня
addMember('Ed_Low', 'L', NOW - 100 * D, 6, 7, NOW)
roster.members['Ed_Low'].promotedAt = NOW - 10 * D
local _, r3, w3 = promotionInfo(roster.members['Ed_Low'], NOW)
eq('level 7 blocked for rank 7', r3, false)
ok('  reason mentions level', w3 and w3:find('ур') ~= nil)

-- тот же редактор с 8 уровнем и свободным местом -> можно
roster.members['Ed_Low'].level = 8
local _, r4, w4 = promotionInfo(roster.members['Ed_Low'], NOW)
eq('level 8 ready', r4, true)
eq('  no blocker', w4, nil)

-- заполняем лимит главных редакторов
for i = 1, 4 do addMember('Chief_' .. i, 'L', NOW, 7, 9, NOW) end
eq('countAtRank(7)', countAtRank(7), 4)
local _, r5, w5 = promotionInfo(roster.members['Ed_Low'], NOW)
eq('cap 4 blocks promotion', r5, false)
eq('  reason is cap', w5, 'нет мест: 4 из 4')

-- уволенный не занимает место
dismissMember('Chief_1', 'ушёл', NOW)
eq('dismissed not counted', countAtRank(7), 3)
local _, r6 = promotionInfo(roster.members['Ed_Low'], NOW)
eq('freed slot unblocks', r6, true)

-- ранг 9 - потолок редакции: срока нет, статус «максимальный ранг»
addMember('Prog_Dir', 'L', NOW - 400 * D, 9, 12, NOW)
local n9, r9, w9 = promotionInfo(roster.members['Prog_Dir'], NOW)
eq('rank 9 ceiling nextAt is nil', n9, nil)
eq('rank 9 ceiling ready flag', r9, true)
eq('rank 9 ceiling reason', w9, 'максимальный ранг')

-- ранг выше потолка при приёме упирается в 9 (ген.директора в SFN нет)
addMember('Top_Boss', 'L', NOW - 400 * D, 12, 12, NOW)
eq('addMember clamps to ceiling', roster.members['Top_Boss'].rank, 9)
local nn, rr, ww = promotionInfo(roster.members['Top_Boss'], NOW)
eq('clamped rank nextAt is nil', nn, nil)
eq('clamped rank ready flag', rr, true)
eq('clamped rank reason', ww, 'максимальный ранг')

section('Restore')
roster = { members = {}, version = 1 }
addMember('Come_Back', 'L', NOW - 50 * D, 3, 5, NOW)
dismissMember('Come_Back', 'ушёл', NOW - 10 * D)
eq('dismissed flag', roster.members['Come_Back'].dismissed, true)
restoreMember('Come_Back', NOW)
eq('restored', roster.members['Come_Back'].dismissed, false)
eq('timer restarted on restore', roster.members['Come_Back'].promotedAt, NOW)

-- ====================================================== ФОРМАТ ===========
section('Formatting')
eq('fmtDate', fmtDate(os.time({ year = 2026, month = 3, day = 7, hour = 0 })), '07.03.2026')
eq('fmtLeft 0', fmtLeft(0), 'готово')
eq('fmtLeft 90m', fmtLeft(90 * 60), '1ч 30м')
eq('fmtLeft 2d3h', fmtLeft(2 * D + 3 * H), '2д 3ч')
eq('fmtLeft nil', fmtLeft(nil), '-')
eq('nickOf clean', nickOf('  Ivan_Petrov  '), 'Ivan_Petrov')
eq('nickOf takes first token', nickOf('[SFN] Ivan_Petrov'), 'SFN')
eq('trim', trim('  x  '), 'x')

-- ====================================================== ЭКСПОРТ =========
section('Export')
roster = { members = {}, version = 1 }
addMember('Ivan_Petrov', 'Leader_Name', NOW - 40 * D, 5, 7, NOW)
roster.members['Ivan_Petrov'].promotedAt = NOW - 10 * D
addMember('Old_Chief', 'Leader_Name', NOW - 200 * D, 7, 9, NOW)
roster.members['Old_Chief'].promotedAt = NOW - 20 * D
addMember('Fresh_Intern', 'Leader_Name', NOW - 2 * H, 1, 3, NOW)

local text, count = buildExport(NOW)
eq('export row count', count, 3)
ok('  header present',    text:find('San Fierro News') ~= nil)
ok('  contains nick',     text:find('Ivan_Petrov') ~= nil)
ok('  contains accepter', text:find('Leader_Name') ~= nil)
ok('  contains rank',     text:find('Ведущий') ~= nil)
ok('  ready flag shown',  text:find('МОЖНО ПОВЫШАТЬ') ~= nil)
ok('  waiting shown',     text:find('через ') ~= nil)
ok('  cap summary',       text:find('Главный редактор%s*1 из 4') ~= nil)

-- ранги идут по убыванию в экспорте
local posChief = text:find('Old_Chief')
local posIvan  = text:find('Ivan_Petrov')
local posFresh = text:find('Fresh_Intern')
ok('sorted by rank desc', posChief < posIvan and posIvan < posFresh)

-- ============================================ ШАБЛОНЫ ЧАТА (удалено) =====
-- v2.1.0: перехвата чата по шаблонам в скрипте больше нет (состав берётся из
-- /members и из вкладки «Поиск»), поэтому здесь нечего проверять. Разбор
-- Lua-паттернов ниже был копией кода скрипта, а не тестом его поведения -
-- вместе с функцией он удалён, чтобы не создавать ложного покрытия.
-- Ниже остались проверки loadIni: они про сам парсер INI и от [patterns]
-- не зависят.

-- ============================================ ФАЙЛЫ И INI ================
section('File and INI round-trip')
local probe = PATHS.roster
ok('  roster path is absolute-ish', type(probe) == 'string' and #probe > 0)
ok('  writeFile works', writeFile(probe, '{"members":{"A":{"rank":2}}}') ~= false)
eq('  readFile returns same', readFile(probe), '{"members":{"A":{"rank":2}}}')
eq('  readFile missing -> nil', readFile(PATHS.roster .. '.nope'), nil)

local iniPath = PATHS.config .. '.test'
writeFile(iniPath, table.concat({
    '; comment line',
    '# also comment',
    '[main]',
    'hotkey = 0x79',
    'showDismissed = 1',
    '',
    '[members]',
    'enabled = 1',
    '; неизвестный ключ просто сохраняется как есть',
    'unknown = значение',
    'empty =',
}, '\r\n'))
local ini = loadIni(iniPath)
eq('  ini main.hotkey', ini.main and ini.main.hotkey, '0x79')
eq('  ini comments skipped', ini['; comment line'], nil)
eq('  ini section value kept', ini.members and ini.members['enabled'], '1')
eq('  ini cyrillic value kept', ini.members and ini.members['unknown'], 'значение')
eq('  ini empty value', ini.members and ini.members['empty'], '')

PATHS.config = iniPath
if PATHS.hotkey then os.remove(PATHS.hotkey) end   -- hotkey.json с прошлого прогона не должен влиять
loadConfig()
eq('  cfg.hotkey parsed from hex string', cfg.hotkey, tonumber('0x79'))
eq('  cfg.showDismissed', cfg.showDismissed, true)
eq('  members.enabled parsed', cfg.members.enabled, true)
eq('  v2.1.0: cfg.patterns больше нет', cfg.patterns, nil)
eq('  v2.1.0: cfg.captureChat больше нет', cfg.captureChat, nil)

-- ============================================ СИНХРОНИЗАЦИЯ ==============
section('URL encoding and query building')
eq('space -> %20', urlEncode('a b'), 'a%20b')
eq('cyrillic encoded', urlEncode('ключ'), '%D0%BA%D0%BB%D1%8E%D1%87')
eq('unreserved kept', urlEncode('a-b_c.d~e'), 'a-b_c.d~e')
eq('slash encoded', urlEncode('a/b'), 'a%2Fb')
eq('ampersand encoded', urlEncode('a&b'), 'a%26b')
eq('plus encoded', urlEncode('a+b'), 'a%2Bb')
eq('query sorted & joined', buildQuery({ b = '2', a = '1' }), 'a=1&b=2')
eq('nil value skipped', buildQuery({ a = '1', b = nil }), 'a=1')

section('Evolve Logs API: разбор рангов и дат')
local k, n = parseApiRank('Репортер [4]')
eq('rank from brackets', n, 4)
eq('rank kind', k, 'number')
k, n = parseApiRank('Гл.Редактор')
eq('alias Гл.Редактор', n, 7)
k, n = parseApiRank('Тех.Директор [8]')
eq('alias + brackets', n, 8)
k, n = parseApiRank('Ген.Директор')
eq('alias Ген.Директор -> потолок 9', n, 9)
eq('invite', parseApiRank('Invite'), 'invite')
eq('uninvite', parseApiRank('Uninvite'), 'uninvite')
eq('empty string', parseApiRank(''), nil)
eq('nil', parseApiRank(nil), nil)
local t = parseApiDate('10.06.26 14:32')
ok('dd.mm.yy hh:mm parsed', t ~= nil)
eq('  two-digit year', os.date('%Y', t), '2026')
eq('dd.mm.yyyy hh:mm', os.date('%d.%m.%Y %H:%M', parseApiDate('29.11.2025 23:22')), '29.11.2025 23:22')
eq('date only', os.date('%d.%m.%Y', parseApiDate('01.02.2025')), '01.02.2025')
eq('garbage', parseApiDate('когда-то'), nil)

section('[api] config parsing')
local iniPath = PATHS.config .. '.apitest'
writeFile(iniPath, table.concat({
    '[main]', 'hotkey = 0x7A',
    '[api]', 'enabled = 1', 'ttl = 900', 'base = https://api.evolvelogs.ru',
    '[members]', 'enabled = 1',
}, '\r\n'))
PATHS.config = iniPath
if PATHS.hotkey then os.remove(PATHS.hotkey) end
loadConfig()
eq('api enabled', cfg.api.enabled, true)
eq('api ttl', cfg.api.ttl, 900)
eq('api base', cfg.api.base, 'https://api.evolvelogs.ru')
eq('members still parsed', cfg.members.enabled, true)
eq('hotkey from [main]', cfg.hotkey, 0x7A)
-- выключенный API читается как выключенный
writeFile(iniPath, '[api]\r\nenabled = 0\r\n')
loadConfig()
eq('api disabled', cfg.api.enabled, false)
-- пустой base подтягивается к значению по умолчанию
writeFile(iniPath, '[api]\r\nbase =\r\n')
loadConfig()
eq('empty base -> default', cfg.api.base, 'https://api.evolvelogs.ru')
-- транспорт: понимаем auto/download/requests, остальное -> auto
writeFile(iniPath, '[api]\r\ntransport = requests\r\n')
loadConfig()
eq('transport requests', cfg.api.transport, 'requests')
writeFile(iniPath, '[api]\r\ntransport = DOWNLOAD\r\n')
loadConfig()
eq('transport DOWNLOAD -> download', cfg.api.transport, 'download')
writeFile(iniPath, '[api]\r\ntransport = downloadUrlToFile\r\n')
loadConfig()
eq('transport downloadUrlToFile -> download', cfg.api.transport, 'download')
writeFile(iniPath, '[api]\r\ntransport = ерунда\r\n')
loadConfig()
eq('transport мусор -> auto', cfg.api.transport, 'auto')
writeFile(iniPath, '[api]\r\ntransport =\r\n')
loadConfig()
eq('transport пусто -> auto', cfg.api.transport, 'auto')

section('CP1251 <-> UTF-8')

local function chr(...) return string.char(...) end

-- вектор из реальной игры: строка из чата на скриншоте бага
local gameLine = '[SFN Logs] загружен. /sfnlog - окно, /sfnlogsync - обмен'
local cpLine = utf8ToCp1251(gameLine)
eq('utf8->cp1251 обмен', cpLine:match('/sfnlogsync %- (.+)$'), chr(0xEE,0xE1,0xEC,0xE5,0xED))
eq('cp1251->utf8 roundtrip', cp1251ToUtf8(cpLine), gameLine)
eq('utf8->cp1251 roundtrip', utf8ToCp1251(cp1251ToUtf8(cpLine)), cpLine)

-- ASCII не меняется ни в одну сторону
eq('ascii passthrough ->', utf8ToCp1251('Nick_Name 123 !?'), 'Nick_Name 123 !?')
eq('ascii passthrough <-', cp1251ToUtf8('Nick_Name 123 !?'), 'Nick_Name 123 !?')

-- вся кириллица + знаки: полный круг через обе таблицы
local mix = 'АБВ абв Ёё № «» — … Їґі Јўђ'
eq('mix roundtrip', cp1251ToUtf8(utf8ToCp1251(mix)), mix)

-- строка уже в CP1251 (не UTF-8): utf8ToCp1251 не должна её портить
eq('cp1251 input untouched', utf8ToCp1251(cpLine), cpLine)

-- не отображаемый в CP1251 символ превращается в '?'
eq('unmappable -> ?', utf8ToCp1251('a✓b'), 'a?b')

-- байт 0x98 в CP1251 не определён -> U+FFFD
eq('0x98 -> U+FFFD', cp1251ToUtf8(chr(0x98)), chr(0xEF,0xBF,0xBD))

-- isUtf8 отличает новые файлы от старых CP1251
ok('isUtf8 ascii', isUtf8('plain ascii'))
ok('isUtf8 utf8', isUtf8(mix))
ok('isUtf8 cp1251 false', not isUtf8(cpLine))
ok('isUtf8 empty', isUtf8(''))
-- обрезанная UTF-8-последовательность - не валидна
ok('isUtf8 truncated false', not isUtf8(mix:sub(1, #mix - 1)))

-- старые конфиги в CP1251 читаются как UTF-8
local legacyPath = TMP .. '/legacy_config.ini'
writeFile(legacyPath,
    '[main]\r\nrequester = ' .. utf8ToCp1251('Главный_Редактор') .. '\r\n')
local legacy = loadIni(legacyPath)
eq('legacy ini converted', legacy.main['requester'], 'Главный_Редактор')

-- новый конфиг в UTF-8 читается без изменений
local utf8Path = TMP .. '/utf8_config.ini'
writeFile(utf8Path, '[main]\r\nrequester = Главный_Редактор\r\n')
local fresh = loadIni(utf8Path)
eq('utf8 ini as-is', fresh.main['requester'], 'Главный_Редактор')

-- ключи рангов есть в обеих кодировках
eq('rank key utf8', RANK_BY_NAME['Стажёр'], 1)
eq('rank key cp1251', RANK_BY_NAME[utf8ToCp1251('Стажёр')], 1)
eq('rank key cp1251 lower', RANK_BY_NAME[utf8ToCp1251('стажёр')], 1)

-- ================================================= /members (v2.0.9) =====
section('разбор строк /members')

eq('stripColors 6 hex', stripColors('{008000}На работе{FFFFFF}'), 'На работе')
eq('stripColors строка /members',
   stripColors('ID: 1 | 10:00 01.01.2026 | X[1] : Y[2] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 5 секунд'),
   'ID: 1 | 10:00 01.01.2026 | X[1] : Y[2] - Выходной | [AFK]: 5 секунд')
eq('stripColors 8 hex', stripColors('{FF00FF80}x'), 'x')
eq('stripColors не трогает похожее', stripColors('{zzzzzz}x'), '{zzzzzz}x')

local T0 = parseMembersTime('19:23', '06.09.2026')
ok('parseMembersTime разбирает', T0 ~= nil and T0 > 0)
eq('  часы/минуты', os.date('%H:%M', T0), '19:23')
eq('  дата', os.date('%d.%m.%Y', T0), '06.09.2026')
eq('parseMembersTime мусор', parseMembersTime('xx', '06.09.2026'), nil)

local L1 = 'ID: 248 | 19:23 06.09.2026 | Jonny_Wilde[248] (Voice): Программный директор[9] - {008000}На работе{FFFFFF}'
local L2 = 'ID: 986 | 16:55 27.08.2026 | Keron_Power[986] : Редактор[6] - {ae433d}Выходной{FFFFFF}'
local L3 = 'ID: 663 | 23:31 18.06.2026 | Vallo_Caballero[663] (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 360+ секунд'
local L4 = 'ID: 783 | 23:32 03.09.2026 | Gabriela_Bradberry[783] : Ведущий[5] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 311 секунд'

local e1 = parseMembersLine(stripColors(L1))
ok('L1 разобрана', e1 ~= nil)
eq('  ник', e1 and e1.nick, 'Jonny_Wilde')
eq('  id', e1 and e1.id, 248)
eq('  ранг числом', e1 and e1.rank, 9)
eq('  название ранга', e1 and e1.rankText, 'Программный директор')
eq('  Voice', e1 and e1.voice, true)
eq('  На работе', e1 and e1.duty, true)
eq('  AFK нет', e1 and e1.afk, nil)
eq('  последний вход', e1 and e1.loginAt, parseMembersTime('19:23', '06.09.2026'))

local e2 = parseMembersLine(stripColors(L2))
ok('L2 без Voice разобрана', e2 ~= nil)
eq('  voice = false', e2 and e2.voice, false)
eq('  Выходной', e2 and e2.duty, false)
eq('  ранг', e2 and e2.rank, 6)

eq('L3 AFK 360+', (parseMembersLine(stripColors(L3)) or {}).afk, 360)
local e4 = parseMembersLine(stripColors(L4))
eq('L4 AFK 311', e4 and e4.afk, 311)
eq('L4 ранг 5', e4 and e4.rank, 5)

eq('заголовок - не сотрудник', parseMembersLine(stripColors('Члены организации Он-лайн:')), nil)
eq('итог - не сотрудник', parseMembersLine('Всего: 10 человек'), nil)
eq('болтовня - не сотрудник', parseMembersLine('Darren_Tate says hello [1]'), nil)
ok('заголовок распознаётся', membersHeadLine(' Члены организации Он-лайн:'))
eq('итог распознаётся', membersTotalLine(' Всего: 10 человек'), 10)

section('перехват блока /members')

local NOW = os.time()
roster.members = {}
cfg.members = { enabled = true }
local queued, said = {}, {}
MEMBERS_HOOKS.refresh = function(nick, wantHistory)
    queued[#queued + 1] = { nick = nick, hist = wantHistory and true or false }
end
MEMBERS_HOOKS.say = function(text) said[#said + 1] = text end

local BLOCK = {
    ' Члены организации Он-лайн:',
    ' ',
    L1,
    'ID: 568 | 17:02 27.08.2026 | Bad_Dog[568] (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    'ID: 422 | 22:38 03.09.2026 | Akio_Omano[422] (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    L2,
    L3,
    'ID: 376 | 16:57 09.05.2026 | Garik_Grifon[376] (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    'ID: 385 | 00:52 14.09.2026 | Linnea_Korhonen[385] (Voice): Редактор[6] - {008000}На работе{FFFFFF}',
    L4,
    'ID: 264 | 04:18 23.09.2026 | Anna_Malboro[264] (Voice): Звукорежиссер[3] - {008000}На работе{FFFFFF}',
    'ID: 165 | 04:18 23.09.2026 | Sonya_Malboro[165] (Voice): Звукорежиссер[3] - {008000}На работе{FFFFFF}',
    ' ',
    ' Всего: 10 человек',
}

eq('заголовок начинает перехват', membersFeed(BLOCK[1], NOW), 'head')
for i = 2, #BLOCK - 1 do membersFeed(BLOCK[i], NOW + i) end
eq('итог закрывает блок', membersFeed(BLOCK[#BLOCK], NOW + #BLOCK), 'total')

local c = membersCapture
eq('разобрано строк', c.parsed, 10)
eq('добавлено', c.added, 10)
eq('всего из итога', c.total, 10)
eq('перехват закрыт', c.active, false)
eq('в очередь API', c.queued, 10)
eq('репорт в чат один', #said, 1)
ok('репорт содержит «10 строк из 10»',
   said[1] and said[1]:find('10 строк из 10', 1, true) ~= nil, tostring(said[1]))

local uniq = {}
for _, q in ipairs(queued) do uniq[q.nick] = (uniq[q.nick] or 0) + 1 end
local uniqN = 0
for _ in pairs(uniq) do uniqN = uniqN + 1 end
eq('в очереди 10 уникальных ников', uniqN, 10)
eq('запрошена полная история', queued[1] and queued[1].hist, true)

local j = roster.members['Jonny_Wilde']
ok('Jonny_Wilde добавлен', j ~= nil)
eq('  ранг 9', j and j.rank, 9)
eq('  онлайн', j and j.online, true)
eq('  на работе', j and j.onDuty, true)
eq('  последний вход', j and j.lastLogin, parseMembersTime('19:23', '06.09.2026'))
eq('  дата принятия = вход (оценка)', j and j.acceptedAt, parseMembersTime('19:23', '06.09.2026'))
eq('  флаг приблизительной даты', j and j.acceptedApprox, true)
eq('  метка в истории', j and j.history[#j.history].note,
   'состав из /members (дата приблизительная)')
local g = roster.members['Gabriela_Bradberry']
eq('Gabriela ранг 5', g and g.rank, 5)
eq('Gabriela AFK 311', g and g.afk, 311)
eq('Keron без Voice', roster.members['Keron_Power'] and roster.members['Keron_Power'].voice, false)
eq('Vallo AFK 360', roster.members['Vallo_Caballero'] and roster.members['Vallo_Caballero'].afk, 360)

section('повторный /members не плодит записи')
local jHist = #roster.members['Jonny_Wilde'].history
said, queued = {}, {}
membersFeed(BLOCK[1], NOW + 100)
for i = 2, #BLOCK - 1 do membersFeed(BLOCK[i], NOW + 100 + i) end
membersFeed(BLOCK[#BLOCK], NOW + 100 + #BLOCK)
eq('новых нет', membersCapture.added, 0)
eq('все узнаны', membersCapture.seen, 10)
eq('изменений нет', membersCapture.updated, 0)
eq('история не задвоилась', #roster.members['Jonny_Wilde'].history, jHist)

section('изменение ранга по /members')
membersFeed('Члены организации Он-лайн:', NOW + 200)
membersFeed('ID: 783 | 23:32 03.09.2026 | Gabriela_Bradberry[783] : Редактор[6] - {ae433d}Выходной{FFFFFF}', NOW + 201)
membersFeed('Всего: 1 человек', NOW + 202)
eq('ранг обновлён', roster.members['Gabriela_Bradberry'].rank, 6)
eq('учтено как обновление', membersCapture.updated, 1)
local gh = roster.members['Gabriela_Bradberry'].history
eq('запись в истории', gh[#gh].note, 'по /members')

section('уволенный в /members - восстанавливается')
dismissMember('Bad_Dog', 'тест')
eq('уволен', roster.members['Bad_Dog'].dismissed, true)
membersFeed('Члены организации Он-лайн:', NOW + 300)
membersFeed(BLOCK[4], NOW + 301)
membersFeed('Всего: 1 человек', NOW + 302)
eq('снова в составе', roster.members['Bad_Dog'].dismissed, false)

section('кто принял не затирается')
roster.members['Anna_Malboro'].acceptedBy = 'Chief_News'
membersFeed('Члены организации Он-лайн:', NOW + 400)
membersFeed(BLOCK[11], NOW + 401)
membersFeed('Всего: 1 человек', NOW + 402)
eq('acceptedBy сохранён', roster.members['Anna_Malboro'].acceptedBy, 'Chief_News')

section('приблизительная дата не даёт повышать')
local anna = roster.members['Anna_Malboro']
local _, readyA, whyA = promotionInfo(anna, NOW)
eq('не готов', readyA, false)
eq('причина', whyA, 'дата приблизительная (/members)')
anna.apiFetchedAt = NOW
local _, readyB = promotionInfo(anna, NOW + 3 * 86400)
eq('после API срок считается', readyB, true)

section('ранг выше потолка прижимается к 9')
membersFeed('Члены организации Он-лайн:', NOW + 500)
membersFeed('ID: 5 | 12:00 01.01.2026 | Big_Boss[5] : Ген.Директор[10] - {008000}На работе{FFFFFF}', NOW + 501)
membersFeed('Всего: 1 человек', NOW + 502)
eq('ранг 10 -> 9', roster.members['Big_Boss'] and roster.members['Big_Boss'].rank, 9)

section('обрыв блока и выключенный перехват')
membersFeed('Члены организации Он-лайн:', NOW + 600)
membersFeed(BLOCK[3], NOW + 601)
membersFeed('какой-то другой текст', NOW + 620)
eq('перехват закрыт по таймауту', membersCapture.active, false)
ok('репорт помечен (обрыв)',
   membersCapture.text:find('обрыв', 1, true) ~= nil, membersCapture.text)
eq('разобранное сохранено', membersCapture.parsed, 1)

membersStart(NOW + 700)
cfg.members.enabled = false
membersFeed(BLOCK[3], NOW + 701)
eq('выключен - строки не разбираются', membersCapture.parsed, 0)
cfg.members.enabled = true

section('многострочные сообщения /members (v2.0.10)')
-- На Evolve RP блок /members приходит не построчно, а несколькими сообщениями,
-- строки внутри которых склеены \\n. Раньше из такого сообщения виделся только
-- заголовок, а строки того же сообщения пропадали (в чате «0 строк из 10»).
-- Теперь membersFeed режет сообщение на строки и кормит их по одной.
roster.members = {}
said, queued = {}, {}
local M1 = table.concat({
    '{00FF00}[23:49:52] Члены организации Он-лайн:',
    '',
    '{FFFFFF}[23:49:52] ID: 248 | 19:23 06.09.2026 | {FF66CC}Jonny_Wilde{FFFFFF}[248] (Voice): Программный директор[9] - {008000}На работе{FFFFFF}',
    '[23:49:52] ID: 568 | 17:02 27.08.2026 | Bad_Dog[568] (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    '[23:49:52] ID: 986 | 16:55 27.08.2026 | Keron_Power[986] : Редактор[6] - {ae433d}Выходной{FFFFFF}',
    '{00FF00}[23:49:52] Всего: 3 человека',
}, '\n')
eq('блок одним сообщением: вердикт', membersFeed(M1, NOW + 800), 'total')
eq('  разобрано', membersCapture.parsed, 3)
eq('  добавлено', membersCapture.added, 3)
eq('  итог из сообщения', membersCapture.total, 3)
eq('  в очередь API', membersCapture.queued, 3)
eq('  перехват закрыт', membersCapture.active, false)
eq('  Jonny_Wilde ранг 9 (цвет ника срезан)',
   roster.members['Jonny_Wilde'] and roster.members['Jonny_Wilde'].rank, 9)
eq('  Bad_Dog ранг 6 (префикс [23:49:52] не мешает)',
   roster.members['Bad_Dog'] and roster.members['Bad_Dog'].rank, 6)
ok('  Keron_Power добавлен', roster.members['Keron_Power'] ~= nil)
ok('  репорт в чат «3 строк из 3»',
   said[1] and said[1]:find('3 строк из 3', 1, true) ~= nil, tostring(said[1]))

-- заголовок одним сообщением, строки+итог - вторым (вариант из скриншота)
roster.members = {}
said, queued = {}, {}
eq('заголовок отдельным сообщением',
   membersFeed('{00FF00}[23:49:52] Члены организации Он-лайн:', NOW + 900), 'head')
membersFeed(table.concat({
    '[23:49:52] ID: 248 | 19:23 06.09.2026 | Jonny_Wilde[248] (Voice): Программный директор[9] - На работе',
    '[23:49:52] ID: 264 | 04:18 23.09.2026 | Anna_Malboro[264] (Voice): Звукорежиссер[3] - На работе',
    '[23:49:52] Всего: 2 человека',
}, '\n'), NOW + 901)
eq('два сообщения: разобрано', membersCapture.parsed, 2)
eq('два сообщения: добавлено', membersCapture.added, 2)
eq('два сообщения: итог', membersCapture.total, 2)
eq('два сообщения: перехват закрыт', membersCapture.active, false)

-- CRLF и хвостовой перевод строки
roster.members = {}
membersFeed('Члены организации Он-лайн:\r\n'
    .. 'ID: 7 | 12:00 01.01.2026 | Test_Odin[7] : Стажёр[1] - Выходной\r\n'
    .. 'Всего: 1 человек\r\n', NOW + 950)
eq('CRLF разбирается', membersCapture.parsed, 1)
eq('CRLF итог', membersCapture.total, 1)

-- однострочные сообщения - поведение прежнее
roster.members = {}
eq('одна строка: заголовок', membersFeed('Члены организации Он-лайн:', NOW + 960), 'head')
eq('одна строка: сотрудник',
   membersFeed('ID: 8 | 12:00 01.01.2026 | Test_Dva[8] : Стажёр[1] - Выходной', NOW + 961), 'added')
eq('одна строка: болтовня', membersFeed('просто болтовня', NOW + 962), nil)
eq('одна строка: итог', membersFeed('Всего: 1 человек', NOW + 963), 'total')

section('реальный дамп Evolve RP: без [ID] после ника (v2.0.11)')
-- chat_dump.txt от 28.09.2026 00:35:13 (saint-louis, SF News): сервер печатает
-- «Jonny_Wilde (Voice):», а НЕ «Jonny_Wilde[248] (Voice):». Старый шаблон
-- требовал обязательный [ID] после ника и не разбирал ни одной строки —
-- в чате было «/members: 0 строк из 11», в настройках «последний разбор: 0 из 11».
local D1 = ' ID: 248 | 19:23 06.09.2026 | Jonny_Wilde (Voice): Программный директор[9] - {008000}На работе{FFFFFF}'
local D2 = ' ID: 38 | 21:47 22.09.2026 | Aru_Traxer (Voice): Гл.Редактор[7] - {008000}На работе{FFFFFF}'
local D3 = ' ID: 68 | 23:32 03.09.2026 | Gabriela_Bradberry : Ведущий[5] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 360+ секунд'
local D4 = ' ID: 376 | 16:57 09.05.2026 | Garik_Grifon (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 360+ секунд'

local d1 = parseMembersLine(stripColors(D1))
ok('D1 «Nick (Voice):» разобрана', d1 ~= nil)
eq('  ник', d1 and d1.nick, 'Jonny_Wilde')
eq('  id берётся из начала строки', d1 and d1.id, 248)
eq('  ранг', d1 and d1.rank, 9)
eq('  название ранга', d1 and d1.rankText, 'Программный директор')
eq('  Voice', d1 and d1.voice, true)
eq('  На работе', d1 and d1.duty, true)
eq('  последний вход', d1 and d1.loginAt, parseMembersTime('19:23', '06.09.2026'))
eq('  цветные теги не мешают и без stripColors', (parseMembersLine(D1) or {}).nick, 'Jonny_Wilde')

local d2 = parseMembersLine(stripColors(D2))
eq('D2 «Гл.Редактор» -> 7', d2 and d2.rank, 7)
eq('  название ранга', d2 and d2.rankText, 'Гл.Редактор')
eq('  ник', d2 and d2.nick, 'Aru_Traxer')

local d3 = parseMembersLine(stripColors(D3))
ok('D3 без (Voice) и без [ID] разобрана', d3 ~= nil)
eq('  voice = false', d3 and d3.voice, false)
eq('  ранг 5', d3 and d3.rank, 5)
eq('  AFK 360+', d3 and d3.afk, 360)
eq('  Выходной', d3 and d3.duty, false)

local d4 = parseMembersLine(stripColors(D4))
eq('D4 Voice + AFK вместе', d4 and d4.voice, true)
eq('  AFK', d4 and d4.afk, 360)

-- старый формат с [ID] после ника продолжает разбираться
local o1 = parseMembersLine('ID: 248 | 19:23 06.09.2026 | Jonny_Wilde[248] (Voice): Программный директор[9] - На работе')
eq('[ID]+(Voice): ник', o1 and o1.nick, 'Jonny_Wilde')
eq('[ID]+(Voice): ранг', o1 and o1.rank, 9)
eq('[ID]+(Voice): голос', o1 and o1.voice, true)
local o2 = parseMembersLine('ID: 986 | 16:55 27.08.2026 | Keron_Power[986] : Редактор[6] - Выходной')
eq('[ID] без (Voice): ник', o2 and o2.nick, 'Keron_Power')
eq('[ID] без (Voice): голос', o2 and o2.voice, false)

-- прочие варианты хвоста между ником и двоеточием
eq('хвост (Voice)[8]', (parseMembersLine('ID: 8 | 10:00 01.01.2026 | Test_Voice_Id (Voice) [8]: Стажёр[1] - На работе') or {}).voice, true)
eq('хвост [8](Voice) без пробелов', (parseMembersLine('ID: 2 | 10:00 01.01.2026 | Petr_Sidorov[2](Voice): Стажёр[1] - На работе') or {}).voice, true)
eq('хвост пустой (닉 сразу с двоеточием)', (parseMembersLine('ID: 3 | 10:00 01.01.2026 | Oleg_Kuvshinov:Стажёр[1] - На работе') or {}).nick, 'Oleg_Kuvshinov')
eq('чужая метка в скобках голосом не считается', (parseMembersLine('ID: 1 | 10:00 01.01.2026 | Ivan_Petrov (Голос): Стажёр[1] - На работе') or {}).voice, false)

-- статус может отсутствовать: дефис перед ним необязателен
local nd = parseMembersLine('ID: 4 | 10:00 01.01.2026 | Test_Bez_St: Стажёр[1]')
eq('без статуса: ник', nd and nd.nick, 'Test_Bez_St')
eq('без статуса: ранг', nd and nd.rank, 1)
eq('без статуса: duty неизвестен', nd and nd.duty, nil)

-- ник не режется по границе: подозрительный хвост отвергает строку целиком
eq('ник с точкой отвергается', parseMembersLine('ID: 5 | 10:00 01.01.2026 | John.Smith (Voice): Стажёр[1] - Выходной'), nil)
eq('мусор в хвосте отвергается', parseMembersLine('ID: 6 | 10:00 01.01.2026 | Nick - Лидер: Стажёр[1] - Выходной'), nil)
-- на версиях до 2.0.11 такой функции нет: тест должен падать, а не обрывать прогон
local tailOk = membersNickTailOk or function() return false end
ok('membersNickTailOk: «[248] (Voice)»', tailOk('[248] (Voice)'))
ok('membersNickTailOk: « (Voice)»', tailOk(' (Voice)'))
ok('membersNickTailOk: «[248] »', tailOk('[248] '))
ok('membersNickTailOk: « »', tailOk(' '))
ok('membersNickTailOk: nil', tailOk(nil))
eq('membersNickTailOk: «.Smith»', tailOk('.Smith'), false)
eq('membersNickTailOk: « - Лидер»', tailOk(' - Лидер'), false)

-- служебные символы сообщения не мешают
eq('хвостовой CR', (parseMembersLine('ID: 7 | 10:00 01.01.2026 | Test_Cr (Voice): Стажёр[1] - На работе\r') or {}).duty, true)
eq('префикс времени чата', (parseMembersLine('[00:35:13] ID: 9 | 10:00 01.01.2026 | Test_Prefix (Voice): Стажёр[1] - На работе') or {}).nick, 'Test_Prefix')

section('блок /members из живого дампа целиком (v2.0.11)')
local DUMP = {
    ' Члены организации Он-лайн:',
    ' ',
    D1,
    D2,
    ' ID: 385 | 00:52 14.09.2026 | Linnea_Korhonen (Voice): Редактор[6] - {008000}На работе{FFFFFF}',
    D4,
    ' ID: 663 | 23:31 18.06.2026 | Vallo_Caballero (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    ' ID: 478 | 17:02 27.08.2026 | Bad_Dog (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    ' ID: 10 | 22:38 03.09.2026 | Akio_Omano (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
    D3,
    ' ID: 917 | 18:58 14.04.2026 | Alex_Wilde (Voice): Ведущий[5] - {ae433d}Выходной{FFFFFF}',
    ' ID: 179 | 04:18 23.09.2026 | Anna_Malboro (Voice): Репортер[4] - {008000}На работе{FFFFFF}',
    ' ID: 165 | 04:18 23.09.2026 | Sonya_Malboro (Voice): Репортер[4] - {008000}На работе{FFFFFF}',
    ' ',
    ' Всего: 11 человек',
}

roster.members = {}
said, queued = {}, {}
for i, m in ipairs(DUMP) do membersFeed(m, NOW + 1000 + i) end
eq('дамп: разобрано строк', membersCapture.parsed, 11)
eq('дамп: добавлено', membersCapture.added, 11)
eq('дамп: итог', membersCapture.total, 11)
eq('дамп: в очередь API', membersCapture.queued, 11)
eq('дамп: пропущено', membersCapture.skipped, 0)
eq('дамп: перехват закрыт', membersCapture.active, false)
ok('дамп: репорт «11 строк из 11»',
   said[1] and said[1]:find('11 строк из 11', 1, true) ~= nil, tostring(said[1]))
eq('дамп: Aru_Traxer ранг 7', roster.members['Aru_Traxer'] and roster.members['Aru_Traxer'].rank, 7)
eq('дамп: Gabriela_Bradberry ранг 5', roster.members['Gabriela_Bradberry'] and roster.members['Gabriela_Bradberry'].rank, 5)
eq('дамп: Gabriela AFK 360', roster.members['Gabriela_Bradberry'] and roster.members['Gabriela_Bradberry'].afk, 360)
eq('дамп: Anna_Malboro ранг 4', roster.members['Anna_Malboro'] and roster.members['Anna_Malboro'].rank, 4)
eq('дамп: Sonya_Malboro ранг 4', roster.members['Sonya_Malboro'] and roster.members['Sonya_Malboro'].rank, 4)
eq('дамп: Akio_Omano ранг 6', roster.members['Akio_Omano'] and roster.members['Akio_Omano'].rank, 6)
eq('дамп: Linnea_Korhonen на работе', roster.members['Linnea_Korhonen'] and roster.members['Linnea_Korhonen'].onDuty, true)
eq('дамп: Garik_Grifon выходной', roster.members['Garik_Grifon'] and roster.members['Garik_Grifon'].onDuty, false)
eq('дамп: Jonny_Wilde голос', roster.members['Jonny_Wilde'] and roster.members['Jonny_Wilde'].voice, true)
eq('дамп: Gabriela без голоса', roster.members['Gabriela_Bradberry'] and roster.members['Gabriela_Bradberry'].voice, false)
local dumpNicks = 0
for _ in pairs(roster.members) do dumpNicks = dumpNicks + 1 end
eq('дамп: в журнале 11 человек', dumpNicks, 11)

-- тот же блок одним сообщением (сервер может склеить строки через \n)
roster.members = {}
said, queued = {}, {}
membersFeed(table.concat(DUMP, '\n'), NOW + 1200)
eq('дамп одним сообщением: разобрано', membersCapture.parsed, 11)
eq('дамп одним сообщением: итог', membersCapture.total, 11)
eq('дамп одним сообщением: добавлено', membersCapture.added, 11)

-- повторный /members не плодит записи
said, queued = {}, {}
for i, m in ipairs(DUMP) do membersFeed(m, NOW + 1300 + i) end
eq('дамп повторно: новых нет', membersCapture.added, 0)
eq('дамп повторно: узнаны все', membersCapture.seen, 11)
eq('дамп повторно: разобрано', membersCapture.parsed, 11)

section('живой chat_dump.txt как файл: сквозной прогон дампа')
-- Тот самый дамп, по которому найден баг 2.0.11 (tests/fixtures/). Строка
-- дампа имеет вид «[дд.мм.гггг чч:мм:сс] текст сообщения» + \r от CRLF:
-- префикс срезаем, текст кормим в membersFeed ровно как onServerMessage.
local DUMP_FIXTURE = 'tests/fixtures/chat_dump_2026-09-28.txt'
local fh = io.open(DUMP_FIXTURE, 'rb')
if not fh then
    print('  (нет ' .. DUMP_FIXTURE .. ' — секция пропущена)')
else
    local raw = fh:read('*a')
    fh:close()
    roster.members = {}
    said, queued = {}, {}
    local fed = 0
    for line in raw:gmatch('[^\n]+') do
        local text = line:match('^%[%d%d?%.%d%d?%.%d%d%d%d %d%d?:%d%d:%d%d%] (.*)$')
        if text then
            text = (text:gsub('\r$', ''))
            membersFeed(text, NOW + 2000 + fed)
            fed = fed + 1
        end
    end
    ok('фиксатура дампа прочитана', fed > 0)
    eq('файл-дамп: разобрано сотрудников', membersCapture.parsed, 11)
    eq('файл-дамп: итог из «Всего: 11 человек»', membersCapture.total, 11)
    eq('файл-дамп: добавлено', membersCapture.added, 11)
    eq('файл-дамп: в очередь API', membersCapture.queued, 11)
    ok('файл-дамп: репорт «11 строк из 11»',
       said[1] and said[1]:find('11 строк из 11', 1, true) ~= nil, tostring(said[1]))
    eq('файл-дамп: Jonny_Wilde ранг 9', roster.members['Jonny_Wilde'] and roster.members['Jonny_Wilde'].rank, 9)
    eq('файл-дамп: Aru_Traxer ранг 7', roster.members['Aru_Traxer'] and roster.members['Aru_Traxer'].rank, 7)
    eq('файл-дамп: Gabriela_Bradberry AFK', roster.members['Gabriela_Bradberry'] and roster.members['Gabriela_Bradberry'].afk, 360)
end

section('нулевые даты не показывают 1970 год')
eq('fmtDate(0)', fmtDate(0), '--.--.----')
eq('fmtDateTime(0)', fmtDateTime(0), '-')
eq('fmtDate(nil)', fmtDate(nil), '--.--.----')
local anon = addMember('No_Login', '', nil, 1, 0, NOW)
roster.members['No_Login'].acceptedAt = 0
roster.members['No_Login'].promotedAt = 0
eq('без входа - прочерк', fmtDate(roster.members['No_Login'].acceptedAt), '--.--.----')

MEMBERS_HOOKS.refresh, MEMBERS_HOOKS.say = nil, nil

-- ================================================== v2.0.12 ==============
section('v2.0.12: клавиша окна (VK-коды, миграция, фронт) и ник запрашивающего')

-- список клавиш: коды Win32 VK, без дублей
local hasList = type(HOTKEY_OPTIONS) == 'table' and #HOTKEY_OPTIONS > 0
ok('список клавиш HOTKEY_OPTIONS есть', hasList)
if hasList then
    local seenCode, seenName = {}, {}
    for _, hk in ipairs(HOTKEY_OPTIONS) do
        ok('список клавиш: код уникален ' .. hk.name, not seenCode[hk.code])
        ok('список клавиш: имя уникален ' .. hk.name, not seenName[hk.name])
        seenCode[hk.code], seenName[hk.name] = true, true
    end
end
local hasVk = type(vkToName) == 'function'
ok('vkToName есть', hasVk)
if hasVk then
    eq('vkToName F8',  vkToName(0x77), 'F8')
    eq('vkToName F6',  vkToName(0x75), 'F6')
    eq('vkToName F11', vkToName(0x7A), 'F11')
    eq('vkToName PageDown', vkToName(0x22), 'PageDown')
    eq('vkToName неизвестный код', vkToName(0x1234), 'VK 0x1234')
end

-- миграция старых перепутанных кодов: намерение по подписи, а не сырой код
local migPath = PATHS.config .. '.hk'
if PATHS.hotkey then os.remove(PATHS.hotkey) end
for _, c in ipairs({ { 0x75, 0x77 }, { 0x77, 0x79 }, { 0x70, 0x70 },
                     { 0x7A, 0x7A }, { 0x2E, 0x2E } }) do
    writeFile(migPath, '[main]\r\nhotkey = ' .. c[1] .. '\r\n')
    PATHS.config = migPath
    loadConfig()
    eq('миграция hotkey ' .. c[1] .. ' -> ' .. c[2], cfg.hotkey, c[2])
end

-- выбор в настройках пишется в hotkey.json и важнее config.ini
local hasHkSave = type(saveHotkey) == 'function' and type(loadHotkey) == 'function'
ok('saveHotkey/loadHotkey есть', hasHkSave)
cfg.hotkey = 0x79
if hasHkSave then saveHotkey() end
writeFile(migPath, '[main]\r\nhotkey = 0x75\r\n')
PATHS.config = migPath
loadConfig()
eq('hotkey.json важнее config.ini', cfg.hotkey, 0x79)
cfg.hotkey = 0x70
if hasHkSave then loadHotkey() end
eq('loadHotkey возвращает выбор', cfg.hotkey, 0x79)
local hkRaw = hasHkSave and readFile(PATHS.hotkey) or nil
ok('hotkey.json хранит код', hkRaw ~= nil and hkRaw:find('"hotkey":121', 1, true) ~= nil,
   tostring(hkRaw))

-- фронт нажатия: удержание = одно срабатывание, чужой курсор не открывает
local hasPress = type(checkHotkeyPress) == 'function'
ok('checkHotkeyPress есть', hasPress)
local key = { down = false, cursor = false, chat = false }
isKeyDown = function() return key.down end
sampIsCursorActive = function() return key.cursor end
sampIsChatInputActive = function() return key.chat end
local win = { [0] = false }
cfg.hotkey = 0x77
if hasPress then
    key.down = true
    ok('фронт: окно открылось', checkHotkeyPress(win) == true and win[0] == true)
    ok('удержание: без повторов', checkHotkeyPress(win) == false and win[0] == true)
    key.down = false
    ok('отпускание: тихо', checkHotkeyPress(win) == false and win[0] == true)
    key.down = true
    ok('фронт: окно закрылось (курсор наш)', checkHotkeyPress(win) == true and win[0] == false)
    key.down = false
    checkHotkeyPress(win)
    key.cursor, key.down = true, true
    ok('чужой курсор: не открывает', checkHotkeyPress(win) == false and win[0] == false)
    key.down = false
    checkHotkeyPress(win)
    key.cursor, key.chat, key.down = false, true, true
    ok('ввод в чат: не переключает', checkHotkeyPress(win) == false and win[0] == false)
    key.chat, key.down = false, false
    checkHotkeyPress(win)
end
isKeyDown, sampIsCursorActive, sampIsChatInputActive = nil, nil, nil

-- ник запрашивающего: два способа, оба под pcall
local hasNick = type(detectLocalNick) == 'function'
ok('detectLocalNick есть', hasNick)
PLAYER_PED = 0
local savedNickFn = sampGetPlayerNickname
if hasNick then
    sampGetPlayerId = function() return 42 end
    sampGetPlayerNickname = function(id) return id == 42 and 'Jonny_Wilde' or ('Wrong_' .. tostring(id)) end
    eq('ник: способ 1 (ид локального игрока)', detectLocalNick(), 'Jonny_Wilde')
    sampGetPlayerId = nil
    sampGetPlayerIdByCharHandle = function() return true, 7 end
    sampGetPlayerNickname = function(id) return id == 7 and 'Akio_Omano' or 'Wrong' end
    eq('ник: способ 2 (пара успех+ид из хендла)', detectLocalNick(), 'Akio_Omano')
    sampGetPlayerIdByCharHandle = function() return true end     -- старая ошибка: только «успех»
    eq('ник: одиночный «успех» не ид', detectLocalNick(), nil)
    sampGetPlayerIdByCharHandle = function() return false, -1 end
    eq('ник: нет успеха - nil', detectLocalNick(), nil)
    sampGetPlayerId = function() error('no samp') end
    sampGetPlayerIdByCharHandle = function() error('no samp') end
    eq('ник: оба способа недоступны - nil', detectLocalNick(), nil)
end
sampGetPlayerNickname = savedNickFn
sampGetPlayerId, sampGetPlayerIdByCharHandle = nil, nil

-- ================================================ батчинг saveRoster ======
-- фикс 2.0.13 (фризы): roster.json больше не пишется после каждого ответа
-- API - saveRoster() лишь помечает журнал «грязным», главный цикл пишет не
-- чаще раза в 5 с (tickRosterSave), saveRoster(true) - немедленная запись.
section('saveRoster: отложенная запись (батчинг)')
roster = { members = {}, version = 1 }
writeFile(PATHS.roster, 'STALE')
rosterSaveInterval(3600)
addMember('Batch_Man', '', os.time(), 1, 0)      -- внутри зовёт saveRoster()
eq('после правки файл сразу не перезаписан', readFile(PATHS.roster), 'STALE')
eq('тик до истечения интервала не пишет', tickRosterSave(), false)
eq('файл по-прежнему прежний', readFile(PATHS.roster), 'STALE')
rosterSaveInterval(0)
eq('тик после истечения интервала пишет', tickRosterSave(), true)
local dBatch = json.decode(readFile(PATHS.roster))
ok('отложенная запись сохранила сотрудника',
   dBatch and dBatch.members and dBatch.members['Batch_Man'] ~= nil)
eq('повторный тик ничего не делает (не грязно)', tickRosterSave(), false)
rosterSaveInterval(3600)
addMember('Batch_Force', '', os.time(), 1, 0)
saveRoster(true)
local dForce = json.decode(readFile(PATHS.roster))
ok('saveRoster(true) пишет немедленно',
   dForce and dForce.members and dForce.members['Batch_Force'] ~= nil)
eq('интервал по умолчанию 5 с', rosterSaveInterval(5), 5)
-- страховка исходника: убранные кнопки и мёртвые вызовы не возвращаются
local full = assert(io.open(SRC, 'r')):read('*a')
ok('окно: кнопки добавления/уровней/экспорта убраны',
   full:find("flowButton('jadd'", 1, true) == nil
   and full:find("flowButton('jlevels'", 1, true) == nil
   and full:find("flowButton('jexport'", 1, true) == nil)
ok('цикл: мёртвая wasKeyPressed не вернулась',
   full:find('wasKeyPressed(cfg.hotkey)', 1, true) == nil)
ok('цикл: клавиша через фронт isKeyDown',
   full:find('checkHotkeyPress(win)', 1, true) ~= nil)
ok('запрашивающий: ник двумя способами',
   full:find('function detectLocalNick()', 1, true) ~= nil
   and full:find('pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)', 1, true) ~= nil)
ok('API: финальный код 58 зашит явно',
   full:find('[58] = true', 1, true) ~= nil)
ok('API: авто-уход на requests только после 8 неудач',
   full:find("and 8 or 2", 1, true) ~= nil)
ok('батчинг: saveRoster(true) на выгрузке скрипта',
   full:find('pcall(saveRoster, true)', 1, true) ~= nil)
ok('батчинг: в главном цикле тик отложенной записи',
   full:find('pcall(tickRosterSave)', 1, true) ~= nil)
ok('батчинг: старого немедленного pcall(saveRoster) в цикле нет',
   full:find('pcall(saveRoster)', 1, true) == nil)
-- ====================================== v2.1.0: УБОРКА ИНТЕРФЕЙСА =========
section('v2.1.0: перехват чата и значок «‹» убраны')

-- перехвата чата по шаблонам больше нет: ни функции, ни конфига, ни файлов
ok('в PURE-секции нет перехвата чата', body:find('cfg.patterns', 1, true) == nil)
ok('в PURE-секции нет дампа чата', body:find('captureChat', 1, true) == nil)
-- упоминание chat_dump.txt в PURE-секции осталось только в историческом
-- комментарии к фикстурам /members: самого файла скрипт больше не создаёт
eq('PATHS больше не содержит chatdump', PATHS.chatdump, nil)
eq('PATHS config на месте', type(PATHS.config), 'string')
eq('PATHS roster на месте', type(PATHS.roster), 'string')
eq('PATHS export на месте', type(PATHS.export), 'string')

-- состав по-прежнему собирается из /members: разбор строк не пострадал
ok('разбор /members остался', body:find('function membersFeed(', 1, true) ~= nil)
ok('хук очереди API остался', body:find('MEMBERS_HOOKS', 1, true) ~= nil)

-- страховка по всему исходнику: удалённое не возвращается
-- в исходнике остались только исторические комментарии про удалённое,
-- поэтому проверяем рабочий код, а не упоминания в тексте
ok('исходник: команда /sfnlogcap не регистрируется',
   full:find("sampRegisterChatCommand('sfnlogcap'", 1, true) == nil)
ok('исходник: нет ключа chatdump в PATHS', full:find("chatdump  = DIR", 1, true) == nil)
ok('исходник: секция [patterns] не создаётся', full:find('\n[patterns]', 1, true) == nil)
ok('исходник: нет loadPatternsFromIni', full:find('loadPatternsFromIni', 1, true) == nil)
ok('исходник: нет matchPattern/onAccept', full:find('matchPattern', 1, true) == nil
   and full:find('function onAccept', 1, true) == nil)
ok('исходник: значок «‹» не рисуется', full:find("'ANGLE_LEFT'", 1, true) == nil)
ok('исходник: команда выгрузки зарегистрирована',
   full:find("sampRegisterChatCommand('sfnlogexport'", 1, true) ~= nil)
ok('исходник: версии в шапке и внутри совпадают',
   full:find("script_version('2.2.4')", 1, true) ~= nil
   and full:find("SFN_VERSION_STR = '2.2.4'", 1, true) ~= nil)
-- v2.2.3: в 2.1.0 подписка на чат потерялась, и /members не перехватывался в
-- игре при зелёных тестах (они зовут membersFeed напрямую). Больше нельзя.
ok('исходник: подписка sampev.onServerMessage на месте',
   full:find('function sampev.onServerMessage', 1, true) ~= nil)
ok('исходник: onServerMessage опубликован для тестов',
   full:find('SFNLogs.onServerMessage = onServerMessage', 1, true) ~= nil)
ok('исходник: скролл-фикс v2.2.2 на месте (закрепление тела и клип строк)',
   full:find("NoScrollWithMouse", 1, true) ~= nil
   and full:find("PushClipRect, dl, V(bx, by - S(1))", 1, true) ~= nil)

-- заголовки разделов окна: string.upper() не знает кириллицу
eq('titleCase: латиница', titleCase('evolve logs'), 'Evolve logs')
eq('titleCase: кириллица', titleCase('состав из игры'), 'Состав из игры')
eq('titleCase: смешанный', titleCase('данные из evolve logs'), 'Данные из evolve logs')
eq('titleCase: латиница в верхнем регистре не портится', titleCase('EVOLVE'), 'EVOLVE')
eq('titleCase: уже смешанный', titleCase('Evolve Logs'), 'Evolve Logs')
eq('titleCase: ё', titleCase('ёлки'), 'Ёлки')
eq('titleCase: уже заглавная', titleCase('Окно'), 'Окно')
eq('titleCase: пустая строка', titleCase(''), '')
eq('titleCase: nil', titleCase(nil), nil)
eq('titleCase: одна буква', titleCase('о'), 'О')

-- дефолтный конфиг, который скрипт создаёт при первом запуске, чистый
ok('DEFAULT_INI: нет [patterns]', DEFAULT_INI:find('\n[patterns]', 1, true) == nil)
ok('DEFAULT_INI: нет /sfnlogcap', DEFAULT_INI:find('sfnlogcap', 1, true) == nil)
ok('DEFAULT_INI: нет chat_dump', DEFAULT_INI:find('chat_dump', 1, true) == nil)
ok('DEFAULT_INI: [members] на месте', DEFAULT_INI:find('[members]', 1, true) ~= nil)
ok('DEFAULT_INI: [api] на месте', DEFAULT_INI:find('[api]', 1, true) ~= nil)

-- пустой/старый config.ini не роняет загрузку
local emptyPath = TMP .. '/empty_config.ini'
writeFile(emptyPath, '')
PATHS.config = emptyPath
if PATHS.hotkey then os.remove(PATHS.hotkey) end   -- выбор клавиши важнее config.ini
loadConfig()
ok('пустой config.ini читается без ошибок', cfg ~= nil and cfg.api ~= nil)
-- hotkey.json в этой песочнице удалить нельзя (путь с обратными слэшами),
-- поэтому проверяем не значение по умолчанию, а то, что конфиг перечитывается
writeFile(emptyPath, '[main]\r\nshowDismissed = 1\r\n[members]\r\nenabled = 0\r\n')
loadConfig()
eq('  showDismissed из config.ini', cfg.showDismissed, true)
eq('  members.enabled из config.ini', cfg.members.enabled, false)

-- ============================================ v2.2.0: АВТООБНОВЛЕНИЕ ======
section('v2.2.0: parseVersion и сравнение версий')
local v = parseVersion('2.1.0')
ok('parseVersion разбирает «2.1.0»', v and v[1] == 2 and v[2] == 1 and v[3] == 0)
eq('parseVersion: мусор -> nil', parseVersion('когда-то'), nil)
eq('parseVersion: две цифры -> nil', parseVersion('2.1'), nil)
eq('parseVersion: nil -> nil', parseVersion(nil), nil)
eq('parseVersion: число -> nil', parseVersion(210), nil)
eq('parseVersion: бета-хвост -> nil', parseVersion('2.1.0-beta'), nil)
ok('parseVersion допускает пробелы', parseVersion(' 2.1.0 ') ~= nil)

ok('2.1.1 новее 2.1.0', isNewerVersion('2.1.1', '2.1.0'))
ok('2.2.0 новее 2.1.9', isNewerVersion('2.2.0', '2.1.9'))
ok('2.1.10 новее 2.1.9 (не лексикографически)', isNewerVersion('2.1.10', '2.1.9'))
ok('10.0.0 новее 9.9.9', isNewerVersion('10.0.0', '9.9.9'))
ok('равные версии - не новее (иначе цикл обновления)', not isNewerVersion('2.1.0', '2.1.0'))
ok('старая версия - не новее', not isNewerVersion('2.0.13', '2.1.0'))
ok('мусор вместо новой версии - не новее', not isNewerVersion('abc', '2.1.0'))
ok('мусор вместо текущей версии - не новее', not isNewerVersion('2.2.0', nil))

section('v2.2.0: extractScriptVersion')
eq('версия из шапки', extractScriptVersion("script_name('X')\nscript_version('2.3.1')\n"), '2.3.1')
eq('версия с пробелами в вызове', extractScriptVersion("script_version ( '2.3.1' )"), '2.3.1')
eq('нет script_version -> nil', extractScriptVersion('local a = 1'), nil)
eq('nil на входе', extractScriptVersion(nil), nil)

-- «скачанный скрипт»: все маркеры на месте, размер добирается комментариями
local function fakeScript(ver, padTo)
    local head = table.concat({
        "script_name('SFN Logs')",
        "script_version('" .. ver .. "')",
        "script_author('San Fierro News')",
        '-- >>> PURE LOGIC ' .. 'BEGIN',
        'function membersFeed(text, now) return true end',
        '-- <<< PURE LOGIC ' .. 'END',
        'function main() end',
        "local SFN_VERSION_STR = '" .. ver .. "'",
    }, '\n')
    local pad = padTo or (UPDATE_MIN_BYTES + 100)
    while #head < pad do head = head .. '\n-- x' end
    return head
end

section('v2.2.0: validateScriptText — скачанный файл проверяется до замены')
-- SFN_VERSION_STR объявлен вне PURE-секции (в ImGui-части), поэтому здесь
-- версия задаётся явно; её совпадение с исходником проверяется в страховках.
local CUR = '2.2.4'
ok('текущая версия скрипта совпадает с ожидаемой в тесте',
   full:find("script_version('" .. CUR .. "')", 1, true) ~= nil)

-- у строк Lua нет :replace(), а gsub трактует шаблон как паттерн, поэтому
-- literal-замена своя (в «скачанных» файлах подменяются маркеры проверки)
local function literalReplace(s, from, to)
    local i = s:find(from, 1, true)
    if not i then return s end
    return s:sub(1, i - 1) .. to .. s:sub(i + #from)
end
local good = fakeScript('9.9.9')
eq('годный файл принят', validateScriptText(good, CUR), '9.9.9')
ok('та же версия отвергнута (защита от цикла)', select(1, validateScriptText(fakeScript(CUR), CUR)) == nil)
ok('более старая версия отвергнута', select(1, validateScriptText(fakeScript('1.0.0'), CUR)) == nil)

local badName = literalReplace(fakeScript('9.9.9'), "script_name('SFN Logs')", "script_name('Другой')")
local _, whyName = validateScriptText(badName, CUR)
ok('чужой script_name отвергнут', whyName ~= nil and whyName:find('script_name', 1, true) ~= nil, whyName)

local noMain = literalReplace(fakeScript('9.9.9'), 'function main() end', '')
local _, whyMain = validateScriptText(noMain, CUR)
ok('без main() отвергнут', whyMain ~= nil and whyMain:find('main', 1, true) ~= nil, whyMain)

local noMembers = literalReplace(fakeScript('9.9.9'), 'function membersFeed(text, now) return true end', '')
local _, whyMembers = validateScriptText(noMembers, CUR)
ok('без разбора /members отвергнут', whyMembers ~= nil and whyMembers:find('/members', 1, true) ~= nil, whyMembers)

local desync = literalReplace(fakeScript('9.9.9'), "SFN_VERSION_STR = '9.9.9'", "SFN_VERSION_STR = '1.0.0'")
local _, whyDesync = validateScriptText(desync, CUR)
ok('рассинхрон версий отвергнут', whyDesync ~= nil and whyDesync:find('рассинхрон', 1, true) ~= nil, whyDesync)

local broken = fakeScript('9.9.9') .. '\nthis is not lua ((( '
local _, whyBroken = validateScriptText(broken, CUR)
ok('некомпилируемый файл отвергнут', whyBroken ~= nil and whyBroken:find('компилируется', 1, true) ~= nil, whyBroken)

local _, whyShort = validateScriptText(fakeScript('9.9.9', 1000), CUR)
ok('обрезанный файл отвергнут', whyShort ~= nil and whyShort:find('короткий', 1, true) ~= nil, whyShort)

eq('пустая строка отвергнута', validateScriptText('', CUR), nil)
eq('nil отвергнут', validateScriptText(nil, CUR), nil)

section('v2.2.0: состояние обновления (update.json)')
ok('в PATHS есть update.json', type(PATHS.update) == 'string' and PATHS.update:find('update%.json', 1) ~= nil)
updateState.lastCheck    = 1234567
updateState.available    = '9.9.9'
updateState.ready        = false
updateState.pendingPath  = ''
updateState.lastError    = 'сеть молчит'
updateState.installedAt  = 7654321
updateState.installedVer = '2.5.0'
updateState.notified     = '2.5.0'
ok('saveUpdateState пишет файл', saveUpdateState() ~= false)
local rawUp = readFile(PATHS.update)
ok('update.json не пустой', rawUp ~= nil and #rawUp > 10, rawUp and #rawUp)
updateState.lastCheck, updateState.available, updateState.lastError = 0, '', ''
loadUpdateState()
eq('lastCheck пережил перезапись', updateState.lastCheck, 1234567)
eq('available пережил перезапись', updateState.available, '9.9.9')
eq('lastError пережил перезапись', updateState.lastError, 'сеть молчит')
eq('installedVer пережил перезапись', updateState.installedVer, '2.5.0')

-- готовый файл обновления пропал (игрок почистил папку) -> не обещаем установку
local ghost = TMP .. '/ghost_update.lua'
writeFile(ghost, fakeScript('9.9.9'))
updateState.ready, updateState.pendingPath = true, ghost
saveUpdateState()
os.remove(ghost)
loadUpdateState()
ok('пропавший pending-файл сбрасывает ready', updateState.ready == false)
eq('  и очищает путь', updateState.pendingPath, '')

section('v2.2.0: needUpdateCheck')
cfg.update = { enabled = true, auto = true, url = '', every = 6 * 3600 }
-- ready/lastCheck сбрасываем ДО проверки: секция update.json выше оставляла
-- состояние «обновление скачано», а с ним повторная проверка не нужна
updateState.ready = false
updateState.lastCheck = 0
-- lastCheck = 0 означает «никогда не проверяли»: проверка нужна сразу,
-- иначе первый запуск скрипта ждал бы полного интервала (6 часов)
ok('первая проверка нужна сразу', needUpdateCheck(1000, false))
ok('force нужен всегда', needUpdateCheck(1000, true))
updateState.lastCheck = 1000
ok('сразу после проверки не нужно', not needUpdateCheck(1100, false))
ok('спустя интервал - нужно', needUpdateCheck(1000 + 6 * 3600 + 1, false))
ok('force работает и сразу после проверки', needUpdateCheck(1100, true))
cfg.update.enabled = false
ok('выключенное обновление не проверяется', not needUpdateCheck(10 ^ 9, false))
ok('  и force его не включает', not needUpdateCheck(10 ^ 9, true))
cfg.update.enabled = true
updateState.ready = true
ok('со скачанным обновлением повторно не качаем', not needUpdateCheck(10 ^ 9, false))
ok('  но force позволяет', needUpdateCheck(10 ^ 9, true))
updateState.ready = false
updateState.lastCheck = 1000   -- иначе сработает правило «первая проверка сразу»
cfg.update.every = 5           -- меньше 10 минут не принимаем
ok('интервал короче 600 с прижимается к 600', needUpdateCheck(1000 + 601, false))
ok('  а 300 с ещё не срок', not needUpdateCheck(1000 + 300, false))

section('v2.2.0: [update] в config.ini')
ok('DEFAULT_INI содержит секцию [update]', DEFAULT_INI:find('[update]', 1, true) ~= nil)
ok('DEFAULT_INI: автообновление включено', DEFAULT_INI:find('enabled = 1', 1, true) ~= nil)
ok('DEFAULT_INI: источник - raw.githubusercontent',
   DEFAULT_INI:find('raw%.githubusercontent%.com/Wereskkk/SFN_Logs/main/SFNLogs%.lua', 1) ~= nil)
local upPath = TMP .. '/update_config.ini'
writeFile(upPath, table.concat({
    '[update]', 'enabled = 1', 'auto = 0', 'every = 3600',
    'url = https://example.invalid/SFNLogs.lua',
}, '\r\n'))
PATHS.config = upPath
loadConfig()
eq('update.enabled из ini', cfg.update.enabled, true)
eq('update.auto из ini (0)', cfg.update.auto, false)
eq('update.every из ini', cfg.update.every, 3600)
eq('update.url из ini', cfg.update.url, 'https://example.invalid/SFNLogs.lua')
writeFile(upPath, '[update]\r\nevery = 10\r\nauto = 1\r\n')
loadConfig()
eq('every короче 600 прижимается', cfg.update.every, 600)
eq('update.auto = 1', cfg.update.auto, true)
eq('пустой url -> адрес по умолчанию', cfg.update.url, UPDATE_URL_DEFAULT)
writeFile(upPath, '[update]\r\nenabled = 0\r\n')
loadConfig()
eq('update.enabled = 0', cfg.update.enabled, false)

section('v2.2.0: saveConfig — настройки окна переживают перезапуск')
local cfgPath = TMP .. '/save_config.ini'
writeFile(cfgPath, table.concat({
    '; пользовательский комментарий обязан уцелеть',
    '[main]',
    'hotkey = 0x79',
    'showDismissed = 0',
    '',
    '[members]',
    'enabled = 1',
    '',
    '[update]',
    'enabled = 1',
    'auto = 1',
}, '\r\n'))
PATHS.config = cfgPath
cfg.showDismissed = true
cfg.members.enabled = false
cfg.update = { enabled = true, auto = false, url = UPDATE_URL_DEFAULT, every = 3600 }
ok('saveConfig отработал', saveConfig() == true)
local saved = readFile(cfgPath)
ok('комментарий пользователя уцелел', saved:find('; пользовательский комментарий обязан уцелеть', 1, true) ~= nil)
ok('showDismissed записан', saved:find('showDismissed = 1', 1, true) ~= nil)
ok('members.enabled записан', saved:find('enabled = 0', 1, true) ~= nil)
ok('[update] auto записан', saved:find('auto = 0', 1, true) ~= nil)
ok('hotkey не тронут', saved:find('hotkey = 0x79', 1, true) ~= nil)
ok('перевод строк CRLF сохранён', saved:find('\r\n', 1, true) ~= nil)
local _, dupCount = saved:gsub('showDismissed', '')
eq('дублей ключей не появилось', dupCount, 1)
loadConfig()
eq('перечитывание вернуло showDismissed', cfg.showDismissed, true)
eq('перечитывание вернуло members.enabled', cfg.members.enabled, false)
eq('перечитывание вернуло update.auto', cfg.update.auto, false)

-- старый конфиг без секции [update]: ключи дописываются, секция создаётся
local oldPath = TMP .. '/old_config.ini'
writeFile(oldPath, table.concat({ '[main]', 'hotkey = 0x77', 'showDismissed = 0' }, '\r\n'))
PATHS.config = oldPath
cfg.showDismissed = true
cfg.members = { enabled = true }
cfg.update = { enabled = true, auto = true, url = UPDATE_URL_DEFAULT, every = 21600 }
ok('saveConfig на старом конфиге отработал', saveConfig() == true)
local oldSaved = readFile(oldPath)
ok('в старом конфиге появилась секция [update]', oldSaved:find('[update]', 1, true) ~= nil)
ok('в старом конфиге появилась секция [members]', oldSaved:find('[members]', 1, true) ~= nil)
ok('  и enabled в ней', oldSaved:find('enabled = 1', 1, true) ~= nil)
ok('в [main] дописан недостающий ключ', oldSaved:find('showDismissed = 1', 1, true) ~= nil)
loadConfig()
eq('старый конфиг перечитался', cfg.showDismissed, true)

-- идемпотентность: повторная запись ничего не ломает и не растит файл
local before, after = #readFile(oldPath), nil
saveConfig()
after = #readFile(oldPath)
eq('повторный saveConfig не меняет файл', after, before)

section('v2.2.0: страховки по исходнику')
ok('исходник: источник обновлений - ветка main',
   full:find('raw.githubusercontent.com/Wereskkk/SFN_Logs/main/SFNLogs.lua', 1, true) ~= nil)
ok('исходник: команда /sfnlogupdate зарегистрирована',
   full:find("sampRegisterChatCommand('sfnlogupdate'", 1, true) ~= nil)
ok('исходник: обновление проверяется в фоновом потоке',
   full:find('startUpdateWorker()', 1, true) ~= nil)
ok('исходник: скачанный файл проверяется перед заменой',
   full:find('validateScriptText(body, SFN_VERSION_STR)', 1, true) ~= nil)
ok('исходник: старая версия сохраняется как .bak',
   full:find("target .. '.bak'", 1, true) ~= nil)
ok('исходник: замена не на месте (сначала .new)',
   full:find('update.lua.new', 1, true) ~= nil)
ok('исходник: состояние пишется в update.json',
   full:find('saveUpdateState()', 1, true) ~= nil)
ok('исходник: saveConfig вызывается из настроек окна',
   full:find('saveConfig()', 1, true) ~= nil)
ok('исходник: версия шапки и литерал совпадают (2.2.3)',
   full:find("script_version('2.2.4')", 1, true) ~= nil
   and full:find("SFN_VERSION_STR = '2.2.4'", 1, true) ~= nil)
local _, nVerLit = full:gsub("SFN_VERSION_STR%s*=%s*'[%d%.]+'", '')
eq('исходник: литерал версии ровно один (иначе разъедется)', nVerLit, 1)
local posTop = full:find("SFN_VERSION_STR = '", 1, true)
local posUpd = full:find('validateScriptText(body, SFN_VERSION_STR)', 1, true)
ok('исходник: версия объявлена ДО автообновления (иначе она там nil)',
   posTop ~= nil and posUpd ~= nil and posTop < posUpd,
   string.format('%s vs %s', tostring(posTop), tostring(posUpd)))
eq('исходник: локального SFN_VERSION_STR больше нет',
   full:find('local SFN_VERSION_STR', 1, true), nil)
local _, nBegin = full:gsub('\n%-%- >>> PURE LOGIC BEGIN', '')
local _, nEnd = full:gsub('\n%-%- <<< PURE LOGIC END', '')
ok('исходник: логотип перерисован (нет старого микрофона)',
   full:find('малиновый круг с микрофоном', 1, true) == nil)
ok('исходник: таблицы форм логотипа на месте',
   full:find('LOGO_SPLASH', 1, true) ~= nil and full:find('LOGO_E', 1, true) ~= nil)
eq('исходник: метка начала PURE одна', nBegin, 1)
eq('исходник: метка конца PURE одна', nEnd, 1)

-- ============================================ ПОРЯДОК СТРОК ЖУРНАЛА ========
section('Порядок строк журнала детерминирован')
-- сотрудники одного ранга с одной датой приёма: без тай-брейка по нику
-- table.sort получал сравнение «ни больше ни меньше», порядок обхода pairs
-- deciding случайным образом, и журнал переставлял строки между запусками
-- (это же ломало побайтовую воспроизводимость SVG-превью в CI)
do
    local T = 1750000000
    roster = { members = {}, version = 1 }
    for _, nick in ipairs({ 'Zoya_Orlova', 'Anna_Malboro', 'Boris_Volkov',
                            'Sonya_Malboro', 'Alex_Wilde' }) do
        addMember(nick, 'Leader_Name', T - 5 * D, 4, 6, T)
    end
    local first = {}
    for _, m in ipairs(sortedMembers(false)) do first[#first + 1] = m.nick end
    eq('одинаковые ранг и дата - сортировка по нику',
       table.concat(first, ','),
       'Alex_Wilde,Anna_Malboro,Boris_Volkov,Sonya_Malboro,Zoya_Orlova')

    -- тот же набор, добавленный в обратном порядке: результат обязан совпасть
    roster = { members = {}, version = 1 }
    for _, nick in ipairs({ 'Alex_Wilde', 'Sonya_Malboro', 'Boris_Volkov',
                            'Anna_Malboro', 'Zoya_Orlova' }) do
        addMember(nick, 'Leader_Name', T - 5 * D, 4, 6, T)
    end
    local second = {}
    for _, m in ipairs(sortedMembers(false)) do second[#second + 1] = m.nick end
    eq('порядок добавления не влияет на список', table.concat(second, ','),
       table.concat(first, ','))

    -- ранг важнее ника, уволенные всегда ниже
    addMember('Yan_Frolov', 'Leader_Name', T - 5 * D, 7, 9, T)
    local y = dismissMember('Boris_Volkov', 'нарушение регламента', T)
    local mixed = {}
    for _, m in ipairs(sortedMembers(true)) do mixed[#mixed + 1] = m.nick end
    eq('старший ранг первым', mixed[1], 'Yan_Frolov')
    eq('уволенный - последним', mixed[#mixed], 'Boris_Volkov')
    ok('увольнение вернуло запись', y ~= nil)
end

-- ============================================================ ИТОГ =======
print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
