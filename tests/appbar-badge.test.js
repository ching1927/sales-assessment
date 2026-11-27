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
  var reqTab = makeEl(), boTab = makeEl(), spotTab = makeEl(), email = makeEl(), av = makeEl();
  var moves = [];
  if (opts.withParent) { boTab.parentNode = { insertBefore: function (a, b) { moves.push([a === reqTab ? 'req' : 'other', b === boTab ? 'bo' : 'other']); } }; }
  email.textContent = 'bl-sm1@2motor.tw';
  var calls = [], storageWrites = [];
  var doc = {
    getElementById: function (id) { return id === 'whoEmail' ? email : id === 'whoAvatar' ? av : null; },
    querySelector: function (sel) {
      if (sel === 'a.ab-tab[href="requests.html"]') return reqTab;
      if (sel === 'a.ab-tab[href="backoffice.html"]') return opts.noBackoffice ? null : boTab;
      if (sel === 'a.ab-tab[href="spotcheck.html"]') return opts.noSpot ? null : spotTab;
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
  return { win: win, reqBadge: reqTab.children[0], boBadge: boTab.children[0], spotBadge: spotTab.children[0], calls: calls, storageWrites: storageWrites, moves: moves };
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
  eq(a.reqBadge.textContent, '2', '待考回報紅點＝exam_req_badge（新語意已含已輔導未約考，不再加 coached_pending_count）');
  eq(a.calls.indexOf('coached_pending_count'), -1, '不再呼叫 coached_pending_count');
  eq(a.reqBadge.hidden, false, '待考回報紅點顯示');
  eq(a.boBadge.textContent, '3', '成績單&考核後台紅點＝improve_badge');
  eq(a.boBadge.hidden, false, '成績單&考核後台紅點顯示');
  eq(a.calls.indexOf('improve_badge') >= 0 && a.calls.indexOf('exam_req_badge') >= 0, true, '兩個 RPC 都有呼叫');

  // 2. 「點進去」＝頁面再載入／再重抓：資料庫仍給同樣數字，紅點不會自己消；不寫任何 storage
  await a.win.AppBadge.refresh(); await tick();
  eq(a.reqBadge.textContent, '2', '重抓後待考回報紅點仍在');
  eq(a.boBadge.textContent, '3', '重抓後回填輔導紀錄紅點仍在');
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
  eq(b.boBadge.hidden, false, '回填輔導紀錄紅點不受影響');
  rpcState.im = 0; await b.win.AppBadge.refresh(); await tick();
  eq([b.boBadge.hidden, b.boBadge.textContent], [true, ''], '複檢完成→回填輔導紀錄紅點消');

  // 4. 超過 99 顯示 99+
  var c = run({ exam_req_badge: { data: 0, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: { data: 150, error: null } });
  await tick();
  eq(c.boBadge.textContent, '99+', '超過 99 顯示 99+');

  // 5. improve_badge 失敗（資料庫還沒更新）：安靜略過，待考回報紅點照常
  var d = run({ exam_req_badge: { data: 4, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: { data: null, error: { message: 'x' } } });
  await tick();
  eq(d.reqBadge.textContent, '4', 'improve_badge 失敗時待考回報紅點照常');
  eq(d.boBadge.hidden, true, 'improve_badge 失敗時回填輔導紀錄紅點維持隱藏');
  var e = run({ exam_req_badge: { data: 4, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: function () { return Promise.reject(new Error('網路')); } });
  await tick();
  eq(e.reqBadge.textContent, '4', 'improve_badge 丟例外時待考回報紅點照常');

  // 6. exam_req_badge 失敗：待考回報紅點不顯示，但改善單紅點仍照 improve_badge
  var f = run({ exam_req_badge: { data: null, error: { message: 'x' } }, improve_badge: { data: 2, error: null } });
  await tick();
  eq([f.reqBadge.hidden, f.boBadge.textContent], [true, '2'], 'exam_req_badge 失敗不影響回填輔導紀錄紅點');

  // 7. 頁面上沒有「成績單&考核後台」分頁：不報錯、不呼叫 improve_badge
  var g = run({ exam_req_badge: { data: 1, error: null }, coached_pending_count: { data: 0, error: null }, improve_badge: { data: 9, error: null } }, { noBackoffice: true });
  await tick();
  eq([g.reqBadge.textContent, g.boBadge === undefined, g.calls.indexOf('improve_badge')], ['1', true, -1], '沒有後台分頁時只做待考回報紅點');

  // 8. 第三顆紅點：登記&健檢（spot_badge）
  var h = run({ exam_req_badge: { data: 1, error: null }, improve_badge: { data: 2, error: null }, spot_badge: { data: 5, error: null } });
  await tick();
  eq([h.spotBadge.textContent, h.spotBadge.hidden], ['5', false], '登記&健檢紅點＝spot_badge');
  eq([h.reqBadge.textContent, h.boBadge.textContent], ['1', '2'], '第三顆不影響另外兩顆');
  await h.win.AppBadge.refresh(); await tick();
  eq(h.spotBadge.textContent, '5', '重抓後健檢紅點仍在');
  eq(h.storageWrites, [], '三顆紅點都不寫 storage');
  var i = run({ exam_req_badge: { data: 1, error: null }, improve_badge: { data: 2, error: null } });
  await tick();
  eq([i.spotBadge.hidden, i.reqBadge.textContent, i.boBadge.textContent], [true, '1', '2'], '資料庫沒有 spot_badge：健檢紅點隱藏、其他照常');
  var j = run({ exam_req_badge: { data: 1, error: null }, spot_badge: function () { return Promise.reject(new Error('網路')); } });
  await tick();
  eq([j.spotBadge.hidden, j.reqBadge.textContent], [true, '1'], 'spot_badge 丟例外時安靜略過');
  var k = run({ exam_req_badge: { data: 1, error: null }, spot_badge: { data: 9, error: null } }, { noSpot: true });
  await tick();
  eq([k.spotBadge === undefined, k.calls.indexOf('spot_badge'), k.reqBadge.textContent], [true, -1, '1'], '沒有健檢分頁時不呼叫 spot_badge');
  var l = run({ exam_req_badge: { data: 0, error: null }, spot_badge: { data: 150, error: null } });
  await tick();
  eq(l.spotBadge.textContent, '99+', '健檢紅點超過 99 顯示 99+');

    // 9. 店長端導覽順序：待考回報移到成績單&考核後台前面；其他角色、失敗、沒有父節點都維持原順序
  var m1 = run({ exam_req_badge: { data: 1, error: null }, roster_my_role: { data: 'store_manager', error: null } }, { withParent: true });
  await tick();
  eq(m1.moves, [['req', 'bo']], '店長：待考回報移到成績單&考核後台前面');
  await m1.win.AppBadge.refresh(); await tick();
  eq(m1.moves.length, 1, '店長：重抓紅點不會重複搬');
  var m2 = run({ exam_req_badge: { data: 1, error: null }, roster_my_role: { data: 'cs_admin', error: null } }, { withParent: true });
  await tick();
  eq(m2.moves, [], '客服部：順序不變');
  var m3 = run({ exam_req_badge: { data: 1, error: null }, roster_my_role: { data: 'hq_viewer', error: null } }, { withParent: true });
  await tick();
  eq(m3.moves, [], '總公司主管：順序不變');
  var m4 = run({ exam_req_badge: { data: 1, error: null }, roster_my_role: { data: null, error: { message: 'x' } } }, { withParent: true });
  await tick();
  eq([m4.moves, m4.reqBadge.textContent], [[], '1'], '查角色失敗：順序不變、紅點照常');
  var m5 = run({ exam_req_badge: { data: 1, error: null }, roster_my_role: function () { return Promise.reject(new Error('網路')); } }, { withParent: true });
  await tick();
  eq([m5.moves, m5.reqBadge.textContent], [[], '1'], '查角色丟例外：順序不變、紅點照常');
  eq(m1.storageWrites, [], '搬順序不寫 storage');

  console.log('appbar-badge 測試通過：' + passed + ' 項');
})().catch(function (err) { console.error(err); process.exit(1); });
