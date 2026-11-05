/* 成績單 PDF 純邏輯測試：node tests/report-pdf-core.test.js
 * 「現在」一律傳固定值，結果可重現。 */
var assert = require('node:assert');
var C = require('../js/report-pdf-core.js');
var Scoring = require('../js/scoring.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function ok(cond, label) { assert.ok(cond, label); passed++; }

var NOW = Date.parse('2026-11-03T10:00:00+08:00');
var DIMS = Scoring.DIMENSIONS.map(function (d) { return d.name; });
var LV = { o: '優', g: '良', w: '待加強', f: '不及格', n: '不適用' };
function lv(s) { var o = {}; DIMS.forEach(function (d, i) { o[d] = LV[s.charAt(i)]; }); return o; }
function item(id, seq, cat, code, s, extra, title) {
  var levels = lv(s);
  var it = { id: id, seq: seq, category: cat, code: code, levels: levels, item_score: Scoring.scoreItem(levels).score, isExtra: !!extra };
  if (title !== undefined) it.title = title;
  return it;
}
// 一張考核列（含 Scoring 算出的總分與判定）
function asm(id, iso, tenure, itemsLevels, over) {
  var r = Scoring.scoreAssessment(itemsLevels.map(lv), tenure);
  var row = { id: id, status: 'submitted', tenure: tenure, total_score: r.total, verdict: r.verdict, pass_line: r.passLine,
    hire_date_snapshot: '2026-06-01', created_at: iso, submitted_at: iso, voided_at: null, store_code: '中和' };
  Object.keys(over || {}).forEach(function (k) { row[k] = over[k]; });
  return row;
}

// ---- 日期 ----
eq(C.taipeiToday(NOW), '2026-11-03', '台北今天');
eq(C.taipeiToday(Date.parse('2026-11-03T16:00:00Z')), '2026-11-04', 'UTC 16:00 = 台北隔天');
eq(C.taipeiDate('2026-07-14T17:30:00Z'), '2026-07-15', '成績單日期用台北日期');
eq(C.taipeiDate('壞掉'), '', '壞日期回空字串');

// ---- 資料：同一考生四次已送出（第 4 次含加考題）＋ 草稿 ＋ 作廢 ----
var S1 = ['ggwwgog', 'wggwwgg'];                       // 第 1 次（首次）
var S2 = ['gogwgog', 'gggwggo', 'ogggwog'];
var S3 = ['ogogwog', 'ooggwgo', 'ogoggoo'];
var S4 = ['ooogooo', 'ogoogoo', 'ooogoog'];
var rows = [
  asm('a1', '2026-07-14T10:00:00+08:00', '新人', S1),
  asm('a2', '2026-08-11T10:00:00+08:00', '新人', S2),
  asm('a3', '2026-09-15T10:00:00+08:00', '正式', S3),
  asm('a4', '2026-10-20T10:00:00+08:00', '正式', S4),
  asm('a9', '2026-10-25T10:00:00+08:00', '正式', S4, { status: 'draft', total_score: null, verdict: null, submitted_at: null }),
  asm('av', '2026-10-01T10:00:00+08:00', '正式', S4, { status: 'voided', voided_at: '2026-10-02T10:00:00+08:00' })
];
var itemsBy = {
  a1: S1.map(function (s, i) { return item('i1' + i, i + 1, '分類' + i, 'C-0' + i, s, false, '機密題名甲' + i); }),
  a2: S2.map(function (s, i) { return item('i2' + i, i + 1, '分類' + i, 'C-1' + i, s, false, '機密題名乙' + i); }),
  a3: S3.map(function (s, i) { return item('i3' + i, i + 1, '分類' + i, 'C-2' + i, s, false, '機密題名丙' + i); }),
  a4: S4.map(function (s, i) { return item('i4' + i, i + 1, '分類' + i, 'C-3' + i, s, false, '機密題名丁' + i); })
    .concat([item('i4x', 4, '加考', 'C-3X', 'ffffooo', true, '機密題名加考')])
};
function build(currentId, over) {
  var inp = { person: { name: '範例同仁甲', id: 'E0123', hire: '2026-06-01' }, storeName: '示範門市', assessments: rows,
    currentId: currentId, itemsByAssessment: itemsBy, showTitle: true, nowMs: NOW };
  Object.keys(over || {}).forEach(function (k) { inp[k] = over[k]; });
  return C.buildReport(inp);
}

// ---- 走勢：全部歷次、未送出與作廢排除 ----
var el = C.eligibleAssessments(rows);
eq(el.map(function (r) { return r.id; }), ['a1', 'a2', 'a3', 'a4'], '只留已送出且未作廢，由舊到新');
eq(el.map(function (r) { return r.date; }), ['2026-07-14', '2026-08-11', '2026-09-15', '2026-10-20'], '日期');
eq(C.eligibleAssessments([{ id: 'x', status: 'submitted', voided_at: '2026-01-01T00:00:00Z', total_score: 80, submitted_at: '2026-01-01T00:00:00Z' }]), [], '有 voided_at 的排除');
eq(C.eligibleAssessments([{ id: 'x', status: 'submitted', total_score: null, submitted_at: '2026-01-01T00:00:00Z' }]), [], '沒有總分的排除');
eq(C.eligibleAssessments([
  { id: 'b', status: 'submitted', total_score: 80, verdict: '及格', tenure: '正式', submitted_at: '2026-01-01T00:00:00Z' },
  { id: 'a', status: 'submitted', total_score: 81, verdict: '及格', tenure: '正式', submitted_at: '2026-01-01T00:00:00Z' }
]).map(function (r) { return r.id; }), ['a', 'b'], '同時間依 id 排序');
var rMid = build('a2');
eq(rMid.model.trend.points.length, 4, '看第 2 次的成績單，走勢仍畫全部 4 次（含之後的）');
eq(rMid.model.trend.curIdx, 1, '標出本份是第 2 點');
eq(rMid.model.trend.points.map(function (p) { return p.isCurrent; }), [false, true, false, false], '只有本份標記');
eq(build('a4').model.trend.curIdx, 3, '最新一次標在最後一點');
ok(build('a9').ok === false, '草稿（未送出）不能出 PDF');
ok(build('av').ok === false, '已作廢不能出 PDF');
eq(build('zzz').error, '找不到這張成績單，可能已作廢或尚未送出。', '找不到的白話訊息');

// ---- 首次考核 ----
var first = build('a1');
ok(first.ok, '首次考核可建立');
eq(first.model.compare, null, '首次考核沒有比較');
eq(first.model.prevDate, '', '首次考核沒有上一次日期');
eq(first.model.prevTotal, null, '首次考核沒有上一次總分');
eq(first.model.trend.points.length, 4, '首次考核的走勢也畫全部歷次');
eq(first.model.scoredCount, 2, '首次考核題組數');

// ---- 有上一次 ----
var cur = build('a3').model;
eq(cur.prevDate, '2026-08-11', '上一次是 a2（不是作廢的那張）');
eq(cur.compare.totalDiff, Math.round((cur.total - build('a2').model.total) * 10) / 10, '總分差');
eq(cur.compare.rows.length, 7, '七個面向都有比較');
cur.compare.rows.forEach(function (r) {
  eq(r.diff, Math.round((r.cur - r.prev) * 10) / 10, '面向差 ' + r.name);
});
ok(cur.compare.best && cur.compare.best.value > 0, '有進步面向');
// 手算：全優 vs 全良
var allO = ['oooooo' + 'o'], allG = ['ggggggg'];
var rowsOG = [asm('p', '2026-01-01T10:00:00+08:00', '正式', allG), asm('q', '2026-02-01T10:00:00+08:00', '正式', allO)];
var itemsOG = { p: [item('ip', 1, 'A', 'A-1', allG[0])], q: [item('iq', 1, 'A', 'A-1', allO[0])] };
var og = C.buildReport({ person: { name: 'x', id: 'x' }, assessments: rowsOG, currentId: 'q', itemsByAssessment: itemsOG, showTitle: false, nowMs: NOW }).model;
eq(og.total, 100, '全優總分 100');
eq(og.compare.totalDiff, 30, '全良 70 → 全優 100，差 30');
eq(og.compare.best, { names: DIMS, value: 30 }, '七面向並列進步最多（30 個百分點）');
eq(og.compare.worst, null, '沒有退步面向');
// 退步與持平
var og2 = C.buildReport({ person: { name: 'x', id: 'x' }, assessments: rowsOG, currentId: 'p', itemsByAssessment: itemsOG, showTitle: false, nowMs: NOW });
eq(og2.model.compare, null, 'p 是較早的一次，沒有上一次');
var rowsGO = [rowsOG[1], rowsOG[0]];   // 全優在前、全良在後（時間：把 q 改到 p 之前）
rowsGO[0] = asm('q', '2026-01-01T10:00:00+08:00', '正式', allO); rowsGO[1] = asm('p', '2026-02-01T10:00:00+08:00', '正式', allG);
var down = C.buildReport({ person: { name: 'x', id: 'x' }, assessments: rowsGO, currentId: 'p', itemsByAssessment: itemsOG, showTitle: false, nowMs: NOW }).model;
eq(down.compare.totalDiff, -30, '退步總分差 -30');
eq(down.compare.best, null, '全部退步沒有進步面向');
eq(down.compare.worst.value, 30, '退步幅度 30');
// 持平
var same = C.compare([{ name: 'a', pct: 70 }], [{ name: 'a', pct: 70 }], 80, 80);
eq(same.totalDiff, 0, '持平總分差 0');
eq(same.best, null, '持平沒有進步');
eq(same.worst, null, '持平沒有退步');
// 十分位比較：76.6667 vs 76.7 視為同分，不誤判進步
eq(C.compare([{ name: 'a', pct: 76.6667 }], [{ name: 'a', pct: 76.7 }], 80, 80).best, null, '四捨五入到 0.1 相同視為持平');
// 進步與退步並列
var tie = C.compare([{ name: 'a', pct: 80 }, { name: 'b', pct: 80 }, { name: 'c', pct: 40 }], [{ name: 'a', pct: 70 }, { name: 'b', pct: 70 }, { name: 'c', pct: 70 }], 70, 70);
eq(tie.best, { names: ['a', 'b'], value: 10 }, '並列進步面向全列');
eq(tie.worst, { names: ['c'], value: 30 }, '退步最多面向');
eq(C.compare([{ name: 'a', pct: null }], [{ name: 'a', pct: 70 }], 1, 1).rows[0].diff, null, '任一次不適用則差異為 null');

// ---- 加考題不計入 ----
var withX = build('a4').model;
eq(withX.scoredCount, 3, '計分題組 3 組');
eq(withX.extraCount, 1, '另有加考 1 組');
eq(withX.hasExtra, true, '有加考');
var noX = C.dimRates(itemsBy.a4.filter(function (i) { return !i.isExtra; }));
eq(withX.dims, noX.rows, '有加考題與沒有加考題的面向得分率完全相同');
eq(withX.total, rows[3].total_score, '總分用資料庫存的總分');
eq(Scoring.scoreAssessment(S4.map(lv), '正式').total, withX.total, '加考題不影響總分（與只算核心題組的 Scoring 一致）');
var wrongIfCounted = Scoring.scoreAssessment(S4.concat(['ffffooo']).map(lv), '正式').dimAverages[DIMS[0]];
ok(wrongIfCounted !== withX.dims[0].pct, '（對照）若誤把加考算進去，數字會不一樣');
eq(withX.items.length, 4, '每題得分表含加考題');
eq(withX.items.map(function (r) { return r.isExtra; }), [false, false, false, true], '加考題排在最後');
eq(withX.items.map(function (r) { return r.no; }), [1, 2, 3, null], '加考題沒有題組序號');
eq(withX.items[3].levels, ['不及格', '不及格', '不及格', '不及格', '優', '優', '優'], '加考題等級照列');
ok(typeof withX.items[3].score === 'number', '加考題有分數');
// 加考題即使 seq 較小也排最後
var swapped = C.itemRows([item('1', 1, 'X', 'X-1', 'ooooooo', true), item('2', 2, 'Y', 'Y-1', 'ooooooo', false)], { showTitle: false });
eq(swapped.map(function (r) { return r.isExtra; }), [false, true], '核心題組在前、加考在後（不看 seq 大小）');

// ---- 面向得分率與 Scoring 一致 ----
[['a1', S1], ['a2', S2], ['a3', S3], ['a4', S4]].forEach(function (p) {
  var m = build(p[0]).model, sc = Scoring.scoreAssessment(p[1].map(lv), rows.filter(function (r) { return r.id === p[0]; })[0].tenure);
  eq(m.dims.map(function (d) { return d.pct; }), DIMS.map(function (d) { return sc.dimAverages[d]; }), p[0] + ' 面向得分率與 Scoring.dimAverages 完全相同');
  eq(m.dims.map(function (d) { return d.name; }), DIMS, p[0] + ' 面向順序固定');
  // 總分 ＝ Σ 面向得分率 × 配分 ÷ 100（四捨五入到 0.1）
  var calc = Scoring.DIMENSIONS.reduce(function (s, d, i) { return s + d.weight * m.dims[i].pct / 100; }, 0);
  eq(Math.round(calc * 10) / 10, m.total, p[0] + ' 總分與面向算式一致');
});
// 不適用面向：該面向只算有評的題組
var naRates = C.dimRates([item('1', 1, 'A', 'A-1', 'noooooo'), item('2', 2, 'B', 'B-1', 'ggggggg')]);
eq(naRates.rows[0].pct, 70, '不適用的題組不計入該面向平均');
eq(naRates.rows[1].pct, 85, '其他面向正常平均');
// 資料不完整：錯誤而不是亂算
ok(C.dimRates([{ id: 'x', seq: 1, levels: { 資訊正確性: '優' }, isExtra: false }]).ok === false, '等級不完整回錯誤');
ok(C.dimRates([]).ok === false, '沒有題組回錯誤');
ok(C.dimRates([item('1', 1, 'A', 'A-1', 'ooooooo', true)]).ok === false, '只有加考題沒有核心題組回錯誤');

// ---- 錯誤處理 ----
var missingPrev = build('a3', { itemsByAssessment: { a3: itemsBy.a3 } });
ok(missingPrev.ok === false && /上一次/.test(missingPrev.error), '上一次題組讀不到時說明原因，不亂畫');
ok(build('a3', { itemsByAssessment: {} }).ok === false, '本次題組讀不到回錯誤');

// ---- 考生資料 ----
eq(cur.person, { name: '範例同仁甲', id: 'E0123', store: '示範門市', hire: '2026-06-01' }, '考生資料');
eq(cur.tenure, '正式', '考核時身分取成績單當時的');
eq(cur.date, '2026-09-15', '考核日期');
eq(cur.passLine, 85, '正式合格線 85');
eq(build('a2').model.passLine, 70, '新人合格線 70');
eq(cur.generated, '2026-11-03', '產生日期');
eq(build('a3', { assessments: rows.map(function (r) { return r.id === 'a3' ? Object.assign({}, r, { hire_date_snapshot: null }) : r; }) }).model.person.hire, '2026-06-01', '快照沒有到職日時用名冊到職日');

// ---- 非客服部不含題名 ----
var CS = build('a4', { showTitle: true }).model, MGR = build('a4', { showTitle: false }).model;
ok(JSON.stringify(CS).indexOf('機密題名') >= 0, '客服部版含題名');
eq(CS.items[0].title, '機密題名丁0', '客服部版每題帶 title');
eq(CS.showTitle, true, '客服部版 showTitle');
eq(MGR.showTitle, false, '非客服部版 showTitle 為 false');
ok(JSON.stringify(MGR).indexOf('機密題名') < 0, '非客服部版整份內容都沒有題名（即使輸入資料夾帶題名也不輸出）');
MGR.items.forEach(function (r) { ok(!Object.prototype.hasOwnProperty.call(r, 'title'), '非客服部版每題沒有 title 欄位'); });
eq(MGR.items[0].code, 'C-30', '非客服部版仍有題組編號');
eq(MGR.items[0].category, '分類0', '非客服部版仍有分類');
ok(JSON.stringify(build('a4', {}).model.items) === JSON.stringify(CS.items), '預設呼叫（showTitle 預設 true 的測試輸入）一致');
var noFlag = C.buildReport({ person: { name: 'x', id: 'x' }, assessments: rows, currentId: 'a4', itemsByAssessment: itemsBy, nowMs: NOW });
ok(JSON.stringify(noFlag.model).indexOf('機密題名') < 0, '沒傳 showTitle 時預設不含題名（保守）');
eq(noFlag.model.showTitle, false, '沒傳 showTitle 視為 false');

// ---- 分頁 ----
var H = 1045;
function docBlocks(nRows) {
  var b = [];
  for (var i = 0; i < 5; i++) b.push({ h: [60, 110, 80, 330, 170][i], type: 'blk' });          // 第 1 頁固定內容（共 750）
  b.push({ h: 30, type: 'title', forceBreak: true, keepNext: true });
  b.push({ h: 30, type: 'thead', keepNext: true });
  for (var r = 0; r < nRows; r++) b.push({ h: 40, type: 'row' });
  b.push({ h: 40, type: 'blk' });                                  // 說明
  b.push({ h: 330, type: 'blk', keepNext: true });                 // 走勢
  b.push({ h: 40, type: 'blk' });                                  // 頁尾
  return b;
}
function pageIds(lay) { return lay.pages.map(function (p) { return p.items.map(function (x) { return (x.rep ? 'r' : '') + x.i; }); }); }
var L0 = C.layoutPages(docBlocks(3), H);
eq(L0.pages.length, 2, '3 題組 → 2 頁');
eq(L0.pages[0].items.length, 5, '第 1 頁放抬頭到與上一次比較');
eq(L0.pages[1].items[0].i, 5, '第 2 頁從「每題得分」標題開始');
eq(L0.overflow, false, '沒有溢出');
// 第 2 頁固定高度 30+30+40+330+40 = 470，加 40n；上限 1045 → n ≤ 14（575/40=14.4）
eq(C.layoutPages(docBlocks(14), H).pages.length, 2, '14 列剛好還是 2 頁');
ok(C.layoutPages(docBlocks(14), H).pages[1].used <= H, '14 列第 2 頁沒有超高');
eq(C.layoutPages(docBlocks(15), H).pages.length, 3, '15 列溢出 → 3 頁');
var L15 = C.layoutPages(docBlocks(15), H);
var last15 = L15.pages[2].items.map(function (x) { return x.i; });
eq(last15, [docBlocks(15).length - 2, docBlocks(15).length - 1], '15 列：走勢與頁尾一起換到第 3 頁，列都留在第 2 頁');
ok(L15.pages[2].items.every(function (x) { return !x.rep; }), '15 列：沒有切到表格所以不重印表頭');
// 列多到要切表格：換頁處重印表頭
var L30 = C.layoutPages(docBlocks(30), H), ids30 = pageIds(L30);
eq(L30.pages.length, 3, '30 列 → 3 頁');
eq(L30.pages[2].items[0], { i: 6, rep: true }, '第 3 頁第一項是重印的表頭（表頭區塊 6）');
eq(L30.pages[2].items[1].i, 7 + L30.pages[1].items.filter(function (x) { return !x.rep && x.i >= 7 && x.i < 37; }).length, '第 3 頁第二項接著第 2 頁最後一列的下一列');
// 每個區塊只出現一次（重印表頭除外）
var seen = {};
L30.pages.forEach(function (p) { p.items.forEach(function (x) { if (!x.rep) { ok(!seen[x.i], '區塊 ' + x.i + ' 只出現一次'); seen[x.i] = 1; } }); });
eq(Object.keys(seen).length, docBlocks(30).length, '所有區塊都被排進頁面');
// 每頁不超過可用高度（含重印表頭）
L30.pages.forEach(function (p, i) { ok(p.used <= H, '第 ' + (i + 1) + ' 頁沒有超高'); });
// 標題不會孤零零留在頁尾：標題→表頭→第一列綁在一起
var kb = C.layoutPages([{ h: 1000, type: 'blk' }, { h: 30, type: 'title', keepNext: true }, { h: 30, type: 'thead', keepNext: true }, { h: 40, type: 'row' }, { h: 40, type: 'row' }], H);
eq(pageIds(kb), [['0'], ['1', '2', '3', '4']], '標題與表頭不會單獨留在上一頁，整組換頁');
// 第 2 頁的列放不下時，換頁處重印表頭
var rp = C.layoutPages([{ h: 900, type: 'blk' }, { h: 30, type: 'thead' }, { h: 40, type: 'row' }, { h: 40, type: 'row' }, { h: 40, type: 'row' }], H);
eq(pageIds(rp), [['0', '1', '2', '3'], ['r1', '4']], '表格跨頁時，新的一頁先重印表頭');
// 非表格區塊換頁不重印表頭
var nr = C.layoutPages([{ h: 900, type: 'blk' }, { h: 30, type: 'thead' }, { h: 40, type: 'row' }, { h: 100, type: 'blk' }, { h: 40, type: 'row' }], H);
eq(pageIds(nr).map(function (p) { return p.filter(function (x) { return x[0] === 'r'; }).length; }), [0, 0], '表格結束後的區塊與列不重印表頭');
// 單一區塊超過整頁：照放並標記溢出
var big = C.layoutPages([{ h: 1200, type: 'blk' }], H);
eq(big.overflow, true, '單一區塊比一頁還高要標記溢出');
eq(big.pages.length, 1, '溢出的區塊照放');
// 空文件
eq(C.layoutPages([], H).pages.length, 0, '沒有區塊就沒有頁');

// ---- 剩餘高度分配（兩頁都填滿）----
function filled(lay, blocks) {
  return lay.pages.map(function (pg) {
    var rowsN = pg.items.filter(function (x) { return !x.rep && blocks[x.i].type === 'row'; }).length;
    var gaps = pg.items.slice(0, -1).filter(function (x) { return !x.rep && blocks[x.i].type === 'blk'; }).length;
    return pg.used + pg.rowExtra * rowsN + pg.gapExtra * gaps;
  });
}
var bl3 = docBlocks(3), l3 = C.layoutPages(bl3, H);
l3.pages.forEach(function (p) { ok(p.rowExtra <= C.ROW_EXTRA_MAX, '每列加高不超過上限'); });
filled(l3, bl3).forEach(function (f, i) { ok(Math.abs(f - H) < 0.001, '第 ' + (i + 1) + ' 頁剩餘高度分配後剛好填滿（' + f + '）'); });
eq(l3.pages[0].rowExtra, 0, '第 1 頁沒有表格列，不加高列');
ok(l3.pages[0].gapExtra > 0, '第 1 頁剩餘高度加在區塊之間');
ok(l3.pages[1].rowExtra > 0 && l3.pages[1].rowExtra <= 26, '第 2 頁的列有加高');
var bl30 = docBlocks(30), l30 = C.layoutPages(bl30, H);
filled(l30, bl30).forEach(function (f, i) { ok(f <= H + 0.001, '30 列第 ' + (i + 1) + ' 頁分配後不超高'); });
ok(l30.pages[1].rowExtra <= 1, '第 2 頁已幾乎塞滿，列只加高一點點');
var full = C.layoutPages([{ h: H, type: 'blk' }], H);
eq(full.pages[0].gapExtra, 0, '剛好一頁高沒有可分配');


// ===== 走勢圖標籤避讓 trendLabelLayout =====
function rectsOf(lay, o) {
  var rs = [];
  lay.lines.forEach(function (l, i) { var w = 0; String(o.lines[i].text).split('').forEach(function (c) { w += c.charCodeAt(0) > 255 ? 11 : 6.2; }); var L = l.anchor === 'end' ? l.x - w : l.x; rs.push({ l: L, r: L + w, t: l.y - 10, b: l.y + 3 }); });
  return rs;
}
function overlap(a, b) { return a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b; }
// 情境 (a)：最後一點 81.5 貼近 85 線，單條合格線
var oa = { lineX: { l: 44, r: 690 }, bounds: { l: 44, r: 712, t: 2, b: 640 }, lines: [{ y: 100, text: '及格線 85' }],
  points: [{ x: 94, y: 160, score: '59.5', verdict: '不及格' }, { x: 366, y: 140, score: '72', verdict: '需複訓' }, { x: 640, y: 110, score: '81.5', verdict: '需複訓' }] };
var la = C.trendLabelLayout(oa);
eq(la.points.length, 3, '建議單：每點都有標籤位置');
var ra = rectsOf(la, oa)[0];
la.points.forEach(function (p, i) {
  var x = oa.points[i].x, y = oa.points[i].y, bx = p.score.anchor === 'middle' ? x - 14 : p.score.anchor === 'start' ? p.score.x : p.score.x - 28;
  ok(!overlap({ l: bx, r: bx + 28, t: p.score.y - 11, b: p.score.y + 2 }, ra), '建議單：第 ' + (i + 1) + ' 點分數不壓合格線文字');
  ok(!overlap({ l: bx, r: bx + 28, t: p.score.y - 11, b: p.score.y + 2 }, { l: x - 8, r: x + 8, t: y - 8, b: y + 8 }), '建議單：第 ' + (i + 1) + ' 點分數不壓自己的圓點');
});
// 情境 (b)：兩條合格線 85、70，74.5 夾在兩線中間且貼右緣
var ob = { lineX: { l: 44, r: 580 }, bounds: { l: 44, r: 598, t: 2, b: 320 }, lines: [{ y: 127, text: '新人合格線 70' }, { y: 83.5, text: '正式合格線 85' }],
  points: [{ x: 80, y: 100.9, score: '79', verdict: '需複訓' }, { x: 340, y: 70.5, score: '89.5', verdict: '及格' }, { x: 544, y: 114, score: '74.5', verdict: '不及格' }] };
var lb = C.trendLabelLayout(ob), rb = rectsOf(lb, ob);
ok(!overlap(rb[0], rb[1]), '成績單：兩條合格線文字互不重疊');
lb.points.forEach(function (p, i) {
  var x = ob.points[i].x, bx = p.score.anchor === 'middle' ? x - 14 : p.score.anchor === 'start' ? p.score.x : p.score.x - 28, sr = { l: bx, r: bx + 28, t: p.score.y - 11, b: p.score.y + 2 };
  rb.forEach(function (r, k) { ok(!overlap(sr, r), '成績單：第 ' + (i + 1) + ' 點分數不壓合格線文字 ' + (k + 1)); });
  ok(sr.l >= 44 - 1 && sr.r <= 598, '成績單：第 ' + (i + 1) + ' 點分數在可用範圍內');
});
// 沒有合格線、單一點：回傳上方標籤
var one = C.trendLabelLayout({ lineX: { l: 0, r: 100 }, bounds: { l: 0, r: 100, t: 0, b: 100 }, lines: [], points: [{ x: 50, y: 60, score: '80', verdict: '' }] });
eq(one.lines.length, 0, '無合格線時 lines 為空');
eq(one.points[0].verdict, null, '沒有判定文字時不回傳判定位置');
console.log('通過 ' + passed + ' 項');
