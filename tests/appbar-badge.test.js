/* 導覽紅點（js/appbar.js）測試：node tests/appbar-badge.test.js
 * 用最小的假 DOM＋假 supabase 執行 appbar.js，確認：兩顆紅點（待考回報、成績單&考核後台）各呼叫對的 RPC、
 * 數字照資料庫給的顯示、點進去（重新整理、頁面載入）不會自己把紅點清掉、不寫任何 storage、improve_badge 失敗時安靜略過。
 * 全部是假資料。 */
var assert = require('node:assert');
var fs = require('fs');
var path = require('path');
var vm = require('vm');

var SRC = fs.readFileSync(path.join(__dirname, '..', 'js', 'appbar.js'), 'utf8');
var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

function makeEl() {
  var el = { children: [], hidden: false, textContent: '', className: '', attrs: {} };
  el.appendChild = function (c) { el.children.push(c); return c; };
  el.setAttribute = function (k, v) { el.attrs[k] = v; };
  return el;
}

// rpcs：{ rpc名稱: 回傳的 {data,error} 或函式 }
function run(rpcs, opts) {
  opts = opts || {};
  var reqTab = makeEl(), boTab = makeEl(), email = makeEl(), av = makeEl();
  email.textContent = 'bl-sm1@2motor.tw';
  var calls = [], storageWrites = [];
  var doc = {
    getElementById: function (id) { return id === 'whoEmail' ? email : id === 'whoAvatar' ? av : null; },
    querySelector: function (sel) {
      if (sel === 'a.ab-tab[href="requests.html"]') return reqTab;
      if (sel === 'a.ab-tab[href="backoffice.html"]') return opts.noBackoffice ? null : boTab;
      return null;
    },
    createElement: function () { return makeEl(); }
  };
  var win = {
    APP_CONFIG: { SUPABASE_URL: 'https://abcdef.supabase.co', SUPABASE_KEY: 'k' },
    localStorage: {
      getItem: function () { return JSON.stringify({ access_token: 'tok' }); },
      setItem: function (k) { storageWrites.push(k); },
      removeItem: function (k) { storageWrites.push(k); }
    },
    supabase: {
      createClient: function () {
        return { rpc: function (name) {
          calls.push(name);
          var v = rpcs[name];
          if (typeof v === 'function') return v();
          return Promise.resolve(v || { data: null, error: { message: '沒有這個函式' } });
        } };
      }
    }
  };
  var ctx = { document: doc, window: win, MutationObserver: function () { this.observe = function () {}; }, Promise: Promise, Number: Number, String: String, Math: Math, JSON: JSON };
  vm.runInNewContext(SRC, ctx);
  return { win: win, reqBadge: reqTab.children[0], boBadge: boTab.children[0], calls: calls, storageWrites: storageWrites };
}
function tick() { return new Promise(function (r) { setTimeout(r, 0); }); }

(async function () {
  // 1. 兩顆紅點各顯示資料庫給的數字
  var a = run({
    exam_req_badge: { data: 2, error: null },
    coached_pending_count: { data: 1, error: null },
    improve_badge: { data: 3, error: null }
  });
  await tick();
  eq(a.reqBadge.textContent, '3', '待考回報紅點＝exam_req_badge＋coached_pending_count');
  eq(a.reqBadge.hidden, false, '待考回報紅點顯示');
  eq(a.boBadge.textContent, '3', '成績單&考核後台紅點＝improve_badge');
  eq(a.boBadge.hidden, false, '成績單&考核後台紅點顯示');
  eq(a.calls.indexOf('improve_badge') >= 0 && a.calls.indexOf('exam_req_badge') >= 0, true, '兩個 RPC 都有呼叫');

  // 2. 「點進去」＝頁面再載入／再重抓：資料庫仍給同樣數字，紅點不會自己消；不寫任何 storage
  await a.win.AppBadge.refresh(); await tick();
  eq(a.reqBadge.textContent, '3', '重抓後待考回報紅點仍在');
  eq(a.boBadge.textContent, '3', '重抓後改善單紅點仍在');
  eq(a.storageWrites, [], '不寫任何 localStorage');

  // 3. 資料庫數字變 0（例如新人已上線、複檢完成）才消
  var rpcState = { ex: 1, im: 1 };
  var b = run({
    exam_req_badge: function () { return Promise.resolve({ data: rpcState.ex, error: null }); },
    coached_pending_count: { data: 0, error: null },
    improve_badge: function () { return Promise.resolve({ data: rpcState.im, error: null }); }
  });
  await tick();
  eq([b.reqBadge.hidden, b.boBadge.hidden], [false, false], '一開始兩顆都在');
  rpcState.ex = 0; await b.win.AppBadge.refresh(); await tick();
  eq([b.reqBadge.hidden, b.reqBadge.textContent], [true, ''], '新人已上線→待考回報紅點消');
  eq(b.boBadge.hidden, false, '改善單紅點不受影響');
  rpcState.im = 0; await b.win.AppBadge.refresh(); await tick();
  eq([b.boBadge.hidden, b.boBadge.textContent], [true, ''], '複檢完成→改善單紅點消');

  // 4. 超過 99 顯示 99+
  var c = run({ exam_req_badge: { data: 0, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: { data: 150, error: null } });
  await tick();
  eq(c.boBadge.textContent, '99+', '超過 99 顯示 99+');

  // 5. improve_badge 失敗（資料庫還沒更新）：安靜略過，待考回報紅點照常
  var d = run({ exam_req_badge: { data: 4, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: { data: null, error: { message: 'x' } } });
  await tick();
  eq(d.reqBadge.textContent, '4', 'improve_badge 失敗時待考回報紅點照常');
  eq(d.boBadge.hidden, true, 'improve_badge 失敗時改善單紅點維持隱藏');
  var e = run({ exam_req_badge: { data: 4, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: function () { return Promise.reject(new Error('網路')); } });
  await tick();
  eq(e.reqBadge.textContent, '4', 'improve_badge 丟例外時待考回報紅點照常');

  // 6. exam_req_badge 失敗：待考回報紅點不顯示，但改善單紅點仍照 improve_badge
  var f = run({ exam_req_badge: { data: null, error: { message: 'x' } }, improve_badge: { data: 2, error: null } });
  await tick();
  eq([f.reqBadge.hidden, f.boBadge.textContent], [true, '2'], 'exam_req_badge 失敗不影響改善單紅點');

  // 7. 頁面上沒有「成績單&考核後台」分頁：不報錯、不呼叫 improve_badge
  var g = run({ exam_req_badge: { data: 1, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: { data: 9, error: null } }, { noBackoffice: true });
  await tick();
  eq([g.reqBadge.textContent, g.boBadge === undefined, g.calls.indexOf('improve_badge')], ['1', true, -1], '沒有後台分頁時只做待考回報紅點');

  console.log('appbar-badge 測試通過：' + passed + ' 項');
})().catch(function (err) { console.error(err); process.exit(1); });
