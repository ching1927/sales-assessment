/* 輔導紀錄編輯版本資料層測試：node tests/coach-history-api.test.js
 * 用假的 supabase client 載入 js/backoffice-api.js（不連網、全是假資料）。
 * 重點：讀版本只走 RPC improve_coach_versions（不直接查版本表）、參數名稱正確、錯誤轉成白話並往外丟、
 *       版本標題（目前／首次回填）、markCoached 簽名不變。 */
var assert = require('node:assert');
var fs = require('fs');
var path = require('path');
var vm = require('vm');

var passed = 0;
function eq(actual, expected, label) {
  actual = JSON.parse(JSON.stringify(actual === undefined ? null : actual)); expected = JSON.parse(JSON.stringify(expected));
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function ok(cond, label) { assert.ok(cond, label); passed++; }

function makeEnv(rpcResult) {
  var log = { tables: [], rpcs: [] };
  var sb = {
    from: function (t) { log.tables.push(t); throw new Error('不該直接查資料表：' + t); },
    rpc: function (name, args) { log.rpcs.push({ name: name, args: args }); return Promise.resolve(rpcResult); },
    storage: { from: function () { return {}; } }, auth: {}
  };
  var win = { APP_CONFIG: { SUPABASE_URL: 'http://localhost', SUPABASE_KEY: 'k' }, supabase: { createClient: function () { return sb; } } };
  var ctx = vm.createContext({ window: win, console: console, setTimeout: setTimeout, Promise: Promise });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'js', 'backoffice-api.js'), 'utf8'), ctx, { filename: 'backoffice-api.js' });
  return { api: win.BackofficeApi, log: log };
}

var ROWS = [
  { version_no: 3, coached_on: '2026-11-12', coach_note: '第三版', edited_at: '2026-11-16T10:40:00Z', editor_label: '示範B-小店長', edited_by: null, is_current: true },
  { version_no: 2, coached_on: '2026-11-12', coach_note: '第二版', edited_at: '2026-11-13T01:10:00Z', editor_label: '示範B-小店長', edited_by: null, is_current: false },
  { version_no: 1, coached_on: '2026-11-12', coach_note: '第一版', edited_at: '2026-11-12T12:05:00Z', editor_label: '示範B-小店長', edited_by: null, is_current: false }
];

(async function () {
  // 讀版本：走 RPC、參數正確、原樣回傳（新到舊的順序由資料庫決定，前端不重排）
  var e = makeEnv({ data: ROWS, error: null });
  var got = await e.api.coachVersions('tk-1');
  eq(e.log.rpcs, [{ name: 'improve_coach_versions', args: { p_ticket_id: 'tk-1' } }], '只呼叫 improve_coach_versions，參數 p_ticket_id');
  eq(got.map(function (r) { return r.version_no; }), [3, 2, 1], '版本順序照資料庫給的（3、2、1）');
  eq(e.log.tables, [], '沒有直接查任何資料表');

  // 沒資料 → 空陣列
  e = makeEnv({ data: null, error: null });
  eq(await e.api.coachVersions('tk-1'), [], '沒有版本回空陣列');

  // 沒有權限：資料庫丟「沒有權限」→ 轉成白話並往外丟
  e = makeEnv({ data: null, error: { code: 'P0001', message: '沒有權限' } });
  var err = null; try { await e.api.coachVersions('tk-1'); } catch (x) { err = x; }
  ok(err && /沒有這個操作的權限/.test(err.message), '沒有權限會丟出白話訊息：' + (err && err.message));

  // 函式還不存在（資料庫尚未執行 coach_history_schema.sql）→ 一樣丟錯，不回空資料
  e = makeEnv({ data: null, error: { code: 'PGRST202', message: 'Could not find the function public.improve_coach_versions' } });
  err = null; try { await e.api.coachVersions('tk-1'); } catch (x) { err = x; }
  ok(err && /系統發生問題/.test(err.message) && !/improve_coach_versions/.test(err.message), '函式不存在丟白話訊息，不洩漏函式名稱');

  // 版本標題
  e = makeEnv({ data: [], error: null });
  var T = e.api.coachVersionTitle;
  eq(T(ROWS[0]), '第 3 版（目前）', '目前版標題');
  eq(T(ROWS[1]), '第 2 版', '中間版標題');
  eq(T(ROWS[2]), '第 1 版（首次回填）', '首次回填標題');
  eq(T({ version_no: 1, is_current: true }), '第 1 版（目前、首次回填）', '只有一版：目前＋首次回填');
  eq(T({ version_no: '2', is_current: false }), '第 2 版', '序號是字串也行');

  // markCoached 簽名與參數名稱沒變
  e = makeEnv({ data: null, error: null });
  await e.api.markCoached('tk-9', '2026-11-12', '備註');
  eq(e.log.rpcs, [{ name: 'improve_mark_coached', args: { p_ticket_id: 'tk-9', p_coached_on: '2026-11-12', p_note: '備註' } }], 'markCoached 呼叫 improve_mark_coached，三個參數不變');

  console.log('coach-history-api：' + passed + ' 項通過');
})().catch(function (x) { console.error('失敗：' + x.message); process.exit(1); });
