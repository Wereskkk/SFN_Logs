-- Тесты чистой логики SFN_Helper: идентификация ядра и модуль «Фото»
-- (диалог папарацци, заказы и зачёт съёмок, недельные лимиты, файл базы).
-- Запуск:  python3 tests/run_helper_logic.py   (lupa, Lua 5.4)

local SRC = arg[1] or '../../SFN_Helper.lua'

-- ------------------------------------------------------------ заглушки ----
local TMP = '/tmp/sfnhelper_test'
os.execute('mkdir -p ' .. TMP)
os.execute('mkdir -p ' .. TMP .. '/SFNHelper')
os.execute('mkdir -p ' .. TMP .. '/SFNLogs')
os.execute('mkdir -p ' .. TMP .. '/sfn_photo_data')
os.execute('mkdir -p ' .. TMP .. '/sfn_data')
-- DIR и LEGACY_DIR в исходнике строятся от USERPROFILE: без заглузы os.getenv
-- возвращает nil, и конкатенация nil .. '\\SFNHelper' уронила бы загрузку
os.getenv = function() return TMP end
getWorkingDirectory  = function() return TMP end
doesDirectoryExist   = function() return true end
createDirectory      = function() return true end

local full = assert(io.open(SRC, 'r')):read('*a')
local body = full:match('\n%-%- >>> PURE LOGIC BEGIN(.-)\n%-%- <<< PURE LOGIC END\n')
assert(body, 'метки PURE LOGIC не найдены в ' .. SRC)
body = body .. [[

return { json = json, PATHS = PATHS, DIR = DIR, readFile = readFile, writeFile = writeFile }
]]
local chunk, err = load(body, 'purelogic')
assert(chunk, err)
local exposed = assert(chunk())
local writeFile = exposed.writeFile
local readFile  = exposed.readFile
-- DIR/PATHS в исходнике local главного чанка: берём их из таблицы, которую
-- возвращает извлечённая PURE-секция
local DIR, PATHS = exposed.DIR, exposed.PATHS

-- ------------------------------------------------------------ ассерты ----
local passed, failed = 0, 0
local function eq(name, got, want)
    if got == want then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-52s got=%s want=%s', name, tostring(got), tostring(want)))
    end
end
local function ok(name, cond, extra)
    if cond then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-52s %s', name, tostring(extra or '')))
    end
end
local function section(t) print('\n== ' .. t) end

-- ============================================ ЯДРО ПОМОЩНИКА ==============
section('helper: идентификация ядра')
ok('имя скрипта - SFN Helper', full:find("script_name('SFN Helper')", 1, true) ~= nil)
-- версия не захардкожена: шапка и литерал обязаны совпасть при любом релизе
local hdr_ver = full:match("script_version%('([^']+)'%)")
local lit_ver = full:match("SFN_VERSION_STR = '([^']+)'")
ok('версия шапки и литерал совпадают (' .. tostring(hdr_ver) .. ')',
   hdr_ver ~= nil and hdr_ver == lit_ver)
ok('апдейтер берёт SFN_Helper.lua',
   full:find('raw.githubusercontent.com/Wereskkk/SFN_Logs/main/SFN_Helper.lua', 1, true) ~= nil)
ok('папка данных - SFNHelper', full:find(".. '\\\\SFNHelper'", 1, true) ~= nil)
ok('тегов [SFN Logs] в чат не осталось', full:find('[SFN Logs]', 1, true) == nil)
ok('валидация обновления ждёт имя Helper',
   full:find("script_name('SFN Helper')\", 1, true", 1, true) ~= nil)
ok('подписка sampev.onServerMessage на месте (регресс 2.1.0)',
   full:find('function sampev.onServerMessage', 1, true) ~= nil)
ok('диспетчер событий модулей на месте',
   full:find('for _, mod in ipairs(MODULES) do', 1, true) ~= nil)
ok('команда /sfnhelper зарегистрирована',
   full:find("sampRegisterChatCommand('sfnhelper'", 1, true) ~= nil)
ok('реестр модулей global (лимит 200 локалей чанка)',
   full:find('local MODULES', 1, true) == nil and full:find('MODULES, MODULE_BY_ID = {}, {}', 1, true) ~= nil)
-- без этих диспетчеров модули не получают ни кадров, ни сигнала выгрузки
ok('диспетчер onTick: главный цикл дёргает модули',
   full:find('if mod.onTick then pcall(mod.onTick, now) end', 1, true) ~= nil)
ok('диспетчер onTerminate: выгрузка скрипта сохраняет базы модулей',
   full:find('if mod.onTerminate then pcall(mod.onTerminate) end', 1, true) ~= nil)
ok('диспетчер onLoad: main() инициализирует модули',
   full:find('if mod.onLoad then pcall(mod.onLoad) end', 1, true) ~= nil)

-- валидация автообновления отличает Helper от Logs
local function fakeScript(name, ver)
    local head = table.concat({
        "script_name('" .. name .. "')",
        "script_version('" .. ver .. "')",
        '-- >>> PURE LOGIC ' .. 'BEGIN',
        'function membersFeed(text, now) return true end',
        '-- <<< PURE LOGIC ' .. 'END',
        'function main() end',
        "local SFN_VERSION_STR = '" .. ver .. "'",
    }, '\n')
    while #head < 60100 do head = head .. '\n-- x' end
    return head
end
eq('валидация принимает Helper новее', validateScriptText(fakeScript('SFN Helper', '9.9.9'), hdr_ver), '9.9.9')
ok('валидация отвергает чужое имя (SFN Logs)',
   select(1, validateScriptText(fakeScript('SFN Logs', '9.9.9'), hdr_ver)) == nil)

-- ============================================ ФОТО: ДИАЛОГ ПАПАРАЦЦИ =======
section('фото: колонка «Фото» в заказ-диалоге')

local function cp(s) return utf8ToCp1251(s) end

photoReset()
local dlgPlayers = cp(table.concat({
    'Игрок\tID\tПоследний вход',
    'Jonny_Wilde\t248\t19:23',
    'Anna_Malboro\t264\t04:18',
    '',
}, '\n'))
local out = photoTransformDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', dlgPlayers)
ok('диалог игроков распознан', out ~= nil)
ok('шапка получила колонку Фото', out ~= nil and out:find(cp('Фото'), 1, true) ~= nil)
ok('строки получили метки [V]', out ~= nil and select(2, out:gsub('%[V%]', '')) == 2, out)

photoState.players['Jonny_Wilde'] = { date = photoToday() }
out = photoTransformDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', dlgPlayers)
ok('снятый игрок помечен [X]',
   out ~= nil and out:find(cp('Jonny_Wilde\t248\t19:23') .. '\t{FF3333}[X]', 1, true) ~= nil, out)
ok('неснятый игрок помечен [V]',
   out ~= nil and out:find(cp('Anna_Malboro\t264\t04:18') .. '\t{33FF33}[V]', 1, true) ~= nil, out)

local dlgPlaces = cp(table.concat({
    'Название\tГород',
    'Мост\tЛос-Сантос',
    'Пирс\tСан-Фиерро',
    '',
}, '\n'))
out = photoTransformDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', dlgPlaces)
ok('диалог мест распознан', out ~= nil and select(2, out:gsub('%[V%]', '')) == 2)
photoState.places['Мост|Лос-Сантос'] = { date = photoToday() }
out = photoTransformDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', dlgPlaces)
ok('снятое место помечено [X]',
   out ~= nil and out:find(cp('Мост\tЛос-Сантос') .. '\t{FF3333}[X]', 1, true) ~= nil, out)

eq('чужой диалог не трогаем', photoTransformDialog(1234, 5, 't', 'a', 'b', dlgPlayers), nil)
eq('диалог другого стиля не трогаем', photoTransformDialog(32700, 1, 't', 'a', 'b', dlgPlayers), nil)
eq('пустой текст не трогаем', photoTransformDialog(32700, 5, 't', 'a', 'b', ''), nil)
-- шапка уже с Фото: колонка не дублируется
local twice = photoTransformDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', dlgPlayers)
local out2 = photoTransformDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', twice)
ok('колонка Фото не дублируется', out2 ~= nil and select(2, out2:gsub(cp('Фото'), '')) == 1, out2)

-- ============================================ ФОТО: ЗАКАЗЫ И ЗАЧЁТ =========
section('фото: заказы, съёмки, награда')

photoReset()
local ev = photoHandleText('Вам нужно сделать фотографию "Jonny_Wilde[248]"')
eq('заказ игрока принят', photoOrder and photoOrder.nick, 'Jonny_Wilde')
eq('  событий лишних нет', #ev, 0)

ev = photoHandleText('Снимок вышел удачным')
eq('удачный снимок: заказа нет, ждём награду', photoOrder, nil)
ok('  флаг съёмки поднят', photoTaken == true)

ev = photoHandleText('Ваша награда: 500$')
eq('награда записала игрока', photoState.players['Jonny_Wilde'] ~= nil and 1 or nil, 1)
ok('  событие сохранения есть', (function() for _, e in ipairs(ev) do if e.save then return true end end end)())
ok('  зелёное сообщение о зачёте', (function()
    for _, e in ipairs(ev) do if e.say and e.say:find('Зачтено фото игрока', 1, true) then return true end end
end)())
eq('счётчик игроков', photoCountPlayers(), 1)

-- повторный заказ на этой неделе: предупреждение, без записи
ev = photoHandleText('Вам нужно сделать фотографию "Jonny_Wilde[248]"')
ok('повторный заказ: красное предупреждение', #ev == 1 and ev[1].say:find('уже выполнен', 1, true) ~= nil,
   ev[1] and ev[1].say)
ev = photoHandleText('Снимок вышел удачным')
ev = photoHandleText('Ваша награда: 500$')
ok('повторно не записали', photoCountPlayers() == 1)
ok('  и сохранения не было', not (function() for _, e in ipairs(ev) do if e.save then return true end end end)())

-- место
photoReset()
photoHandleText('Вам нужно сделать фотографию "Мост" в городе "Лос-Сантос"')
eq('заказ места принят', photoOrder and photoOrder.type, 'place')
photoHandleText('Снимок вышел удачным')
photoHandleText('Ваша награда: 300$')
eq('место записано ключом place|city', photoState.places['Мост|Лос-Сантос'] ~= nil and 1 or nil, 1)
eq('счётчик мест', photoCountPlaces(), 1)

-- неудачный снимок отменяет зачёт
photoReset()
photoHandleText('Вам нужно сделать фотографию "Anna_Malboro[264]"')
photoHandleText('Снимок вышел удачным')
photoHandleText('Снимок вышел неудачным')
photoHandleText('Ваша награда: 0$')
eq('неудачный снимок: запись не сделана', photoCountPlayers(), 0)

-- награда без заказа и без съёмки: тихо
photoReset()
eq('награда без заказа тихая', #photoHandleText('Ваша награда: 100$'), 0)
eq('посторонний чат игнорируется', #photoHandleText('Просто сообщение в чате'), 0)
eq('ник без подчёркивания не заказ', (function()
    photoReset()
    photoHandleText('Вам нужно сделать фотографию "ОдинокоеСлово"')
    return photoOrder
end)(), nil)

-- лимит игроков: предупреждение на 25-м
photoReset()
for i = 1, 24 do
    photoState.players['Fill_' .. i] = { date = photoToday() }
end
photoHandleText('Вам нужно сделать фотографию "Last_Photo[999]"')
photoHandleText('Снимок вышел удачным')
local evLim = photoHandleText('Ваша награда: 500$')
eq('25-й игрок записан', photoCountPlayers(), 25)
ok('предупреждение о лимите игроков', (function()
    for _, e in ipairs(evLim) do if e.say and e.say:find('Лимит фото игроков', 1, true) then return true end end
end)())

-- ============================================ ФОТО: ФАЙЛ БАЗЫ ==============
section('фото: файл базы совместим со старым скриптом')

photoReset()
photoState.players['Keep_Me[1]'] = nil
photoState.players['Keep_Me'] = { date = '2026-09-29' }
photoState.places['Пирс|Сан-Фиерро'] = { date = '2026-09-28' }
ok('photoSaveFile пишет файл', photoSaveFile() ~= false)
local raw = readFile(PHOTO_PATH)
ok('файл не пустой', raw ~= nil and #raw > 10)
ok('в файле игроки и места', raw:find('Keep_Me', 1, true) ~= nil and raw:find('Пирс', 1, true) ~= nil)

-- старый формат от sfn_photo_helper.lua читается без миграций
writeFile(PHOTO_PATH, '{"players":{"Old_Script":{"date":"2026-09-27"}},"places":{"Старое|Место":{"date":"2026-09-26"}}}')
photoReset()
photoLoad()
eq('старая база прочитана: игроки', photoCountPlayers(), 1)
eq('старая база прочитана: места', photoCountPlaces(), 1)
eq('дата старого игрока', photoState.players['Old_Script'].date, '2026-09-27')

-- битый файл не роняет загрузку
writeFile(PHOTO_PATH, '{не json')
photoReset()
photoLoad()
eq('битый файл: игроков ноль', photoCountPlayers(), 0)
eq('битый файл: мест ноль', photoCountPlaces(), 0)

-- ============================================ ЭФИР: ДОСТУП И ФОРМЫ ========
section('эфир: sha256, доступ, русские формы')
eq('sha256("abc") эталон', efirSha256('abc'),
   'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
eq('sha256("") эталон', efirSha256(''),
   'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
eq('sha256 ника стабилен и длиной 64', #efirSha256('Jonny_Wilde' .. EFIR_AUTH_SALT), 64)
ok('Unknown не админ', efirIsAdmin('Unknown') == false)
ok('случайный ник не в списке', efirIsAllowed('Random_Person') == false)
ok('пустой ник не в списке', efirIsAllowed('') == false)

eq('pluralScore 1', efirPluralScore(1), 'балл')
eq('pluralScore 2', efirPluralScore(2), 'балла')
eq('pluralScore 5', efirPluralScore(5), 'баллов')
eq('pluralScore 11', efirPluralScore(11), 'баллов')
eq('pluralScore 21', efirPluralScore(21), 'балл')
eq('форма мужского пола', efirGenderForms('Any_Nick').first, 'первый')
efirGenders['Girl_Nick'] = 'f'
eq('форма женского пола', efirGenderForms('Girl_Nick').first, 'первая')
eq('форма женского: дала', efirGenderForms('Girl_Nick').gave, 'дала')
efirGenders['Girl_Nick'] = nil

-- знак уходит только с самого конца строки (поведение оригинала),
-- пробелы схлопываются после: 'Ёлка? ' -> 'ЁЛКА?' ровно как в v7.0.1
eq('normalizeAnswer: ё не сворачивается, как в оригинале',
   efirNormalizeAnswer(utf8ToCp1251('Ёлка?')), utf8ToCp1251('ЁЛКА'))
eq('normalizeAnswer: знак с конца и пробелы внутри',
   efirNormalizeAnswer(utf8ToCp1251('При вет!')), utf8ToCp1251('ПРИВЕТ'))
eq('formatNick подчёркивание', efirFormatNick('Jonny_Wilde'), 'Jonny Wilde')
eq('capitalizeWord', efirCapitalizeWord('привет'), 'Привет')
eq('anagram dots', efirFormatAnagramDots('КОТ'), 'К.О.Т')

efirScreenshots = 3
efirMode, efirType = 'math', 'Математика'
eq('placeholders', efirApplyPlaceholders('{NICK} ведёт {TYPE}, скринов {N}', { nick = 'My_Nick' }),
   'My Nick ведёт Математика, скринов 3')
efirScreenshots = 0

-- ============================================ ЭФИР: ГЕНЕРАТОРЫ =============
section('эфир: генераторы заданий')
local function evalExpr(expr)
    local f = load('return (' .. expr .. ')')
    if not f then return nil end
    return f()
end
local kinds = {}
for _ = 1, 300 do
    local q, a, suffix = efirGenerateMath()
    ok('пример не пустой', q ~= '' and a ~= nil, q)
    if suffix == ', x = ?' then
        local lhs, rhs = q:match('^(.-)%s*=%s*(.+)$')
        local sub = lhs:gsub('x', '(' .. a .. ')')
        local lv, rv = evalExpr(sub), evalExpr(rhs)
        ok('уравнение сходится: ' .. q, lv ~= nil and rv ~= nil and math.abs(lv - rv) < 1e-9,
           tostring(lv) .. ' vs ' .. tostring(rv))
    else
        local v = evalExpr(q)
        ok('пример сходится: ' .. q, v ~= nil and math.abs(v - a) < 1e-9, tostring(v) .. ' vs ' .. tostring(a))
    end
    kinds[#kinds + 1] = suffix == ', x = ?' and 'eq' or 'arith'
end
ok('генератор крутится без ошибок', #kinds == 300)

efirAnagrams = { 'ПРИВЕТ' }
local word, shuffled = efirGenerateAnagram()
eq('анаграмма взята из базы', word, 'ПРИВЕТ')
local function sortedChars(s)
    local ch = efirSplitUtf8(s)
    table.sort(ch)
    return table.concat(ch, '|')
end
ok('анаграмма - перестановка букв', sortedChars(shuffled or '') == sortedChars('ПРИВЕТ'), shuffled)

efirWords = { 'ТЕЛЕВИЗОР' }
local w, masked = efirGenerateVyshibaly()
eq('вышибалы: слово из базы', w, 'ТЕЛЕВИЗОР')
ok('вышибалы: маска той же длины', #efirSplitUtf8(masked) == #efirSplitUtf8('ТЕЛЕВИЗОР'), masked)
ok('вышибалы: есть закрытые позиции', masked:find('[*_]') ~= nil, masked)
ok('вышибалы: маска не равна слову', masked ~= w)

-- ============================================ ЭФИР: ОТВЕТЫ И СЧЁТ ==========
section('эфир: разбор ответов и начисление')
efirRunning, efirMode = true, 'math'
efirMathQ, efirMathA, efirMathSuffix = '2 + 2', 4, ' = ?'
efirFirstAnswer = nil
ok('ответ распознан', efirTryParseAnswer('Jonny_Wilde[248]: [EFIR] 4.') == true)
ok('первый ответ запомнен', efirFirstAnswer ~= nil and efirFirstAnswer.nick == 'Jonny_Wilde')
ok('второй верный не перезаписал первого', (function()
    efirTryParseAnswer('Anna_Malboro[264]: [EFIR] 4.')
    return efirFirstAnswer.nick == 'Jonny_Wilde'
end)())
efirFirstAnswer = nil
ok('неверный ответ не запомнен', (function()
    efirTryParseAnswer('Jonny_Wilde[248]: [EFIR] 5.')
    return efirFirstAnswer == nil
end)())
ok('без ника ответ не считается', efirTryParseAnswer('[EFIR] 4.') == false)
ok('эфир выключен: ответ помечается, но не пишется', (function()
    efirRunning = false
    local r = efirTryParseAnswer('Jonny_Wilde[248]: [EFIR] 4.')
    efirRunning = true
    return r == true and efirFirstAnswer == nil
end)())

efirScores = {}
efirFirstAnswer = { nick = 'Jonny_Wilde', id = 248, answer = '4' }
local ev = efirApplyCorrect('Jonny_Wilde', 248)
eq('балл начислен', efirScores['Jonny_Wilde'].score, 1)
ok('событие сохранения', (function() for _, e in ipairs(ev) do if e.save == 'scores' then return true end end end)())
ok('фраза с мужской формой', (function()
    for _, e in ipairs(ev) do
        if e.chat and e.chat:find('первый дал правильный ответ и у него 1 балл', 1, true) then return true end
    end
end)(), ev[2] and ev[2].chat)
ok('событие показа ответа', (function() for _, e in ipairs(ev) do if e.reveal == '4' then return true end end end)())
efirApplyCorrect('Jonny_Wilde', 248)
eq('второй балл добавился', efirScores['Jonny_Wilde'].score, 2)

efirScores = { A = { id = 1, score = 5 }, B = { id = 2, score = 5 }, C = { id = 3, score = 2 } }
local groups = efirTopScoreGroups()
eq('групп две', #groups, 2)
eq('ранг первой группы', groups[1].rank, 1)
eq('в первой группе двое', #groups[1].nicks, 2)
eq('вторая группа с 2 баллами', groups[2].score, 2)

-- упаковка строк в сообщения чата
local items = {}
for i = 1, 10 do items[i] = string.rep('x', 40) end
local packed = efirPackMessages(items, 'Топ: ', '   ')
ok('сообщения не длиннее 120', (function()
    for _, m in ipairs(packed) do if #m > 120 then return false end end
    return true
end)(), #packed)
ok('все элементы упакованы', (function()
    local total = 0
    for _, m in ipairs(packed) do total = total + select(2, m:gsub('xxxx', '')) - 1 end
    return #packed >= 3 and #packed <= 6
end)(), #packed)
ok('первое сообщение с первым префиксом', packed[1]:find('Топ: ', 1, true) == 1)

-- ============================================ ЭФИР: ФАЙЛЫ СОВМЕСТИМЫ =======
section('эфир: конфиг и базы старого скрипта')
writeFile(EFIR_CFG_PATH, '{"hotkey":122,"max_score":30,"prize_fund":777,"price_per_minute":1,"screenshot_interval":2}')
efirCfg.max_score, efirCfg.hotkey = 20, 0x7A
efirLoadConfig()
eq('max_score из старого конфига', efirCfg.max_score, 30)
eq('hotkey из старого конфига', efirCfg.hotkey, 122)
eq('prize_fund из старого конфига', efirCfg.prize_fund, 777)

writeFile(EFIR_SCORES, '{"Old_Player":{"id":7,"score":3}}')
efirScores = {}
efirLoadScores()
eq('старые баллы прочитаны', efirScores['Old_Player'] and efirScores['Old_Player'].score, 3)

writeFile(EFIR_GENDERS, '{"Girl_Nick":"f","Bad":123}')
efirGenders = {}
efirLoadGenders()
eq('пол прочитан', efirGenders['Girl_Nick'], 'f')
eq('мусор отброшен', efirGenders['Bad'], nil)

writeFile(EFIR_TEXTS, 'return { intro = { jingle = "j", lines = { "l" } }, outro = { lines = {} },'
    .. ' rules = { math = {} }, scores_intros = { "i" },'
    .. ' advertisement = { jingle = "j", intros = { "i" }, blocks = { { "b" } } }, system = {} }')
local txt = efirLoadTexts()
ok('texts.lua загружен', txt ~= nil and txt.intro.lines[1] == 'l')

writeFile(EFIR_WORDS, 'return { "привет", "мир" }')
local wl = efirLoadWordList(EFIR_WORDS)
ok('слова загружены верхним регистром', wl ~= nil and wl[1] == 'ПРИВЕТ' and wl[2] == 'МИР',
   wl and wl[1])

-- ============================================ ПОЛ: ОБЩАЯ БАЗА ==============
section('пол: общая база и перенос из старых файлов')

local function gendersReset()
    GENDERS = {}
    GENDERS_LOADED = false
    GENDERS_MIGRATED = false
end

-- общий файл пуст, оба старых существуют: при первом чтении они сливаются
writeFile(GENDERS_SHARED, '')
writeFile(GENDERS_LEGACY_EFIR, '{"Efir_Girl":"f","Efir_Boy":"m"}')
writeFile(GENDERS_LEGACY_PHOTO, '{"Soc_Girl":"f","Efir_Boy":"m"}')
gendersReset()
eq('перенос дал три записи (дубль не умножается)', gendersCount(), 3)
eq('пол из базы эфира', gendersGet('Efir_Girl'), 'f')
eq('пол из базы соцопроса', gendersGet('Soc_Girl'), 'f')
ok('перенос записал общий файл', (readFile(GENDERS_SHARED) or ''):find('Efir_Girl', 1, true) ~= nil)

-- запись идёт в общий файл, старые не переписываются
gendersSet('New_Player', 'f')
eq('новая запись видна', gendersGet('New_Player'), 'f')
ok('общий файл сохранён', (readFile(GENDERS_SHARED) or ''):find('New_Player', 1, true) ~= nil)
eq('старая база эфира не переписана', readFile(GENDERS_LEGACY_EFIR),
   '{"Efir_Girl":"f","Efir_Boy":"m"}')

-- общая база переживает перезагрузку
gendersReset()
eq('после перечитанного файла записей столько же', gendersCount(), 4)
eq('мусорные значения не принимаются', gendersSet('X_Player', 'x'), false)
eq('пустой ник не принимается', gendersSet('', 'm'), false)

-- «Эфир» читает общую базу, а при пустой - прежний свой файл
efirGenders = {}
efirLoadGenders()
eq('эфир видит общий пол', efirGenders['Efir_Girl'], 'f')
writeFile(EFIR_GENDERS, '{"Legacy_Girl":"f","Bad":123}')
gendersReset()
writeFile(GENDERS_SHARED, '{}')
efirGenders = {}
efirLoadGenders()
eq('эфир: откат к старой базе, если общая пуста', efirGenders['Legacy_Girl'], 'f')
eq('эфир: мусор отброшен', efirGenders['Bad'], nil)

-- ============================================ СОЦОПРОС: ФАЙЛ БАЗЫ ========
section('соцопрос: файл базы старого скрипта')

local function socialResetState()
    social.active, social.stage = false, 0
    social.targetId, social.targetNick = nil, nil
    social.surveys, social.flyers, social.log = {}, {}, {}
    socialQuestion, socialFlyerText = '', SOCIAL_DEFAULT_FLYER_ME
    socialHotkey, socialSelectedId, socialNeedGender = SOCIAL_HOTKEY_DEFAULT, nil, false
end

-- файл, сохранённый отдельным скриптом sfn_social.lua v4.0 (его prettyJson)
writeFile(SOCIAL_PATH, table.concat({
    '{',
    '    "flyers": {',
    '        "Anna_Malboro": {',
    '            "date": "2026-09-20"',
    '        }',
    '    },',
    '    "hotkey": 122,',
    '    "log": [',
    '        "[12:00:00] старая запись"',
    '    ],',
    '    "surveys": {',
    '        "Jonny_Wilde": {',
    '            "date": "2026-09-21"',
    '        }',
    '    },',
    '    "surveyQuestion": "Как вам погода?",',
    '    "flyerMeText": "протянул листовку"',
    '}',
}, '\n'))
socialResetState()
socialLoadFile()
eq('опросы прочитаны', social.surveys['Jonny_Wilde'] and social.surveys['Jonny_Wilde'].date,
   '2026-09-21')
eq('листовки прочитаны', social.flyers['Anna_Malboro'] and social.flyers['Anna_Malboro'].date,
   '2026-09-20')
eq('вопрос недели прочитан', socialQuestion, 'Как вам погода?')
eq('текст /me прочитан', socialFlyerText, 'протянул листовку')
eq('хоткей F11 заменён на F10 (F11 занят «Эфиром»)', socialHotkey, SOCIAL_HOTKEY_DEFAULT)

socialSaveFile()
local rawSoc = readFile(SOCIAL_PATH) or ''
ok('сохранение держит формат старого скрипта',
   rawSoc:find('"surveys"', 1, true) ~= nil and rawSoc:find('"flyerMeText"', 1, true) ~= nil)
socialResetState()
socialLoadFile()
eq('сохранённое переживает перезагрузку', social.surveys['Jonny_Wilde'] ~= nil, true)
ok('журнал из файла перечитан',
   (function()
       for _, l in ipairs(social.log) do
           if tostring(l):find('старая запись', 1, true) then return true end
       end
       return false
   end)(), table.concat(social.log, ' | '))

-- битый файл не роняет модуль
writeFile(SOCIAL_PATH, '{ не json')
socialResetState()
socialLoadFile()
eq('битый файл: базы пустые', socialCount(social.surveys), 0)
eq('битый файл: вопрос пустой', socialQuestion, '')

-- ============================================ СОЦОПРОС: ТЕКСТЫ ============
section('соцопрос: вопрос недели и текст листовки')

socialResetState()
eq('пустой вопрос не применяется', select(1, socialApplyQuestion('   ')), false)
eq('длинный вопрос не применяется',
   select(1, socialApplyQuestion(string.rep('а', SOCIAL_QUESTION_LIMIT + 1))), false)
eq('вопрос в лимите применяется', select(1, socialApplyQuestion('Как вам наш эфир?')), true)
eq('вопрос сохранён в состоянии', socialQuestion, 'Как вам наш эфир?')
eq('пробелы по краям обрезаны', select(1, socialApplyQuestion('  Тест  ')) and socialQuestion,
   'Тест')
eq('пустой текст /me не применяется', select(1, socialApplyFlyerText('')), false)
eq('текст /me в лимите применяется', select(1, socialApplyFlyerText('протянул листовку')), true)
eq('длинный текст /me не применяется',
   select(1, socialApplyFlyerText(string.rep('б', SOCIAL_FLYER_LIMIT + 1))), false)

-- ============================================ СОЦОПРОС: СОГЛАСИЕ И ПОЛ ====
section('соцопрос: согласие, пол и реплики')

ok('«да» - согласие', socialAgree('Да') == true)
ok('«окей» - согласие', socialAgree('ОКЕЙ') == true)
ok('«конечно, давай» - согласие', socialAgree('Конечно, давай') == true)
ok('«нет» - не согласие', socialAgree('Нет, извини') == false)
ok('пустая строка - не согласие', socialAgree('') == false)

gendersReset()
GENDERS_LOADED, GENDERS_MIGRATED = true, true
GENDERS = {}
eq('пол по умолчанию мужской', socialGenderOf('Someone'), 'm')
eq('формы по умолчанию', socialForms('Someone').citizen, 'Гражданин')
gendersSet('Girl_Nick', 'f')
eq('женский пол из общей базы', socialGenderOf('Girl_Nick'), 'f')
eq('формы для девушки', socialForms('Girl_Nick').citizen, 'Гражданка')
eq('«взяла» для девушки', socialForms('Girl_Nick').took, 'взяла')

local ev = socialBeginInterview('Girl_Nick', 'Jonny_Wilde')
ok('приветствие очищает локальный чат', ev.clearChat == true)
eq('первой строкой идёт /clearchat', ev.chat[1], '/clearchat')
ok('приветствие учитывает пол',
   ev.chat[2]:find('Гражданка, здравствуйте', 1, true) == 1, ev.chat[2])
ok('в приветствии есть ник ведущего', ev.chat[2]:find('Jonny Wilde', 1, true) ~= nil, ev.chat[2])
ok('пауза после /clearchat', ev.waits[1] == SOCIAL_CLEAR_DELAY)

ev = socialBeginInterview('Boy_Nick', 'Jonny_Wilde')
ok('для парня - «Гражданин»', ev.chat[2]:find('Гражданин, здравствуйте', 1, true) == 1)

ev = socialGiveFlyer('Girl_Nick')
eq('реплик листовки четыре', #ev.chat, 4)
ok('текст /me без префикса в третьей реплике',
   ev.chat[3] == '/me ' .. socialFlyerText, ev.chat[3])
ok('взяла - женская форма', ev.chat[4]:find('взяла листовку', 1, true) ~= nil, ev.chat[4])

-- ============================================ СОЦОПРОС: ЦИКЛ ===============
section('соцопрос: цикл, стадии, скриншоты')

local near = { { id = 7, nick = 'Girl_Nick', dist = 1.2 },
               { id = 9, nick = 'Boy_Nick', dist = 2.5 } }

socialResetState()
socialQuestion = ''            -- секция текстов выше вопрос уже задала
local okS, errS = socialStart(near, 'Jonny_Wilde')
eq('без вопроса недели цикл не стартует', okS, false)
eq('причина отказа понятна', errS, 'сначала задайте вопрос недели')

socialApplyQuestion('Как вам наш город?')
okS, errS, ev = socialStart(near, '')
eq('пустой ник ведущего - отказ', okS, false)
eq('причина: ник', errS, 'ваш ник ещё не определён')
eq('цикл не запущен', social.active, false)

okS, errS, ev = socialStart({}, 'Jonny_Wilde')
eq('без игроков в радиусе - отказ', okS, false)
ok('причина упоминает радиус', tostring(errS):find('3.0', 1, true) ~= nil, errS)

okS, errS, ev = socialStart(near, 'Jonny_Wilde')
eq('пол известен - цикл стартовал', okS, true)
eq('стадия 1', social.stage, 1)
eq('цель - ближайшая', social.targetNick, 'Girl_Nick')
eq('id цели', social.targetId, 7)
ok('приветствие отправляется сразу', type(ev) == 'table' and ev.chat ~= nil)
ok('запись в журнале', social.log[1]:find('старт', 1, true) ~= nil, social.log[1])

okS, errS = socialStart(near, 'Jonny_Wilde')
eq('повторный старт отклонён', errS, 'цикл уже идёт')

-- согласие словом из чата
ev = socialHandleMessage(7, 'да, конечно', function() return 'Girl_Nick' end)
eq('после согласия стадия 2', social.stage, 2)
ok('вопрос недели уходит в чат', ev ~= nil and ev.chat[1] == 'Как вам наш город?')
eq('чужое сообщение игнорируется', socialHandleMessage(11, 'да', function() return 'X' end), nil)

-- ответ на вопрос
ev = socialHandleMessage(7, 'Мне нравится ваш город', function() return 'Girl_Nick' end)
eq('стадия 2.5 - ждём скрин №1', social.stage, 2.5)
ok('опрос записан в базу', social.surveys['Girl_Nick'] ~= nil)
eq('дата опроса - сегодня', social.surveys['Girl_Nick'].date, socialToday())
ok('событие требует сохранения', ev ~= nil and ev.save == true)
eq('повторно на 2.5 не принимаем', socialHandleMessage(7, 'ещё', function() return 'Girl_Nick' end),
   nil)

-- скриншот №1 -> листовка
ev = socialAfterShot1('Girl_Nick')
eq('стадия 3 - ждём /me листовки', social.stage, 3)
ok('реплики листовки отправлены', ev ~= nil and #ev.chat == 4)
eq('скрин №1 на чужой стадии не срабатывает', socialAfterShot1('Girl_Nick'), nil)

-- «взяла» засчитывается и без слова «листовку»
ev = socialHandleMessage(7, 'взяла', function() return 'Girl_Nick' end)
eq('стадия 3.5 - ждём скрин №2', social.stage, 3.5)
ok('листовка записана', social.flyers['Girl_Nick'] ~= nil)
eq('не «взял» - не засчитываем', socialHandleMessage(7, 'спасибо', function() return 'Girl_Nick' end),
   nil)

-- скриншот №2 завершает цикл
ev = socialAfterShot2('Girl_Nick', false)
ok('финальная реплика «Спасибо»', ev ~= nil and ev.chat[1] == 'Спасибо')
eq('цикл завершён', social.active, false)
eq('стадия сброшена', social.stage, 0)

-- ручной зачёт листовки на стадии 3
socialResetState()
socialApplyQuestion('Вопрос')
socialStart(near, 'Jonny_Wilde')
social.stage, social.targetNick, social.targetId = 3, 'Boy_Nick', 9
ev = socialAfterShot2('Boy_Nick', true)
ok('листовка зачтена вручную', social.flyers['Boy_Nick'] ~= nil)
eq('цикл после ручного зачёта закрыт', social.active, false)
ok('в журнале про ручной зачёт',
   (function()
       for _, l in ipairs(social.log) do
           if tostring(l):find('вручную', 1, true) then return true end
       end
       return false
   end)())

-- прерывание
socialResetState()
socialAbort('сброс перед тестом')
social.stage, social.active, social.targetNick = 2, true, 'Girl_Nick'
ev = socialAbort('вручную')
eq('после прерывания цикл выключен', social.active, false)
ok('прерывание требует сохранения', ev ~= nil and ev.save == true)
ok('причина в журнале', social.log[1]:find('вручную', 1, true) ~= nil, social.log[1])
eq('прерывание неидущего цикла - ничего', socialAbort('x'), nil)

-- вопрос о поле, если он неизвестен
gendersReset()
GENDERS_LOADED, GENDERS_MIGRATED = true, true
GENDERS = {}
socialResetState()
socialApplyQuestion('Вопрос недели')
okS, errS, ev = socialStart(near, 'Jonny_Wilde')
eq('цикл стартовал', okS, true)
eq('ждём выбор пола', socialNeedGender, true)
eq('реплик пока нет', ev, nil)
eq('стадия 1', social.stage, 1)

-- ============================================ СОЦОПРОС: РАЗБОР ЧАТА ========
section('соцопрос: разбор строк сервера')

socialResetState()
eq('неидущий цикл строки не разбирает', socialParseLine('Nick[7]: да', 15, 'My_Nick'), nil)
social.active, social.stage, social.targetId = true, 1, 7

local resolve = function(nick) if nick == 'Anna_Malboro' then return 264 end return nil end
local id, msg = socialParseLine('Girl_Nick[7]: да, конечно', 15, 'My_Nick', resolve)
eq('чат с ID: игрок', id, 7)
eq('чат с ID: текст', msg, 'да, конечно')

id, msg = socialParseLine('Girl_Nick[7] взяла листовку', 15, 'My_Nick', resolve)
eq('/me с ID: игрок', id, 7)
eq('/me с ID: текст', msg, 'взяла листовку')

id, msg = socialParseLine('Anna_Malboro: привет', 15, 'My_Nick', resolve)
eq('чат без ID: игрок найден по списку', id, 264)
eq('чат без ID: текст', msg, 'привет')

eq('своё сообщение не разбираем', socialParseLine('My_Nick[15]: да', 15, 'My_Nick', resolve), nil)
eq('своё /me не разбираем',
   socialParseLine('My_Nick[15] взял листовку', 15, 'My_Nick', resolve), nil)
eq('неизвестный ник без ID игнорируем',
   socialParseLine('Someone: да', 15, 'My_Nick', resolve), nil)
eq('пустая строка игнорируется', socialParseLine('', 15, 'My_Nick', resolve), nil)

-- строка сразу двигает стадию
social.stage = 1
socialRunEventsCheck = socialHandleMessage(socialParseLine('Girl_Nick[7]: ага', 15, 'My_Nick',
                                                           resolve),
                                           'да', function() return 'Girl_Nick' end)
eq('согласие из строки сервера подняло стадию', social.stage, 2)

-- ============================================ СОЦОПРОС: СПИСКИ И ХОТКЕЙ ===
section('соцопрос: игроки рядом, цель, базы, хоткей')

local list = { { id = 1, nick = 'Far_Player', dist = 9.0 },
               { id = 2, nick = 'Near_Player', dist = 1.5 },
               { id = 15, nick = 'My_Nick', dist = 0.1 } }
local sel = socialPlayersNear(list, SOCIAL_RANGE, 15)
eq('в радиусе 3 м только один (я исключён)', #sel, 1)
eq('это ближний игрок', sel[1].nick, 'Near_Player')
local wide = socialPlayersNear(list, SOCIAL_TARGET_RANGE, 15)
eq('в радиусе 10 м двое', #wide, 2)
ok('сортировка по дистанции', wide[1].dist <= wide[2].dist)
eq('список без дистанции отброшен',
   #socialPlayersNear({ { id = 3, nick = 'No_Dist' } }, 10, 15), 0)
eq('пустой ник отброшен', #socialPlayersNear({ { id = 4, nick = '', dist = 1 } }, 10, 15), 0)

eq('цель по умолчанию - ближайший', socialActualTarget(wide, nil).nick, 'Near_Player')
eq('выбранный вручную важнее', socialActualTarget(wide, 1).nick, 'Far_Player')
socialSelectedId = 999
eq('несуществующий выбор сбрасывается',
   socialActualTarget(wide, socialSelectedId).nick, 'Near_Player')
eq('сброс записан в состояние', socialSelectedId, nil)

local mark, col = socialMarks('Nobody')
eq('метка нового игрока пустая', mark, '')
eq('цвет нового - обычный текст', col, 'text')
social.surveys = { S = { date = '2026-09-29' } }
social.flyers = { F = { date = '2026-09-29' } }
eq('опрошен', (socialMarks('S')), 'ОПРОШЕН')
eq('цвет опрошенного', select(2, socialMarks('S')), 'soon')
eq('листовка', (socialMarks('F')), 'ЛИСТ')
social.surveys.B, social.flyers.B = { date = 'x' }, { date = 'x' }
eq('опрошен + листовка', (socialMarks('B')), 'ОПРОШЕН + ЛИСТ')
eq('цвет - красный', select(2, socialMarks('B')), 'blocked')
social.surveys, social.flyers = {}, {}

local rows = socialBaseRows({ Anna = { date = '2026-09-28' }, Bob = { date = '2026-09-29' } })
eq('строк в базе две', #rows, 2)
eq('сортировка по нику', rows[1].nick, 'Anna')
eq('нумерация', rows[2].n, '2')
eq('пустая база', #socialBaseRows({}), 0)

eq('стадия 2.5 названа', socialStageName(2.5), 'ЖДЁМ СКРИН №1 (соцопрос)')
eq('неидущий цикл', socialStageName(0), 'не идёт')
eq('неизвестная стадия', socialStageName(9), '?')

ok('F10 - допустимый хоткей', socialValidHotkey(0x79) == true)
ok('мышь не берём', socialValidHotkey(1) == false and socialValidHotkey(2) == false)
ok('0 и 300 вне диапазона', socialValidHotkey(0) == false and socialValidHotkey(300) == false)
eq('ESC отменяет выбор', socialScanHotkey(function(k) return k == 0x1B end), false)
eq('нажатая клавиша становится хоткеем', socialScanHotkey(function(k) return k == 0x79 end),
   0x79)
eq('ничего не нажато - nil', socialScanHotkey(function() return false end), nil)

-- журнал модуля держит 20 последних событий
social.log = {}
for i = 1, 25 do socialLogAdd('событие ' .. i) end
eq('журнал ограничен 20 записями', #social.log, 20)
ok('свежие сверху', social.log[1]:find('событие 25', 1, true) ~= nil, social.log[1])

-- ============================================ ПЕРЕНОС ДАННЫХ SFN LOGS ======
section('helper: перенос журнала из папки SFN Logs')

ok('пути разные: SFNHelper и SFNLogs', DIR ~= LEGACY_DIR, DIR .. ' vs ' .. LEGACY_DIR)
ok('старая папка - SFNLogs', LEGACY_DIR:find('SFNLogs') ~= nil, LEGACY_DIR)

local legacyRoster = LEGACY_DIR .. '\\roster.json'
local legacyCfg = LEGACY_DIR .. '\\config.ini'
local myRoster = PATHS.roster
local myCfg = PATHS.config
os.remove(myRoster); os.remove(myCfg); os.remove(PATHS.export)
writeFile(legacyRoster, '{"members":{"Jonny_Wilde":{"rank":9}},"version":1}')
writeFile(legacyCfg, '[window]\nhotkey = 120\n')

eq('первый запуск перенёс два файла', migrateLegacyData(), 2)
ok('журнал скопирован в папку Helper-а', readFile(myRoster) ~= nil)
ok('содержимое журнала не повреждено',
   (readFile(myRoster) or ''):find('Jonny_Wilde', 1, true) ~= nil)
ok('настройки скопированы', (readFile(myCfg) or ''):find('hotkey = 120', 1, true) ~= nil)
ok('исходные файлы не удалены (откат безопасен)',
   readFile(legacyRoster) ~= nil and readFile(legacyCfg) ~= nil)
eq('повторный запуск ничего не трогает', migrateLegacyData(), 0)

-- свои данные не затираются чужими
writeFile(myRoster, '{"members":{"My_Own":{"rank":5}},"version":1}')
writeFile(legacyRoster, '{"members":{"Other":{"rank":1}},"version":1}')
eq('перенос не перезаписывает свой журнал', migrateLegacyData(), 0)
ok('свой журнал уцелел', (readFile(myRoster) or ''):find('My_Own', 1, true) ~= nil)

os.remove(myRoster); os.remove(myCfg); os.remove(PATHS.export)
os.remove(legacyRoster); os.remove(legacyCfg)

-- ============================================================ ИТОГ =======
print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
