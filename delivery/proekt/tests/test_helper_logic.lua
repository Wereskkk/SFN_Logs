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

-- ============================================================ ИТОГ =======
print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
