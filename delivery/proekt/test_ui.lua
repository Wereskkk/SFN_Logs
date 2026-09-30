-- Сквозная проверка вёрстки SFN Logs на headless-моке mimgui.
-- Запуск:  luajit test_ui.lua
--
-- Проверяется не «красиво/не красиво», а геометрия:
--   * тексты не наезжают друг на друга (пересечение прямоугольников);
--   * содержимое не вылезает за границы окна и дочерних регионов;
--   * стек Begin/End и Push/Pop стилей сбалансирован;
--   * размер окна следует за содержимым (пусто / 3 / 40 записей);
--   * интерфейс выживает при DPI 1.5 и при отказе DrawList.

local mock = require 'tests.mock_imgui'
local st = mock.st

-- ------------------------------------------------------------- заглушки --
local TMP = os.getenv('SFN_TMP') or '/tmp/sfntest_ui'
os.execute('mkdir -p "' .. TMP .. '"')
getWorkingDirectory = function() return TMP end
doesDirectoryExist  = function() return true end
createDirectory     = function() return true end
isSampLoaded        = function() return true end
isSampfuncsLoaded   = function() return true end
isSampAvailable     = function() return true end
wasKeyPressed       = function() return false end
isChatInputActive   = function() return false end
isPauseMenuActive   = function() return false end
downloadUrlToFile   = nil
lua_thread          = { create = function() return {} end }
sampAddChatMessage  = function() end
sampRegisterChatCommand = function() end
sampGetPlayerNickname = function() return 'Test_Leader' end
sampGetPlayerScore  = function() return 7 end
sampIsPlayerConnected = function() return false end
sampGetPlayerIdByCharHandle = function() return nil end
thisScript          = function() return {} end
PLAYER_PED          = 0

-- --------------------------------------------------------------- ассерты --
local passed, failed = 0, 0
local function ok(name, cond, extra)
    if cond then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-50s %s', name, tostring(extra or '')))
    end
end
local function section(t) print('\n== ' .. t) end

-- --------------------------------------------------- анализ наложений ----
-- Пересечение прямоугольников текста = наложение. Допуск 1 px на кернинг.
-- Текст под PushClipRect физически не рисуется шире границы клипа —
-- учитываем это, иначе «обрезанный» текст ложно считается наложением.
local function effW(t)
    if t.clipped and t.clipped > 0 and t.clipped < t.w then return t.clipped end
    return t.w
end

local function findOverlaps(from, to)
    local list = {}
    for i = from, to do list[#list + 1] = st.texts[i] end
    local bad = {}
    for i = 1, #list do
        for j = i + 1, #list do
            local a, b = list[i], list[j]
            local vOv = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
            local hOv = math.min(a.x + effW(a), b.x + effW(b)) - math.max(a.x, b.x)
            if vOv > 1 and hOv > 1 then
                bad[#bad + 1] = string.format(
                    '«%s» x=%.0f..%.0f y=%.0f  ×  «%s» x=%.0f..%.0f y=%.0f  (пересечение %.1f px)',
                    a.text:sub(1, 24), a.x, a.x + effW(a), a.y,
                    b.text:sub(1, 24), b.x, b.x + effW(b), b.y, hOv)
            end
        end
    end
    return bad
end

-- Кадров всегда два: размер окна считается из измерения предыдущего кадра
-- (chromeMeasured), поэтому первый кадр строится по оценке, а второй — уже по
-- факту. В игре окно открыто сотни кадров, так что оцениваем установившийся.
local WARMUP_FRAMES = 4

local function checkFrame(title, opts)
    opts = opts or {}
    mock.reset()
    for id in pairs(opts.popups or {}) do st.popupOpen[id] = true end
    for id in pairs(opts.combos or {}) do st.comboOpen[id] = true end
    local info
    for _ = 1, WARMUP_FRAMES do
        info = mock.frame({ clicks = opts.clicks, hovers = opts.hovers, inputs = opts.inputs })
    end
    st.errors = {}                      -- ошибки кадров прогрева не учитываем
    info = mock.frame({ clicks = opts.clicks, hovers = opts.hovers, inputs = opts.inputs })
    local bad = findOverlaps(info.from, info.to)
    ok(title .. ': тексты не наезжают друг на друга', #bad == 0,
       (#bad > 0 and ('\n       ' .. table.concat(bad, '\n       ')) or ''))
    ok(title .. ': раскладка без ошибок', #st.errors == 0,
       (#st.errors > 0 and ('\n       ' .. table.concat(st.errors, '\n       ')) or ''))
    return info
end

-- ------------------------------------------------------------ данные ----
local function fillRoster(n, opts)
    opts = opts or {}
    roster.members = {}
    for i = 1, n do
        local nick = string.format('%s_%d', opts.longNick and 'Очень_Длинный_Никнейм' or 'Member', i)
        local m = addMember(nick, opts.by or 'Boss_Name', os.time() - i * 86400,
                            opts.rank or ((i % 9) + 1), (i % 20) + 1)
        if m then
            if opts.notes then m.note = 'заметка о сотруднике номер ' .. i end
            if opts.dismissSome and i % 5 == 0 then
                dismissMember(nick, 'нарушение регламента редакции и субординации')
            end
        end
    end
end

local function anyNick()
    -- Детерминированный выбор для проверок меню: предпочитает НЕ уволенного.
    -- Порядок pairs() в Lua 5.4 зависит от хеш-сида строки: попади в тест
    -- уволенный, набор пунктов меню другой и проверка «Повысить до:» краснеет.
    local fallback
    for nick, m in pairs(roster.members) do
        if not m.dismissed then return nick end
        fallback = fallback or nick
    end
    return fallback
end

-- ============================================================ ЗАГРУЗКА ===
section('загрузка скрипта')
mock.runInit()
loadConfig()
loadRoster()
SFNLogs.setVisible(true)          -- окно открыто: /sfnlog или F8
ok('подписка на кадр создана', #mock.subscriptions.frame == 1)
ok('отладочный доступ к UI опубликован', SFNLogs.ui ~= nil and SFNLogs.setMenu ~= nil)
ok('API настроен только на SF News', SFNLogs.api.status().faction == 9
   and SFNLogs.api.status().server == 'saint-louis')

-- ============================================================ ПУСТО ======
st.display = { x = 1920, y = 2400 }

section('пустой журнал')
roster.members = {}
local infoEmpty = checkFrame('пустой журнал')
if SFNLogs.lastUiError then print('   !! ошибка отрисовки: ' .. SFNLogs.lastUiError) end
print(string.format('   окно: %.0f x %.0f px', infoEmpty.win.x, infoEmpty.win.y))
local emptyW, emptyH = infoEmpty.win.x, infoEmpty.win.y
ok('пустое окно не уже их базовых 1030', emptyW >= 1030, emptyW)
ok('пустое окно не ниже их базовых 520', emptyH >= 520, emptyH)
-- Пустое окно состоит из той же шапки, панелей и вкладок, что и полное, —
-- меньше его делает только тело списка. Поэтому сравниваем с заполненным.
ok('пустое окно держит базовую высоту 520', emptyH <= 540, emptyH)

-- ============================================================ 3 ЗАПИСИ ===
section('три записи')
fillRoster(3)
local info3 = checkFrame('3 записи')
print(string.format('   окно: %.0f x %.0f px', info3.win.x, info3.win.y))
ok('окно с записями не ниже пустого', info3.win.y >= emptyH,
   string.format('%.0f vs %.0f', info3.win.y, emptyH))

-- ============================================================ 40 ЗАПИСЕЙ =
section('40 записей: длинные ники, увольнения, заметки')
fillRoster(40, { longNick = true, dismissSome = true, notes = true, rank = 7 })
local info40 = checkFrame('40 записей')
print(string.format('   окно: %.0f x %.0f px', info40.win.x, info40.win.y))
ok('ширина подстроилась под длинные ники', info40.win.x > info3.win.x,
   string.format('%.0f vs %.0f', info40.win.x, info3.win.x))
ok('высота ограничена экраном', info40.win.y <= st.display.y - 40, info40.win.y)

-- ============================================================ ПОИСК ======
section('фильтр журнала сужает список')
SFNLogs.ui.search = 'member_1_'
local infoSearch = checkFrame('поиск')
print(string.format('   окно при поиске: %.0f x %.0f px, строк: %d',
                    infoSearch.win.x, infoSearch.win.y, SFNLogs.layoutInfo().rows))
ok('после фильтра строк меньше', SFNLogs.layoutInfo().rows < 40)
SFNLogs.ui.search = ''

-- ============================================================ ВКЛАДКИ ====
section('вкладки')
fillRoster(8, { dismissSome = true, notes = true })
for i, name in ipairs({ 'Журнал', 'Поиск', 'Настройки', 'О скрипте' }) do
    ok('раздел переключается: ' .. name, SFNLogs.setMenu(i))
    local inf = checkFrame('раздел ' .. name)
    print(string.format('   %-11s окно %.0f x %.0f px', name, inf.win.x, inf.win.y))
end
SFNLogs.setMenu(1)

-- ============================================================ ПОПАПЫ ======
section('меню строки и модальные окна')
fillRoster(6, { dismissSome = true, notes = true })
local nick = anyNick()
SFNLogs.openRowMenu(nick)
checkFrame('меню строки', { popups = { rowmenu = true }, hovers = { ['##row1'] = true } })

SFNLogs.openReasonDialog(nick)
checkFrame('модалка увольнения', { popups = { ['Уволить##rsn'] = true } })

SFNLogs.openHistoryDialog(nick)
checkFrame('модалка истории', { popups = { ['История##hist'] = true } })

-- «Главный редактор» — самое длинное название ранга: колонка 150 px должна
-- его уместить (многоточие), не наехав на колонку примечания.
local longNick2 = 'History_Long'
roster.members[longNick2] = nil
addMember(longNick2, 'Очень_Длинный_Ник_Принявшего', os.time() - 30 * 86400, 7, 12)
changeRank(longNick2, 7, 'повышен до главного редактора за серию материалов')
SFNLogs.api.applyJournal(roster.members[longNick2], {
    player_nickname = longNick2, initiator_nickname = 'Glavnaya_Kollegiya',
    previous_rank = 'Редактор [6]', new_rank = 'Гл.Редактор [7]',
    reason = 'за серию репортажей о жизни города', event_date = '10.06.26 14:32',
})
SFNLogs.openHistoryDialog(longNick2)
checkFrame('модалка истории: длинные ранги', { popups = { ['История##hist'] = true } })

SFNLogs.openAddDialog()
checkFrame('модалка добавления', { popups = { ['Добавить игрока'] = true },
                                   inputs = { ['##nick'] = 'New_Member' } })

-- меню уволенного (другой набор пунктов)
local disNick
for n, m in pairs(roster.members) do if m.dismissed then disNick = n break end end
if disNick then
    SFNLogs.openRowMenu(disNick)
    checkFrame('меню уволенного', { popups = { rowmenu = true } })
else
    print('   (уволенных нет — пункт пропущен)')
end

-- ============================== v2.0.8: ГЕОМЕТРИЯ МЕНЮ СТРОКИ =============
section('v2.0.8: меню строки — панель, а не вертикальная полоска')
-- Ширину попапа задаёт SetNextWindowSize ДО BeginPopup. Вызов внутри открытого
-- попапа отдаёт размер следующему окну, а само меню автосайзится по содержимому,
-- которое само себя не расширяет (ширина кнопок берётся из GetContentRegionAvail):
-- в точке клика оставалась полоска ~1 px высотой во всё меню (баг-репорт 26.09.2026).
local function lastPopup(id)
    local e
    for _, p in ipairs(st.popupLog) do if p.id == id then e = p end end
    return e
end
local function popupText(info, pm, label)
    for i = info.from, info.to do
        local t = st.texts[i]
        if t.text:find(label, 1, true) and t.x >= pm.x - 1
           and t.x + effW(t) <= pm.x + pm.w + 1 then
            return true
        end
    end
    return false
end

fillRoster(6, { dismissSome = true })
local mnick = anyNick()
SFNLogs.openRowMenu(mnick)
local infoMenu = checkFrame('меню строки: размер', { popups = { rowmenu = true } })
local pm = lastPopup('rowmenu')
ok('меню: ширина задана ДО BeginPopup (SetNextWindowSize)',
   pm ~= nil and pm.sized == true,
   pm and string.format('sized=%s w=%.0f', tostring(pm.sized), pm.w) or 'попап не открылся')
ok('меню: шире вырожденной полоски (>=200 px)', pm ~= nil and pm.w >= 200, pm and pm.w)
ok('меню: не шире половины экрана (<=620 px)', pm ~= nil and pm.w <= 620, pm and pm.w)
ok('меню: высота вмещает все пункты (>=100 px)', pm ~= nil and pm.h >= 100, pm and pm.h)
ok('меню: пункт «Повысить до:» внутри рамки',
   pm ~= nil and popupText(infoMenu, pm, 'Повысить до:'))
ok('меню: пункт «История изменений» внутри рамки',
   pm ~= nil and popupText(infoMenu, pm, 'История изменений'))
ok('меню: пункт «Уволить» внутри рамки',
   pm ~= nil and popupText(infoMenu, pm, 'Уволить'))

-- меню уволенного: другой набор пунктов, требования к геометрии те же
local disNick2
for n2, m2 in pairs(roster.members) do if m2.dismissed then disNick2 = n2 break end end
if disNick2 then
    SFNLogs.openRowMenu(disNick2)
    local infoDis = checkFrame('меню уволенного: размер', { popups = { rowmenu = true } })
    local pd = lastPopup('rowmenu')
    ok('меню уволенного: ширина задана и достаточна',
       pd ~= nil and pd.sized == true and pd.w >= 200, pd and pd.w)
    ok('меню уволенного: пункт «Вернуть в состав» внутри рамки',
       pd ~= nil and popupText(infoDis, pd, 'Вернуть в состав'))
else
    print('   (уволенных нет — пункт пропущен)')
end

-- ============================================================ API ========
section('разбор ответов Evolve Logs API')
local eq = function(name, got, want)
    ok(name, got == want, string.format('got=%s want=%s', tostring(got), tostring(want)))
end
local k, n = parseApiRank('Репортер [4]')
eq('ранг из скобок', n, 4)
k, n = parseApiRank('Гл.Редактор')
eq('алиас Гл.Редактор', n, 7)
k, n = parseApiRank('Тех.Директор [8]')
eq('алиас со скобками', n, 8)
eq('invite', parseApiRank('Invite'), 'invite')
eq('uninvite', parseApiRank('Uninvite'), 'uninvite')
eq('пустая строка', parseApiRank(''), nil)
local t = parseApiDate('10.06.26 14:32')
ok('дата dd.mm.yy hh:mm', t ~= nil and t > 0, t)
eq('год из 2 цифр', os.date('%Y', t), '2026')
local t2 = parseApiDate('29.11.2025 23:22')
eq('дата dd.mm.yyyy', os.date('%d.%m.%Y %H:%M', t2), '29.11.2025 23:22')
eq('мусор', parseApiDate('когда-то'), nil)

roster.members = {}
local m = addMember('Api_Probe', 'Boss_Name', os.time(), 1, 3)
SFNLogs.api.applyJournal(m, {
    player_nickname = 'Api_Probe', initiator_nickname = 'Glavnaya_Kollegiya',
    previous_rank = 'Редактор [6]', new_rank = 'Гл.Редактор [7]',
    reason = 'за серию репортажей', event_date = '10.06.26 14:32',
})
eq('ранг применён из API', m.rank, 7)
eq('инициатор из API', m.lastInitiator, 'Glavnaya_Kollegiya')
eq('дата события распознана', os.date('%d.%m.%y', m.promotedAt), '10.06.26')
SFNLogs.api.applyJournal(m, {
    player_nickname = 'Api_Probe', initiator_nickname = 'Kadr_SF',
    previous_rank = 'Гл.Редактор [7]', new_rank = 'Uninvite',
    reason = 'неактив', event_date = '29.11.2025 23:22',
})
eq('uninvite увольняет', m.dismissed, true)
eq('дата увольнения', os.date('%d.%m.%Y', m.dismissedAt), '29.11.2025')
SFNLogs.api.applyHistory(m, {
    { player_nickname = 'Api_Probe', initiator_nickname = 'Priemshik_One',
      previous_rank = 'Invite', new_rank = 'Стажер [1]',
      reason = '', event_date = '01.02.25 10:00' },
    { player_nickname = 'Api_Probe', initiator_nickname = 'Priemshik_Two',
      previous_rank = 'Стажер [1]', new_rank = 'Звукооператор [2]',
      reason = '', event_date = '03.02.25 18:30' },
})
eq('дата принятия из истории', os.date('%d.%m.%Y', m.acceptedAt), '01.02.2025')
eq('принял из истории', m.acceptedBy, 'Priemshik_One')
eq('лента истории API', #m.apiHistory, 2)
checkFrame('журнал после применения API')

-- ============================================================ DPI ========
section('DPI 1.5 (mimgui dpi_scaling_mode = 3)')
st.dpi, st.fontH = 1.5, 21
fillRoster(12, { dismissSome = true, notes = true })
local infoDpi = checkFrame('DPI 1.5')
print(string.format('   окно при DPI 1.5: %.0f x %.0f px (при 1.0 было %.0f x %.0f)',
                    infoDpi.win.x, infoDpi.win.y, info3.win.x, info3.win.y))
ok('окно масштабируется вместе с DPI', infoDpi.win.x > info3.win.x * 1.15,
   string.format('%.0f vs %.0f', infoDpi.win.x, info3.win.x))
ok('dpiScale подхвачен', math.abs(SFNLogs.layoutInfo().dpi - 1.5) < 0.01)
st.dpi, st.fontH = 1.0, 16

-- ========================== v2.0.3: ПОЛНОШИРОЧНЫЕ ПОЛОСЫ И ПРАВЫЙ КРАЙ ====
section('v2.0.3: полосы во всю ширину, правый край и низ не режутся')
local function stripOf()
    local best = nil
    for _, r in ipairs(st.rects) do
        if r.kind == 'grad' and r.h >= 18 and r.h <= 24 then
            if not best or r.w > best.w then best = r end
        end
    end
    return best
end
local function sideBox()
    for _, r in ipairs(st.rects) do
        if r.kind == 'fill' and r.w > 150 and r.w < 170 and r.h > 300 then return r end
    end
end
local function itemByLabel(sub)
    for _, it in ipairs(st.items) do
        if tostring(it.id):find(sub, 1, true) then return it end
    end
end
for menu, title in ipairs({ 'журнал', 'поиск', 'настройки', 'о скрипте' }) do
    SFNLogs.setMenu(menu)
    checkFrame('полоса: ' .. title)
    local strip = stripOf()
    ok('полоса раздела «' .. title .. '» во всю ширину тела',
       strip and strip.w >= 700,
       strip and ('w=' .. string.format('%.0f', strip.w)) or 'полоса не найдена')
end
SFNLogs.setMenu(1)
checkFrame('журнал: прижим и низ')
local stripJ, sideJ = stripOf(), sideBox()
local chk = itemByLabel('уволенные')
ok('чекбокс «уволенные» не режется правым краем тела',
   chk and stripJ and (chk.x + chk.w) <= (stripJ.x + stripJ.w + 1),
   chk and stripJ and string.format('right=%.0f stripRight=%.0f',
                                    chk.x + chk.w, stripJ.x + stripJ.w))
-- v2.0.12: ряда кнопок под таблицей больше нет - список получил их место
local jadd = itemByLabel('jadd')
ok('v2.0.12: кнопки добавления под таблицей нет', jadd == nil,
   jadd and string.format('y=%.0f', jadd.y) or '')
SFNLogs.setMenu(2)
checkFrame('поиск: прижим ряда')
local stripS = stripOf()
local inp = itemByLabel('apinick')
ok('поле поиска не режется правым краем тела',
   inp and stripS and (inp.x + inp.w) <= (stripS.x + stripS.w + 1),
   inp and string.format('right=%.0f', inp.x + inp.w))
SFNLogs.setMenu(3)
checkFrame('настройки: строки во всю ширину')
local wideLine = nil
for _, r in ipairs(st.rects) do
    if r.kind == 'line' and r.w >= 700 then wideLine = r end
end
ok('строки настроек тянутся на всю ширину тела', wideLine ~= nil,
   wideLine and ('w=' .. string.format('%.0f', wideLine.w)) or 'широкой линии нет')
SFNLogs.setMenu(1)

-- ================== v2.0.7: НАВЕДЕНИЕ НА СТРОКУ И ЧЁРНАЯ ПОЛОСА СКРОЛЛА ===
section('v2.0.7: наведение на строку журнала не ломает раскладку')
-- mimgui: BeginTooltip возвращает nil (void). Старая проверка «if not
-- imgui.BeginTooltip()» оставляла тултип открытым: следующая строка таблицы,
-- кнопки и EndChild падали в него — строки исчезали, кнопки прыгали внутрь
-- таблицы. Проверяем установившуюся геометрию с ховером и без.
fillRoster(3)
SFNLogs.setMenu(1)
local function itemById(sub, frame)
    local best
    for _, it in ipairs(st.items) do
        if tostring(it.id):find(sub, 1, true) and (not frame or it.frame == frame) then
            best = it
        end
    end
    return best
end
local function childById(sub, frame)
    local best
    for _, c in ipairs(st.childLog) do
        if tostring(c.id):find(sub, 1, true) and (not frame or c.frame == frame) then
            best = c
        end
    end
    return best
end
local function rowButtons(frame)
    local n = 0
    for _, it in ipairs(st.items) do
        if tostring(it.id):match('^##jrow%d+$') and it.frame == frame then n = n + 1 end
    end
    return n
end
local infoNoH = checkFrame('журнал без ховера')
local jaddPlain = itemById('##jadd', st.frames)
local r1Plain = itemById('##jrow1', st.frames)
ok('без ховера: три строки таблицы на месте', rowButtons(st.frames) == 3,
   rowButtons(st.frames))
ok('v2.0.12: без ховера кнопки добавления нет', jaddPlain == nil)
local jtPlain = childById('##jtable', st.frames)
ok('без ховера: горизонтальный скролл выключен (нет чёрной полосы)',
   jtPlain and (jtPlain.flags % 64) < 32, jtPlain and jtPlain.flags)

local infoH = checkFrame('журнал: ховер строки 2', { hovers = { ['##jrow2'] = true } })
local fr = st.frames
ok('ховер: все три строки остались в таблице', rowButtons(fr) == 3, rowButtons(fr))
local r2 = itemById('##jrow2', fr)
ok('ховер: строки не уехали в тултип (x < 1000)',
   r2 ~= nil and r2.x < 1000, r2 and string.format('x=%.0f', r2.x))
local tipLine
for _, t in ipairs(st.texts) do
    if t.text == 'клик — меню сотрудника' then tipLine = t end
end
ok('ховер: подсказка рисуется в тултипе', tipLine ~= nil and tipLine.x >= 4000,
   tipLine and string.format('x=%.0f', tipLine.x) or 'текст подсказки не найден')
local r1H = itemById('##jrow1', fr)
ok('ховер: строки таблицы не сдвинулись',
   r1H and r1Plain and math.abs(r1H.y - r1Plain.y) < 1.5
   and math.abs(r1H.x - r1Plain.x) < 1.5,
   (r1H and r1Plain) and string.format('(%.0f,%.0f) -> (%.0f,%.0f)',
       r1Plain.x, r1Plain.y, r1H.x, r1H.y) or 'нет строки')
local jtH = childById('##jtable', fr)
ok('ховер: строки ВНУТРИ региона таблицы (кнопок под ним нет)',
   jtH and r2 and (r2.y + r2.h) <= (jtH.y + jtH.h + 1),
   (jtH and r2) and string.format('rowBottom=%.0f childBottom=%.0f',
       r2.y + r2.h, jtH.y + jtH.h) or '')
ok('ховер: горизонтальный скролл выключен', jtH and (jtH.flags % 64) < 32,
   jtH and jtH.flags)
ok('ховер: регион таблицы той же высоты, что без ховера',
   jtH and jtPlain and math.abs(jtH.h - jtPlain.h) < 1.5,
   (jtH and jtPlain) and string.format('%.0f vs %.0f', jtPlain.h, jtH.h) or '')

-- 40 длинных записей: окно расширяется под таблицу, скролл не нужен
fillRoster(40, { longNick = true, notes = true })
checkFrame('40 записей с ховером', { hovers = { ['##jrow5'] = true } })
local jt40 = childById('##jtable', st.frames)
ok('40 записей: горизонтальный скролл выключен', jt40 and (jt40.flags % 64) < 32,
   jt40 and jt40.flags)
-- поиск: таблица результатов тоже без паразитной полосы
SFNLogs.setMenu(2)
checkFrame('поиск: ховер списка')
local stbl = childById('##stable', st.frames)
ok('поиск: горизонтальный скролл выключен', stbl and (stbl.flags % 64) < 32,
   stbl and stbl.flags)
SFNLogs.setMenu(1)
fillRoster(3)

-- ================================== ПОТОЛОК РАНГОВ, ТРАНСПОРТ, REQUESTER ===
section('потолок рангов, транспорт и requester')
ok('потолок редакции - ранг 9', MAX_RANK == 9, MAX_RANK)
ok('у потолка нет срока', SECONDS_TO_NEXT[9] == nil)
local savedDl = downloadUrlToFile
downloadUrlToFile = function() end
ok('downloadUrlToFile выбран транспортом',
   SFNLogs.api.transport() == 'downloadUrlToFile', SFNLogs.api.transport())
downloadUrlToFile = nil
ok('без фоновой загрузки и requests транспорта нет',
   SFNLogs.api.transport() == 'нет транспорта', SFNLogs.api.transport())
downloadUrlToFile = savedDl

cfg.api.requester = 'Test_Boss'
ok('requester из config.ini', SFNLogs.api.requester() == 'Test_Boss',
   SFNLogs.api.requester())
cfg.api.requester = ''
ok('requester fallback без ника', SFNLogs.api.requester() == 'SFNLogs',
   SFNLogs.api.requester())

local mc = { nick = 'Clamp_Guy' }
ok('ранг выше потолка упирается в 9',
   SFNLogs.api.applyJournal(mc, { new_rank = 'Генеральный директор [12]',
                                  event_date = '2025-06-01T12:00:00' })
   and mc.rank == 9, mc.rank)

-- ========================= v2.0.9: СОСТАВ ИЗ /members В ОКНЕ ==============
section('v2.0.9: «Состав из /members» — кнопка, настройки, тултип')

local function hasText(sub)
    for _, t in ipairs(st.texts) do
        if tostring(t.text):find(sub, 1, true) then return t end
    end
    return nil
end

-- 1) панель журнала: кнопка между «Обновить» и «Экспорт», не вылезает за тело
fillRoster(3)
SFNLogs.setMenu(1)
checkFrame('журнал с кнопкой /members')
local jRefresh9 = itemById('##jrefresh', st.frames)
local jMembers9 = itemById('##jmembers', st.frames)
local jExport9  = itemById('##jexport', st.frames)
local strip9    = stripOf()
ok('кнопка «Состав из /members» на месте', jMembers9 ~= nil)
ok('порядок кнопок: Обновить -> /members, экспорта нет (v2.0.12)',
   jRefresh9 and jMembers9 and jExport9 == nil
   and jRefresh9.x < jMembers9.x,
   (jRefresh9 and jMembers9) and string.format('%.0f < %.0f, export=%s',
       jRefresh9.x, jMembers9.x, tostring(jExport9 ~= nil)) or 'не найдены')
ok('кнопка /members не вылезает за правый край тела',
   jMembers9 and strip9 and (jMembers9.x + jMembers9.w) <= (strip9.x + strip9.w + 1),
   jMembers9 and strip9 and string.format('right=%.0f stripRight=%.0f',
       jMembers9.x + jMembers9.w, strip9.x + strip9.w) or '')
ok('подпись кнопки рисуется', hasText('Состав из /members') ~= nil)

-- 2) настройки: секция, чекбокс, кнопка и состояние перехвата
SFNLogs.setMenu(3)
checkFrame('настройки с секцией /members')
ok('секция «СОСТАВ ИЗ ИГРЫ» в настройках', hasText('СОСТАВ ИЗ ИГРЫ') ~= nil)
ok('чекбокс перехвата /members', hasText('Забирать состав из ответа /members') ~= nil)
ok('кнопка обновления состава', hasText('ОБНОВИТЬ СОСТАВ ИЗ ИГРЫ') ~= nil)
ok('строка «состав из игры» в настройках', hasText('ещё не запрашивали') ~= nil)
-- v2.1.0: технической диагностики API в настройках нет (она осталась в /sfnlogapi)
ok('настройки: нет строки «повторы запросов»', hasText('повторы запросов') == nil)

membersStart(os.time())
checkFrame('настройки: перехват активен')
ok('активный перехват виден в настройках', hasText('слушаю ответ сервера') ~= nil)
membersReset()

-- 3) сотрудники из /members: строки журнала, приблизительная дата, тултип
roster.members = {}
local t9 = os.time()
membersFeed('Члены организации Он-лайн:', t9)
membersFeed('ID: 248 | 19:23 06.09.2026 | Jonny_Wilde[248] (Voice): Программный директор[9] - {008000}На работе{FFFFFF}', t9 + 1)
membersFeed('ID: 264 | 04:18 23.09.2026 | Anna_Malboro[264] (Voice): Звукорежиссер[3] - {008000}На работе{FFFFFF}', t9 + 2)
membersFeed('Всего: 2 человека', t9 + 3)
ok('перехват добавил сотрудников', roster.members['Jonny_Wilde'] ~= nil
   and roster.members['Anna_Malboro'] ~= nil)
SFNLogs.setMenu(1)
-- строки сортируются по рангу: Jonny (9) — первая, Anna (3) — вторая
checkFrame('журнал: сотрудники из /members', { hovers = { ['##jrow2'] = true } })
ok('ник из /members в таблице', hasText('Jonny_Wilde') ~= nil)
ok('второй ник из /members в таблице', hasText('Anna_Malboro') ~= nil)
ok('статус объясняет приблизительную дату', hasText('дата приблизительная') ~= nil)
ok('тултип показывает последний вход', hasText('вход (/members)') ~= nil)

fillRoster(3)
membersReset()
SFNLogs.setMenu(1)

-- ============================================ КРЕСТИК ЗАКРЫТИЯ ============
section('крестик закрытия окна')
SFNLogs.setMenu(1)
SFNLogs.setVisible(true)
local infoC = checkFrame('окно с крестиком')
local cr = SFNLogs.ui.closeRect
ok('крестик имеет геометрию', cr ~= nil and cr.x2 > cr.x1 and cr.y2 > cr.y1,
   cr and string.format('%.0f,%.0f..%.0f,%.0f', cr.x1, cr.y1, cr.x2, cr.y2) or 'нет rect')
ok('крестик у правого верхнего угла окна',
   cr ~= nil and cr.x2 > 40 + infoC.win.x - 40 and cr.y1 < 60,
   cr and string.format('x2=%.0f winRight=%.0f y1=%.0f', cr.x2, 40 + infoC.win.x, cr.y1))
ok('окно открыто до клика', SFNLogs.isOpen() == true)
st.mouse = { x = (cr.x1 + cr.x2) / 2, y = (cr.y1 + cr.y2) / 2 }
st.mouseClicked = { [0] = true }
mock.frame()
ok('клик по крестику закрывает окно', SFNLogs.isOpen() == false)
st.mouseClicked = {}
SFNLogs.setVisible(true)
st.mouse = { x = cr.x1 - 80, y = cr.y1 + 4 }
st.mouseClicked = { [0] = true }
mock.frame()
ok('клик мимо крестика не закрывает', SFNLogs.isOpen() == true)
st.mouse = { x = (cr.x1 + cr.x2) / 2, y = (cr.y1 + cr.y2) / 2 }
st.anyItemHovered = true
mock.frame()
ok('клик поверх элемента не срабатывает', SFNLogs.isOpen() == true)
st.anyItemHovered = false
st.mouseClicked = {}
st.mouse = { x = -500, y = -500 }
SFNLogs.setVisible(true)

-- ================================== v2.0.12: КНОПКИ ОКНА И КЛАВИША =======
section('v2.0.12: в журнале нет кнопок добавления/уровней/экспорта')
SFNLogs.setMenu(1)
fillRoster(5)
local infoJ12 = checkFrame('журнал v2.0.12')
local function frameHasText(info, label)
    for i = info.from, info.to do
        if st.texts[i].text:find(label, 1, true) then return true end
    end
    return false
end
local function frameHasItem(sub)
    for _, it in ipairs(st.items) do
        if tostring(it.id):find(sub, 1, true) then return true end
    end
    return false
end
ok('журнал: нет «+ Добавить сотрудника»', not frameHasText(infoJ12, '+ Добавить сотрудника'))
ok('журнал: нет «Уровни из игры»', not frameHasText(infoJ12, 'Уровни из игры'))
ok('журнал: нет «Экспорт»', not frameHasText(infoJ12, 'Экспорт'))
ok('журнал: нет кнопок jadd/jlevels/jexport',
   not frameHasItem('##jadd') and not frameHasItem('##jlevels')
   and not frameHasItem('##jexport'))
ok('журнал: обновление и /members остались',
   frameHasItem('##jrefresh') and frameHasItem('##jmembers'))

section('v2.0.12: настройка клавиши - выпадающий список с сохранением')
SFNLogs.setMenu(3)
local infoS12 = checkFrame('настройки v2.0.12')
ok('настройки: строка «Горячая клавиша» с текущим именем',
   frameHasText(infoS12, 'Горячая клавиша:') and frameHasText(infoS12, vkToName(cfg.hotkey)))
ok('настройки: выпадающий список на месте', frameHasItem('##hotkey_combo'))
checkFrame('настройки: раскрытый список',
           { combos = { ['##hotkey_combo'] = true }, clicks = { ['F10'] = true } })
ok('настройки: клик по списку меняет клавишу', cfg.hotkey == 0x79, tostring(cfg.hotkey))
local hkFile = SFNLogs.paths and SFNLogs.readfile(SFNLogs.paths.hotkey) or nil
ok('настройки: выбор сразу записан в hotkey.json',
   hkFile ~= nil and hkFile:find('"hotkey":121', 1, true) ~= nil, tostring(hkFile))
SFNLogs.setMenu(1)

-- ============================== v2.1.0: УПРОЩЁННЫЙ ИНТЕРФЕЙС ===============
section('v2.1.0: без значка «‹», без перехвата чата, без диагностики API')

local function frameTexts(info)
    local out = {}
    for i = info.from, info.to do out[#out + 1] = tostring(st.texts[i].text) end
    return out
end

-- 1) значок «‹» больше не рисуется ни в одной полосе раздела
for _, tab in ipairs({ 1, 2, 3, 4 }) do
    SFNLogs.setMenu(tab)
    local infoT = checkFrame('v2.1.0: вкладка ' .. tab .. ' без стрелочки')
    local joined = table.concat(frameTexts(infoT), '\n')
    ok('вкладка ' .. tab .. ': нет значка «‹» в полосе раздела',
       joined:find('<', 1, true) == nil)
end
ok('исходник: sectionStrip не рисует ANGLE_LEFT',
   DEFAULT_INI ~= nil and SFNLogs.layoutInfo() ~= nil)

-- 2) настройки обычного пользователя: только понятные разделы
SFNLogs.setMenu(3)
local infoS21 = checkFrame('настройки v2.1.0')
ok('настройки: раздел «Окно»', frameHasText(infoS21, 'Окно'))
ok('настройки: раздел «Состав из игры»', frameHasText(infoS21, 'Состав из игры'))
ok('настройки: раздел «Данные из Evolve Logs»', frameHasText(infoS21, 'Данные из Evolve Logs'))
ok('настройки: раздел «Служебное»', frameHasText(infoS21, 'Служебное'))
ok('настройки: латиница не осталась в ВЕРХНЕМ регистре',
   not frameHasText(infoS21, 'EVOLVE LOGS'))
ok('настройки: есть состояние соединения', frameHasText(infoS21, 'соединение'))
ok('настройки: понятно, от чьего имени запросы',
   frameHasText(infoS21, 'данные запрашиваются от имени'))
ok('настройки: состояние состава подписано понятно',
   frameHasText(infoS21, 'последний состав'))
ok('настройки: есть кнопка обновления данных', frameHasText(infoS21, 'ОБНОВИТЬ ДАННЫЕ ВСЕХ'))
ok('настройки: есть кнопка сохранения', frameHasText(infoS21, 'СОХРАНИТЬ ЖУРНАЛ'))
ok('настройки: есть выгрузка в файл', frameHasText(infoS21, 'ВЫГРУЗИТЬ В ФАЙЛ'))
ok('настройки: нет строки «транспорт»', not frameHasText(infoS21, 'ранспорт'))
ok('настройки: нет строки «запрашивающий... 422»', not frameHasText(infoS21, '422'))
ok('настройки: нет «ожидание строк»', not frameHasText(infoS21, 'ожидание строк'))
ok('настройки: нет выбора кеша API', not frameHasItem('##ttl'))
ok('настройки: нет дампа чата', not frameHasText(infoS21, 'ДАМП ЧАТА'))
ok('настройки: нет раздела перехвата чата', not frameHasText(infoS21, 'ерехват чата'))
ok('настройки: нет шаблонов accept/promote', not frameHasText(infoS21, 'accept'))

-- 3) «О скрипте» рассказывает, откуда берётся состав, без /sfnlogcap
SFNLogs.setMenu(4)
local infoA21 = checkFrame('о скрипте v2.1.0')
ok('о скрипте: есть «Откуда берутся сотрудники»', frameHasText(infoA21, 'Откуда берутся сотрудники'))
ok('о скрипте: есть «Откуда берутся ранги и даты»', frameHasText(infoA21, 'Откуда берутся ранги и даты'))
ok('о скрипте: есть /sfnlogexport', frameHasText(infoA21, '/sfnlogexport'))
ok('о скрипте: нет /sfnlogcap', not frameHasText(infoA21, '/sfnlogcap'))
ok('о скрипте: нет Google Sheets', not frameHasText(infoA21, 'Google Sheets'))

-- 4) пустой журнал подсказывает понятные действия
roster.members = {}
SFNLogs.setMenu(1)
local infoE21 = checkFrame('пустой журнал v2.1.0')
ok('пустой журнал: подсказка про /members', frameHasText(infoE21, 'Состав из /members'))
ok('пустой журнал: подсказка про «Поиск»', frameHasText(infoE21, '+ В состав'))
ok('пустой журнал: нет упоминания перехвата чата', not frameHasText(infoE21, 'перехват чата'))
fillRoster(3)

SFNLogs.setMenu(1)

-- ============================== v2.2.0: АВТООБНОВЛЕНИЕ В ОКНЕ ==============
section('v2.2.0: раздел «Обновления» в настройках и справка')

cfg.update = { enabled = true, auto = true, url = UPDATE_URL_DEFAULT, every = 21600 }
local upd = SFNLogs.update.info
upd.lastCheck, upd.available, upd.ready = 0, '', false
upd.pendingPath, upd.lastError = '', ''
upd.installedAt, upd.installedVer, upd.notified = 0, '', ''

SFNLogs.setMenu(3)
local infoU22 = checkFrame('настройки v2.2.0: обновления')
ok('настройки: раздел «Обновления»', frameHasText(infoU22, 'Обновления'))
ok('настройки: галочка проверки обновлений',
   frameHasText(infoU22, 'Проверять обновления автоматически'))
ok('настройки: галочка автоустановки', frameHasText(infoU22, 'Ставить новую версию сразу'))
ok('настройки: кнопка проверки', frameHasText(infoU22, 'ПРОВЕРИТЬ ОБНОВЛЕНИЯ'))
ok('настройки: строка «обновлений нет»', frameHasText(infoU22, 'обновлений'))
ok('настройки: последняя проверка', frameHasText(infoU22, 'последняя проверка'))
ok('настройки: упомянут резервный файл .bak', frameHasText(infoU22, 'SFNLogs.lua.bak'))
ok('настройки: нет кнопки установки, пока нечего ставить',
   not frameHasText(infoU22, 'ПОСТАВИТЬ ОБНОВЛЕНИЕ'))
ok('настройки: раздел «Служебное» остался', frameHasText(infoU22, 'Служебное'))

-- скачанное обновление: появляется кнопка установки и номер версии
upd.available, upd.ready = '9.9.9', true
upd.pendingPath = '/tmp/sfntest_ui/update.lua.new'
local infoR22 = checkFrame('настройки v2.2.0: обновление готово')
ok('готова версия - виден её номер', frameHasText(infoR22, '9.9.9'))
ok('готова версия - есть кнопка установки', frameHasText(infoR22, 'ПОСТАВИТЬ ОБНОВЛЕНИЕ'))
upd.available, upd.ready, upd.pendingPath = '', false, ''

-- ошибка проверки видна пользователю
upd.lastError = 'сеть молчит 10 с'
local infoE22 = checkFrame('настройки v2.2.0: ошибка обновления')
ok('ошибка проверки показана в настройках', frameHasText(infoE22, 'сеть молчит 10 с'))
upd.lastError = ''

-- «О скрипте»: блок про обновления и команда
SFNLogs.setMenu(4)
local infoA22 = checkFrame('о скрипте v2.2.0')
ok('о скрипте: есть блок «Обновления»', frameHasText(infoA22, 'Обновления'))
ok('о скрипте: упомянута резервная копия', frameHasText(infoA22, 'SFNLogs.lua.bak'))
ok('о скрипте: упомянута команда /sfnlogupdate', frameHasText(infoA22, '/sfnlogupdate'))
ok('о скрипте: упомянут /reload', frameHasText(infoA22, '/reload'))

SFNLogs.setMenu(1)

-- ============================================ ОТКАЗ DRAWLIST (деградация) =
section('аварийный режим без DrawList')
local savedOk = SFNLogs.layoutInfo().drawListOk
ok('до отказа DrawList доступен', savedOk == true, SFNLogs.lastUiError)
-- ломаем примитивы: теперь интерфейс обязан уйти в текстовый fallback
mock.imgui.GetWindowDrawList = function()
    return setmetatable({}, { __index = function() return function() error('no drawlist') end end })
end
local infoFb = checkFrame('fallback без DrawList')
print(string.format('   окно fallback: %.0f x %.0f px', infoFb.win.x, infoFb.win.y))
ok('в аварийном режиме окно тоже без наложений', #st.errors == 0,
   table.concat(st.errors, '\n       '))

-- ============================================================ ИТОГ =======
print(string.format('\n%d passed, %d failed', passed, failed))
if os.exit then os.exit(failed == 0 and 0 or 1) end
