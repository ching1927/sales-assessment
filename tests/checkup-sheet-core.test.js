/* 健檢單純函式測試：node tests/checkup-sheet-core.test.js
 * 「現在」一律傳固定值，結果可重現。 */
var assert = require('node:assert');
var S = require('../js/checkup-sheet-core.js');
var D = require('../js/spotdims-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function ok(cond, label) { assert.ok(cond, label); passed++; }

// ---- 日曆季範圍 ----
eq(S.quarterRange(2026, 1), { start: '2026-01-01', end: '2026-03-31' }, 'Q1');
eq(S.quarterRange(2026, 2), { start: '2026-04-01', end: '2026-06-30' }, 'Q2');
eq(S.quarterRange(2026, 3), { start: '2026-07-01', end: '2026-09-30' }, 'Q3');
eq(S.quarterRange(2026, 4), { start: '2026-10-01', end: '2026-12-31' }, 'Q4');
eq(S.quarterRange(2024, 1), { start: '2024-01-01', end: '2024-03-31' }, '閏年 Q1 仍是 3/31 結束');
eq(S.quarterRange('2026', '4'), { start: '2026-10-01', end: '2026-12-31' }, '字串年季也可');
eq(S.quarterRange(2026, 5), null, '季次 5 不合法');
eq(S.quarterRange(2026, 0), null, '季次 0 不合法');
eq(S.quarterRange(2026, 1.5), null, '季次小數不合法');
eq(S.quarterRange(1999, 1), null, '年度太小不合法');
eq(S.quarterRange(null, 1), null, 'null 年度不合法');
eq(S.quarterLabel(2026, 3), '2026 年第 3 季（7–9 月）', 'Q3 標題');
eq(S.quarterLabel(2026, 4), '2026 年第 4 季（10–12 月）', 'Q4 標題');

// ---- 面向次數與被勾最多 ----
var DIMS = D.DIMS;
eq(S.dimCounts([]), [0, 0, 0, 0, 0, 0, 0], '沒有紀錄全 0');
eq(S.dimCounts([{ improve_dims: ['問題掌握', '亂寫'] }, { improve_dims: ['問題掌握', '資訊正確性'] }, { improve_dims: [] }, {}]),
  [1, 0, 2, 0, 0, 0, 0], '算次數、忽略不認得與空值');
eq(S.dimCounts([{ improve_dims: ['問題掌握', '問題掌握'] }]), [0, 0, 1, 0, 0, 0, 0], '同一筆重複只算一次');
eq(S.topDims([0, 0, 0, 0, 0, 0, 0]), [], '全 0 沒有被勾最多');
eq(S.topDims([3, 0, 1, 0, 0, 0, 0]), ['資訊正確性'], '單一最多');
eq(S.topDims([2, 0, 2, 0, 0, 0, 2]), ['資訊正確性', '問題掌握', '文字品質'], '並列全列，依七面向順序');
eq(S.topDims(null), [], 'null 回空');

// ---- 彙整 ----
function R(id, emp, store, day, verdict, dims, extra) {
  var r = { id: id, employee_id: emp, employee_label: '範例' + emp.slice(-1), store_code: store, checked_on: day, verdict: verdict,
    improve_dims: dims || [], improve_note: '', shot_paths: [], total_score: null, created_at: day + 'T01:00:00Z' };
  Object.keys(extra || {}).forEach(function (k) { r[k] = extra[k]; });
  return r;
}
var ROWS = [
  R('r3', 'MI-0002', '新莊', '2026-09-19', '不適當', ['資訊正確性', '主動引導']),
  R('r1', 'MI-0002', '新莊', '2026-07-08', '適當', ['主動引導']),
  R('r2', 'MI-0002', '新莊', '2026-07-22', '不適當', ['資訊正確性', '風險意識'], { improve_note: '  保固報錯  ', shot_paths: ['spot/a/b.jpg'] }),
  R('r4', 'MI-0001', '中和', '2026-08-01', '適當', []),
  R('r5', 'MI-0009', '台南', '2026-08-02', '適當', ['文字品質']),
  R('r6', 'MI-0003', '新莊', '2026-08-02', '適當', [])
];
var sum = S.summarize(ROWS);
eq(sum.map(function (s) { return s.employee_id; }), ['MI-0001', 'MI-0002', 'MI-0003', 'MI-0009'], '依門市順序（中和、新莊、台南）再員編');
var s2 = sum[1];
eq([s2.total, s2.good, s2.weak], [3, 1, 2], '次數與優良／待加強');
eq(s2.counts, [2, 0, 0, 2, 1, 0, 0], '面向被勾次數');
eq(s2.top, ['資訊正確性', '主動引導'], '被勾最多並列');
eq(s2.records.map(function (r) { return r.id; }), ['r1', 'r2', 'r3'], '紀錄依日期由舊到新');
eq(sum[0].top, [], '沒勾面向的人沒有被勾最多');
eq(S.summarize([]), [], '沒有紀錄沒有人（沒紀錄的不出現）');
eq(S.summarize(null), [], 'null 沒有人');
eq(S.summarize([{ employee_id: '', checked_on: '2026-07-01' }, { employee_id: 'MI-0001' }]), [], '缺員編或日期的列忽略');
eq(S.filterByStore(sum, '新莊').map(function (s) { return s.employee_id; }), ['MI-0002', 'MI-0003'], '門市篩選');
eq(S.filterByStore(sum, '').length, 4, '空字串＝全部');
// 同一人跨門市：以最新一筆的門市為準
var moved = S.summarize([R('m1', 'MI-0005', '中和', '2026-07-01', '適當'), R('m2', 'MI-0005', '新莊', '2026-09-01', '適當')]);
eq(moved[0].store_code, '新莊', '調店者以最新一筆門市為準');
// 同日同 created_at 以 id 穩定排序
var tie = S.summarize([R('b', 'MI-0001', '中和', '2026-07-01', '適當'), R('a', 'MI-0001', '中和', '2026-07-01', '適當')]);
eq(tie[0].records.map(function (r) { return r.id; }), ['a', 'b'], '同日同時間依 id 排序');

// ---- PDF 內容 ----
var NOW = Date.parse('2026-10-02T09:00:00+08:00');
var m = S.buildModel(s2, { year: 2026, quarter: 3, storeName: '新莊店', nowMs: NOW });
eq([m.name, m.id, m.store, m.quarterText], ['範例2', 'MI-0002', '新莊店', '2026 年第 3 季（7–9 月）'], '標題資料');
eq([m.total, m.good, m.weak], [3, 1, 2], '次數');
eq(m.generated, '2026-10-02', '產生日期（台北）');
eq(m.records[1].verdict, '待加強回覆', '判定顯示名（待加強回覆）');
eq(m.records[0].verdict, '優良回覆', '判定顯示名（優良回覆）');
eq(m.records[1].isWeak, true, '待加強旗標');
eq(m.records[1].note, '保固報錯', '說明去頭尾空白');
eq(m.records[1].shots, ['spot/a/b.jpg'], '截圖路徑');
eq(m.records[0].shots, [], '沒截圖');
eq(m.records[1].dims, ['資訊正確性', '風險意識'], '面向依七面向順序');
eq(m.records[0].legacy, null, '新制沒有舊制分數');
var m2 = S.buildModel(S.summarize([R('x', 'MI-0001', '中和', '2026-07-01', '適當', [], { total_score: 78.5, shot_paths: ['spot/x/1.jpg', 'evil/path.jpg', 5] })])[0], { year: 2026, quarter: 3, nowMs: NOW });
eq(m2.records[0].legacy, 78.5, '舊制紀錄帶舊制分數');
eq(m2.records[0].shots, ['spot/x/1.jpg'], '只收 spot/ 開頭的路徑');
eq(m2.store, '中和', '沒給門市名稱用代碼');
var many = [];
for (var i = 0; i < 12; i++) many.push('spot/x/' + i + '.jpg');
eq(S.buildModel(S.summarize([R('y', 'MI-0001', '中和', '2026-07-01', '適當', [], { shot_paths: many })])[0], { year: 2026, quarter: 3, nowMs: NOW }).records[0].shots.length, D.MAX_SHOTS, '截圖最多 10 張');
eq(S.fileName(m), '健檢單_範例2_2026Q3.pdf', '檔名');
eq(S.fileName({ name: 'a/b:c', year: 2026, quarter: 1 }), '健檢單_a_b_c_2026Q1.pdf', '檔名去掉不允許字元');

// ---- 面向分數（新算法：1 − 被勾次數 ÷ 登記次數，越外圈越好）----
var near = function (a, b) { return Math.abs(a - b) < 1e-9; };
var M8 = { checks: 8, weak: 3, counts: [4, 2, 5, 1, 3, 0, 2] };
var sc8 = S.scoreOf(M8);
[0.5, 0.75, 0.375, 0.875, 0.625, 1, 0.75].forEach(function (v, i) { ok(near(sc8[i], v), '手算分數 ' + D.DIMS[i] + '＝' + v); });
eq(S.pct(sc8[2]), 38, '37.5% 進位顯示 38');
eq(S.scoreOf({ checks: 0, weak: 0, counts: [0, 0, 0, 0, 0, 0, 0] }), null, '登記 0 筆不產生');
eq(S.scoreOf(null), null, 'null 不產生');
eq(S.scoreOf({ checks: 5, weak: 0, counts: [0, 0, 0, 0, 0, 0, 0] }), [1, 1, 1, 1, 1, 1, 1], '整季沒被勾＝全 100%（最外圈）');
eq(S.scoreOf({ checks: 2, weak: 2, counts: [2, 2, 2, 2, 2, 2, 2] }), [0, 0, 0, 0, 0, 0, 0], '每次都被勾＝圓心 0%');
eq(S.quarterModel([]), null, '沒紀錄沒有模型');
eq(S.quarterModel(ROWS.filter(function (r) { return r.employee_id === 'MI-0002'; })), { checks: 3, weak: 2, counts: [2, 0, 0, 2, 1, 0, 0] }, '由紀錄算模型');
// 舊制紀錄（沒有 improve_dims）視為未被勾；全舊制不壞
var legacyOnly = S.quarterModel([R('o1', 'MI-0001', '中和', '2026-07-01', '適當', undefined, { improve_dims: null, total_score: 80 }), R('o2', 'MI-0001', '中和', '2026-07-02', '不適當', undefined, { improve_dims: null, total_score: 60 })]);
eq(legacyOnly, { checks: 2, weak: 1, counts: [0, 0, 0, 0, 0, 0, 0] }, '全舊制：登記 2 筆、無勾選');
eq(S.scoreOf(legacyOnly), [1, 1, 1, 1, 1, 1, 1], '全舊制：分數全 100% 不壞');
ok(S.quarterCompareSvg(legacyOnly, null).svg.indexOf('</svg>') > 0, '全舊制仍能畫圖');
eq(S.totalModel([M8, null, { checks: 2, weak: 1, counts: [1, 0, 0, 0, 0, 0, 1] }]), { checks: 10, weak: 4, counts: [5, 2, 5, 1, 3, 0, 3] }, '全年彙整：次數各季加總');
eq(S.totalModel([null, null, null, null]).checks, 0, '全年都沒紀錄');

// ---- 上一季與年度脈絡（含跨年）----
eq(S.prevQuarterOf(2026, 3), { year: 2026, quarter: 2 }, '上一季');
eq(S.prevQuarterOf(2026, 1), { year: 2025, quarter: 4 }, '第一季的上一季是去年第四季');
eq(S.contextRange(2026, 3), { start: '2026-04-01', end: '2026-06-30' }, '第三季抓第二季');
eq(S.contextRange(2026, 1), { start: '2025-10-01', end: '2025-12-31' }, '第一季抓去年第四季');
eq(S.contextRange(2026, 4), { start: '2026-07-01', end: '2026-09-30' }, '第四季的季度健檢單只抓第三季');
eq(S.yearRange(2026), { start: '2026-01-01', end: '2026-12-31' }, '年度健檢單抓全年');
eq(S.yearRange(1999), null, '年度不合法回 null');
var CTX = [
  R('c1', 'MI-0002', '新莊', '2025-11-05', '適當', ['問題掌握']), R('c2', 'MI-0002', '新莊', '2025-12-30', '不適當', []),
  R('c3', 'MI-0002', '新莊', '2026-02-10', '適當', ['文字品質']),
  R('c4', 'MI-0002', '新莊', '2026-05-10', '不適當', ['主動引導']), R('c5', 'MI-0002', '新莊', '2026-06-30', '適當', ['主動引導', '風險意識']),
  R('c6', 'MI-0002', '新莊', '2026-07-08', '適當', ['主動引導']),
  R('c7', 'MI-0001', '中和', '2026-06-01', '適當', ['資訊正確性']),
  R('c8', 'MI-0002', '新莊', '2026-10-05', '適當', ['問題掌握']), R('c9', 'MI-0002', '新莊', '2026-12-31', '不適當', ['資訊正確性'])
];
eq(S.modelFromRows(CTX, 'MI-0002', 2026, 2), { checks: 2, weak: 1, counts: [0, 0, 0, 2, 1, 0, 0] }, '只取這位業務、這一季（含 6/30 邊界）');
eq(S.modelFromRows(CTX, 'MI-0002', 2026, 4).checks, 2, '含 12/31 邊界');
eq(S.modelFromRows(CTX, 'MI-0009', 2026, 2), null, '別人沒紀錄');
var q3sum = S.summarize(ROWS.filter(function (r) { return r.employee_id === 'MI-0002'; }))[0];
var mq3 = S.buildModel(q3sum, { year: 2026, quarter: 3, nowMs: NOW, ctxRows: CTX });
eq([mq3.isQ4, mq3.prevName, mq3.prev.checks], [false, '第二季', 2], '第三季對比第二季');
eq(mq3.yearQs, null, '第三季沒有年度頁');
eq(mq3.yearAnalysis, null, '第三季沒有年度分析');
var mnone = S.buildModel(q3sum, { year: 2026, quarter: 3, nowMs: NOW, ctxRows: [] });
eq(mnone.prev, null, '上季沒紀錄：prev 為 null');
eq(S.buildModel(q3sum, { year: 2026, quarter: 3, nowMs: NOW }).prev, null, '沒給脈絡紀錄也不壞');
var q1sum = S.summarize([R('q1a', 'MI-0002', '新莊', '2026-01-15', '適當', ['問題掌握'])])[0];
var mq1 = S.buildModel(q1sum, { year: 2026, quarter: 1, nowMs: NOW, ctxRows: CTX });
eq([mq1.prevName, mq1.prev.checks, mq1.prev.weak], ['第四季', 2, 1], '第一季對比去年第四季（跨年）');
var q4sum = S.summarize(CTX.filter(function (r) { return r.employee_id === 'MI-0002' && r.checked_on >= '2026-10-01'; }))[0];
var mq4 = S.buildModel(q4sum, { year: 2026, quarter: 4, nowMs: NOW, ctxRows: CTX, yearRows: CTX });
var mq4q = S.buildModel(q4sum, { year: 2026, quarter: 4, nowMs: NOW, ctxRows: CTX.filter(function (r) { return r.checked_on >= '2026-07-01' && r.checked_on <= '2026-09-30'; }) });
eq([mq4q.yearQs, mq4q.yearItems, mq4q.prev.checks], [null, null, 1], '第四季季度健檢單：不帶年度資料，只抓第三季');
eq([mq4.isQ4, mq4.prevName, mq4.prev.checks], [true, '第三季', 1], '第四季對比第三季');
eq(mq4.yearQs.map(function (q) { return q ? q.checks : null; }), [1, 2, 1, 2], '年度彙整：Q1~Q4 登記次數（2025 年的不算）');
eq(mq4.yearQs[3], { checks: 2, weak: 1, counts: [1, 0, 1, 0, 0, 0, 0] }, 'Q4 模型來自當季彙整');
ok(Array.isArray(mq4.yearAnalysis) && mq4.yearAnalysis.length >= 2, '第四季有年度分析');
var mq4b = S.buildModel(q4sum, { year: 2026, quarter: 4, nowMs: NOW, ctxRows: CTX.filter(function (r) { return r.checked_on >= '2026-10-01'; }), yearRows: CTX.filter(function (r) { return r.checked_on >= '2026-10-01'; }) });
eq(mq4b.yearQs.map(function (q) { return q ? q.checks : null; }), [null, null, null, 2], '年度資料沒紀錄的季是 null（不畫點）');
eq(mq4b.prev, null, '第四季沒有第三季紀錄：不畫對比');

// ---- 副標 ----
eq(Object.keys(D.DIM_SUBTITLE).length, 7, '七個面向都有副標');
DIMS.forEach(function (d) { ok(typeof D.DIM_SUBTITLE[d] === 'string' && D.DIM_SUBTITLE[d].length > 0, '有副標：' + d); });
eq(D.DIM_SUBTITLE['問題掌握'], '聽懂客戶需求，針對問題提供重點回答', '副標原文照用');
eq(D.DIM_SUBTITLE['風險意識'], '預先評估客訴風險，避免不當承諾及爭議', '副標原文照用 2');
ok(S.DIM_SUBTITLE === D.DIM_SUBTITLE, '副標只有一處定義（core 引用 spotdims-core）');

// ---- 星狀圖 SVG ----
function texts(svg) {
  var out = [], re = /<text ([^>]*)>([^<]*)<\/text>/g, mm;
  while ((mm = re.exec(svg))) {
    var a = mm[1], fsz = Number(a.match(/font-size="([\d.]+)"/)[1]), bold = /font-weight="(7|8)00"/.test(a);
    var x = Number(a.match(/(?:^| )x="([-\d.]+)"/)[1]), anc = (a.match(/text-anchor="(\w+)"/) || [0, 'start'])[1], txt = mm[2];
    var w = 0; for (var i = 0; i < txt.length; i++) w += txt.charCodeAt(i) > 255 ? fsz : fsz * (bold ? 0.62 : 0.56);
    out.push({ txt: txt, fs: fsz, x: x, y: Number(a.match(/(?:^| )y="([-\d.]+)"/)[1]), l: anc === 'end' ? x - w : anc === 'middle' ? x - w / 2 : x, r: anc === 'end' ? x : anc === 'middle' ? x + w / 2 : x + w });
  }
  return out;
}
var prevM = { checks: 9, weak: 4, counts: [3, 2, 4, 1, 2, 1, 3] };
var QC = S.quarterCompareSvg(M8, prevM);
ok(QC.svg.indexOf('<svg') === 0 && QC.svg.indexOf('</svg>') > 0, '單季星狀圖是 SVG');
ok(QC.svg.indexOf('<title>') < 0, '星狀圖沒有 tooltip（title）');
ok(QC.svg.indexOf('var(--') < 0 && QC.svg.indexOf('class=') < 0, '星狀圖不靠外部 CSS（可單獨轉圖）');
ok(QC.svg.indexOf('stroke-dasharray="8 5"') > 0, '有上一季虛線');
ok(QC.svg.indexOf('rgba(217,255,0,.45)') > 0, '本季黃綠填色');
ok(QC.svg.indexOf('stroke-width="2.5"') > 0, '本季黑粗線');
ok(S.quarterCompareSvg(M8, null).svg.indexOf('stroke-dasharray="8 5"') < 0, '上季無紀錄只畫實線');
var tx = texts(QC.svg);
DIMS.forEach(function (d, i) {
  ok(tx.some(function (t) { return t.txt === d + '（' + S.pct(sc8[i]) + '%）'; }), '軸標籤「' + d + '（百分比）」');
  var sub = D.DIM_SUBTITLE[d].replace(/，/g, '');
  ok(tx.filter(function (t) { return t.fs < 17; }).map(function (t) { return t.txt; }).join('').replace(/，/g, '').indexOf(sub) >= 0, '副標出現：' + d);
});
ok(QC.svg.indexOf('font-weight="800"') > 0, '最低分面向標籤加粗');
tx.forEach(function (t) { ok(t.l >= 0 && t.r <= QC.width, '星狀圖文字不被裁切：' + t.txt + '（' + Math.round(t.l) + '～' + Math.round(t.r) + ' / ' + QC.width + '）'); });
ok(QC.height > 0 && QC.width / QC.height > 0.9 && QC.width / QC.height < 2.2, '星狀圖長寬比合理');
var T4 = S.totalSvg(mq4.yearQs);
ok(T4.svg.indexOf('<title>') < 0 && T4.svg.indexOf('</svg>') > 0, '全年總合星狀圖');
// 全年總合分數：全年被勾次數 ÷ 全年登記次數
var totM = S.totalModel(mq4.yearQs), totS = S.scoreOf(totM);
ok(near(totS[2], 1 - 1 / 6) && near(S.scoreOf(totM)[3], 1 - 3 / 6), '全年總合分數用全年加總：1−被勾÷登記');
ok(T4.svg.indexOf('問題掌握（' + S.pct(totS[2]) + '%）') > 0, '全年總合標籤百分比');
// ---- 年度洞察、摘要卡、重點三條（假資料同設計圖）----
var YQS = [{ checks: 6, weak: 2, counts: [2, 1, 3, 0, 1, 0, 2] }, { checks: 9, weak: 4, counts: [3, 2, 4, 1, 2, 1, 3] }, M8, { checks: 10, weak: 5, counts: [3, 1, 6, 0, 2, 1, 4] }];
var INS = S.yearInsights(YQS);
eq(INS.ts.map(S.pct), [64, 82, 45, 94, 76, 94, 67], '全年綜合分數（手算：1 − 被勾 ÷ 登記）');
eq(INS.strong.map(function (i) { return DIMS[i]; }), ['主動引導', '語氣與禮貌'], '全年強項：最高且 ≥ 85%，並列全列');
eq(INS.weakest.map(function (i) { return DIMS[i]; }), ['問題掌握'], '全年最低');
eq([INS.improve.i, INS.improve.diff, INS.decline.i, INS.decline.diff], [0, 20, 6, 15], 'Q4 進步最多 ▲20、退步最多 ▼15');
eq(INS.key.map(function (k) { return [DIMS[k.i], k.kind]; }), [['問題掌握', 'weak'], ['資訊正確性', 'improve'], ['文字品質', 'decline']], '重點三條');
eq(S.yearCards(YQS).map(function (c) { return c.title + '：' + c.text; }), ['全年強項：主動引導、語氣與禮貌 94%', '最需要加強：問題掌握 45%', 'Q4 進步最多：資訊正確性 ▲20', 'Q4 需要留意：文字品質 ▼15'], '四張摘要卡');
// 沒有符合者：卡片 text 為 null、不報錯
var noImp = S.yearCards([null, null, null, M8]);
eq([noImp[2].text, noImp[3].text], [null, null], '沒有第三季：進步／退步卡沒有內容');
eq(S.yearCards([null, null, null, null]).map(function (c) { return c.text; }), [null, null, null, null], '全年沒紀錄：四張卡都沒內容、不報錯');
var lowAll = S.yearCards([null, null, null, { checks: 10, weak: 5, counts: [3, 3, 3, 3, 3, 3, 3] }]);
eq(lowAll[0].text, null, '全部 70%：沒有 ≥ 85% 的強項');
eq(lowAll[1].text, null, '全部相同：沒有最弱');
// 強項門檻 85%
eq(S.yearInsights([null, null, null, { checks: 20, weak: 3, counts: [3, 5, 5, 5, 5, 5, 5] }]).strong, [0], '85% 剛好算強項');
eq(S.yearInsights([null, null, null, { checks: 20, weak: 3, counts: [4, 5, 5, 5, 5, 5, 5] }]).strong, [], '80% 不算強項');
// 重點三條去重：同一面向不畫兩次，重複的改取次要者
var dupDec = S.yearInsights([null, null, { checks: 10, weak: 0, counts: [0, 0, 0, 0, 0, 0, 0] }, { checks: 10, weak: 5, counts: [6, 1, 1, 1, 1, 1, 1] }]);
eq(dupDec.key.map(function (k) { return [k.i, k.kind]; }), [[0, 'weak'], [1, 'decline']], '最低同時是退步最多：退步改取次要者（資訊正確性）');
var dupImp = S.yearInsights([null, null, { checks: 10, weak: 5, counts: [8, 0, 0, 0, 0, 0, 0] }, { checks: 10, weak: 5, counts: [5, 0, 0, 0, 0, 0, 0] }]);
eq(dupImp.key.map(function (k) { return [k.i, k.kind]; }), [[0, 'weak']], '最低同時是進步最多：沒有次要者就不補');
ok(INS.key.every(function (k, i, a) { return a.filter(function (x) { return x.i === k.i; }).length === 1; }), '重點三條沒有重複面向');

// ---- 星狀圖：60% 待加強線、強項（綠）／最弱（紅）、副標單行截斷 ----
var TS = S.totalSvg(YQS);
ok(TS.svg.indexOf('stroke="#D64B3C"') > 0 && TS.svg.indexOf('stroke-dasharray="6 4"') > 0, '全年綜合星狀圖有紅色 60% 虛線');
var wl = TS.svg.match(/<polygon points="([^"]+)" fill="none" stroke="#D64B3C"/)[1].split(' ').map(function (p) { return p.split(',').map(Number); });
var rings = TS.svg.match(/<polygon points="([^"]+)" fill="none" stroke="#8F99A8"/)[1].split(' ').map(function (p) { return p.split(',').map(Number); });
var tcx = TS.width / 2, tcy = Number(TS.svg.match(/<line x1="[\d.]+" y1="([\d.]+)"/)[1]);
ok(Math.abs((tcy - wl[0][1]) / (tcy - rings[0][1]) - 0.6) < 0.01, '紅色虛線畫在 60% 的位置（相對外圈）');
eq((TS.svg.match(/★ 全年強項/g) || []).length, 2, '強項並列兩個都標 ★ 全年強項');
eq((TS.svg.match(/▲ 最需要加強/g) || []).length, 1, '最弱標 ▲ 最需要加強');
ok(TS.svg.indexOf('fill="' + S.COLORS.greenTx + '"') > 0 && TS.svg.indexOf('fill="' + S.COLORS.redTx + '"') > 0, '強項標籤綠色、最弱標籤紅色');
ok(TS.svg.indexOf('fill="' + S.COLORS.green + '" stroke="#fff"') > 0 && TS.svg.indexOf('fill="' + S.COLORS.red + '" stroke="#fff"') > 0, '強項點綠色、最弱點紅色');
ok(TS.svg.indexOf('文字正確通順，排版方便易…') > 0 && TS.svg.indexOf('預先評估客訴風險，避免不…') > 0, '過長副標單行加「…」截斷');
ok(TS.svg.indexOf('排版方便易讀') < 0, '被截斷的副標完整文字不在圖上（表格才有）');
ok(TS.svg.indexOf('聽懂客戶需求') < 0, '有強調標籤的面向以標籤取代副標');
texts(TS.svg).forEach(function (t) { ok(t.l >= 0 && t.r <= TS.width, '全年綜合星狀圖文字不被裁切：' + t.txt); });
ok(S.totalSvg([null, null, null, { checks: 5, weak: 0, counts: [0, 0, 0, 0, 0, 0, 0] }]).svg.indexOf('最需要加強') < 0, '全 100%：沒有最弱標示');
var QE = S.quarterCompareSvg(M8, prevM);
ok(QE.svg.indexOf('stroke-dasharray="6 4"') > 0, '單季星狀圖也有 60% 紅色虛線');
ok(QE.svg.indexOf('★ 本季強項') > 0 && QE.svg.indexOf('▲ 最需要加強') > 0, '單季：最強（語氣與禮貌 100%）綠色、最弱（問題掌握）紅色標示');
ok(QE.svg.indexOf('聽懂客戶需求') > 0, '單季標籤保留副標（標示接在副標下）');
eq(Object.keys(S.emphOf([0.9, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8])).length, 7, '強項與最弱都標（0.9 強項、其餘並列最弱）');
eq(S.emphOf([0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9])[0].tag, '★ 全年強項', '全部一樣：只有強項、沒有最弱');
eq(Object.keys(S.emphOf([0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7])).length, 0, '全部 70%：沒有強項也沒有最弱');

// ---- 折線圖：預設重點三條彩色、其餘灰色 ----
var LCH = S.lineChartSvg(YQS);
ok(LCH.svg.indexOf('<title>') < 0, '折線圖沒有 tooltip');
['（全年最低）', '（Q4 進步最多）', '（Q4 退步最多）'].forEach(function (nt) { eq(LCH.svg.split(nt).length - 1, 1, '重點標註只出現一次：' + nt); });
ok(LCH.svg.indexOf('問題掌握 40%（全年最低）') > 0 && LCH.svg.indexOf('資訊正確性 70%（Q4 進步最多）') > 0 && LCH.svg.indexOf('文字品質 60%（Q4 退步最多）') > 0, '重點線尾標籤文字（面向＋百分比＋註記）');
ok(LCH.svg.indexOf('stroke="' + S.COLORS.red + '"') > 0 && LCH.svg.indexOf('stroke="' + S.COLORS.blue + '"') > 0 && LCH.svg.indexOf('stroke="' + S.COLORS.gold + '"') > 0, '重點三條用紅、藍、金');
eq(LCH.svg.split('stroke="' + S.COLORS.gray + '" stroke-width="2"').length - 1, 4 * 3, '其餘四條灰色細線（每條 3 段）');
DIMS.forEach(function (d) { ok(LCH.svg.indexOf('>' + d + ' ') > 0, '折線圖線尾標籤：' + d); });
ok(LCH.svg.indexOf('Q1') > 0 && LCH.svg.indexOf('Q4') > 0, '橫軸 Q1~Q4');
ok(LCH.lo >= 0 && LCH.lo < 1, '縱軸下限動態：' + LCH.lo);
function endLabels(svg) { return texts(svg).filter(function (t) { return t.fs >= 16 && t.fs <= 17 && /\d%/.test(t.txt) && t.txt.indexOf('縱軸') < 0; }); }
eq(endLabels(LCH.svg).length, 7, '七條線尾各一個標籤');
var eys = endLabels(LCH.svg).map(function (t) { return t.y; }).sort(function (a, b) { return a - b; });
for (var ei = 1; ei < eys.length; ei++) ok(eys[ei] - eys[ei - 1] >= 20, '線尾標籤不重疊（相隔 ' + Math.round(eys[ei] - eys[ei - 1]) + '）');
texts(LCH.svg).forEach(function (t) { ok(t.r <= LCH.width + 0.5 && t.l >= 0, '折線圖文字不被裁切：' + t.txt); });
var L1 = S.lineChartSvg(YQS, 2);
eq(endLabels(L1.svg).length, 1, '單選一個面向：只畫那一條');
ok(L1.svg.indexOf('stroke="' + S.DIM_COLORS[2] + '"') > 0 && L1.svg.indexOf('（全年最低）') < 0, '單選用該面向自己的顏色、沒有重點註記');
ok(S.lineChartSvg([null, null, null, null]).svg.indexOf('</svg>') > 0, '折線圖全無資料不壞');
ok(S.lineChartSvg([null, null, null, M8]).svg.indexOf('Q1（無）') > 0, '沒有紀錄的季標示（無）');

// ---- 全年數值表：色階與 ▲▼ ----
var TM = S.yearTableModel(YQS);
var c0 = TM[0].cells;
eq(c0.map(function (c) { return c.pct; }), [67, 67, 50, 70], '資訊正確性 各季');
eq(c0.map(function (c) { return c.diff ? c.diff.dir + c.diff.n : null; }), [null, null, 'down17', 'up20'], '▲▼ 與上一季差距（Q1 不標）');
eq(c0.map(function (c) { return c.bg; }), ['', '', 'red', ''], '< 60% 紅底、其餘白底');
eq(TM[1].cells.map(function (c) { return [c.bg, c.diff ? c.diff.dir + c.diff.n : null].join('|'); }), ['|', '|', '|', 'green|up15'], '預設訊息運用：90% 綠底 ▲15');
eq([TM[2].nameRed, TM[2].total.bg, TM[0].nameRed], [true, 'red', false], '全年 < 60% 的面向名稱與全年格標紅');
eq(TM[5].cells.map(function (c) { return c.diff ? c.diff.dir + c.diff.n : null; }), [null, 'down11', 'up11', 'down10'], '差距剛好 10 也標');
var tm9 = S.yearTableModel([{ checks: 100, weak: 0, counts: [10, 0, 0, 0, 0, 0, 0] }, { checks: 100, weak: 0, counts: [1, 0, 0, 0, 0, 0, 0] }, null, null]);
eq([tm9[0].cells[0].pct, tm9[0].cells[1].pct, tm9[0].cells[1].diff], [90, 99, null], '差距 9 不標');
eq(S.yearTableModel([null, M8, null, M8])[0].cells[3].diff, null, '上一季沒紀錄不標差異');
eq(TM[0].cells.every(function (c) { return c.has; }), true, '有紀錄的格子 has');
eq(S.yearTableModel([null, null, null, M8])[0].cells.map(function (c) { return c.has; }), [false, false, false, true], '沒紀錄的季 has=false');
ok(TM.every(function (r) { return r.sub === D.DIM_SUBTITLE[r.name]; }), '表格保留面向副標');

// ---- 年度分析：帶標籤的條列 ----
var YI = S.yearItems(YQS);
eq(YI.map(function (it) { return it.tag; }), ['感謝', '強項', '待加強', '進步', '留意'], '標籤順序');
eq(YI[0].text, '這一年辛苦了，優良回覆佔 58%，謝謝你的用心！', '感謝列');
ok(YI[1].text.indexOf('「主動引導」、「語氣與禮貌」全年都是 94%') === 0, '強項列點名全年強項');
ok(YI[2].text.indexOf('「問題掌握」全年 45%，四季都是最低') === 0 && YI[2].advice === S.DIM_ADVICE['問題掌握'], '待加強列：全年最低＋四季都最低＋建議');
ok(YI[3].text.indexOf('「資訊正確性」第四季從 50% 進步到 70%') === 0 && YI[3].advice.indexOf(S.DIM_ADVICE['資訊正確性']) >= 0, '進步列：由 50% 到 70%＋建議');
ok(YI[4].text.indexOf('「文字品質」第四季降到 60%') === 0 && YI[4].advice === S.DIM_ADVICE['文字品質'], '留意列：降到 60%＋建議');
YI.forEach(function (it) { ok(!/[（）()]/.test(it.text + (it.advice || '')), '年度分析句子沒有括號：' + it.tag); ok(!/\d+\s*次/.test(it.text), '年度分析沒有次數句：' + it.tag); ok(!!S.TAG_COLOR[it.tag], '標籤有顏色：' + it.tag); });
ok(YI[0].advice === undefined && YI[1].advice === undefined, '感謝與強項列沒有建議');
eq(S.yearItems([YQS[0], YQS[1], YQS[2], { checks: 10, weak: 0, counts: [0, 0, 0, 0, 0, 0, 0] }]).map(function (it) { return it.tag; }).indexOf('留意'), -1, '沒有退步：不產生留意列');
eq(S.yearItems([null, null, null, M8]).map(function (it) { return it.tag; }).indexOf('進步'), -1, '沒有第三季：不產生進步列');
ok(S.yearItems([null, null, null, M8]).some(function (it) { return it.tag === '待加強' && it.text.indexOf('是全年最低') > 0; }), '只有一季資料：不說「四季都是最低」');
eq(S.yearItems([null, null, null, null]), [], '全年沒紀錄：沒有分析列');
eq(S.yearAnalysis(YQS).length, 5, '年度分析字串陣列與列數一致');
eq(S.quarterItems(M8, prevM).map(function (it) { return it.tag; }), ['進步', '待加強', '待加強'], '單季小結用標籤：進步、待加強');
eq(S.quarterItems(allGood0(), null)[0].tag, '強項', '單季全穩：強項');
function allGood0() { return { checks: 20, weak: 1, counts: [1, 0, 0, 2, 0, 0, 0] }; }

// ---- 配色對比（文字對底色至少 4.5:1）----
function lum(hex) { var c = [1, 3, 5].map(function (i) { var v = parseInt(hex.substr(i, 2), 16) / 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; }
function contrast(a, b) { var x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
['green', 'red', 'blue', 'gold'].forEach(function (k) {
  ok(contrast(S.COLORS[k + 'Tx'], S.COLORS[k + 'Bg']) >= 4.5, k + ' 文字對淡底 ≥ 4.5：' + contrast(S.COLORS[k + 'Tx'], S.COLORS[k + 'Bg']).toFixed(2));
  ok(contrast(S.COLORS[k + 'Tx'], '#FFFFFF') >= 4.5, k + ' 文字對白底 ≥ 4.5');
});
Object.keys(S.TAG_COLOR).forEach(function (t) { ok(contrast('#FFFFFF', S.TAG_COLOR[t]) >= 4.5, '標籤白字對色塊 ≥ 4.5：' + t); });
ok(contrast(S.COLORS.grayTx, S.COLORS.grayBg) >= 4.5 && contrast('#6B7280', '#FFFFFF') >= 4.5, '灰字對比');
eq([S.COLORS.green, S.COLORS.red, S.COLORS.blue, S.COLORS.gold, S.COLORS.gray], ['#2E7D5B', '#D64B3C', '#1F6FD1', '#C98A00', '#9AA0A6'], '配色主色');
eq([S.STRONG_MIN, S.WEAK_LINE, S.DIFF_MIN], [0.85, 0.6, 10], '門檻常數');
eq(S.fileNameYear({ name: '範例2', year: 2026 }), '年度健檢單_範例2_2026.pdf', '年度檔名');
eq(S.fileNameYear({ name: 'a/b:c', year: 2026 }), '年度健檢單_a_b_c_2026.pdf', '年度檔名去掉不允許字元');
ok(S.fileNameYear({ name: 'x', year: 2026 }) !== S.fileName({ name: 'x', year: 2026, quarter: 4 }), '季度與年度檔名不同');

// ---- PDF 頁面組裝：季度頁 vs 年度頁（用假 window 載入 pdf 檔，只測組字串，不碰 DOM）----
global.window = { CheckupSheetCore: S };
require('../js/checkup-sheet-pdf.js');
var PDF = global.window.CheckupSheetPdf;
var mQ = S.buildModel(q4sum, { year: 2026, quarter: 4, nowMs: NOW, ctxRows: CTX, yearRows: CTX });
var hq = PDF._buildHtml(mQ, {}, 'quarter'), hy = PDF._buildHtml(mQ, {}, 'year');
ok(hq.indexOf('本季小結') > 0 && hq.indexOf('登記紀錄（共 2 筆）') > 0 && hq.indexOf('對比：第三季') > 0, '季度頁：小結、登記紀錄、對比第三季');
ok(hq.indexOf('年度') < 0 && hq.indexOf('全年') < 0, '季度頁（含第四季）完全沒有年度內容或字樣');
ok(hy.indexOf('年度健檢單') > 0 && hy.indexOf('class="cards"') > 0 && hy.indexOf('全年數值表') > 0 && hy.indexOf('年度分析') > 0 && hy.indexOf('各面向四季變化') > 0, '年度頁：頁首、摘要卡、折線圖、數值表、年度分析');
ok(hy.indexOf('登記紀錄') < 0 && hy.indexOf('data-type="row"') < 0 && hy.indexOf('<img alt="截圖') < 0, '年度頁沒有登記紀錄與截圖');
ok(hy.indexOf('本季小結') < 0 && hy.indexOf('stat ok') < 0, '年度頁沒有單季小結與次數卡');
ok(hy.split('class="card"').length - 1 === 4, '年度頁 4 張摘要卡');
ok(hy.indexOf('▼17') > 0 || hy.indexOf('▲') > 0, '年度表有 ▲▼ 文字符號');
ok(hy.indexOf('85% 以上（綠底）') > 0 && hy.indexOf('低於 60%（紅底）') > 0 && hy.indexOf('▲▼ 為與上一季相比') > 0, '年度表圖例說明');
ok(hy.indexOf('重點三條') > 0 && hy.indexOf('紅色虛線是 60% 待加強線') > 0, '重點三條圖例與 60% 說明');
[hq, hy].forEach(function (h, k) { ok(h.indexOf('抽查') < 0, '頁面文字沒有「抽查」#' + k); });
var hq3 = PDF._buildHtml(S.buildModel(q3sum, { year: 2026, quarter: 3, nowMs: NOW, ctxRows: [] }), {}, 'quarter');
ok(hq3.indexOf('上季無紀錄，只畫本季實線') > 0, '季度頁：上季無紀錄的說明');
ok(PDF._buildHtml(mQ, {}) === hq, '預設是季度頁');

// ---- 小結文案 ----
var A = S.quarterAnalysis(M8, prevM);
eq(A, '「語氣與禮貌」比上季進步很多，繼續保持！「問題掌握」還有進步空間，建議：' + S.DIM_ADVICE['問題掌握'] + '「資訊正確性」還有進步空間，建議：' + S.DIM_ADVICE['資訊正確性'], '單季小結：進步鼓勵＋最低兩個面向建議（手算核對）');
var allGood = { checks: 20, weak: 1, counts: [1, 0, 0, 2, 0, 0, 0] };   // 95%、100%、100%、90%…全部 ≥ 90%
var AG = S.quarterAnalysis(allGood, null);
ok(AG.indexOf('建議') < 0 && AG.indexOf('很穩') > 0, '全部 ≥ 90%：只寫鼓勵、沒有不足建議');
var edge = { checks: 10, weak: 1, counts: [1, 0, 0, 0, 0, 0, 0] };   // 資訊正確性剛好 90%
ok(S.quarterAnalysis(edge, null).indexOf('建議') < 0, '剛好 90% 不算不足');
var below = { checks: 10, weak: 1, counts: [2, 0, 0, 0, 0, 0, 0] };  // 80%
ok(S.quarterAnalysis(below, null).indexOf('「資訊正確性」還有進步空間') >= 0, '80% 算不足');
var manyLow = { checks: 10, weak: 9, counts: [5, 4, 3, 2, 6, 1, 7] };
var ml = S.quarterAnalysis(manyLow, null);
eq((ml.match(/還有進步空間/g) || []).length, 2, '不足面向最多 2 個');
ok(ml.indexOf('「文字品質」還有進步空間') >= 0 && ml.indexOf('「風險意識」還有進步空間') >= 0, '不足取分數最低的兩個（文字品質 30%、風險意識 40%）');
var manyUp = S.quarterAnalysis({ checks: 10, weak: 0, counts: [0, 0, 0, 0, 0, 0, 0] }, { checks: 10, weak: 9, counts: [5, 4, 3, 2, 6, 1, 7] });
ok(manyUp.indexOf('比上季進步很多') > 0 && manyUp.indexOf('建議') < 0, '全進步且全穩：只鼓勵');
eq(((manyUp.match(/「[^」]+」/g)) || []).length <= 3, true, '優秀面向最多 3 個');
var qaList = [A, AG, ml, manyUp, S.quarterAnalysis(M8, null), S.quarterAnalysis(legacyOnly, null)];
var yaList = S.yearAnalysis(mq4.yearQs).concat(S.yearAnalysis([M8, M8, M8, M8]), S.yearAnalysis([null, null, null, M8]), S.yearAnalysis([allGood, allGood, allGood, allGood]));
qaList.concat(yaList).forEach(function (t) {
  ok(!/[（）()]/.test(t), '小結沒有括號：' + t.slice(0, 20));
  ok(!/\d+\s*次/.test(t) && t.indexOf('次紀錄') < 0 && t.indexOf('次抽查') < 0, '小結沒有紀錄次數句：' + t.slice(0, 20));
  ok(t.indexOf('抽查') < 0, '小結沒有抽查字樣');
});
Object.keys(S.DIM_ADVICE).forEach(function (k) { ok(DIMS.indexOf(k) >= 0 && S.DIM_ADVICE[k].indexOf('抽查') < 0 && !/[（）()]/.test(S.DIM_ADVICE[k]), '建議句：' + k); });
eq(Object.keys(S.DIM_ADVICE).length, 7, '七個面向都有建議句');
var YA = S.yearAnalysis([allGood, allGood, allGood, allGood]);
ok(YA.join('').indexOf('建議') < 0 && YA[0].indexOf('優良回覆佔 95%') >= 0, '年度全穩：只鼓勵；優良回覆佔 95%');
var YB = S.yearAnalysis([manyLow, manyLow, manyLow, manyLow]);
eq(YB.filter(function (t) { return t.indexOf('建議：') > 0; }).length, 1, '年度只點名全年最低的一個面向給建議');
ok(S.yearAnalysis([M8, null, null, prevM]).length >= 2, '年度分析可處理缺季');
ok(YA.every(function (t) { return typeof t === 'string'; }), '年度分析是字串陣列');
// 全站字樣：顯示用文字都沒有「抽查」
[QC.svg, T4.svg, LCH.svg, S.quarterLabel(2026, 3), JSON.stringify(S.DIM_ADVICE), JSON.stringify(D.DIM_SUBTITLE), mq4.analysis, mq4.yearAnalysis.join('')].forEach(function (t, k) { ok(t.indexOf('抽查') < 0, '輸出文字不含「抽查」#' + k); });
ok(S.markerSvg(0, 10, 10, 6).indexOf('<circle') === 0 && S.markerSvg(6, 10, 10, 6).indexOf('<polygon') === 0, '七種標記');
eq(S.DIM_COLORS.length, 7, '七色'); eq(S.DIM_DASH.length, 7, '七種線型');

// ---- 登記截圖卡片：資料組裝、續卡編號、分頁 ----
eq(S.cardDate('2026-11-13'), { md: '11/13', wk: '（五）', text: '11/13（五）' }, '星期依實際曆法：2026-11-13 是週五');
eq([S.cardDate('2026-01-01').text, S.cardDate('2024-02-29').text, S.cardDate('2026-10-04').text, S.cardDate('2026-07-08').text], ['1/1（四）', '2/29（四）', '10/4（日）', '7/8（三）'], '星期：元旦、閏日、週日、個位數月日不補零');
function CR(id, day, verdict, dims, extra) { return R(id, 'MI-0002', '新莊', day, verdict, dims, extra); }
var cardSum = S.summarize([
  CR('k1', '2026-11-13', '不適當', ['問題掌握', '文字品質'], { improve_note: '三段對話都有漏接客人的追問。', shot_paths: ['spot/k1/a.jpg', 'spot/k1/b.jpg', 'spot/k1/c.jpg'] }),
  CR('k2', '2026-11-05', '適當', [], { shot_paths: ['spot/k2/a.jpg'] }),
  CR('k3', '2026-10-08', '不適當', ['資訊正確性'], { improve_note: '  只有說明沒有截圖  ' }),
  CR('k4', '2026-10-09', '適當', [], { total_score: 72, improve_dims: null })
])[0];
var cm = S.buildModel(cardSum, { year: 2026, quarter: 4, nowMs: NOW });
var cards = S.buildCards(cm.records);
eq(cards.length, 6, '3 張截圖 + 1 張 + 兩筆沒有截圖 = 6 張卡片');
eq(cards.map(function (c) { return c.recId; }), ['k3', 'k4', 'k2', 'k1', 'k1', 'k1'], '依登記日期排序，每筆的截圖依序展開');
var k1 = cards.filter(function (c) { return c.recId === 'k1'; });
eq(k1.map(function (c) { return c.seq; }), ['(1/3)', '(2/3)', '(3/3)'], '一筆三張截圖：續卡編號 (1/3)(2/3)(3/3)');
eq(k1.map(function (c) { return c.cap; }), ['截圖 1/3', '截圖 2/3', '截圖 3/3'], '截圖 n/N 小膠囊');
eq(k1.map(function (c) { return c.shot; }), ['spot/k1/a.jpg', 'spot/k1/b.jpg', 'spot/k1/c.jpg'], '每張卡片對應一張截圖');
ok(k1.every(function (c) { return c.dateText === '11/13（五）' && c.verdict === '待加強回覆' && c.isWeak && c.note === '三段對話都有漏接客人的追問。' && c.dims.join() === '問題掌握,文字品質'; }), '續卡重複相同日期、判定、面向、說明');
eq(k1[0].dimIdx, [2, 6], '面向索引（對應七色）');
var k2 = cards.filter(function (c) { return c.recId === 'k2'; })[0];
eq([k2.seq, k2.cap, k2.verdict, k2.isWeak, k2.dimIdx, k2.note], ['', '截圖', '優良回覆', false, [], ''], '單張截圖：不標續卡、只寫「截圖」；無面向、無說明');
var k3 = cards.filter(function (c) { return c.recId === 'k3'; })[0];
eq([k3.hasShot, k3.shot, k3.cap, k3.seq, k3.note], [false, null, '', '', '只有說明沒有截圖'], '沒有截圖的登記：一張沒有截圖框的小卡');
var k4 = cards.filter(function (c) { return c.recId === 'k4'; })[0];
eq(S.buildCards([]), [], '沒有紀錄沒有卡片'); eq(S.buildCards(null), [], 'null 沒有卡片');
eq(S.clampNote('a'.repeat(72)), 'a'.repeat(72), '說明剛好 72 字不截');
eq(S.clampNote('字'.repeat(100)), '字'.repeat(72) + '…', '說明超過 72 字截成「…」');
eq(S.clampNote('  第一行\n\n 第二行  '), '第一行 第二行', '說明換行與多餘空白收成一個空格');
eq(S.clampNote(null), '', '沒有說明');
ok(S.buildCards(S.buildModel(S.summarize([CR('z', '2026-10-01', '適當', [], { improve_note: '字'.repeat(100) })])[0], { year: 2026, quarter: 4, nowMs: NOW }).records)[0].noteCut, '說明被截斷有旗標');
// 分頁：有截圖的卡一頁 2 張
function shotCard(i) { return { hasShot: true, dimIdx: [], note: '', id: i }; }
function bareCard(o) { return { hasShot: false, dimIdx: o && o.dims ? [0] : [], note: o && o.note ? '說明' : '' }; }
var PG = { pageH: 1045, firstOffset: 48, footH: 36 };
function sizes(p) { return p.map(function (x) { return x.length; }); }
eq(sizes(S.paginateCards([shotCard(1), shotCard(2), shotCard(3), shotCard(4)], PG)), [2, 2], '4 張有截圖：每頁 2 張');
eq(sizes(S.paginateCards([shotCard(1), shotCard(2), shotCard(3), shotCard(4), shotCard(5)], PG)), [2, 2, 1], '單數張：最後一頁只有一張');
eq(sizes(S.paginateCards([shotCard(1)], PG)), [1], '只有 1 張');
eq(sizes(S.paginateCards([shotCard(1), shotCard(2)], PG)), [2], '剛好 2 張（含標題與頁尾）仍同一頁');
eq(sizes(S.paginateCards([shotCard(1), shotCard(2), shotCard(3)], PG)), [2, 1], '3 張：2＋1');
eq(S.paginateCards([], PG), [], '沒有卡片沒有頁');
var many = []; for (var qi = 0; qi < 7; qi++) many.push(shotCard(qi));
var pgs = S.paginateCards(many, PG);
eq(pgs.reduce(function (a, p) { return a.concat(p.map(function (c) { return c.id; })); }, []), [0, 1, 2, 3, 4, 5, 6], '分頁不漏卡、不重複、順序不變');
ok(pgs.every(function (p, i) { return p.reduce(function (a, c) { return a + S.cardHeight(c) + S.CARD_GAP; }, 0) <= 1045 - (i === 0 ? 48 : 0); }), '每頁高度都放得下（卡片不被切）');
eq(sizes(S.paginateCards([shotCard(1), bareCard(), shotCard(3)], PG)), [2, 1], '有截圖＋小卡＋有截圖：小卡與前一張同頁，第三張換頁');
eq(sizes(S.paginateCards([bareCard(), bareCard(), bareCard()], PG)), [3], '沒有截圖的小卡依高度自然排列，不硬湊兩張一頁');
var bares = []; for (var bi = 0; bi < 10; bi++) bares.push(bareCard());
eq(sizes(S.paginateCards(bares, PG)), [9, 1], '頁尾放不下時最後一張移到下一頁（頁尾不單獨成頁）');
ok(S.cardHeight(bareCard({ dims: 1, note: 1 })) > S.cardHeight(bareCard()), '小卡高度隨面向與說明增加');
eq(S.cardHeight(shotCard(1)), S.CARD_H, '有截圖的卡片固定高度');
ok(2 * (S.CARD_H + S.CARD_GAP) + 48 + 36 <= 1045, '一頁 2 張＋標題＋頁尾放得下');
eq(S.CARD.dim.length, 7, '七個面向各有膠囊顏色');
eq([S.CARD.ok, S.CARD.bad, S.CARD.bg, S.CARD.line, S.CARD.edge], ['#10B981', '#EF4444', '#FAFBFC', '#E8EAEE', '#DDE0E5'], '卡片配色（優良綠、待加強紅、很淡的灰底、分隔線、極淡外框）');
ok(Object.keys(S.buildCards(cm.records)[0]).indexOf('legacy') < 0, '卡片資料不含舊制分數');

// ---- 卡片 HTML（PDF 頁面組裝）----
var cardsHtml = PDF._buildHtml(S.buildModel(cardSum, { year: 2026, quarter: 4, nowMs: NOW }), { 'spot/k1/a.jpg': { src: 'data:image/png;base64,AAAA', w: 360, h: 640 }, 'spot/k1/b.jpg': { src: 'data:image/png;base64,AAAA', w: 1000, h: 620 }, 'spot/k2/a.jpg': null }, 'quarter');
var cardPart = cardsHtml.slice(cardsHtml.indexOf('登記紀錄（共'));
eq(cardPart.split('class="ccard').length - 1, 6, '6 張卡片');
eq(cardPart.split('<img alt=').length - 1, 2, '取到圖的 2 張放截圖');
eq(cardPart.split('截圖載入失敗').length - 1, 2, '取圖失敗的 2 張顯示「截圖載入失敗」（k1 第 3 張、k2）');
eq(cardPart.split('可私訊客服部確認聊天室網址').length - 1, 2, '失敗卡片第二行小字');
ok(cardPart.indexOf('class="fail"><b>截圖載入失敗</b><small>可私訊客服部確認聊天室網址</small>') > 0, '失敗框兩行：大字＋小字');
ok(cardPart.indexOf('(2/3)') > 0 && cardPart.indexOf('(3/3)') > 0 && cardPart.indexOf('11/13') > 0 && cardPart.indexOf('（五）') > 0, '日期、星期、續卡膠囊');
ok(cardPart.indexOf('優良回覆') > 0 && cardPart.indexOf('待加強回覆') > 0 && cardPart.indexOf('<svg') > 0, '判定徽章含 SVG 圖示');
ok(!/[\u{1F300}-\u{1FAFF}☀-➿☺]/u.test(cardPart), '卡片區沒有 emoji（笑臉、驚嘆號用 SVG）');
ok(cardPart.indexOf('可改善面向') > 0 && cardPart.indexOf('background:' + S.CARD.dim[2].bg) > 0, '面向膠囊用既有七色');
ok(cardPart.indexOf('舊制分數') < 0 && cardPart.indexOf('clegacy') < 0, '卡片上不顯示舊制分數');
ok(cardPart.indexOf('class="cap">截圖 1/3<') > 0 && cardPart.indexOf('class="cap">截圖<') > 0, '截圖 n/N 與單張「截圖」');
eq(cardPart.split('data-break="1"').length - 1, 2, '第一張卡片之後每頁第一張強制換頁（6 張＝有截圖 3 張一頁 2 張 → 換頁處）');
ok(cardPart.indexOf('抽查') < 0, '卡片區沒有「抽查」');
ok(hy.indexOf('ccard') < 0, '年度頁沒有登記卡片');

// ---- 小結後的「往下滑」提醒顯示條件 ----
eq(S.HINT_MIN_GAP, 260, '提醒門檻常數');
eq(S.HINT_TEXT, '往下滑看本季登記詳細紀錄', '提醒文字');
eq(S.showScrollHint(500, 3), true, '有卡片、空白大：顯示');
eq(S.showScrollHint(261, 1), true, '空白剛好超過門檻：顯示');
eq(S.showScrollHint(260, 1), false, '空白剛好等於門檻：不顯示（要大於）');
eq(S.showScrollHint(120, 5), false, '空白小：不顯示');
eq(S.showScrollHint(800, 0), false, '沒有任何卡片：不顯示');
eq(S.showScrollHint(800, undefined), false, '沒有卡片資料：不顯示');
ok(PDF._buildHtml(mQ, {}, 'year').indexOf('往下滑') < 0, '年度頁沒有提醒');

// ---- 第 1 頁固定＝頁首＋摘要卡＋星狀圖＋本季小結（版面預算）----
eq(S.SUMMARY_MAX_ROWS, 5, '小結最多 5 列');
var seven = [{ tag: '感謝', text: 'a' }, { tag: '進步', text: 'b' }, { tag: '留意', text: 'c' }, { tag: '待加強', text: 'd', advice: 'x' }, { tag: '待加強', text: 'e', advice: 'x' }, { tag: '強項', text: 'f' }, { tag: '待加強', text: 'g', advice: 'x' }];
eq(S.capItems(seven).map(function (it) { return it.text; }), ['b', 'd', 'e', 'f', 'g'], '超過 5 列：依優先序（強項、待加強、進步、留意、感謝）留前 5 名，留意與感謝被捨棄，原順序不變');
eq(S.capItems(seven.slice(0, 4)).length, 4, '不超過 5 列不動');
var seed = 7; function rnd() { seed = (seed * 9301 + 49297) % 233280; return seed / 233280; }
var maxChartH = 0, maxRows = 0;
for (var ti = 0; ti < 60; ti++) {
  var cc = [], pc = [];
  for (var di = 0; di < 7; di++) { cc.push(Math.floor(rnd() * 11)); pc.push(Math.floor(rnd() * 11)); }
  var curM = { checks: 10, weak: 3, counts: cc }, prevM2 = rnd() < 0.7 ? { checks: 10, weak: 3, counts: pc } : null;
  var chH = S.chartHeight(S.quarterCompareSvg(curM, prevM2));
  maxChartH = Math.max(maxChartH, chH);
  var its = S.quarterItems(curM, prevM2);
  maxRows = Math.max(maxRows, its.length);
  ok(its.length <= S.SUMMARY_MAX_ROWS, '小結列數不超過上限 #' + ti);
  ok(S.summaryHeight(its) <= S.summaryBudget(chH), '小結高度排得進第 1 頁預算 #' + ti);
}
ok(maxRows >= 3, '亂數情況涵蓋 3 列以上：' + maxRows);
var longest = Object.keys(S.DIM_ADVICE).reduce(function (a, k) { return S.DIM_ADVICE[k].length > a.length ? S.DIM_ADVICE[k] : a; }, '');
var worst = []; for (var wi = 0; wi < 5; wi++) worst.push({ tag: '待加強', text: '「問題掌握」還有進步空間', advice: longest });
ok(longest.length <= 40, '最長建議句不超過 40 字（單行放得下）：' + longest.length);
ok(S.summaryHeight(worst) <= S.summaryBudget(maxChartH), '最壞情況（5 列、每列都有最長建議）高度 ' + S.summaryHeight(worst) + ' ≤ 預算 ' + S.summaryBudget(maxChartH) + '（最高的圖 ' + maxChartH + '）');
ok(S.summaryHeight([{ tag: '強項', text: 'a' }]) < S.summaryHeight(worst), '只有 1 列時高度小很多');
eq(S.QCHART_W, 555, '單季星狀圖固定寬度');
// 沒有登記卡片：不產生「登記紀錄」標題、不強制換頁（第 1 頁後不會多出空白頁）
var noCardHtml = PDF._buildHtml(S.buildModel(cardSum, { year: 2026, quarter: 4, nowMs: NOW }) && Object.assign({}, S.buildModel(cardSum, { year: 2026, quarter: 4, nowMs: NOW }), { records: [] }), {}, 'quarter');
ok(noCardHtml.indexOf('登記紀錄') < 0 && noCardHtml.indexOf('data-break') < 0 && noCardHtml.indexOf('class="ccard') < 0, '沒有卡片：沒有標題、沒有強制換頁');
ok(noCardHtml.indexOf('本季小結') > 0, '沒有卡片仍有小結');
ok(cardsHtml.indexOf('data-type="title" data-break="1"') > 0, '有卡片：登記紀錄標題強制換頁（從第 2 頁開始）');
var iT = cardsHtml.indexOf('data-type="title"'), iS = cardsHtml.indexOf('本季小結'), iC = cardsHtml.indexOf('class="ccard');
ok(iS > 0 && iS < iT && iT < iC, '順序：小結在標題之前、卡片在標題之後');

console.log('健檢單 core 測試通過：' + passed + ' 項');
