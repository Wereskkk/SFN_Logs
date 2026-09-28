/**
 * SFN Logs — серверная часть (Google Apps Script).
 *
 * Зачем именно Apps Script, а не Google Sheets API напрямую:
 * для прямого API нужен сервисный аккаунт и подпись JWT (RS256), а в MoonLoader
 * нет ни RSA, ни удобного HTTP-клиента. Web App решает это одним запросом:
 * скрипт дёргает обычный HTTPS GET, всю работу с таблицей делает этот файл.
 *
 * ---------------------------- УСТАНОВКА ------------------------------------
 * 1. Создайте Google-таблицу (или откройте существующую).
 * 2. Расширения -> Apps Script. Удалите содержимое, вставьте этот файл.
 * 3. Замените TOKEN на длинную случайную строку (см. генератор ниже).
 * 4. Сохраните, нажмите "Развернуть" -> "Новое развёртывание".
 *      Тип:              Веб-приложение
 *      Выполнять как:    Я (ваш аккаунт)
 *      У кого есть доступ: Все  (обязательно — иначе Lua-клиент не сможет
 *                               вызвать без OAuth)
 * 5. Скопируйте URL вида
 *      https://script.google.com/macros/s/AKfycb.../exec
 *    и впишите его в config.ini скрипта (секция [sync], поле url),
 *    туда же — тот же TOKEN.
 * 6. Откройте URL в браузере и добавьте ?action=ping&token=ВАШ_ТОКЕН
 *    Должно вернуться {"ok":true,"action":"ping",...}
 *
 * Листы Roster и Log создаются сами при первом обращении.
 *
 * Генератор токена (выполните в браузере в консоли):
 *   crypto.getRandomValues(new Uint8Array(24)).reduce((s,b)=>s+b.toString(16).padStart(2,'0'),'')
 *
 * ---------------------------- БЕЗОПАСНОСТЬ ---------------------------------
 * Доступ к Web App открыт всем, единственный барьер — TOKEN. Поэтому:
 *   - сама таблица НЕ должна быть расшарена на редактирование никому,
 *     кроме старшего состава;
 *   - токен общий для всех, кто имеет право писать, и лежит в config.ini
 *     на их машинах — считайте его секретом команды;
 *   - параметры GET попадают в логи Apps Script и в историю браузера,
 *     поэтому токен в URL — компромисс. Если это критично, переключите
 *    клиент на POST (см. USE_POST в Lua-части) — тело POST в логи не пишется;
 *   - при утечке токена смените его здесь и в config.ini у всех,
 *     затем "Развернуть" -> "Управление развёртываниями" -> изменить версию.
 *
 * Все записи идут через LockService, поэтому одновременная правка несколькими
 * людьми не рвёт таблицу: запросы выстраиваются в очередь.
 */

// ===========================================================================
//  НАСТРОЙКИ
// ===========================================================================

var TOKEN = 'CHANGE_ME_PUT_A_LONG_RANDOM_STRING_HERE';

var SHEET_ROSTER    = 'Roster';
var SHEET_LOG       = 'Log';

var ROSTER_COLUMNS = [
  'nick',         // A  ник (ключ записи)
  'acceptedBy',   // B  кто принял
  'acceptedAt',   // C  дата принятия, YYYY-MM-DD HH:MM
  'rank',         // D  ранг 1..9
  'promotedAt',   // E  дата последнего повышения
  'level',        // F  уровень игрока
  'dismissed',    // G  0/1
  'dismissedAt',  // H  дата увольнения
  'note',         // I  заметка
  'updatedAt',    // J  unix-время последней правки — по нему идёт слияние
  'updatedBy'     // K  кто правил
];

var LOG_COLUMNS = ['at', 'nick', 'action', 'details', 'by'];

var RANK_NAMES = {
  1: 'Стажёр', 2: 'Звукооператор', 3: 'Звукорежиссёр', 4: 'Репортёр',
  5: 'Ведущий', 6: 'Редактор', 7: 'Главный редактор',
  8: 'Технический директор', 9: 'Программный директор'
};

// ===========================================================================
//  ВСПОМОГАТЕЛЬНОЕ
// ===========================================================================

function fail_(message, extra) {
  var out = { ok: false, error: message };
  if (extra) { for (var k in extra) out[k] = extra[k]; }
  return json_(out);
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function checkToken_(e) {
  var got = (e && e.parameter && e.parameter.token) || '';
  return TOKEN !== '' && got === TOKEN;
}

function sheet_(name, columns) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
  }
  if (sh.getLastRow() === 0) {
    sh.getRange(1, 1, 1, columns.length).setValues([columns])
      .setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  return sh;
}

/** Читает лист в массив объектов, ключи — из первой строки. */
function readRows_(sh) {
  var last = sh.getLastRow();
  if (last < 2) return [];
  var values = sh.getRange(2, 1, last - 1, sh.getLastColumn()).getValues();
  var header = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  var out = [];
  for (var i = 0; i < values.length; i++) {
    var row = values[i];
    // полностью пустые строки пропускаем
    var empty = true;
    for (var c = 0; c < row.length; c++) {
      if (row[c] !== '' && row[c] !== null) { empty = false; break; }
    }
    if (empty) continue;
    var obj = { __row: i + 2 };
    for (var h = 0; h < header.length; h++) obj[header[h]] = row[h];
    out.push(obj);
  }
  return out;
}

/** Дата в читаемом виде для таблицы: YYYY-MM-DD HH:MM (локальное время листа). */
function fmtDate_(unix) {
  var n = Number(unix);
  if (!n || isNaN(n)) return '';
  var tz = SpreadsheetApp.getActiveSpreadsheet().getSpreadsheetTimeZone();
  // Секунды обязательны: updatedAt участвует в слиянии, а acceptedAt и
  // promotedAt должны переживать round-trip лист -> клиент без потерь.
  return Utilities.formatDate(new Date(n * 1000), tz, 'yyyy-MM-dd HH:mm:ss');
}

/** Обратное преобразование: строка листа или число -> unix-секунды. */
function toUnix_(v) {
  if (v === '' || v === null || v === undefined) return 0;
  if (v instanceof Date) return Math.floor(v.getTime() / 1000);
  var n = Number(v);
  if (!isNaN(n) && n > 1e9) return Math.floor(n);      // уже unix
  var tz = SpreadsheetApp.getActiveSpreadsheet().getSpreadsheetTimeZone();
  var s = String(v);
  // Сначала формат с секундами: более короткий «съест» секунды и не ошибётся.
  var fmts = ['yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm'];
  for (var i = 0; i < fmts.length; i++) {
    try {
      var d = Utilities.parseDate(s, tz, fmts[i]);
      if (!isNaN(d.getTime())) return Math.floor(d.getTime() / 1000);
    } catch (err) { /* пробуем следующий формат */ }
  }
  var d2 = new Date(s);
  return isNaN(d2.getTime()) ? 0 : Math.floor(d2.getTime() / 1000);
}

function appendLog_(nick, action, details, by) {
  try {
    var sh = sheet_(SHEET_LOG, LOG_COLUMNS);
    sh.appendRow([fmtDate_(Math.floor(Date.now() / 1000)), nick || '',
                  action || '', details || '', by || '']);
  } catch (err) {
    // журнал не должен ломать основную операцию
  }
}

// ===========================================================================
//  ТОЧКА ВХОДА
// ===========================================================================

function doGet(e) {
  return handle_(e);
}

function doPost(e) {
  var params = (e && e.parameter) ? e.parameter : {};
  // тело POST разбираем сами: клиент шлёт его как query-строку
  if (e && e.postData && e.postData.contents) {
    var pairs = String(e.postData.contents).split('&');
    for (var i = 0; i < pairs.length; i++) {
      var kv = pairs[i].split('=');
      if (kv.length >= 2) {
        params[decodeURIComponent(kv[0])] =
          decodeURIComponent(kv.slice(1).join('=').replace(/\+/g, ' '));
      }
    }
  }
  return handle_({ parameter: params });
}

function handle_(e) {
  var p = (e && e.parameter) || {};
  var action = String(p.action || '');

  if (action === 'ping') {
    return json_({ ok: checkToken_(e), action: 'ping',
                   sheets: [SHEET_ROSTER, SHEET_LOG] });
  }
  if (!checkToken_(e)) {
    return fail_('bad_token');
  }

  switch (action) {
    case 'pull':     return pull_(p);
    case 'push':     return push_(p);
    case 'pushmany': return pushMany_(p);
    case 'log':      return logOnly_(p);
    default:         return fail_('unknown_action', { action: action });
  }
}

// ===========================================================================
//  ЧТЕНИЕ
// ===========================================================================

/** Отдаёт весь журнал одним ответом. since — unix-время, если нужно только новое. */
function pull_(p) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var since = Number(p.since || 0);

    var rSh = sheet_(SHEET_ROSTER, ROSTER_COLUMNS);
    var roster = [];
    var rows = readRows_(rSh);
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i];
      var updated = toUnix_(r.updatedAt);
      if (since && updated && updated <= since) continue;
      roster.push({
        nick:        String(r.nick || ''),
        acceptedBy:  String(r.acceptedBy || ''),
        acceptedAt:  toUnix_(r.acceptedAt),
        rank:        Number(r.rank || 1),
        promotedAt:  toUnix_(r.promotedAt),
        level:       Number(r.level || 0),
        dismissed:   String(r.dismissed) === '1' || r.dismissed === true,
        dismissedAt: toUnix_(r.dismissedAt),
        note:        String(r.note || ''),
        updatedAt:   updated,
        updatedBy:   String(r.updatedBy || '')
      });
    }

    return json_({
      ok: true,
      action: 'pull',
      serverTime: Math.floor(Date.now() / 1000),
      roster: roster,
      ranks: RANK_NAMES
    });
  } catch (err) {
    return fail_('pull_failed', { message: String(err) });
  } finally {
    lock.releaseLock();
  }
}

// ===========================================================================
//  ЗАПИСЬ
// ===========================================================================

/**
 * Обновляет или создаёт одну запись состава.
 * Обязательные поля: nick, updatedAt, updatedBy.
 * Обновление происходит только если присланный updatedAt не старше хранящегося,
 * иначе сервер отвечает conflict и возвращает свою версию — клиент сам решит.
 */
function push_(p) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    var nick = String(p.nick || '').replace(/^\s+|\s+$/g, '');
    if (!nick) return fail_('empty_nick');

    var incoming = Number(p.updatedAt || 0);
    if (!incoming) return fail_('empty_updatedAt');
    var by = String(p.updatedBy || '');

    var sh = sheet_(SHEET_ROSTER, ROSTER_COLUMNS);
    var rows = readRows_(sh);
    var found = null;
    for (var i = 0; i < rows.length; i++) {
      if (String(rows[i].nick) === nick) { found = rows[i]; break; }
    }

    if (found) {
      var stored = toUnix_(found.updatedAt);
      if (stored > incoming) {
        return fail_('conflict', {
          nick: nick,
          server: {
            nick: nick,
            acceptedBy: String(found.acceptedBy || ''),
            acceptedAt: toUnix_(found.acceptedAt),
            rank: Number(found.rank || 1),
            promotedAt: toUnix_(found.promotedAt),
            level: Number(found.level || 0),
            dismissed: String(found.dismissed) === '1',
            dismissedAt: toUnix_(found.dismissedAt),
            note: String(found.note || ''),
            updatedAt: stored,
            updatedBy: String(found.updatedBy || '')
          }
        });
      }
      sh.getRange(found.__row, 1, 1, ROSTER_COLUMNS.length).setValues([[
        nick,
        String(p.acceptedBy || ''),
        fmtDate_(p.acceptedAt),
        Number(p.rank || 1),
        fmtDate_(p.promotedAt),
        Number(p.level || 0),
        (String(p.dismissed) === '1' || p.dismissed === true) ? 1 : 0,
        fmtDate_(p.dismissedAt),
        String(p.note || ''),
        incoming,
        by
      ]]);
      appendLog_(nick, p.action || 'update',
                 'ранг ' + Number(p.rank || 1) + ' (' +
                 (RANK_NAMES[Number(p.rank || 1)] || '?') + ')', by);
      return json_({ ok: true, action: 'push', nick: nick, updatedAt: incoming });
    }

    sh.appendRow([
      nick,
      String(p.acceptedBy || ''),
      fmtDate_(p.acceptedAt),
      Number(p.rank || 1),
      fmtDate_(p.promotedAt),
      Number(p.level || 0),
      (String(p.dismissed) === '1' || p.dismissed === true) ? 1 : 0,
      fmtDate_(p.dismissedAt),
      String(p.note || ''),
      incoming,
      by
    ]);
    appendLog_(nick, p.action || 'add',
               'принят, ранг ' + Number(p.rank || 1) + ', принял ' +
               String(p.acceptedBy || '?'), by);
    return json_({ ok: true, action: 'push', nick: nick, created: true,
                   updatedAt: incoming });
  } catch (err) {
    return fail_('push_failed', { message: String(err) });
  } finally {
    lock.releaseLock();
  }
}

/** Пакетная отправка: data — JSON-массив записей того же вида, что и push. */
function pushMany_(p) {
  var raw = String(p.data || '');
  if (!raw) return fail_('empty_data');
  var list;
  try { list = JSON.parse(raw); } catch (err) { return fail_('bad_json'); }
  if (!list || list.length === undefined) return fail_('bad_json');

  var results = [], okCount = 0, conflictCount = 0;
  for (var i = 0; i < list.length; i++) {
    var one = list[i];
    one.action = one.action || 'sync';
    var res = push_(one);
    // push_ возвращает TextOutput — разбираем его обратно
    var parsed;
    try { parsed = JSON.parse(res.getContent()); } catch (e2) { parsed = { ok: false }; }
    if (parsed.ok) okCount++;
    if (parsed.error === 'conflict') conflictCount++;
    results.push({ nick: one.nick, ok: !!parsed.ok, error: parsed.error || null });
  }
  return json_({ ok: true, action: 'pushmany', total: list.length,
                 pushed: okCount, conflicts: conflictCount, results: results });
}

function logOnly_(p) {
  // p.action занят маршрутизацией, поэтому метка события приходит в p.kind
  appendLog_(String(p.nick || ''), String(p.kind || 'note'),
             String(p.details || ''), String(p.by || ''));
  return json_({ ok: true, action: 'log' });
}

// ===========================================================================
//  СЛУЖЕБНОЕ
// ===========================================================================

/** Одноразово: создаёт листы с шапками и пишет строку-пример. */
function setup() {
  sheet_(SHEET_ROSTER, ROSTER_COLUMNS);
  sheet_(SHEET_LOG, LOG_COLUMNS);
  appendLog_('', 'setup', 'листы созданы', '');
  return 'ok';
}

/** Проверяет, что токен задан и листы доступны. Запускается из редактора. */
function selfTest() {
  var out = [];
  out.push('TOKEN set: ' + (TOKEN !== '' && TOKEN.indexOf('CHANGE_ME') < 0));
  out.push('Roster rows: ' + readRows_(sheet_(SHEET_ROSTER, ROSTER_COLUMNS)).length);
  out.push('Log rows: ' + readRows_(sheet_(SHEET_LOG, LOG_COLUMNS)).length);
  Logger.log(out.join('\n'));
  return out.join('\n');
}
