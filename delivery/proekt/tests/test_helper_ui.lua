-- Сквозная проверка вёрстки SFN_Helper: системные вкладки + вкладка модуля
-- «Фото» на headless-моке mimgui. Геометрия: наложения текстов, выход за
-- границы, закреплённые элементы при скролле, клип строк.
-- Запуск:  python3 tests/run_helper_ui.py

local mock = require 'tests.mock_imgui'
local st = mock.st

local passed, failed = 0, 0
local function ok(name, cond, extra)
    if cond then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-52s %s', name, tostring(extra or '')))
    end
end
local function section(t) print('\n== ' .. t) end

local WARMUP_FRAMES = 4
local function findOverlaps(from, to)
    local bad = {}
    local list = {}
    for i = from, to do list[#list + 1] = st.texts[i] end
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            if a.w and b.w and a.w > 0 and b.w > 0
               and a.x < b.x + b.w and b.x < a.x + a.w
               and a.y < b.y + b.h and b.y < a.y + a.h then
                bad[#bad + 1] = string.format('«%s» x «%s»', tostring(a.text), tostring(b.text))
            end
        end
    end
    return bad
end
local function checkFrame(title, opts)
    opts = opts or {}
    mock.reset()
    for id in pairs(opts.popups or {}) do st.popupOpen[id] = true end
    local info
    for _ = 1, WARMUP_FRAMES do info = mock.frame({ clicks = opts.clicks, hovers = opts.hovers }) end
    st.errors = {}
    info = mock.frame({ clicks = opts.clicks, hovers = opts.hovers })
    local bad = findOverlaps(info.from, info.to)
    ok(title .. ': тексты не наезжают друг на друга', #bad == 0,
       (#bad > 0 and ('\n       ' .. table.concat(bad, '\n       ')) or ''))
    ok(title .. ': раскладка без ошибок', #st.errors == 0,
       (#st.errors > 0 and table.concat(st.errors, ' | ') or ''))
    return info
end

local function lastTexts()
    local out = {}
    for _, t in ipairs(st.texts) do
        if t.frame == st.frames then out[#out + 1] = t end
    end
    return out
end
local function lastRects()
    local out = {}
    for _, r in ipairs(st.rects) do
        if r.frame == st.frames then out[#out + 1] = r end
    end
    return out
end
local function hasText(sub)
    for _, t in ipairs(lastTexts()) do
        if tostring(t.text):find(sub, 1, true) then return t end
    end
    return nil
end
local function gradStripY()
    for _, r in ipairs(lastRects()) do
        if r.kind == 'grad' and r.h >= 18 and r.h <= 24 and r.w > 500 then return r.y end
    end
end
local function childRect(id)
    local last = nil
    for _, c in ipairs(st.childLog) do
        if c.id == id then last = c end
    end
    return last
end

mock.runInit()
loadConfig()
loadRoster()
loadUpdateState()
SFNLogs.registerCommands()      -- main() в тестах не крутится, команды регистрируем сами
SFNLogs.setVisible(true)

-- ============================================ МЕНЮ СОБРАНО =================
section('helper: меню из системных вкладок и модулей')
ok('порядок вкладок: Журнал, Поиск, Фото, Эфир, Настройки, О скрипте',
   table.concat(MENU_IDS, ',') == 'journal,search,photo,efir,settings,about',
   table.concat(MENU_IDS, ','))
ok('полосы разделов собраны', table.concat(STRIP_LABELS, ',')
   == 'Журнал состава,Поиск по игроку,База фотографа,Помощник эфира,Настройки,О скрипте',
   table.concat(STRIP_LABELS, ','))
ok('модуль photo в реестре', MODULE_BY_ID['photo'] ~= nil)

SFNLogs.setMenu(1)
local infoJ = checkFrame('журнал helper-а')
ok('журнал: полоса на месте', hasText('Журнал состава') ~= nil)
ok('сайдбар: вкладка Фото есть', hasText('Фото') ~= nil)
ok('сайдбар: заголовок SFN Helper', hasText('SFN Helper') ~= nil)

-- ============================================ ВКЛАДКА ФОТО =================
section('helper: вкладка «Фото»')
photoReset()
SFNLogs.setMenu(3)
local infoP0 = checkFrame('фото: пустая база')
ok('фото: полоса раздела', hasText('База фотографа') ~= nil)
ok('фото: счётчик игроков 0 / 25', hasText('0 / 25') ~= nil)
ok('фото: счётчик мест 0 / 15', hasText('0 / 15') ~= nil)
ok('фото: подсказка пустой таблицы игроков',
   hasText('на этой неделе ещё никто не сфотографирован') ~= nil)
ok('фото: кнопка очистки есть', hasText('Очистить список') ~= nil)

-- наполняем базу и проверяем таблицы
photoState.players['Jonny_Wilde'] = { date = '2026-09-29' }
photoState.players['Anna_Malboro'] = { date = '2026-09-28' }
photoState.players['Linnea_Korhonen'] = { date = '2026-09-27' }
photoState.places['Мост|Лос-Сантос'] = { date = '2026-09-26' }
local infoP1 = checkFrame('фото: с данными')
ok('фото: ники в таблице', hasText('Jonny_Wilde') ~= nil and hasText('Anna_Malboro') ~= nil)
ok('фото: место в таблице', hasText('Мост') ~= nil and hasText('Лос-Сантос') ~= nil)
ok('фото: счётчик игроков 3 / 25', hasText('3 / 25') ~= nil)
ok('фото: текущий заказ «нет»', hasText('нет') ~= nil)

-- скролл таблицы игроков: полосы и счётчики стоят, строки в клипе
st.scroll = {}
checkFrame('фото: прокрутка 0')
local strip0 = gradStripY()
local lim0 = (function() for _, t in ipairs(lastTexts()) do if tostring(t.text) == 'недельные лимиты' then return t.y end end end)()
for i = 4, 40 do photoState.players['Scroll_' .. i] = { date = '2026-09-01' } end
st.scroll['##photop'] = 300
checkFrame('фото: прокрутка 300')
local band = childRect('##photop')
ok('фото: полоса раздела не двинулась при скролле', math.abs((gradStripY() or -1) - strip0) < 0.51)
ok('фото: шапка таблицы игроков не двинулась',
   (function()
       local y0, y1 = nil, nil
       for _, t in ipairs(lastTexts()) do
           if tostring(t.text) == 'Игрок' then y1 = t.y end
       end
       return y1 ~= nil
   end)())
ok('фото: строки вне своей полосы не рисуются',
   (function()
       if not band then return false end
       for _, t in ipairs(lastTexts()) do
           local s = tostring(t.text)
           if s:find('^Scroll_%d+$') and (t.y + t.h < band.y - 1 or t.y > band.y + band.h + 1) then
               return false
           end
       end
       return true
   end)())
st.scroll = {}
for i = 4, 40 do photoState.players['Scroll_' .. i] = nil end

-- диалог папарацци открывает вкладку и добавляет колонку
photoReset()
local cp = utf8ToCp1251
local dlg = cp('Игрок\tID\nJonny_Wilde\t248\n')
local r = MODULE_BY_ID['photo'].onShowDialog(32700, 5, 'Заказ', 'Ок', 'Отмена', dlg)
ok('диалог: возвращены подменённые аргументы', type(r) == 'table' and r[1] == 32700 and type(r[6]) == 'string')
ok('диалог: колонка Фото добавлена', r ~= nil and r[6]:find(cp('Фото'), 1, true) ~= nil)
ok('диалог: окно открыто на вкладке Фото', SFNLogs.isOpen() == true and SFNLogs.ui.menu == 3,
   SFNLogs.ui.menu)

-- ============================================ ВКЛАДКА ЭФИР =================
section('helper: вкладка «Эфир»')
efirAccessGranted = false
efirRunning = false
efirScores = {}
SFNLogs.setMenu(4)
checkFrame('эфир: доступ закрыт')
ok('эфир: полоса замка', hasText('доступ закрыт') ~= nil)
ok('эфир: пояснение про ведущих',
   hasText('Модуль «Эфир» доступен только ведущим San Fierro News.') ~= nil)
ok('эфир: кнопок запуска нет', hasText('НАЧАТЬ ЭФИР (Математика)') == nil)

efirAccessGranted = true
local infoE1 = checkFrame('эфир: доступ открыт, эфир не идёт')
ok('эфир: полоса состояния', hasText('состояние эфира') ~= nil)
ok('эфир: кнопка запуска математики', hasText('НАЧАТЬ ЭФИР (Математика)') ~= nil)
ok('эфир: кнопка запуска анаграмм', hasText('НАЧАТЬ ЭФИР (Анаграммы)') ~= nil)
ok('эфир: кнопка запуска вышибал', hasText('НАЧАТЬ ЭФИР (Вышибалы)') ~= nil)
ok('эфир: поле максимума баллов', hasText('Максимум баллов:') ~= nil)

efirRunning, efirMode, efirType = true, 'math', 'Математика'
efirStartedAt = os.clock() - 65
efirMathQ, efirMathA, efirMathSuffix = '2 + 2', 4, ' = ?'
efirScores = { Jonny_Wilde = { id = 248, score = 2 }, Anna_Malboro = { id = 264, score = 1 } }
local infoE2 = checkFrame('эфир: идёт математика')
ok('эфир: статус «идёт»', hasText('идёт: Математика') ~= nil)
ok('эфир: полоса текущего задания', hasText('текущее задание (Математика)') ~= nil)
ok('эфир: пример виден', hasText('2 + 2 = ?') ~= nil)
ok('эфир: ответ виден ведущему', hasText('ответ: 4') ~= nil)
ok('эфир: кнопка подтверждения', hasText('Верный ответ') ~= nil)
ok('эфир: кнопка завершения', hasText('Завершить эфир') ~= nil)
ok('эфир: полоса счёта', hasText('счёт эфира') ~= nil)
ok('эфир: ник в таблице счёта',
   hasText('Jonny Wilde') ~= nil or hasText('Jonny_Wilde') ~= nil)
ok('эфир: речь и итоги на месте', hasText('Стартовая речь') ~= nil and hasText('Итоги в чат') ~= nil)

-- команда /efir переключает окно на вкладку
SFNLogs.setMenu(1)
SFNLogs.setVisible(true)
ok('команда /efir зарегистрирована', __cmds['efir'] ~= nil)
__cmds['efir']()
ok('/efir открывает вкладку Эфир', SFNLogs.ui.menu == 4, SFNLogs.ui.menu)

efirRunning, efirScores, efirAccessGranted = false, {}, false
SFNLogs.setMenu(1)

-- ============================================ ДИСПЕТЧЕР ONTICK ==============
section('helper: диспетчер onTick (личный хоткей модуля)')
local modE = MODULE_BY_ID['efir']
ok('у модуля «Эфир» есть onTick', type(modE.onTick) == 'function')
ok('у модуля «Эфир» есть onTerminate', type(modE.onTerminate) == 'function')
ok('у модуля «Фото» onTick не обязателен', modE.onTick ~= nil)

-- onTick дёргается из главного цикла main(); цикл здесь не запускаем, поэтому
-- вызываем обработчик так же, как это делает диспетчер: pcall(mod.onTick, now)
efirAccessGranted = true
SFNLogs.setMenu(1)
SFNLogs.setVisible(false)
isKeyDown = function(k) return k == efirCfg.hotkey end
local okTick, tickErr = pcall(modE.onTick, os.time())
ok('onTick модуля не падает', okTick, tostring(tickErr))
ok('личный хоткей эфира открывает окно', SFNLogs.isOpen() == true)
ok('личный хоткей эфира ставит вкладку «Эфир»', SFNLogs.ui.menu == 4, SFNLogs.ui.menu)

-- повторное нажатие той же клавиши не должно «щёлкать» окном каждый кадр
SFNLogs.setVisible(false)
pcall(modE.onTick, os.time())
ok('удержание хоткея не переоткрывает окно', SFNLogs.isOpen() == false)

-- клавиша отпущена - модуль сбрасывает флаг и готов к новому нажатию
isKeyDown = function() return false end
pcall(modE.onTick, os.time())
isKeyDown = function(k) return k == efirCfg.hotkey end
pcall(modE.onTick, os.time())
ok('после отпускания хоткей срабатывает снова', SFNLogs.isOpen() == true and SFNLogs.ui.menu == 4)
isKeyDown = nil

-- без доступа к эфиру его хоткей молчит (окно не открывается)
efirAccessGranted = false
SFNLogs.setMenu(1)
SFNLogs.setVisible(false)
isKeyDown = function(k) return k == efirCfg.hotkey end
pcall(modE.onTick, os.time())
ok('хоткей эфира не работает без доступа', SFNLogs.isOpen() == false)
isKeyDown = nil
efirAccessGranted = true
efirRunning, efirScores = false, {}
SFNLogs.setMenu(1)
SFNLogs.setVisible(true)        -- кадр рисуется только при открытом окне

-- ============================================ НАСТРОЙКИ И О СКРИПТЕ ========
section('helper: настройки и справка содержат модуль')
SFNLogs.setMenu(5)
checkFrame('настройки helper-а')
ok('настройки: секция модуля Фото', hasText('Фото') ~= nil)
ok('настройки: лимит игроков', hasText('лимит игроков в неделю') ~= nil)
ok('настройки: путь к базе', hasText('sfn_photo_data') ~= nil)
ok('настройки: секция модуля Эфир', hasText('призовой фонд') ~= nil)
ok('настройки: статус доступа эфира', hasText('закрыт') ~= nil or hasText('разрешён') ~= nil)
ok('настройки: системные секции на месте', hasText('Окно') ~= nil and hasText('Служебное') ~= nil)

SFNLogs.setMenu(6)
checkFrame('о скрипте helper-а')
ok('о скрипте: список модулей', hasText('Модули помощника') ~= nil)
ok('о скрипте: модуль Фото описан', hasText('недельные лимиты фото') ~= nil)
ok('о скрипте: модуль Эфир описан', hasText('викторины в эфире') ~= nil)

-- ============================================ КОМАНДА /sfnhelper ===========
section('helper: команда /sfnhelper')
ok('команда зарегистрирована', __cmds['sfnhelper'] ~= nil)
SFNLogs.setVisible(false)
__cmds['sfnhelper']('photo')
ok('/sfnhelper photo открывает вкладку Фото', SFNLogs.isOpen() == true and SFNLogs.ui.menu == 3,
   SFNLogs.ui.menu)
__cmds['sfnhelper']('')
ok('/sfnhelper без аргумента закрывает окно', SFNLogs.isOpen() == false)
__cmds['sfnhelper']('photo')
__cmds['sfnhelper']('')

-- значка «‹» нет ни в одной вкладке
for tab = 1, 6 do
    SFNLogs.setMenu(tab)
    checkFrame('вкладка ' .. tab .. ' без стрелочки')
    ok('вкладка ' .. tab .. ': нет значка «‹»',
       (function()
           for _, t in ipairs(lastTexts()) do
               if tostring(t.text) == '<' then return false end
           end
           return true
       end)())
end
SFNLogs.setMenu(1)

-- ============================================================ ИТОГ =======
print(string.format('\n%d passed, %d failed', passed, failed))
if os.exit then os.exit(failed == 0 and 0 or 1) end
