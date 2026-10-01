-- Регрессии сетевого слоя SFN Logs v2.0.6:
--   * промежуточные статусы downloadUrlToFile (1..5) не считаются ошибкой
--     (раньше статус 2 = STATUS_CONNECTING ломал каждый запрос: fail:2);
--   * финал - это 6 / STATUSEX_ENDDOWNLOAD из «moonloader».download_status;
--   * обрыв = тишина колбэка, порог ступенчатый: 10 с без единого статуса
--     (холодный старт WinINET/DNS/TLS), 6 с со статусами без данных,
--     4 с после первых данных (раньше всегда 4 с - ложные switch на старте);
--   * после двух неудач транспорт сам переключается на запасной и обратно,
--     а в простое тихая проба возвращает фоновый транспорт;
--   * [api] transport в config.ini закрепляет транспорт и отключает авто;
--   * бэкофф воркера растёт при сериях неудач и сбрасывается при успехе;
--   * каждому запросу - свой временный файл (брошенная загрузка не портит чужой ответ).
-- Регрессии сетевого слоя SFN Logs v2.0.13 (фризы игры 1-6 с):
--   * реальный финальный код downloadUrlToFile - 58 (STATUSEX_ENDDOWNLOAD из
--     moonloader.lua): зашит явно и работает, даже когда
--     require('moonloader').download_status недоступен;
--   * гонка «финальный статус раньше файла»: тело дожидается до 2,5 с,
--     «пустой ответ» больше не рвёт failStreak;
--   * незнакомый словарь статусов: запрос завершается по телу ответа на диске;
--   * авто-переключение на блокирующий requests - только крайняя мера
--     (8 неудач фона подряд), обратно - по-прежнему после 2 неудач;
--   * проба фонового транспорта больше не ждёт пустых очередей;
--   * на блокирующем requests воркер делает паузу не меньше 1 с.
-- Запуск:  python3 tests/run_api.py   (lupa, Lua 5.4)

local passed, failed = 0, 0
local function ok(name, cond, extra)
    if cond then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-52s %s', name, tostring(extra or '')))
    end
end
local function section(t) print('\n== ' .. t) end

local JOURNAL_JSON = '{"data":{"new_rank":"Репортер [4]",' ..
                     '"event_date":"10.06.26 14:32","initiator_nickname":"Boss_News"}}'

-- виртуальные часы: wait() двигает время и будит отложенные события загрузок
local vt = 0
local schedule = {}
local function later(delay, fn) schedule[#schedule + 1] = { at = vt + delay, fn = fn } end
wait = function(ms)
    vt = vt + (ms or 0) / 1000
    local i = 1
    while i <= #schedule do
        if schedule[i].at <= vt then
            local fn = schedule[i].fn
            table.remove(schedule, i)
            fn()
        else i = i + 1 end
    end
end

-- --------------------------------------------------- сценарии загрузок ----
local function putFile(file, text)
    local f = io.open(file, 'wb')
    if f then f:write(text); f:close() end
end

-- Здоровая загрузка: промежуточные 1..5 асинхронно, затем финальный код.
local function makeHealthy(finalCode)
    return function(url, file, cb)
        for n = 1, 5 do
            later(0.05 * n, function() cb(0, n) end)
        end
        later(0.4, function()
            putFile(file, JOURNAL_JSON)
            cb(0, finalCode)
        end)
        return true
    end
end
local dlHealthy = makeHealthy(6)

-- Обрыв соединения: единственный статус 2 (CONNECTING) и тишина навсегда.
local function dlStall(url, file, cb)
    later(0.05, function() cb(0, 2) end)
    return true
end

local dlFiles = {}
local function dlSpyFiles(url, file, cb)
    dlFiles[#dlFiles + 1] = file
    return dlHealthy(url, file, cb)
end

-- ----------------------------------------------- запасной транспорт -------
local reqCalls = 0
local reqMode = 'ok'          -- 'ok' | 'fail'
package.preload['requests'] = function()
    return { get = function(url, opts)
        reqCalls = reqCalls + 1
        if reqMode == 'fail' then return nil end
        return { status_code = 200, text = JOURNAL_JSON }
    end }
end

-- таблица статусов как в реальной библиотеке moonloader.lua
package.preload['moonloader'] = function()
    return { download_status = {
        STATUS_FINDINGRESOURCE = 1, STATUS_CONNECTING = 2,
        STATUS_REDIRECTING = 3, STATUS_BEGINDOWNLOADDATA = 4,
        STATUS_DOWNLOADINGDATA = 5, STATUS_ENDDOWNLOADDATA = 6,
        STATUSEX_STARTBINDING = 57, STATUSEX_LOWRESOURCE = 59,
        STATUSEX_DATAAVAILABLE = 60,
        -- намеренно условный код (в реальной библиотеке 58): проверяет, что
        -- значения из download_status дополняют зашитые; настоящий
        -- STATUSEX_ENDDOWNLOAD = 58 обязан работать и без этой таблицы.
        STATUSEX_ENDDOWNLOAD = 66,
    } }
end

dofile('SFNLogs.lua')

local api = SFNLogs.api

section('здоровая загрузка: промежуточные статусы не ошибка')
downloadUrlToFile = dlHealthy
ok('эффективный транспорт - downloadUrlToFile',
   api.status().transport == 'downloadUrlToFile', api.status().transport)
local data, err = api.get('/v1/journal', { player = 'Nick_One' })
ok('последовательность 1..5,6 даёт данные', data ~= nil, err)
ok('тело распознано', data and data.data and data.data.new_rank == 'Репортер [4]',
   data and data.data and data.data.new_rank)
ok('серия неудач сброшена', api.state.failStreak == 0, api.state.failStreak)

section('финальный статус STATUSEX_ENDDOWNLOAD понимается')
-- 66 в моке - условный «сборочный» код: проверяет путь дополнения DL_DONE
-- из require('moonloader').download_status. Реальный STATUSEX_ENDDOWNLOAD
-- равен 58 и зашит в скрипте явно (см. секцию ниже).
downloadUrlToFile = makeHealthy(66)
local dEx, eEx = api.get('/v1/journal', { player = 'Nick_Ex' })
ok('код 66 из download_status завершает запрос', dEx ~= nil, eEx)
ok('lastCode зафиксирован (66)', api.status().lastCode == 66, api.status().lastCode)
downloadUrlToFile = dlHealthy

section('v2.0.13: статус 58 - реальный STATUSEX_ENDDOWNLOAD, работает без библиотеки')
-- Сборка из баг-репорта: require('moonloader') не дал download_status,
-- финальный код 58 не распознавался, запрос висел до порога тишины, а две
-- неудачи подряд уводили транспорт на блокирующий requests (фризы 1-6 с).
downloadUrlToFile = function(url, file, cb)
    later(0.05, function() cb(0, 1) end)
    later(0.10, function() cb(0, 2) end)
    later(0.15, function() cb(0, 4) end)
    later(0.30, function() putFile(file, JOURNAL_JSON); cb(0, 58) end)
    return true
end
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
local vt58 = vt
local d58, e58 = api.get('/v1/journal', { player = 'Nick_58' })
ok('58 завершает запрос', d58 ~= nil, e58)
ok('завершилось сразу, без ожидания тишины (<2 с)', vt - vt58 < 2, vt - vt58)
ok('неудача не засчитана', api.state.failStreak == 0, api.state.failStreak)
ok('lastCode зафиксирован (58)', api.status().lastCode == 58, api.status().lastCode)

section('v2.0.13: финальный статус раньше файла - дожидалка тела, а не «пустой ответ»')
-- Гонка из баг-репорта: в момент статуса 6/58 файл ещё не дочитан. Старый код
-- сразу возвращал «пустой ответ» и наращивал failStreak - две такие гонки
-- уводили сессию на блокирующий requests.
downloadUrlToFile = function(url, file, cb)
    later(0.05, function() cb(0, 1) end)
    later(0.10, function() cb(0, 4) end)
    later(0.20, function() cb(0, 5) end)
    later(0.30, function() cb(0, 6) end)   -- финальный статус, файла ещё нет
    later(0.60, function() putFile(file, JOURNAL_JSON) end)
    return true
end
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
local vtR = vt
local dR, eR = api.get('/v1/journal', { player = 'Nick_Race' })
ok('запрос завершился данными несмотря на гонку', dR ~= nil, eR)
ok('«пустой ответ» не засчитан', api.state.failStreak == 0, api.state.failStreak)
ok('тело дождались быстро (<2 с)', vt - vtR < 2, vt - vtR)

section('v2.0.13: незнакомый словарь статусов - завершение по телу ответа')
-- Коды статусов отличаются от сборки к сборке; JSON Evolve Logs узнаваем
-- всегда: как только полное тело легло на диск, запрос завершается.
downloadUrlToFile = function(url, file, cb)
    later(0.05, function() cb(0, 700) end)
    later(0.10, function() cb(0, 701) end)
    later(0.20, function() putFile(file, JOURNAL_JSON); cb(0, 702) end)
    return true
end
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
local vtU = vt
local dU, eU = api.get('/v1/journal', { player = 'Nick_Unknown_Codes' })
ok('тело распознано несмотря на неизвестные статусы', dU ~= nil, eU)
ok('завершилось без 6 с тишины (<2 с)', vt - vtU < 2, vt - vtU)
ok('транспорт здоров', api.state.failStreak == 0, api.state.failStreak)
local lc = api.status().lastCodes or {}
ok('история статусов сохранена (700,701,702)',
   #lc == 3 and lc[1] == 700 and lc[3] == 702, table.concat(lc, ','))
downloadUrlToFile = dlHealthy

section('холодный старт: первый статус через 6 с - это не обрыв')
-- WinINET/DNS/TLS на старте игры греются медленно: раньше 4-секундное окно
-- принимало такой запрос за обрыв и уводило транспорт на блокирующий requests.
local function dlCold(url, file, cb)
    later(6,   function() cb(0, 1) end)
    later(6.5, function() cb(0, 2) end)
    later(7,   function() putFile(file, JOURNAL_JSON); cb(0, 6) end)
    return true
end
downloadUrlToFile = dlCold
local vtC = vt
local dc, ec = api.get('/v1/journal', { player = 'Nick_Cold' })
ok('долгий старт дожидается данных', dc ~= nil, ec)
ok('успех внутри 10-секундного порога (~7 с)', vt - vtC >= 6.5 and vt - vtC < 9, vt - vtC)
ok('неудача не засчитана', api.state.failStreak == 0, api.state.failStreak)

section('полная тишина: обрыв на пороге 10 с, а не 4 с')
local function dlDead(url, file, cb) return true end   -- колбэк не приходит вовсе
downloadUrlToFile = dlDead
api.state.pref, api.state.prefFails = 'downloadUrlToFile', 0
local vtD = vt
local dd, ed = api.get('/v1/journal', { player = 'Nick_Dead' })
ok('тишина без статусов возвращает nil', dd == nil)
ok('порог полной тишины ~10 с', vt - vtD >= 10 and vt - vtD < 12, vt - vtD)
ok('текст ошибки про тишину и статус nil',
   type(ed) == 'string' and ed:find('статуса nil') ~= nil, ed)
ok('одна неудача транспорт не переключает',
   api.state.pref == 'downloadUrlToFile', api.state.pref)
ok('diag зафиксировал: 0 колбэков, порог 100',
   api.state.diag and api.state.diag.cb == 0 and api.state.diag.limit == 100,
   api.state.diag and api.state.diag.limit)

section('обрыв: тишина после статуса 2 - порог 6 с')
downloadUrlToFile = dlStall
api.state.prefFails = 0
local vtBefore = vt
local d2, e2 = api.get('/v1/journal', { player = 'Nick_Two' })
ok('обрыв возвращает nil', d2 == nil)
ok('текст ошибки про тишину/статус', type(e2) == 'string' and e2:find('статуса 2') ~= nil, e2)
ok('счётчик неудач вырос', api.state.failStreak >= 1, api.state.failStreak)
ok('обрыв замечен за ~6 с (порог со статусами без данных)',
   vt - vtBefore >= 6 and vt - vtBefore < 8, vt - vtBefore)

section('v2.0.13: транспорт не прыгает на блокирующий requests после 2 неудач')
-- Баг-репорт «фризы 1-6 с»: двух неудач хватало, чтобы скрипт ушёл на
-- блокирующий requests и оставался на нём всю сессию (проба возврата ждала
-- пустых очередей, а они из-за TTL почти никогда не пустуют). Теперь
-- requests - крайняя мера после 8 неудач фона подряд.
reqMode = 'ok'
downloadUrlToFile = dlStall
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
local swBefore = api.state.switched
local _, e3 = api.get('/v1/journal', { player = 'Nick_F1' })      -- неудача 1
ok('первая ошибка с текстом', type(e3) == 'string' and e3 ~= '', e3)
api.get('/v1/journal', { player = 'Nick_F2' })                     -- неудача 2
ok('после 2-й неудачи всё ещё фоновый транспорт',
   api.state.pref == 'downloadUrlToFile', api.state.pref)
ok('переключения не было', api.state.switched == swBefore, api.state.switched)
for k = 3, 7 do api.get('/v1/journal', { player = 'Nick_F' .. k }) end
ok('после 7-й неудачи всё ещё фоновый транспорт',
   api.state.pref == 'downloadUrlToFile', api.state.pref)
api.get('/v1/journal', { player = 'Nick_F8' })                     -- неудача 8
ok('8-я неудача - крайняя мера, переход на requests',
   api.state.pref == 'requests', api.state.pref)
ok('переключение учтено', api.state.switched == swBefore + 1, api.state.switched)
local d4, e4 = api.get('/v1/journal', { player = 'Nick_Four' })    -- уже через requests
ok('запросы пошли через requests', reqCalls >= 1, reqCalls)
ok('requests принёс данные', d4 ~= nil, e4)
ok('успех сбросил серию неудач', api.state.failStreak == 0, api.state.failStreak)
ok('транспорт в статусе - requests', api.status().transport == 'requests',
   api.status().transport)
downloadUrlToFile = dlHealthy
section('возврат на фоновый транспорт, когда он ожил')
downloadUrlToFile = dlHealthy
reqMode = 'fail'
local _, e5 = api.get('/v1/journal', { player = 'Nick_Five' })     -- requests падает 1
local _, e6 = api.get('/v1/journal', { player = 'Nick_Six' })      -- 2 -> возврат на dUTF
ok('после двух падений requests pref снова downloadUrlToFile',
   api.state.pref == 'downloadUrlToFile', api.state.pref)
ok('ошибки requests не потеряны', type(e5) == 'string' and type(e6) == 'string')
local d7, e7 = api.get('/v1/journal', { player = 'Nick_Seven' })   -- dUTF ожил
ok('фоновый транспорт снова отдаёт данные', d7 ~= nil, e7)
ok('счётчик переключений рос', api.state.switched >= 2, api.state.switched)

section('транспорт закреплён в config.ini ([api] transport)')
local swBefore = api.state.switched
cfg.api.transport = 'requests'
ok('закреплено requests - эффективный транспорт requests',
   api.status().transport == 'requests', api.status().transport)
api.state.pref = 'downloadUrlToFile'
ok('сбитый pref не перебивает закрепление',
   api.status().transport == 'requests', api.status().transport)
api.state.pref = 'requests'
reqMode = 'ok'
local rcBefore = reqCalls
local dq, eq = api.get('/v1/journal', { player = 'Nick_Force' })
ok('запрос прошёл через requests', dq ~= nil and reqCalls == rcBefore + 1, eq)
reqMode = 'fail'
api.state.prefFails = 0
api.get('/v1/journal', { player = 'Nick_Force2' })
api.get('/v1/journal', { player = 'Nick_Force3' })
ok('при закреплении авто-переключение не срабатывает',
   api.state.switched == swBefore, api.state.switched)
ok('транспорт остался requests', api.status().transport == 'requests',
   api.status().transport)
cfg.api.transport = 'download'
ok('закреплено download - эффективный downloadUrlToFile',
   api.status().transport == 'downloadUrlToFile', api.status().transport)
rcBefore = reqCalls
local dh, eh = api.get('/v1/journal', { player = 'Nick_Force4' })
ok('requests при закреплении не дёргается', reqCalls == rcBefore, reqCalls)
ok('закреплённый download отдаёт данные', dh ~= nil, eh)
cfg.api.transport = 'auto'
api.state.pref, api.state.prefFails = 'downloadUrlToFile', 0
reqMode = 'ok'

section('тихая проба возвращает фоновый транспорт в простое')
downloadUrlToFile = dlHealthy
api.state.pref, api.state.prefFails = 'requests', 0
local swB = api.state.switched
api.probe()
ok('проба вернула downloadUrlToFile', api.state.pref == 'downloadUrlToFile',
   api.state.pref)
ok('проба не считалась авто-переключением', api.state.switched == swB,
   api.state.switched)
ok('тихий флаг сброшен', api.state.quiet == false, api.state.quiet)
downloadUrlToFile = function() return true end      -- снова полная тишина
api.state.pref, api.state.prefFails = 'requests', 0
local vtP = vt
api.probe()
ok('тихая неудача пробы вернула requests', api.state.pref == 'requests',
   api.state.pref)
ok('проба ждала по порогу полной тишины ~10 с', vt - vtP >= 10 and vt - vtP < 12,
   vt - vtP)
ok('счётчик переключений не рос (проба тихая)', api.state.switched == swB,
   api.state.switched)
downloadUrlToFile = dlHealthy
api.state.pref, api.state.prefFails = 'downloadUrlToFile', 0

section('бэкофф воркера')
api.state.failStreak = 0
ok('здоровая пауза 260 мс', api.pauseMs() == 260, api.pauseMs())
api.state.failStreak = 2
ok('2 неудачи подряд - 1000 мс', api.pauseMs() == 1000, api.pauseMs())
api.state.failStreak = 4
ok('4 неудачи подряд - 4000 мс', api.pauseMs() == 4000, api.pauseMs())
api.state.failStreak = 20
ok('пауза ограничена 30 с', api.pauseMs() == 30000, api.pauseMs())
api.state.failStreak = 0
api.state.pref = 'requests'
ok('на блокирующем requests (авто) пауза не меньше 1 с',
   api.pauseMs() == 1000, api.pauseMs())
api.state.pref = 'downloadUrlToFile'

section('каждому запросу свой временный файл')
downloadUrlToFile = dlSpyFiles
dlFiles = {}
api.get('/v1/journal', { player = 'A' })
api.get('/v1/journal', { player = 'B' })
ok('два запроса - два разных файла', #dlFiles == 2 and dlFiles[1] ~= dlFiles[2],
   table.concat(dlFiles, ' | '))
ok('имя файла содержит номер попытки',
   dlFiles[1] ~= nil and dlFiles[1]:find('api_%d+%.json') ~= nil, tostring(dlFiles[1]))

-- ============================================ v2.0.9: ответ или не ответ ==
--
-- Нюанс API: на один и тот же ник запрос может пройти и с первого раза, и с
-- третьего. Поэтому каждый исход проверяется:
--   * тело {"errors":[{"code":"NOT_FOUND"}]} (HTTP 404) — это ОТВЕТ
--     «записей нет», а не сбой сети: повтор не назначается, транспорт
--     здоровым остаётся (раньше такое тело рвало failStreak и уводило
--     скрипт на блокирующий requests — «ошибок: 141»);
--   * сетевой сбой — повтор с удваивающейся паузой, после исчерпания
--     попыток ник уходит в откат, чтобы не долбить лежащий API.

-- виртуальные часы для повторов: os.time() двигаем только мы
local realTime = os.time
local fakeNow = realTime()
os.time = function(t)
    if t ~= nil then return realTime(t) end
    return fakeNow
end

local NOTFOUND_JSON = '{"errors":[{"code":"NOT_FOUND",' ..
                      '"message":"Данные отсутствуют"}],"meta":{"version":"v1"}}'

-- здоровая загрузка, но в теле — серверное 404
local function dlNotFound(url, file, cb)
    for n = 1, 5 do later(0.05 * n, function() cb(0, n) end) end
    later(0.4, function() putFile(file, NOTFOUND_JSON); cb(0, 6) end)
    return true
end

section('404 NOT_FOUND в теле downloadUrlToFile — это ответ, а не ошибка')
cfg.api.transport = 'download'          -- закрепляем: авто-переключение не мешается
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
local swBefore = api.state.switched
downloadUrlToFile = dlNotFound
local d404, e404 = api.get('/v1/journal', { player = 'Zzz_Nobody_Here_99' })
ok('данных не вернулось', d404 == nil, tostring(d404))
ok('вердикт «нет данных»', e404 == 'нет данных', tostring(e404))
ok('транспорт не помечен больным', api.state.failStreak == 0, api.state.failStreak)
ok('переключения не было', api.state.switched == swBefore, api.state.switched)

section('тело ответа спасается даже когда финальный статус не пришёл')
-- WinINET пишет тело HTTP-ошибки в файл, но «конец загрузки» может не
-- прислать: раньше это считалось обрывом, теперь тело проверяется.
downloadUrlToFile = function(url, file, cb)
    later(0.05, function() cb(0, 2) end)
    later(0.10, function() putFile(file, NOTFOUND_JSON) end)
    return true
end
local vtS = vt
local dS, eS = api.get('/v1/journal', { player = 'Zzz_Silent_404' })
ok('тишина + тело 404 = «нет данных»', dS == nil and eS == 'нет данных', tostring(eS))
ok('тело 404 распознано сразу, без 6 с ожидания (<2 с)', vt - vtS < 2, vt - vtS)
downloadUrlToFile = function(url, file, cb)
    later(0.05, function() cb(0, 2) end)
    later(0.10, function() putFile(file, JOURNAL_JSON) end)
    return true
end
local vtJ = vt
local dJ, eJ = api.get('/v1/journal', { player = 'Nick_Salvaged' })
ok('полезное тело поднято из тишины', dJ ~= nil and dJ.data ~= nil, tostring(eJ))
ok('поднято по телу без ожидания тишины (<2 с)', vt - vtJ < 2, vt - vtJ)

section('сбой сети: запрос ставится на повтор')
cfg.api.transport = 'auto'
cfg.api.retries, cfg.api.retryPause, cfg.api.giveUp = 3, 4, 600
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
roster.members = {}
addMember('Retry_Man', '', fakeNow, 1, 0)
downloadUrlToFile = dlStall             -- статус 2 и тишина: тела нет
local v1 = api.refreshNow('Retry_Man')
ok('неудача -> вердикт retry', v1 == 'retry', tostring(v1))
ok('назначена попытка 1', api.state.tries['Retry_Man'] == 1,
   tostring(api.state.tries['Retry_Man']))
ok('пауза 1-го повтора 4 с', api.retryDelay(1) == 4, api.retryDelay(1))
ok('пауза 2-го повтора 8 с', api.retryDelay(2) == 8, api.retryDelay(2))
ok('пауза ограничена 30 с', api.retryDelay(10) == 30, api.retryDelay(10))
ok('ждёт повтора один ник', api.retryPending() == 1, api.retryPending())
ok('повтор ещё не созрел', api.nextRetry(fakeNow) == nil,
   tostring(api.nextRetry(fakeNow)))
fakeNow = fakeNow + 5
ok('повтор созрел через 5 с', api.nextRetry(fakeNow) == 'Retry_Man',
   tostring(api.nextRetry(fakeNow)))
api.state.retryAt['Retry_Man'] = nil    -- воркер снимает метку перед запросом
downloadUrlToFile = dlHealthy           -- со второй попытки сеть отвечает
local v2 = api.refreshNow('Retry_Man')
ok('успех -> вердикт ok', v2 == 'ok', tostring(v2))
ok('повторы очищены', api.state.tries['Retry_Man'] == nil
   and api.retryPending() == 0, api.retryPending())
ok('данные применены', roster.members['Retry_Man'].apiFetchedAt ~= nil)
ok('ранг из ответа применён', roster.members['Retry_Man'].rank == 4,
   roster.members['Retry_Man'].rank)

section('исчерпание попыток: откат, а не вечный долбёж')
cfg.api.transport = 'download'          -- закрепляем транспорт: серии неудач не должны его переключать
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
addMember('Stubborn_Man', '', fakeNow, 1, 0)
downloadUrlToFile = dlStall
for i = 1, 3 do
    local v = api.refreshNow('Stubborn_Man')
    ok('попытка ' .. i .. ' -> retry', v == 'retry', tostring(v))
    api.state.retryAt['Stubborn_Man'] = nil
    fakeNow = fakeNow + 30
end
local v4 = api.refreshNow('Stubborn_Man')
ok('4-я неудача -> откат', v4 == 'retry'
   and api.state.gaveUp['Stubborn_Man'] ~= nil, tostring(v4))
ok('в откате один ник', api.status().gaveUp == 1, api.status().gaveUp)
ok('счётчик повторов вырос', api.state.retried >= 4, api.state.retried)
roster.members['Stubborn_Man'].apiFetchedAt = nil
ok('TTL не трогает ник в откате', api.dueNick(fakeNow) ~= 'Stubborn_Man',
   tostring(api.dueNick(fakeNow)))
fakeNow = fakeNow + 601
ok('после отката ник снова по TTL', api.dueNick(fakeNow) == 'Stubborn_Man',
   tostring(api.dueNick(fakeNow)))
api.state.gaveUp['Stubborn_Man'] = fakeNow + 600
api.refresh('Stubborn_Man', false)
ok('явная очередь снимает откат', api.state.gaveUp['Stubborn_Man'] == nil)

section('«записей нет»: apiMissing, без повторов и без ошибок')
cfg.api.transport = 'download'
api.state.pref, api.state.prefFails, api.state.failStreak = 'downloadUrlToFile', 0, 0
addMember('NoData_Man', '', fakeNow, 1, 0)
local errBefore = api.state.errors
downloadUrlToFile = dlNotFound
local v5 = api.refreshNow('NoData_Man')
ok('вердикт nodata', v5 == 'nodata', tostring(v5))
ok('ник помечен apiMissing', roster.members['NoData_Man'].apiMissing == true)
ok('повтор не назначен', api.state.tries['NoData_Man'] == nil
   and api.retryPending() == 0, api.retryPending())
ok('ошибок не прибавилось', api.state.errors == errBefore, api.state.errors)
ok('счётчик «записей нет» растёт', api.status().noData >= 1, api.status().noData)
ok('транспорт здоров', api.state.failStreak == 0, api.state.failStreak)

cfg.api.transport = 'auto'
downloadUrlToFile = dlHealthy

-- ================================================== v2.2.0: АВТООБНОВЛЕНИЕ =
-- Скачивание своей новой версии, проверка файла перед заменой, бэкап и откат.
-- Всё на временном файле: thisScript() переопределён, чтобы тест ни при каком
-- исходе не переписал настоящий SFNLogs.lua в репозитории.

section('v2.2.0: автообновление - загрузка, проверка, установка')

local UPD = SFNLogs.update
local TMPD = '/tmp/sfntest_api'
local TARGET = TMPD .. '/target_script.lua'
local BAK = TARGET .. '.bak'
-- временный файл обновления лежит в рабочей папке скрипта (DIR), а не в корне:
-- getWorkingDirectory() в этом раннере возвращает TMPD, а DIR = TMPD .. '\\SFNLogs'
-- путь ровно как DIR в скрипте: getWorkingDirectory() .. '\SFNLogs'
-- (в Lua-литерале один обратный слэш перед u — это просто «\u», НЕ экранирование)
local PENDING = TMPD .. [[\SFNLogs\update.lua.new]]
local OLD_BODY = '-- текущая версия скрипта\n'

-- writeFile/readFile в скрипте локальные (PURE-секция), поэтому здесь свои
local function writeUpd(path, text)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(text); f:close(); return true
end
local function readUpd(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close()
    return (s == '' and nil) or s
end

os.execute('mkdir -p "' .. TMPD .. '/SFNLogs"')
thisScript = function() return { filename = TARGET } end
ok('путь к своему файлу берётся из thisScript()', UPD.path() == TARGET, UPD.path())

local function fakeUpdateScript(ver, padTo)
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

-- с 2.2.0 SFN_VERSION_STR глобальный и объявлен в шапке, поэтому виден и здесь
local CUR_VER = SFN_VERSION_STR
ok('текущая версия доступна тесту', CUR_VER ~= nil, CUR_VER)
ok('она же в исходнике объявлена один раз',
   select(2, io.open('SFNLogs.lua', 'r'):read('*a')
       :gsub("SFN_VERSION_STR%s*=%s*'[%d%.]+'", '')) == 1)

local GOOD = fakeUpdateScript('9.9.9')

-- gsub трактует строку как Lua-паттерн, а в наших маркерах есть скобки
-- (группы) и точки (любой символ), поэтому подмена только литеральная
local function subLiteral(s, from, to)
    local i = s:find(from, 1, true)
    if not i then return nil end
    return s:sub(1, i - 1) .. to .. s:sub(i + #from)
end
ok('подмена маркера в тестовом скрипте работает',
   subLiteral(GOOD, "script_version('9.9.9')", "script_version('9.9.8')")
       :find("script_version('9.9.8')", 1, true) ~= nil)

local function dlScript(text, finalCode)
    return function(url, file, cb)
        later(0.05, function() cb(0, 2) end)
        later(0.10, function() cb(0, 4) end)
        later(0.20, function()
            putFile(file, text)
            cb(0, finalCode or 58)
        end)
        return true
    end
end

local function resetUpdateState()
    local s = UPD.info
    s.lastCheck, s.available, s.ready = 0, '', false
    s.pendingPath, s.lastError = '', ''
    s.installedAt, s.installedVer, s.notified = 0, '', ''
    os.remove(PENDING); os.remove(TARGET); os.remove(BAK)
    downloadUrlToFile = dlHealthy      -- сбрасываем и заглушку загрузки
    cfg.update = { enabled = true, auto = true, url = UPDATE_URL_DEFAULT, every = 21600 }
end

cfg.update = { enabled = true, auto = true, url = UPDATE_URL_DEFAULT, every = 21600 }

-- 1) удачная проверка: скачали, проверили, поставили, сделали бэкап
resetUpdateState()
downloadUrlToFile = dlScript(GOOD)
writeUpd(TARGET, OLD_BODY)
local err = UPD.check(true)
ok('удачная проверка без ошибки', err == nil, err)
local st = UPD.status()
ok('доступна версия 9.9.9', st.available == '9.9.9', st.available)
ok('она же установлена', st.installedVer == '9.9.9', st.installedVer)
ok('время установки зафиксировано', st.installedAt > 0)
local body = readUpd(TARGET)
ok('файл скрипта заменён новой версией',
   body ~= nil and body:find("script_version('9.9.9')", 1, true) ~= nil)
local bakBody = readUpd(BAK)
ok('старая версия сохранена как .bak',
   bakBody ~= nil and bakBody:find('текущая версия скрипта', 1, true) ~= nil)
ok('временный файл убран', readUpd(PENDING) == nil)
ok('ready сброшен после установки', UPD.status().ready == false)
ok('lastError пуст', UPD.status().lastError == '', UPD.status().lastError)

-- 2) битый файл: целевой скрипт обязан остаться нетронутым
resetUpdateState()
writeUpd(TARGET, OLD_BODY)
downloadUrlToFile = dlScript(GOOD .. '\nthis is not lua ((( ')
err = UPD.check(true)
ok('некомпилируемый файл отвергнут',
   err ~= nil and err:find('компилируется', 1, true) ~= nil, err)
ok('целевой файл не тронут', readUpd(TARGET) == OLD_BODY)
ok('бэкап не создавался', readUpd(BAK) == nil)
ok('ошибка записана в состояние', UPD.status().lastError ~= '')
ok('счётчик ошибок вырос', UPD.status().errors > 0, UPD.status().errors)

-- 3) обрыв загрузки: тело короче порога
resetUpdateState()
writeUpd(TARGET, OLD_BODY)
downloadUrlToFile = dlScript('-- коротыш', 58)
err = UPD.check(true)
ok('обрезанный файл отвергнут', err ~= nil and err:find('оборвалась', 1, true) ~= nil, err)
ok('целевой файл не тронут', readUpd(TARGET) == OLD_BODY)

-- 4) сеть молчит: ни одного статуса, тела нет
resetUpdateState()
downloadUrlToFile = function(url, file, cb) return true end
err = UPD.check(true)
ok('тишина сети - это ошибка, а не успех', err ~= nil, err)
ok('файл скрипта не появился', readUpd(TARGET) == nil)

-- 5) версия не новее: ничего не ставим (иначе цикл обновлений)
resetUpdateState()
writeUpd(TARGET, OLD_BODY)
downloadUrlToFile = dlScript(fakeUpdateScript(CUR_VER))
err = UPD.check(true)
ok('та же версия отвергнута', err ~= nil and err:find('не новее', 1, true) ~= nil, err)
ok('целевой файл не тронут', readUpd(TARGET) == OLD_BODY)

-- 6) автоустановка выключена: скачали и предложили, файл не трогаем
resetUpdateState()
writeUpd(TARGET, OLD_BODY)
cfg.update.auto = false
downloadUrlToFile = dlScript(GOOD)
err = UPD.check(true)
ok('без автоустановки проверка успешна', err == nil, err)
st = UPD.status()
ok('обновление скачано и готово', st.ready == true and st.available == '9.9.9')
ok('но файл НЕ заменён', readUpd(TARGET) == OLD_BODY)
ok('и бэкапа нет', readUpd(BAK) == nil)
ok('pending-файл лежит на диске', (readUpd(st.pending) or '') ~= '')
ok('повторная проверка не нужна', UPD.needCheck(os.time() + 1000000, false) == false)
local okI, verI = UPD.install()
ok('принудительная установка ставит версию', okI == true and verI == '9.9.9', verI)
ok('файл заменён после ручной установки',
   (readUpd(TARGET) or ''):find("script_version('9.9.9')", 1, true) ~= nil)
cfg.update.auto = true

-- 7) готовое обновление пережило перезапуск (pending-файл на диске)
resetUpdateState()
writeUpd(PENDING, GOOD)
UPD.info.ready = true
UPD.info.pendingPath = PENDING
UPD.info.available = '9.9.9'
UPD.saveState()
UPD.info.ready, UPD.info.pendingPath = false, ''
UPD.loadState()
ok('ready восстановлен из update.json', UPD.info.ready == true)
ok('pending-путь восстановлен', UPD.info.pendingPath == PENDING, UPD.info.pendingPath)
writeUpd(TARGET, '-- старая версия\n')
local okR, verR = UPD.install()
ok('установка отложенного обновления', okR == true and verR == '9.9.9', verR)
ok('бэкап создан', (readUpd(BAK) or ''):find('старая версия', 1, true) ~= nil)

-- 8) рассинхрон версий внутри скачанного файла
resetUpdateState()
downloadUrlToFile = dlScript('x')          -- будет переопределена ниже
local desync = assert(subLiteral(GOOD, "SFN_VERSION_STR = '9.9.9'",
                                      "SFN_VERSION_STR = '1.0.0'"))
downloadUrlToFile = dlScript(desync)
err = UPD.check(true)
ok('рассинхрон версий отвергнут', err ~= nil and err:find('рассинхрон', 1, true) ~= nil, err)

-- 9) чужой скрипт (script_name не наш)
resetUpdateState()
local alien = assert(subLiteral(GOOD, "script_name('SFN Logs')",
                                     "script_name('Чужой Скрипт')"))
downloadUrlToFile = dlScript(alien)
err = UPD.check(true)
ok('чужой script_name отвергнут', err ~= nil and err:find('script_name', 1, true) ~= nil, err)

-- 10) обновление выключено в конфиге
resetUpdateState()
cfg.update.enabled = false
downloadUrlToFile = dlScript(GOOD)
err = UPD.check(true)
ok('выключенное обновление не качается', err ~= nil and err:find('выключено', 1, true) ~= nil, err)
ok('загрузка не выполнялась', readUpd(TARGET) == nil)
cfg.update.enabled = true

-- 11) установка без скачанного файла
resetUpdateState()
local okN, errN = UPD.install()
ok('нечего ставить -> nil', okN == nil)
ok('причина понятная', type(errN) == 'string' and errN:find('нечего ставить', 1, true) ~= nil, errN)

-- 12) вчерашний остаток временного файла не выдаётся за успешную загрузу
resetUpdateState()                 -- сперва сброс (он же чистит PENDING)
writeUpd(PENDING, GOOD)            -- потом кладём «вчерашний» файл
ok('остаток на диске есть', readUpd(PENDING) ~= nil)
downloadUrlToFile = function(url, file, cb) return true end
err = UPD.check(true)
ok('остаток файла не спасает молчащую загрузку', err ~= nil, err)
ok('остаток удалён', readUpd(PENDING) == nil)
downloadUrlToFile = dlScript(GOOD)

-- 13) после установки повторная проверка не нужна
resetUpdateState()
downloadUrlToFile = dlScript(GOOD)
UPD.check(true)
ok('после установки проверка не нужна', UPD.needCheck(os.time(), false) == false)

downloadUrlToFile = dlHealthy
thisScript = function() return {} end

-- ====================== v2.2.3: ПЕРЕХВАТ /members ИЗ ЧАТА (регресс) ========
-- В 2.1.0 подписка sampev.onServerMessage потерялась: в игре вывод /members
-- не разбирался, а тесты (membersFeed напрямую) оставались зелёными.
-- Теперь проверяем весь путь: CP1251-байты чата -> onServerMessage -> состав.

section('v2.2.3: onServerMessage перехватывает блок /members')
roster.members = {}
membersReset()
local live = io.open('tests/fixtures/chat_dump_2026-09-28.txt', 'rb'):read('*a')
-- фикстура в UTF-8; чат игры приходит в CP1251 - конвертируем штатной
-- utf8ToCp1251 из PURE-секции (она глобальная)
local cpLines = {}
for line in (utf8ToCp1251(live) .. '\n'):gmatch('([^\n]*)\n') do
    cpLines[#cpLines + 1] = line
end
ok('фикстура прочитана и перекодирована', #cpLines > 5, #cpLines)
for _, line in ipairs(cpLines) do
    SFNLogs.onServerMessage(-1, line)
end
local got = 0
for _ in pairs(roster.members) do got = got + 1 end
ok('состав из живого дампа перехвачен через onServerMessage', got >= 10, got)
ok('Jonny_Wilde в журнале', roster.members['Jonny_Wilde'] ~= nil)
ok('ранг из /members применён', roster.members['Jonny_Wilde']
   and roster.members['Jonny_Wilde'].rank == 9,
   roster.members['Jonny_Wilde'] and roster.members['Jonny_Wilde'].rank)
roster.members = {}
membersReset()

print(string.format('\n%s: %d passed, %d failed',
                    failed == 0 and 'OK' or 'FAIL', passed, failed))
if failed > 0 then error('api-тесты провалены') end
