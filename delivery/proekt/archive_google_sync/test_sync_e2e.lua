-- Сквозной тест синхронизации: настоящий Lua-клиент (SFNLogs.lua) против
-- настоящей логики GoogleAppsScript.gs, запущенной на node с файловым моком
-- таблицы. Проверяется весь путь: buildQuery -> HTTP -> JSON -> merge -> save.
--
-- Запуск:  luajit test_sync_e2e.lua
-- Нужен node в PATH.

local HERE = arg[0]:match('^(.*[/\\])') or './'
local DB   = '/tmp/sfn_sheet_e2e.json'
os.remove(DB)
os.execute('mkdir -p /tmp/sfne2e')

-- ============================================== ЗАГЛУШКИ ОКРУЖЕНИЯ =======
local chatLog, commands = {}, {}

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- mimgui: виджеты не вызываются (OnFrame только регистрируется), но ссылки
-- new.bool/new.int/new.char[N] и ImVec* создаются на этапе загрузки файла.
local imgui = {
    ImVec2 = function(x, y) return { x = x, y = y } end,
    ImVec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
    OnInitialize = function() end,
    OnFrame = function() end,
    GetIO = function() return { IniFilename = nil } end,
}
imgui.new = {
    bool = function(v) return { [0] = v and true or false } end,
    int  = function(v) return { [0] = v or 0 } end,
    char = setmetatable({}, { __index = function(_, n)
        return function()
            local store = {}
            return setmetatable({}, {
                __index    = function(_, i) return store[i] or 0 end,
                __newindex = function(_, i, v) store[i] = v end,
            })
        end
    end }),
}
for _, k in ipairs({ 'Col', 'Cond', 'WindowFlags' }) do
    imgui[k] = setmetatable({}, { __index = function() return 0 end })
end
package.preload['mimgui'] = function() return imgui end

local sampev = {}
package.preload['samp.events'] = function() return sampev end

-- Фальшивый HTTP-транспорт: дёргает node с настоящим GoogleAppsScript.gs.
local function mockRequest(query)
    local cmd = 'node ' .. shq(HERE .. 'mock_sheet_server.js') .. ' ' .. shq(query) .. ' ' .. shq(DB)
    local h = io.popen(cmd)
    if not h then return nil end
    local body = h:read('*a')
    h:close()
    return body
end
local requests = {
    get = function(url)
        local q = url:match('%?(.*)$') or ''
        return { status_code = 200, text = mockRequest(q) }
    end,
    post = function(url, opts)
        return { status_code = 200, text = mockRequest((opts or {}).data or '') }
    end,
}
package.preload['requests'] = function() return requests end

-- MoonLoader / SAMPFUNCS
script_name = function() end
script_version = function() end
script_author = function() end
getWorkingDirectory  = function() return '/tmp/sfne2e' end
doesDirectoryExist   = function() return true end
createDirectory      = function() return true end
wait                 = function() end
isSampLoaded         = function() return true end
isSampfuncsLoaded    = function() return true end
isSampAvailable      = function() return true end
sampRegisterChatCommand = function(n, f) commands[n] = f end
sampAddChatMessage   = function(t) chatLog[#chatLog + 1] = t end
sampGetPlayerNickname = function() return 'Tester_Leader' end
sampGetPlayerIdByCharHandle = function() return 0 end
sampIsPlayerConnected = function() return false end
sampGetPlayerScore   = function() return 5 end
thisScript           = function() return { name = 'SFNLogs', path = '/tmp/sfne2e/SFNLogs.lua' } end
wasKeyPressed        = function() return false end
isChatInputActive    = function() return false end
isPauseMenuActive    = function() return false end
PLAYER_PED           = 0
lua_thread           = { create = function(f) coroutine.wrap(f)() end }
downloadUrlToFile    = nil        -- проверяем ветку с requests

-- ================================================== ЗАГРУЗКА СКРИПТА =====
local chunk, err = loadfile(HERE .. 'SFNLogs.lua')
assert(chunk, err)
chunk()
assert(type(SFNLogs) == 'table', 'тестовый шов SFNLogs не опубликован')

local function useSync()
    cfg.sync.enabled  = true
    cfg.sync.url      = 'https://mock.invalid/exec'
    cfg.sync.token    = 'TESTTOKEN'
    cfg.sync.interval = 60
    cfg.sync.usePost  = false
end

-- ============================================================== ТЕСТЫ ====
local passed, failed = 0, 0
local function eq(name, got, want)
    if tostring(got) == tostring(want) then passed = passed + 1
    else failed = failed + 1
        print(string.format('  FAIL %-48s got=%s want=%s', name, tostring(got), tostring(want)))
    end
end
local function ok(name, c) eq(name, c and true or false, true) end
local function section(t) print('\n== ' .. t) end

local D = 86400
local T0 = 1760000000

section('transport and ping')
useSync()
eq('transport detected', SFNLogs.transportName(), 'requests/GET')
local ping, perr = SFNLogs.httpCall({ action = 'ping' })
ok('ping reached the server', ping ~= nil)
eq('  ping ok', ping and ping.ok, true)
local bad = (function()
    local t = cfg.sync.token; cfg.sync.token = 'wrong'
    local r = SFNLogs.httpCall({ action = 'pull' })
    cfg.sync.token = t
    return r
end)()
eq('wrong token rejected', bad and bad.error, 'bad_token')

section('client A: local edits then push')
localNick = 'Leader_A'
roster = { members = {} }
addMember('Ivan_Petrov', 'Leader_A', T0 - 40 * D, 1, 5, T0 - 40 * D)
addMember('Petr_Sidorov', 'Ivan_Petrov', T0 - 9 * D, 1, 3, T0 - 9 * D)
changeRank('Ivan_Petrov', 5, 'повышен', T0 - 10 * D)
eq('two pending records', SFNLogs.pendingCount(), 2)
local okSync, info = SFNLogs.doSync()
ok('sync reported success', okSync)
eq('queue drained', SFNLogs.pendingCount(), 0)
print('     ' .. tostring(info))

section('client B: fresh state pulls everything')
localNick = 'Leader_B'
roster = { members = {} }
local okB, infoB = SFNLogs.doSync()
ok('B sync ok', okB)
eq('B got 2 members', (function() local n=0 for _ in pairs(roster.members) do n=n+1 end return n end)(), 2)
ok('  Ivan present', roster.members['Ivan_Petrov'] ~= nil)
eq('  Ivan rank from server', roster.members['Ivan_Petrov'].rank, 5)
eq('  Ivan acceptedBy', roster.members['Ivan_Petrov'].acceptedBy, 'Leader_A')
eq('  Ivan promotedAt preserved', roster.members['Ivan_Petrov'].promotedAt, T0 - 10 * D)
eq('  nothing dirty after pull', SFNLogs.pendingCount(), 0)
ok('  history seeded', #(roster.members['Ivan_Petrov'].history or {}) >= 1)
print('     ' .. tostring(infoB))

section('client B promotes, client A receives it')
changeRank('Petr_Sidorov', 3, 'повышен B', T0 + 100)
eq('B has 1 pending', SFNLogs.pendingCount(), 1)
SFNLogs.doSync()
eq('B queue drained', SFNLogs.pendingCount(), 0)

localNick = 'Leader_A'
roster = { members = {} }
SFNLogs.doSync()
eq('A sees B promotion', roster.members['Petr_Sidorov'].rank, 3)
eq('A sees editor nick', roster.members['Petr_Sidorov'].updatedBy, 'Leader_B')

section('conflict: stale client loses and adopts server version')
-- A правит запись, но с устаревшим updatedAt
roster.members['Petr_Sidorov'].rank = 9
roster.members['Petr_Sidorov'].updatedAt = T0 - 1000     -- заведомо старее серверного
roster.members['Petr_Sidorov'].dirty = true
local okC, infoC = SFNLogs.doSync()
ok('conflict sync did not fail hard', okC ~= nil)
eq('server version adopted', roster.members['Petr_Sidorov'].rank, 3)
eq('dirty cleared after conflict', roster.members['Petr_Sidorov'].dirty, false)
ok('conflict recorded in history',
   (function()
       local h = roster.members['Petr_Sidorov'].history or {}
       for i = #h, 1, -1 do if (h[i].note or ''):find('конфликт') then return true end end
       return false
   end)())
print('     ' .. tostring(infoC))

section('newer local edit wins and is pushed')
roster.members['Petr_Sidorov'].rank = 4
roster.members['Petr_Sidorov'].updatedAt = T0 + 5000
roster.members['Petr_Sidorov'].dirty = true
SFNLogs.doSync()
roster = { members = {} }
SFNLogs.doSync()
eq('newer edit survived round trip', roster.members['Petr_Sidorov'].rank, 4)

section('dismissal propagates as a flag, not a deletion')
dismissMember('Ivan_Petrov', 'ушёл', T0 + 6000)
SFNLogs.doSync()
roster = { members = {} }
SFNLogs.doSync()
ok('member still present', roster.members['Ivan_Petrov'] ~= nil)
eq('  dismissed flag came back', roster.members['Ivan_Petrov'].dismissed, true)
eq('  dismissedAt came back', roster.members['Ivan_Petrov'].dismissedAt, T0 + 6000)

section('offline: server unreachable must not lose data')
local savedUrl = cfg.sync.url
cfg.sync.url = 'https://mock.invalid/exec'
local savedToken = cfg.sync.token
cfg.sync.token = 'BROKEN_TOKEN_SO_SERVER_REJECTS'
roster.members['Petr_Sidorov'].rank = 6
roster.members['Petr_Sidorov'].updatedAt = T0 + 9000
roster.members['Petr_Sidorov'].dirty = true
local okOff = SFNLogs.doSync()
eq('offline sync reports failure', okOff, false)
ok('error recorded', SFNLogs.sync.lastErr ~= nil)
eq('local edit NOT lost', roster.members['Petr_Sidorov'].rank, 6)
ok('still marked dirty -> will retry', roster.members['Petr_Sidorov'].dirty == true)
cfg.sync.token = savedToken
SFNLogs.doSync()
eq('recovers after connectivity returns', SFNLogs.pendingCount(), 0)
roster = { members = {} }
SFNLogs.doSync()
eq('  and the edit reached the sheet', roster.members['Petr_Sidorov'].rank, 6)
cfg.sync.url = savedUrl

section('POST transport')
cfg.sync.usePost = true
eq('transport name', SFNLogs.transportName(), 'requests/POST')
roster.members['Petr_Sidorov'].rank = 7
roster.members['Petr_Sidorov'].updatedAt = T0 + 12000
roster.members['Petr_Sidorov'].dirty = true
local okP = SFNLogs.doSync()
ok('POST sync ok', okP)
roster = { members = {} }
SFNLogs.doSync()
eq('POST write reached the sheet', roster.members['Petr_Sidorov'].rank, 7)
cfg.sync.usePost = false

section('commands registered')
SFNLogs.registerCommands()
for _, c in ipairs({ 'sfnlog', 'sfnlogcap', 'sfnlogsave', 'sfnlogadd',
                     'sfnlogsync', 'sfnlogsyncstatus' }) do
    ok('command /' .. c, type(commands[c]) == 'function')
end
commands['sfnlogsyncstatus']()
ok('status command produced a chat line', #chatLog > 0)

section('chat encoding: CP1251 in, CP1251 out')

-- Чат приходит из игры байтами CP1251: шаблон с кириллицей обязан сработать
cfg.patterns.accept = { { pattern = 'Принят (%S+) в семью', fields = { 'nick' } } }
roster.members['Cp_New'] = nil
sampev.onServerMessage(-1, utf8ToCp1251('Принят Cp_New в семью'))
ok('accept fired from CP1251 chat', roster.members['Cp_New'] ~= nil)

-- Аргументы команд тоже приходят в CP1251, а хранятся в UTF-8
commands['sfnlogadd'](utf8ToCp1251('Cp_Add Lider_Test'))
local madd = roster.members['Cp_Add']
ok('sfnlogadd parsed CP1251 args', madd ~= nil)
eq('sfnlogadd by stored as UTF-8', madd and madd.acceptedBy, 'Lider_Test')

-- Сообщения в чат уходят обратно в CP1251 (игры не понимают UTF-8)
local n = #chatLog
commands['sfnlogsave']()
eq('save printed one chat line', #chatLog, n + 1)
local line = chatLog[#chatLog]
eq('chat line is CP1251', line, utf8ToCp1251('{66FF66}[SFN Logs] сохранено'))
ok('chat line is not valid UTF-8', not isUtf8(line))

print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
