// Тесты серверной части SFN Logs (GoogleAppsScript.gs) на node.
// Google API мокается: SpreadsheetApp, ContentService, LockService, Utilities.
//
// Запуск:  node test_apps_script.js

const fs = require('fs');
const path = require('path');

// --------------------------------------------------------------- моки ----
function pad(n, w = 2) { return String(n).padStart(w, '0'); }

class Range {
  constructor(sheet, row, col, nRows, nCols, values) {
    this.sheet = sheet; this.row = row; this.col = col;
    this.nRows = nRows; this.nCols = nCols; this._values = values;
  }
  getValues() { return this._values; }
  setValues(vals) {
    for (let r = 0; r < vals.length; r++) {
      for (let c = 0; c < vals[r].length; c++) {
        const rr = this.row + r, cc = this.col + c;
        while (this.sheet.rows.length < rr) this.sheet.rows.push([]);
        this.sheet.rows[rr - 1][cc - 1] = vals[r][c];
      }
    }
    return this;
  }
  setFontWeight() { return this; }
}

class Sheet {
  constructor(name) { this.name = name; this.rows = []; this.frozen = 0; }
  getLastRow() { return this.rows.length; }
  getLastColumn() {
    return this.rows.reduce((m, r) => Math.max(m, r.length), 0);
  }
  getRange(row, col, nRows, nCols) {
    const values = [];
    for (let r = 0; r < (nRows || 1); r++) {
      const line = [];
      const src = this.rows[row - 1 + r] || [];
      for (let c = 0; c < (nCols || 1); c++) {
        const v = src[col - 1 + c];
        line.push(v === undefined ? '' : v);
      }
      values.push(line);
    }
    return new Range(this, row, col, nRows, nCols, values);
  }
  appendRow(arr) { this.rows.push(arr.slice()); return this; }
  setFrozenRows(n) { this.frozen = n; return this; }
  deleteRow(row) { this.rows.splice(row - 1, 1); return this; }
}

class Spreadsheet {
  constructor() { this.sheets = {}; }
  getSheetByName(n) { return this.sheets[n] || null; }
  insertSheet(n) { const s = new Sheet(n); this.sheets[n] = s; return s; }
  getSpreadsheetTimeZone() { return 'UTC'; }
}

const SS = new Spreadsheet();

global.SpreadsheetApp = { getActiveSpreadsheet: () => SS };
global.ContentService = {
  MimeType: { JSON: 'application/json' },
  createTextOutput: (s) => ({
    _s: s,
    setMimeType() { return this; },
    getContent() { return this._s; },
  }),
};
let lockHeld = 0;
global.LockService = {
  getScriptLock: () => ({
    waitLock() { lockHeld++; return true; },
    releaseLock() { lockHeld--; },
  }),
};
global.Utilities = {
  formatDate(date, tz, fmt) {
    return fmt
      .replace('yyyy', date.getUTCFullYear())
      .replace('MM', pad(date.getUTCMonth() + 1))
      .replace('dd', pad(date.getUTCDate()))
      .replace('HH', pad(date.getUTCHours()))
      .replace('mm', pad(date.getUTCMinutes()))
      .replace('ss', pad(date.getUTCSeconds()));
  },
  parseDate(s, tz, fmt) {
    const m = String(s).match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/);
    if (!m) return new Date(NaN);
    return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)));
  },
};
global.Logger = { log: () => {} };

// -------------------------------------------------------- загрузка кода --
const gsPath = process.argv[2] || path.join(__dirname, 'GoogleAppsScript.gs');
let code = fs.readFileSync(gsPath, 'utf8');
code = code.replace(/^var TOKEN = .*$/m, "var TOKEN = 'TESTTOKEN';");
(0, eval)(code + '\n;global.__api = {doGet, doPost, setup, selfTest, handle_, sheet_, ROSTER_COLUMNS};');
const { doGet, setup } = global.__api;

const call = (params) => JSON.parse(doGet({ parameter: params }).getContent());

// ------------------------------------------------------------- ассерты --
let passed = 0, failed = 0;
const eq = (name, got, want) => {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a === b) passed++;
  else { failed++; console.log(`  FAIL ${name}\n       got  ${a}\n       want ${b}`); }
};
const ok = (name, cond) => eq(name, !!cond, true);
const section = (t) => console.log('\n== ' + t);

// ============================================================== ТЕСТЫ ====
setup();

section('setup and auth');
ok('Roster sheet created', SS.getSheetByName('Roster') !== null);
ok('Log sheet created', SS.getSheetByName('Log') !== null);
eq('Roster header', SS.getSheetByName('Roster').rows[0][0], 'nick');
eq('ping without token -> ok:false', call({ action: 'ping' }).ok, false);
eq('ping with token -> ok:true', call({ action: 'ping', token: 'TESTTOKEN' }).ok, true);
eq('pull with bad token', call({ action: 'pull', token: 'nope' }).error, 'bad_token');
eq('unknown action', call({ action: 'wat', token: 'TESTTOKEN' }).error, 'unknown_action');

const T = { token: 'TESTTOKEN' };

section('push: create');
let r = call(Object.assign({}, T, {
  action: 'push', nick: 'Ivan_Petrov', acceptedBy: 'Leader_Name',
  acceptedAt: '1750000000', rank: '1', promotedAt: '1750000000',
  level: '3', dismissed: '0', dismissedAt: '', note: '',
  updatedAt: '1750001000', updatedBy: 'Leader_Name',
}));
eq('push ok', r.ok, true);
eq('push created', r.created, true);
const rs = SS.getSheetByName('Roster');
eq('roster rows', rs.getLastRow(), 2);
eq('  nick cell', rs.rows[1][0], 'Ivan_Petrov');
eq('  acceptedAt human readable', rs.rows[1][2], '2025-06-15 15:06:40');
eq('  rank cell', rs.rows[1][3], 1);
eq('  updatedAt as number', rs.rows[1][9], 1750001000);

section('push: update in place');
r = call(Object.assign({}, T, {
  action: 'push', nick: 'Ivan_Petrov', acceptedBy: 'Leader_Name',
  acceptedAt: '1750000000', rank: '4', promotedAt: '1750300000',
  level: '6', dismissed: '0', dismissedAt: '', note: 'заметка',
  updatedAt: '1750300100', updatedBy: 'Chief_Editor',
}));
eq('update ok', r.ok, true);
eq('no duplicate row', rs.getLastRow(), 2);
eq('  rank updated', rs.rows[1][3], 4);
eq('  note updated', rs.rows[1][8], 'заметка');
eq('  updatedBy updated', rs.rows[1][10], 'Chief_Editor');

section('push: stale write is rejected as conflict');
r = call(Object.assign({}, T, {
  action: 'push', nick: 'Ivan_Petrov', acceptedBy: 'x', acceptedAt: '1750000000',
  rank: '2', promotedAt: '1750000000', level: '1', dismissed: '0',
  dismissedAt: '', note: '', updatedAt: '1750000500', updatedBy: 'Old_Client',
}));
eq('conflict reported', r.error, 'conflict');
eq('  conflict carries nick', r.nick, 'Ivan_Petrov');
eq('  server version returned', r.server.rank, 4);
eq('  server updatedAt returned', r.server.updatedAt, 1750300100);
eq('  sheet not overwritten', rs.rows[1][3], 4);

section('push: validation');
eq('empty nick rejected', call(Object.assign({}, T, { action: 'push', nick: '  ', updatedAt: '1' })).error, 'empty_nick');
eq('missing updatedAt rejected', call(Object.assign({}, T, { action: 'push', nick: 'X_Y' })).error, 'empty_updatedAt');

section('push: dismissal is a flag, not a deletion');
call(Object.assign({}, T, {
  action: 'push', nick: 'Ivan_Petrov', acceptedBy: 'Leader_Name',
  acceptedAt: '1750000000', rank: '4', promotedAt: '1750300000', level: '6',
  dismissed: '1', dismissedAt: '1750400000', note: 'заметка',
  updatedAt: '1750400100', updatedBy: 'Leader_Name',
}));
eq('dismissed flag stored', rs.rows[1][6], 1);
eq('row still present', rs.getLastRow(), 2);

section('pull');
call(Object.assign({}, T, {
  action: 'push', nick: 'Petr_Sidorov', acceptedBy: 'Ivan_Petrov',
  acceptedAt: '1750100000', rank: '1', promotedAt: '1750100000', level: '2',
  dismissed: '0', dismissedAt: '', note: '', updatedAt: '1750100100', updatedBy: 'Ivan_Petrov',
}));
let p = call(Object.assign({}, T, { action: 'pull' }));
eq('pull ok', p.ok, true);
eq('pull returns 2 members', p.roster.length, 2);
const ivan = p.roster.find((x) => x.nick === 'Ivan_Petrov');
eq('  nick', ivan.nick, 'Ivan_Petrov');
eq('  rank', ivan.rank, 4);
eq('  dismissed parsed back to bool', ivan.dismissed, true);
eq('  acceptedAt round-trips to unix', ivan.acceptedAt, 1750000000);
eq('  promotedAt round-trips', ivan.promotedAt, 1750300000);
eq('  note round-trips utf8', ivan.note, 'заметка');
ok('  serverTime present', p.serverTime > 1e9);
eq('  ranks dictionary sent', p.ranks[1], 'Стажёр');

section('pull with since filter');
p = call(Object.assign({}, T, { action: 'pull', since: '1750200000' }));
eq('only newer returned', p.roster.length, 1);
eq('  and it is the newer one', p.roster[0].nick, 'Ivan_Petrov');

section('pushmany');
const batch = [
  { nick: 'Batch_One', acceptedBy: 'L', acceptedAt: '1750000000', rank: '1', promotedAt: '1750000000', level: '1', dismissed: '0', dismissedAt: '', note: '', updatedAt: '1750600000', updatedBy: 'L' },
  { nick: 'Batch_Two', acceptedBy: 'L', acceptedAt: '1750000000', rank: '2', promotedAt: '1750000000', level: '1', dismissed: '0', dismissedAt: '', note: '', updatedAt: '1750600001', updatedBy: 'L' },
  { nick: 'Ivan_Petrov', acceptedBy: 'L', acceptedAt: '1750000000', rank: '9', promotedAt: '1750000000', level: '1', dismissed: '0', dismissedAt: '', note: '', updatedAt: '1750000001', updatedBy: 'Stale' },
];
r = call(Object.assign({}, T, { action: 'pushmany', data: JSON.stringify(batch) }));
eq('pushmany ok', r.ok, true);
eq('  total', r.total, 3);
eq('  pushed', r.pushed, 2);
eq('  conflicts', r.conflicts, 1);
// было 3 строки (шапка + Ivan_Petrov + Petr_Sidorov), добавили две -> 5
eq('  sheet grew by 2', rs.getLastRow(), 5);
eq('bad json', call(Object.assign({}, T, { action: 'pushmany', data: '{' })).error, 'bad_json');
eq('empty data', call(Object.assign({}, T, { action: 'pushmany' })).error, 'empty_data');

section('log');
call(Object.assign({}, T, { action: 'log', kind: 'note', nick: 'Ivan_Petrov', details: 'проверка', by: 'Tester' }));
const ls = SS.getSheetByName('Log');
ok('log has rows', ls.getLastRow() > 1);
const lastLog = ls.rows[ls.getLastRow() - 1];
eq('  log nick', lastLog[1], 'Ivan_Petrov');
eq('  log details', lastLog[3], 'проверка');
ok('audit trail written for pushes', ls.getLastRow() >= 5);

section('locking');
eq('all locks released', lockHeld, 0);

section('doPost path');
const postRes = JSON.parse(global.__api.doPost({
  parameter: {},
  postData: { contents: 'action=ping&token=TESTTOKEN' },
}).getContent());
eq('POST ping ok', postRes.ok, true);
const postBad = JSON.parse(global.__api.doPost({
  parameter: {},
  postData: { contents: 'action=pull&token=WRONG' },
}).getContent());
eq('POST bad token', postBad.error, 'bad_token');

// ================================================================= ИТОГ ===
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
