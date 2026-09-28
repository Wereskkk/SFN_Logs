-- Подготовка сцены и выгрузка примитивов DrawList для SVG-превью.
-- Возвращает таблицу: win, rects, texts, errors.
return function(tabName, nrows, dpi, longNicks, dismissed, hoverRow, menuRow, membersBlock)
  local mock = require 'tests.mock_imgui'
  mock.runInit()
  loadConfig(); loadRoster(); SFNLogs.setVisible(true)
  -- сцены рендера идут одна за другой и делят /tmp/sfntest_ui: журнал
  -- очищаем в памяти, иначе записи накапливаются и размер окна «плывёт»
  roster.members = {}

  mock.st.dpi = dpi
  mock.st.fontH = math.floor(16 * dpi)
  mock.st.display = { x = 1920, y = 2400 }   -- запас по высоте, как в тесте

  roster.members = {}
  if membersBlock then
    -- v2.0.11: сцена «состав из /members» — ЖИВОЙ блок Evolve RP из
    -- tests/fixtures/chat_dump_2026-09-28.txt: ник БЕЗ [ID], метка (Voice).
    local lines = {
      ' Члены организации Он-лайн:',
      ' ',
      ' ID: 248 | 19:23 06.09.2026 | Jonny_Wilde (Voice): Программный директор[9] - {008000}На работе{FFFFFF}',
      ' ID: 38 | 21:47 22.09.2026 | Aru_Traxer (Voice): Гл.Редактор[7] - {008000}На работе{FFFFFF}',
      ' ID: 385 | 00:52 14.09.2026 | Linnea_Korhonen (Voice): Редактор[6] - {008000}На работе{FFFFFF}',
      ' ID: 376 | 16:57 09.05.2026 | Garik_Grifon (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 360+ секунд',
      ' ID: 663 | 23:31 18.06.2026 | Vallo_Caballero (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
      ' ID: 478 | 17:02 27.08.2026 | Bad_Dog (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
      ' ID: 10 | 22:38 03.09.2026 | Akio_Omano (Voice): Редактор[6] - {ae433d}Выходной{FFFFFF}',
      ' ID: 68 | 23:32 03.09.2026 | Gabriela_Bradberry : Ведущий[5] - {ae433d}Выходной{FFFFFF} | {FFFFFF}[AFK]: 360+ секунд',
      ' ID: 917 | 18:58 14.04.2026 | Alex_Wilde (Voice): Ведущий[5] - {ae433d}Выходной{FFFFFF}',
      ' ID: 179 | 04:18 23.09.2026 | Anna_Malboro (Voice): Репортер[4] - {008000}На работе{FFFFFF}',
      ' ID: 165 | 04:18 23.09.2026 | Sonya_Malboro (Voice): Репортер[4] - {008000}На работе{FFFFFF}',
      ' ',
      ' Всего: 11 человек',
    }
    local t = os.time()
    for i, l in ipairs(lines) do membersFeed(l, t + i) end
  end
  local names = {
    'Ivan_Petrov', 'Fox_River', 'Kate_Morgan', 'Alexey_Volkov', 'Nina_Sokolova',
    'Dmitry_Orlov', 'Sasha_Belov', 'Victor_Tsoi', 'Marina_Lvova', 'Oleg_Drozdov',
    'Kirill_Smirnov', 'Alina_Rotaru', 'Pavel_Zimin', 'Yulia_Nesterenko',
  }
  for i = 1, nrows do
    local nick = longNicks and ('Очень_Длинный_Ник_' .. i) or (names[i] or ('Member_' .. i))
    local rank = ((i * 3) % 9) + 1
    local m = addMember(nick, names[(i % 6) + 1] or 'Boss_Name',
                        os.time() - i * 43200 - 3600, rank, (i * 3) % 14 + 1)
    if m then
      if i % 4 == 0 then m.note = 'ведёт утренний эфир' end
      if dismissed and i % 7 == 0 then dismissMember(nick, 'нарушение регламента редакции') end
    end
  end
  local k = 0
  for _, m in pairs(roster.members) do
    k = k + 1
    if k % 3 == 0 then m.online = true end
  end

  SFNLogs.setMenu(tabName)
  if tabName == 2 then
    -- canned API response for the search-section preview
    SFNLogs.ui.apiResults = {
      { nick = 'Mary_Norton',   by = 'Soichiro_Honda', prev = 'Ефрейтор [2]',    new = 'Uninvite',          date = '29.11.2025 23:22', next = 'Неизвестно',  reason = 'неактив' },
      { nick = 'Alexey_Volkov', by = 'Kate_Morgan',    prev = 'Репортер [4]',    new = 'Ведущий [5]',       date = '18.09.2026 20:14', next = '23.09.2031',    reason = 'за серию репортажей' },
      { nick = 'Nina_Sokolova', by = 'Dmitry_Orlov',   prev = 'Стажер [1]',      new = 'Звукооператор [2]', date = '02.09.2026 12:05', next = '04.09.2026',    reason = '' },
    }
  end
  mock.reset()
  -- v2.0.8: сцена с открытым меню строки — попап ставим в точку «клика» внутри
  -- окна, чтобы в SVG он лежал поверх таблицы, как в игре
  if menuRow and menuRow > 0 then
    local mnick = longNicks and ('Очень_Длинный_Ник_' .. menuRow)
                 or (names[menuRow] or ('Member_' .. menuRow))
    SFNLogs.openRowMenu(mnick)
    mock.st.popX, mock.st.popY = 300, 170
  end
  -- Рендерим до устойчивого размера окна: часть几何 (высота полосы заголовка,
  -- WindowPadding, фактическая высота хрома) узнаётся только из предыдущего
  -- кадра, поэтому первые кадры строятся по оценке. В игре окно открыто сотни
  -- кадров — нас интересует именно установившийся вид.
  local info, prevW, prevH, stable = nil, 0, 0, 0
  local fopts = (hoverRow and hoverRow > 0)
      and { hovers = { ['##jrow' .. tostring(hoverRow)] = true } } or {}
  for _ = 1, 12 do
    info = mock.frame(fopts)
    if info.win.x == prevW and info.win.y == prevH then
      stable = stable + 1
      if stable >= 2 then break end
    else
      stable = 0
    end
    prevW, prevH = info.win.x, info.win.y
    mock.st.errors = {}        -- ошибки кадров схода не показываем
  end

  local function c2t(c)
    if type(c) ~= 'number' then return nil end
    return {
      r = c % 256,
      g = math.floor(c / 256) % 256,
      b = math.floor(c / 65536) % 256,
      a = (math.floor(c / 16777216) % 256) / 255,
    }
  end

  local out = { win = { w = info.win.x, h = info.win.y }, rects = {}, texts = {}, errors = {} }
  for _, rc in ipairs(mock.st.rects) do
    if rc.frame == mock.st.frames then
      out.rects[#out.rects + 1] = {
        kind = rc.kind, x = rc.x, y = rc.y, w = rc.w, h = rc.h,
        col = c2t(rc.col), col2 = c2t(rc.col2), r = rc.rounding or 0,
        thick = rc.thick or 1, cx = rc.cx, cy = rc.cy, rr = rc.r,
        ax = rc.ax, ay = rc.ay, bx = rc.bx, by = rc.by,
      }
    end
  end
  for _, tx in ipairs(mock.st.texts) do
    -- берём только главное окно: попапы и тултипы живут в своих координатах
    if tx.frame == mock.st.frames and tx.path and tx.path:find('/window:') then
      out.texts[#out.texts + 1] = {
        x = tx.x, y = tx.y, w = tx.w, text = tx.text, col = c2t(tx.col),
      }
    end
  end
  for _, e in ipairs(mock.st.errors) do out.errors[#out.errors + 1] = e end
  return out
end
