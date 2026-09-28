// Мок-сервер для сквозного теста синхронизации.
// Использует НАСТОЯЩИЙ GoogleAppsScript.gs: подменяет только Google API
// (SpreadsheetApp/ContentService/LockService/Utilities) на файловую реализацию.
//
// Вызов:  node mock_sheet_server.js '<query-string>' [db.json]
// Печатает JSON-ответ в stdout.

const fs = require('fs');

const DB = process.argv[3] || '/tmp/sfn_sheet.json';

function pad(n) { return String(n).padStart(2, '0'); }

function loadDb() {
  try { return JSON.parse(fs.readFileSync(DB, 'utf8')); }
  catch (e) { return { sheets: {} }; }
}
function saveDb(db) { fs.writeFileSync(DB, JSON.stringify(db)); }

let db = loadDb();

class Range {
  constructor(sheet, row, col, values) {
    this.sheet = sheet; this.row = row; this.col = col; this._v = values;
  }
  getValues() { return this._v; }
  setValues(vals) {
    const s = this.sheet.data();
    for (let r = 0; r < vals.length; r++) {
      for (let c = 0; c < vals[r].length; c++) {
        const rr = this.row + r, cc = this.col + c;
        while (s.rows.length < rr) s.rows.push([]);
        while (s.rows[rr - 1].length < cc) s.rows[rr - 1].push('');
        s.rows[rr - 1][cc - 1] = vals[r][c];
      }
    }
    this.sheet.flush();
    return this;
  }
  setFontWeight() { return this; }
}

class Sheet {
  constructor(name) { this._name = name; }
  data() {
    if (!db.sheets[this._name]) db.sheets[this._name] = { rows: [] };
    return db.sheets[this._name];
  }
  flush() { saveDb(db); }
  getLastRow() { return this.data().rows.length; }
  getLastColumn() {
    return this.data().rows.reduce((m, r) => Math.max(m, r.length), 0);
  }
  getRange(row, col, nRows, nCols) {
    const rows = this.data().rows, values = [];
    for (let r = 0; r < (nRows || 1); r++) {
      const line = [], src = rows[row - 1 + r] || [];
      for (let c = 0; c < (nCols || 1); c++) {
        const v = src[col - 1 + c];
        line.push(v === undefined || v === null ? '' : v);
      }
      values.push(line);
    }
    return new Range(this, row, col, values);
  }
  appendRow(arr) { this.data().rows.push(arr.slice()); this.flush(); return this; }
  setFrozenRows() { return this; }
  deleteRow(row) { this.data().rows.splice(row - 1, 1); this.flush(); return this; }
}

const sheets = {};
global.SpreadsheetApp = {
  getActiveSpreadsheet: () => ({
    getSheetByName: (n) => sheets[n] || null,
    insertSheet: (n) => (sheets[n] = new Sheet(n)),
    getSpreadsheetTimeZone: () => 'UTC',
  }),
};
global.ContentService = {
  MimeType: { JSON: 'application/json' },
  createTextOutput: (s) => ({ _s: s, setMimeType() { return this; }, getContent() { return this._s; } }),
};
global.LockService = { getScriptLock: () => ({ waitLock: () => true, releaseLock: () => {} }) };
global.Utilities = {
  formatDate(d, tz, fmt) {
    return fmt.replace('yyyy', d.getUTCFullYear()).replace('MM', pad(d.getUTCMonth() + 1))
      .replace('dd', pad(d.getUTCDate())).replace('HH', pad(d.getUTCHours()))
      .replace('mm', pad(d.getUTCMinutes())).replace('ss', pad(d.getUTCSeconds()));
  },
  parseDate(s, tz, fmt) {
    const m = String(s).match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?/);
    if (!m) throw new Error('unparsable: ' + s);
    if (fmt.indexOf('ss') < 0 && m[6] !== undefined) throw new Error('format lacks seconds');
    return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)));
  },
};
global.Logger = { log: () => {} };

// восстанавливаем уже известные листы
for (const name of Object.keys(db.sheets)) sheets[name] = new Sheet(name);

let code = fs.readFileSync(__dirname + '/GoogleAppsScript.gs', 'utf8');
code = code.replace(/^var TOKEN = .*$/m, "var TOKEN = 'TESTTOKEN';");
(0, eval)(code + '\n;global.__api = { doGet: doGet, setup: setup };');
global.__api.setup();

// ---------------------------------------------------------- разбор запроса
const qs = String(process.argv[2] || '');
const params = {};
for (const pair of qs.split('&')) {
  if (!pair) continue;
  const i = pair.indexOf('=');
  const k = decodeURIComponent(i < 0 ? pair : pair.slice(0, i));
  const v = i < 0 ? '' : decodeURIComponent(pair.slice(i + 1).replace(/\+/g, ' '));
  params[k] = v;
}

const out = global.__api.doGet({ parameter: params }).getContent();
process.stdout.write(out);
