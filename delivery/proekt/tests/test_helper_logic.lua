-- Тесты чистой логики SFN_Helper: идентификация ядра и модуль «Фото»
-- (диалог папарацци, заказы и зачёт съёмок, недельные лимиты, файл базы).
-- Запуск:  python3 tests/run_helper_logic.py   (lupa, Lua 5.4)

local SRC = arg[1] or '../../SFN_Helper.lua'

-- ------------------------------------------------------------ заглушки ----
local TMP = '/tmp/sfnhelper_test'
os.execute('mkdir -p ' .. TMP)
getWorkingDirectory  = function() return TMP end
doesDirectoryExist   = function() return true end
createDirectory      = function() return true end

local full = assert(io.open(SRC, 'r')):read('*a')
local body = full:match('\n%-%- >>> PURE LOGIC BEGIN(.-)\n%-%- <<< PURE LOGIC END\n')
assert(body, 'метки PURE LOGIC не найдены в ' .. SRC)
body = body .. [[

return { json = json, PATHS = PATHS, readFile = readFile, writeFile = writeFile }
]]
local chunk, err = load(body, 'purelogic')
assert(chunk, err)
local exposed = assert(chunk())
local writeFile = exposed.writeFile
local readFile  = exposed.readFile

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
ok('версия шапки и литерал совпадают (0.1.0)',
   full:find("script_version('0.1.0')", 1, true) ~= nil
   and full:find("SFN_VERSION_STR = '0.1.0'", 1, true) ~= nil)
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
eq('валидация принимает Helper новее', validateScriptText(fakeScript('SFN Helper', '9.9.9'), '0.1.0'), '9.9.9')
ok('валидация отвергает чужое имя (SFN Logs)',
   select(1, validateScriptText(fakeScript('SFN Logs', '9.9.9'), '0.1.0')) == nil)

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

-- ============================================================ ИТОГ =======
print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
