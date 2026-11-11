/* 成績單完整版資料層測試：node tests/fullreport-api.test.js
 * 用假的 supabase client 載入 js/assess-api.js 與 js/backoffice-api.js（不連網、全是假資料）。
 * 重點：店長／主管走 RPC fullreport_items、前端絕不查機密表 assessment_item_secrets；回傳不含考官信箱、步驟、考點；錯誤會往外丟。 */
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

// 假 supabase：記錄所有查詢過的資料表與 RPC；tables 給各表回傳的資料；rpcResult 給 RPC 結果
function makeEnv(tables, rpcResult) {
  var log = { tables: [], rpcs: [], selects: [] };
  function chain(table) {
    var q = { select: function (c) { log.selects.push(table + ':' + c); return q; }, eq: function () { return q; }, in: function () { return q; }, order: function () { return q; }, range: function () { return q; },
      then: function (res, rej) { return Promise.resolve({ data: tables[table] || [], error: null }).then(res, rej); } };
    return q;
  }
  var sb = {
    from: function (t) { log.tables.push(t); return chain(t); },
    rpc: function (name, args) { log.rpcs.push({ name: name, args: args }); return Promise.resolve(rpcResult); },
    storage: { from: function () { return {}; } },
    auth: {}
  };
  var win = { APP_CONFIG: { SUPABASE_URL: 'http://localhost', SUPABASE_KEY: 'k' }, supabase: { createClient: function () { return sb; } } };
  var ctx = vm.createContext({ window: win, console: console, setTimeout: setTimeout, Promise: Promise });
  ['assess-api.js', 'backoffice-api.js'].forEach(function (f) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'js', f), 'utf8'), ctx, { filename: f });
  });
  return { win: win, log: log };
}

var ITEMS = [
  { id: 'i1', seq: 1, category: '分類甲', code: 'ZZ1', levels: { '問題掌握': '待加強' }, item_score: 70, dim_points: {}, note: '題組備註甲', note_url: null, is_extra: false },
  { id: 'i2', seq: 2, category: '分類乙', code: 'ZZ2', levels: { '問題掌握': '優' }, item_score: 90, dim_points: {}, note: null, note_url: null, is_extra: true }
];
var RPC_OK = { data: [
  { item_id: 'i1', assessment_id: 'a1', title: '假題名甲', dim_notes: { '問題掌握': '面向備註甲' } },
  { item_id: 'i2', assessment_id: 'a1', title: '假題名乙', dim_notes: {} }
], error: null };

(async function () {
  // ---- loadItemsFullReport ----
  var e = makeEnv({ assessment_items: ITEMS, assessment_item_images: [] }, RPC_OK);
  var items = await e.win.AssessApi.loadItemsFullReport('a1');
  eq(e.log.rpcs, [{ name: 'fullreport_items', args: { p_assessment_ids: ['a1'] } }], '完整版：呼叫 fullreport_items 且只帶這一張成績單 id');
  ok(e.log.tables.indexOf('assessment_item_secrets') < 0, '完整版：前端不直接查機密表');
  eq(items.map(function (i) { return i.title; }), ['假題名甲', '假題名乙'], '完整版：帶題目名稱');
  eq(items[0].dimNotes, { '問題掌握': '面向備註甲' }, '完整版：帶面向備註');
  eq(items[0].note, '題組備註甲', '完整版：帶題組備註');
  eq(items[1].isExtra, true, '完整版：加考題旗標保留');
  eq(items[1].dimNotes, {}, '完整版：沒有面向備註（舊單式）為空物件');
  ok(JSON.stringify(items).indexOf('examiner') < 0 && JSON.stringify(items).indexOf('steps') < 0, '完整版：結果不含考官信箱與步驟考點欄位');

  // RPC 沒回某題（例如函式被改窄）：題名空字串、備註空物件，不報錯
  var e2 = makeEnv({ assessment_items: ITEMS, assessment_item_images: [] }, { data: [], error: null });
  var items2 = await e2.win.AssessApi.loadItemsFullReport('a1');
  eq([items2[0].title, items2[0].dimNotes], ['', {}], 'RPC 沒回資料：題名空、備註空物件');
  var e2b = makeEnv({ assessment_items: ITEMS, assessment_item_images: [] }, { data: [{ item_id: 'i1', title: null, dim_notes: null }], error: null });
  var items2b = await e2b.win.AssessApi.loadItemsFullReport('a1');
  eq([items2b[0].title, items2b[0].dimNotes], ['', {}], 'RPC 回 null 題名與 null 備註：不報錯');

  // RPC 失敗：錯誤往外丟（不默默降級）
  var e3 = makeEnv({ assessment_items: ITEMS, assessment_item_images: [] }, { data: null, error: { code: 'P0001', message: '沒有權限' } });
  var threw = null;
  try { await e3.win.AssessApi.loadItemsFullReport('a1'); } catch (err) { threw = err; }
  ok(threw && typeof threw.userMessage === 'string' && threw.userMessage.length > 0, 'RPC 失敗：往外丟帶白話訊息的錯誤');

  // ---- loadReportItems（PDF 用）----
  var ROWS = [
    { id: 'i1', assessment_id: 'a1', seq: 1, category: '分類甲', code: 'ZZ1', levels: {}, item_score: 70, is_extra: false, note: '題組備註甲' },
    { id: 'i2', assessment_id: 'a1', seq: 2, category: '分類乙', code: 'ZZ2', levels: {}, item_score: 80, is_extra: false, note: null }
  ];
  var b1 = makeEnv({ assessment_items: ROWS }, RPC_OK);
  var by1 = await b1.win.BackofficeApi.loadReportItems(['a1'], true, true);
  eq(b1.log.rpcs, [{ name: 'fullreport_items', args: { p_assessment_ids: ['a1'] } }], 'PDF 店長／主管：走 fullreport_items');
  ok(b1.log.tables.indexOf('assessment_item_secrets') < 0, 'PDF 店長／主管：不查機密表');
  eq(by1.a1.map(function (i) { return i.title; }), ['假題名甲', '假題名乙'], 'PDF 店長／主管：帶題名');
  eq(by1.a1[0].dimNotes, { '問題掌握': '面向備註甲' }, 'PDF 店長／主管：帶面向備註');
  eq(by1.a1.map(function (i) { return i.note; }), ['題組備註甲', ''], 'PDF 店長／主管：帶題組備註（null 變空字串）');

  var b2 = makeEnv({ assessment_items: ROWS, assessment_item_secrets: [{ item_id: 'i1', title: '機密題名', dim_notes: { '問題掌握': 'N' } }] }, RPC_OK);
  var by2 = await b2.win.BackofficeApi.loadReportItems(['a1'], true, false);
  eq(b2.log.rpcs, [], 'PDF 客服部：不呼叫 RPC');
  ok(b2.log.tables.indexOf('assessment_item_secrets') >= 0, 'PDF 客服部：維持直接讀機密表');
  eq(by2.a1[0].title, '機密題名', 'PDF 客服部：題名來自機密表');
  eq(Object.prototype.hasOwnProperty.call(by2.a1[0], 'note'), false, 'PDF 客服部：維持原樣、不多帶題組備註');

  var b3 = makeEnv({ assessment_items: ROWS }, RPC_OK);
  var by3 = await b3.win.BackofficeApi.loadReportItems(['a1'], false);
  eq(b3.log.rpcs, [], '建議單（withTitle=false）：不呼叫 RPC');
  ok(b3.log.tables.indexOf('assessment_item_secrets') < 0, '建議單：不查機密表');
  eq([Object.prototype.hasOwnProperty.call(by3.a1[0], 'title'), Object.prototype.hasOwnProperty.call(by3.a1[0], 'note')], [false, false], '建議單：不帶題名與備註');

  var b4 = makeEnv({ assessment_items: ROWS }, { data: null, error: { code: '42501', message: 'permission denied' } });
  var threw2 = null;
  try { await b4.win.BackofficeApi.loadReportItems(['a1'], true, true); } catch (err) { threw2 = err; }
  ok(threw2 && threw2.userMessage, 'PDF RPC 失敗：往外丟錯（PDF 會顯示失敗訊息，不印不完整的版本）');

  // ---- 成績單列表：店長／主管不要求考官信箱欄位（網路回應也不帶）----
  var s1 = makeEnv({ assessment_summaries: [] }, RPC_OK);
  await s1.win.AssessApi.loadSummaries(false);
  ok(s1.log.selects.length === 1 && s1.log.selects[0].indexOf('examiner') < 0, '列表（店長／主管）：select 欄位不含考官信箱');
  var s2 = makeEnv({ assessment_summaries: [] }, RPC_OK);
  await s2.win.AssessApi.loadSummaries(true);
  ok(s2.log.selects[0].indexOf('examiner_email') >= 0, '列表（客服部）：照舊含考官信箱');
  var s3 = makeEnv({ assessment_summaries: [] }, RPC_OK);
  await s3.win.AssessApi.loadSummaries();
  ok(s3.log.selects[0].indexOf('examiner') < 0, '列表沒傳參數：預設不含考官信箱（保守）');
  // 完整版詳情與 PDF 的所有查詢欄位都不含考官信箱
  ok(e.log.selects.every(function (x) { return x.indexOf('examiner') < 0; }), '完整版詳情：所有查詢欄位都不含考官信箱');
  ok(b1.log.selects.every(function (x) { return x.indexOf('examiner') < 0; }), '完整版 PDF：所有查詢欄位都不含考官信箱');

  console.log('通過 ' + passed + ' 項');
})().catch(function (err) { console.error(err); process.exit(1); });
