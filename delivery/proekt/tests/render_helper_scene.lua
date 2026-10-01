-- Подготовка сцены SFN_Helper и выгрузка примитивов DrawList для SVG-превью.
-- Возвращает таблицу: win, rects, texts, errors.
--
-- В отличие от render_scene.lua (SFN Logs) сцена задаёт и состояние модулей:
-- вкладки «Фото», «Эфир» и «Соцопрос» рисуют разные наборы полос и кнопок в
-- зависимости от того, идёт ли эфир/цикл опроса и есть ли доступ, поэтому
-- превью обязано показывать оба состояния (параметр state).
return function(tabIndex, nrows, dpi, state)
  local mock = require 'tests.mock_imgui'
  -- Часы сцены заморожены: превью перегенерируются в CI на каждый прогон, и
  -- без фиксированного времени файлы отличались бы побайтово каждый раз
  -- (даты в журнале, «осталось дней», штамп времени в журнале модулей).
  local realTime, realDate = os.time, os.date
  local SCENE_NOW = 1790000000
  os.time = function() return SCENE_NOW end
  os.date = function(fmt, t) return realDate(fmt, t or SCENE_NOW) end
  mock.runInit()
  loadConfig(); loadRoster(); loadUpdateState()
  SFNLogs.registerCommands()      -- main() в превью не крутится
  SFNLogs.setVisible(true)
  roster.members = {}

  mock.st.dpi = dpi or 1.0
  mock.st.fontH = math.floor(16 * (dpi or 1.0))
  mock.st.display = { x = 1920, y = 2400 }

  -- ------------------------------------------------------------- журнал --
  local names = {
    'Jonny_Wilde', 'Aru_Traxer', 'Linnea_Korhonen', 'Garik_Grifon',
    'Vallo_Caballero', 'Bad_Dog', 'Akio_Omano', 'Gabriela_Bradberry',
    'Alex_Wilde', 'Anna_Malboro', 'Sonya_Malboro', 'Kate_Morgan',
    'Dmitry_Orlov', 'Nina_Sokolova',
  }
  for i = 1, (nrows or 0) do
    local nick = names[i] or ('Member_' .. i)
    local rank = math.min(9, ((i * 3) % 9) + 1)
    local m = addMember(nick, names[(i % 6) + 1] or 'Boss_Name',
                        os.time() - i * 43200 - 3600, rank, (i * 3) % 14 + 1)
    if m and i % 4 == 0 then m.note = 'ведёт утренний эфир' end
  end
  local k = 0
  for _, m in pairs(roster.members) do
    k = k + 1
    if k % 3 == 0 then m.online = true end
  end

  -- --------------------------------------------------------------- фото --
  photoReset()
  photoState.players['Jonny_Wilde'] = { date = photoToday() }
  photoState.players['Anna_Malboro'] = { date = photoToday() }
  photoState.players['Linnea_Korhonen'] = { date = photoToday() }
  photoState.places['Мост|Сан-Фиерро'] = { date = photoToday() }
  photoState.places['Пирс|Лос-Сантос'] = { date = photoToday() }

  -- --------------------------------------------------------------- эфир --
  efirAccessGranted = (state ~= 'locked')
  efirAccessChecked = true
  efirRunning = (state == 'quiz')
  efirMode, efirType = 'math', 'Математика'
  efirStartedAt = os.clock() - 372          -- 6 минут 12 секунд эфира
  efirScreenshots = 2
  efirLastShotAt = os.clock()
  efirShotNotified = true
  efirMathQ, efirMathA, efirMathSuffix = '7 + 5', 12, ' = ?'
  efirScores = {
    Jonny_Wilde = { id = 248, score = 7 },
    Anna_Malboro = { id = 179, score = 7 },
    Linnea_Korhonen = { id = 385, score = 4 },
    Alex_Wilde = { id = 917, score = 2 },
    Garik_Grifon = { id = 376, score = 1 },
  }
  efirGenderPending = nil

  -- ---------------------------------------------------------- соцопрос --
  social.active = (state == 'survey' or state == 'flyer')
  social.stage = (state == 'survey') and 1 or ((state == 'flyer') and 3.5 or 0)
  social.targetId, social.targetNick = 179, 'Anna_Malboro'
  social.surveys = {
    Jonny_Wilde = { date = '2026-09-28' },
    Alex_Wilde = { date = '2026-09-27' },
    Bad_Dog = { date = '2026-09-26' },
  }
  social.flyers = {
    Jonny_Wilde = { date = '2026-09-28' },
    Alex_Wilde = { date = '2026-09-27' },
  }
  social.log = {
    '[20:14:07] скрин №1 сделан - этап 2 (листовка)',
    '[20:13:52] опрос сдан: Anna_Malboro (4/100)',
    '[20:13:31] согласие от Anna_Malboro',
    '[20:13:28] старт: цель Anna_Malboro (1.2 м)',
  }
  socialQuestion = 'Как вы относитесь к ночным гонкам в Сан-Фиерро?'
  socialFlyerText = SOCIAL_DEFAULT_FLYER_ME
  socialSelectedId = nil
  socialNeedGender = false
  if socialQuestionBuf and SFNLogs.writeBuf then
    -- поля ввода модуля: в «Новый вопрос» дописан текст, который ещё не
    -- применён (вкладка обязана показывать метку «не применено»)
    SFNLogs.writeBuf(socialQuestionBuf, 160, 'и как часто вы там бываете?')
    SFNLogs.writeBuf(socialFlyerBuf, 160, SOCIAL_DEFAULT_FLYER_ME)
  end
  socialSetPlayersForTests({
    { id = 179, nick = 'Anna_Malboro', dist = 1.2 },
    { id = 385, nick = 'Linnea_Korhonen', dist = 2.4 },
    { id = 248, nick = 'Jonny_Wilde', dist = 2.9 },
    { id = 376, nick = 'Garik_Grifon', dist = 8.4 },
  })
  GENDERS = { Anna_Malboro = 'f', Jonny_Wilde = 'm' }
  GENDERS_LOADED, GENDERS_MIGRATED = true, true

  SFNLogs.setMenu(tabIndex)
  mock.reset()

  -- рендерим до устойчивого размера окна: часть геометрии (высота полосы
  -- заголовка, WindowPadding, высота хрома) узнаётся только из прошлого кадра
  local info, prevW, prevH, stable = nil, 0, 0, 0
  for _ = 1, 14 do
    info = mock.frame({})
    if info.win.x == prevW and info.win.y == prevH then
      stable = stable + 1
      if stable >= 2 then break end
    else
      stable = 0
    end
    prevW, prevH = info.win.x, info.win.y
    mock.st.errors = {}
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

  os.time, os.date = realTime, realDate
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
    if tx.frame == mock.st.frames and tx.path and tx.path:find('/window:') then
      out.texts[#out.texts + 1] = {
        x = tx.x, y = tx.y, w = tx.w, text = tx.text, col = c2t(tx.col),
      }
    end
  end
  for _, e in ipairs(mock.st.errors) do out.errors[#out.errors + 1] = e end
  return out
end
