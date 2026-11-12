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

// ---- 星狀圖 ----
var svg = S.starSvg(s2.counts);
ok(svg.indexOf('<svg') === 0 && svg.indexOf('</svg>') > 0, '星狀圖是 SVG');
DIMS.forEach(function (d, i) { ok(svg.indexOf(d + '（' + s2.counts[i] + '）') >= 0, '星狀圖標示 ' + d + ' 次數'); });
ok(svg.indexOf('var(--') < 0, '星狀圖不含 CSS 變數（可單獨轉圖）');
ok(svg.indexOf('class=') < 0, '星狀圖不靠外部 CSS');
ok(S.starSvg([0, 0, 0, 0, 0, 0, 0]).indexOf('<circle') < 0, '全 0 沒有資料點');
ok(S.starSvg(null).indexOf('</svg>') > 0, 'null 也能畫');
// 幾何：圖心與第一軸（正上方）
function geo(counts) {
  var L = S.starLayout(counts), svg = L.svg;
  var cx = L.width / 2, cy = Number(svg.match(/<line x1="[\d.]+" y1="([\d.]+)"/)[1]);
  var poly = svg.match(/<polygon points="([^"]+)" fill="rgba/);
  return { L: L, cx: cx, cy: cy, first: poly ? poly[1].split(' ')[0].split(',').map(Number) : null };
}
var g1 = geo([1, 0, 0, 0, 0, 0, 0]);
ok(Math.abs((g1.cy - g1.first[1]) - 105 / 3) < 0.1, '最大次數 1 時以 3 為滿格（1/3 半徑）');
var g6 = geo([6, 3, 0, 0, 0, 0, 0]);
ok(Math.abs((g6.cy - g6.first[1]) - 105) < 0.1, '最大次數 6 時最大者在最外圈');
eq([S.starScaleMax([0, 0, 0, 0, 0, 0, 0]), S.starScaleMax([1, 2, 0, 0, 0, 0, 0]), S.starScaleMax([0, 0, 7, 0, 0, 0, 0])], [3, 3, 7], '外圈刻度下限 3');
ok(svg.indexOf('&') < 0 || svg.indexOf('&amp;') >= 0, '特殊字元已跳脫');

// 版面：左右對稱、標籤完整在 viewBox 內（含兩位數次數）、字級
function textBox(tag, fs) {
  var x = Number(tag.match(/ x="([-\d.]+)"/)[1]), anc = tag.match(/text-anchor="(\w+)"/)[1], txt = tag.replace(/<[^>]+>/g, '');
  var w = 0; for (var i = 0; i < txt.length; i++) w += txt.charCodeAt(i) > 255 ? fs : fs * 0.62;
  return { l: anc === 'end' ? x - w : anc === 'middle' ? x - w / 2 : x, r: anc === 'end' ? x : anc === 'middle' ? x + w / 2 : x + w, anc: anc, txt: txt };
}
[[0, 0, 0, 0, 0, 0, 0], [0, 0, 2, 0, 0, 0, 0], [3, 12, 5, 9, 1, 14, 10], [1, 1, 1, 1, 1, 1, 1], [99, 0, 0, 0, 0, 0, 88]].forEach(function (cs, k) {
  var L = S.starLayout(cs), tags = L.svg.match(/<text [^>]*>[^<]*<\/text>/g);
  var vb = L.svg.match(/viewBox="0 0 (\d+) (\d+)"/);
  eq([Number(vb[1]), Number(vb[2])], [L.width, L.height], '情況 ' + k + '：viewBox 寬高與回傳一致');
  var cxm = L.width / 2, lines = L.svg.match(/<line x1="([\d.]+)"/);
  ok(Math.abs(Number(lines[1]) - cxm) < 0.01, '情況 ' + k + '：圖心在 viewBox 水平正中央');
  eq(tags.length, 7, '情況 ' + k + '：七個面向標籤');
  var minL = 1e9, maxR = -1e9;
  tags.forEach(function (t, i) {
    var bx = textBox(t, 15);
    ok(bx.l >= 0 && bx.r <= L.width, '情況 ' + k + '：「' + bx.txt + '」不被裁切（' + Math.round(bx.l) + '～' + Math.round(bx.r) + ' / ' + L.width + '）');
    ok(bx.txt.indexOf('（' + cs[i] + '）') > 0, '情況 ' + k + '：標籤含次數 ' + cs[i]);
    minL = Math.min(minL, bx.l); maxR = Math.max(maxR, bx.r);
  });
  ok(Math.abs(minL - (L.width - maxR)) <= 15, '情況 ' + k + '：左右留白接近對稱（左 ' + Math.round(minL) + '、右 ' + Math.round(L.width - maxR) + '）');
  ok(L.svg.indexOf('font-size="15"') > 0, '情況 ' + k + '：字級 15');
  var mxv = Math.max.apply(null, cs);
  if (mxv > 0) cs.forEach(function (v, i) { if (v === mxv) ok(tags[i].indexOf('font-weight="800"') > 0, '情況 ' + k + '：被勾最多的「' + D.DIMS[i] + '」加粗'); else ok(tags[i].indexOf('font-weight="500"') > 0, '情況 ' + k + '：其他面向不加粗'); });
});
ok(S.starSvg([0, 0, 0, 0, 0, 0, 0]).indexOf('fill="rgba') < 0, '全 0 不畫資料區塊');
var sw = S.starLayout([0, 0, 5, 0, 0, 0, 0]);
ok(sw.width / sw.height > 0.8 && sw.width / sw.height < 2.2, '圖形長寬比合理（寬 ' + sw.width + '、高 ' + sw.height + '）');

// ---- 截圖尺寸（等比、不裁切）----
eq(S.fitShot(1080, 1920, 606, 1000), { w: 563, h: 1000 }, '手機直式截圖受高度限制');
eq(S.fitShot(1920, 1080, 606, 1000), { w: 606, h: 341 }, '橫圖寬度優先填滿');
eq(S.fitShot(360, 270, 606, 1000), { w: 606, h: 455 }, '小圖放大到欄寬');
var fs1 = S.fitShot(1080, 1920, 606, 940);
ok(fs1.w / 606 >= 0.85, '手機截圖在首張可用高度 940 時寬度仍達欄寬 85%：' + fs1.w);
eq(S.fitShot(0, 100, 606, 900), { w: 0, h: 0 }, '寬為 0 回 0');
eq(S.fitShot(100, 5000, 606, 900), { w: Math.round(100 * 900 / 5000), h: 900 }, '極高圖縮到高度上限');
eq(S.fitShot(1000, 1000, 600, 10).h, 120, '可用高度過小時以 120 為下限（避免縮成一點）');
var r0 = S.fitShot(1080, 1920, 606, 940);
ok(Math.abs(r0.w / r0.h - 1080 / 1920) < 0.01, '比例保持');

console.log('健檢單 core 測試通過：' + passed + ' 項');
