/* 三級制評分與面向備註純函式測試：node tests/grade3-core.test.js
 * 全部用假資料。重點：新舊等級換算相同、舊單（優／良／不及格）結果與改制前完全一樣、新人備註必填判斷。 */
var assert = require('node:assert');
var Scoring = require('../js/scoring.js');
var G = require('../js/grade3-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
var DIMS = Scoring.DIMENSIONS.map(function (d) { return d.name; });
function mk(arr) { var o = {}; DIMS.forEach(function (d, i) { o[d] = arr[i]; }); return o; }
var TO_NEW = { '優': '優良', '良': '尚可', '待加強': '待加強', '不適用': '不適用' };
function toNew(levels) { var o = {}; Object.keys(levels).forEach(function (k) { o[k] = TO_NEW[levels[k]]; }); return o; }

// ---- 新舊等級換算 ----
eq(Scoring.LEVEL_NAMES, ['優良', '尚可', '待加強'], '新單三級');
['優良', '優'].forEach(function (lv) { eq(Scoring.scoreItem(mk([lv, '優', '優', '優', '優', '優', '優'])).dimPoints['資訊正確性'], 20, lv + ' = 100%'); });
['尚可', '良'].forEach(function (lv) { eq(Scoring.scoreItem(mk([lv, '優', '優', '優', '優', '優', '優'])).dimPoints['資訊正確性'], 14, lv + ' = 70%'); });
eq(Scoring.scoreItem(mk(['待加強', '優', '優', '優', '優', '優', '優'])).dimPoints['資訊正確性'], 8, '待加強 = 40%');
eq(Scoring.scoreItem(mk(['不及格', '優', '優', '優', '優', '優', '優'])).dimPoints['資訊正確性'], 0, '舊：不及格 = 0%');
eq(Scoring.scoreItem(mk(['超讚', '優', '優', '優', '優', '優', '優'])).ok, false, '不認得的等級仍被拒');
eq(/優良、尚可、待加強或不適用/.test(Scoring.scoreItem(mk(['超讚', '優', '優', '優', '優', '優', '優'])).error), true, '錯誤訊息改用新等級名稱');

// ---- 回歸：舊字串輸入的結果與改制前完全相同（數字取自既有 scoring.test.js 的固定測資）----
var V1 = mk(['良', '優', '良', '待加強', '優', '良', '優']);
var r1 = Scoring.scoreItem(V1);
eq(r1.score, 77.5, '舊 V1 題組分數');
eq(Scoring.DIMENSIONS.map(function (d) { return r1.dimPoints[d.name]; }), [14, 15, 10.5, 6, 15, 7, 10], '舊 V1 面向得分');
eq(Scoring.scoreAssessment([V1], '新人').verdict, '及格', '舊 V1 新人');
eq(Scoring.scoreAssessment([V1], '正式').verdict, '需複訓', '舊 V1 正式');
var V4 = mk(['不及格', '不及格', '不及格', '不及格', '不及格', '不及格', '不及格']);
eq([Scoring.scoreItem(V4).score, Scoring.scoreAssessment([V4], '新人').total, Scoring.scoreAssessment([V4], '新人').verdict], [0, 0, '不及格'], '舊 V4 全不及格');
var V3 = mk(['優', '優', '優', '優', '優', '優', '優']);
var a5 = Scoring.scoreAssessment([V1, V3], '新人');
eq([a5.total, a5.verdict, a5.weakest], [88.8, '優秀', ['主動引導']], '舊 V5 兩題組');
var NA2 = mk(['優', '優', '優', '優', '良', '不適用', '不適用']);
eq(Scoring.scoreAssessment([NA2, NA2], '新人').weakest, ['風險意識'], '舊：全題組不適用的面向不參與最弱');
var G695 = mk(['良', '優', '優', '優', '良', '不及格', '不及格']);
eq(Scoring.scoreItem(G695).score, 69.5, '舊含不及格的題組 69.5');

// ---- 新單與舊單（無不及格）同組合 → 結果逐項完全相同（500 組隨機，固定亂數種子）----
var seed = 20261111;
function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; }
var OLDSET = ['優', '良', '待加強'];
var same = 0;
for (var t = 0; t < 500; t++) {
  var n = 1 + rnd(4), olds = [], news = [];
  for (var k = 0; k < n; k++) {
    var arr = DIMS.map(function () { return OLDSET[rnd(3)]; });
    var naCount = rnd(3);
    for (var m = 0; m < naCount; m++) arr[rnd(7)] = '不適用';
    if (arr.filter(function (x) { return x === '不適用'; }).length > 2) continue;
    olds.push(mk(arr)); news.push(toNew(mk(arr)));
  }
  if (!olds.length) continue;
  ['新人', '正式'].forEach(function (ten) {
    var ro = Scoring.scoreAssessment(olds, ten), rn = Scoring.scoreAssessment(news, ten);
    assert.deepStrictEqual(rn, ro, '隨機組 ' + t + ' ' + ten + ' 新舊結果應完全相同');
    same++;
  });
}
passed++; assert.ok(same > 400, '隨機比對組數足夠：' + same);
// 新舊字串混在同一場（舊單加新單的情境不會同場，但函式要容得下）
eq(Scoring.scoreAssessment([V1, toNew(V1)], '新人').total, 77.5, '新舊混場：77.5 與 77.5 平均 77.5');

// ---- 顏色與等級種類 ----
eq(['優良', '尚可', '待加強', '不適用'].map(G.levelKind), ['top', 'mid', 'low', 'na'], '新等級種類');
eq(['優', '良', '待加強', '不及格'].map(G.levelKind), ['top', 'mid', 'low', 'low'], '舊等級借用對應種類（優→優良色、良→尚可色、不及格→待加強色）');
eq(G.levelKind('亂寫'), '', '不認得的等級');
eq(G.levelKind(undefined), '', '沒有等級');
eq(['優良', '尚可', '待加強', '不適用'].map(G.levelColor), ['#10B981', '#F59E0B', '#EF4444', '#9CA3AF'], '老闆指定的四個顏色');
eq(['優', '良', '不及格'].map(G.levelColor), ['#10B981', '#F59E0B', '#EF4444'], '舊等級顏色');
eq(['優', '良', '不及格', '優良', '尚可', '待加強', '不適用'].map(G.isLegacyLevel), [true, true, true, false, false, false, false], '判斷舊字串（待加強兩制共用，不算舊）');
eq(G.hasLegacy({ '資訊正確性': '優良', '問題掌握': '良' }), true, '含舊字串');
eq(G.hasLegacy({ '資訊正確性': '優良', '問題掌握': '待加強' }), false, '不含舊字串');
eq(G.hasLegacy(null), false, 'null 不含舊字串');

// ---- 備註規則 ----
eq(['優良', '尚可', '待加強', '不適用', '優', '良'].map(G.noteApplies), [false, true, true, false, false, false], '哪些等級跳出備註欄（只有新字串的尚可、待加強）');
eq(['新人', '正式', '未填到職日'].map(function (t) { return G.noteRequired(t, '尚可'); }), [true, false, false], '只有新人考核必填');
eq(['優良', '尚可', '待加強', '不適用'].map(function (lv) { return G.noteRequired('新人', lv); }), [false, true, true, false], '新人：優良與不適用不必填');

var LV = mk(['優良', '尚可', '待加強', '優良', '不適用', '優良', '尚可']);
eq(G.missingNotes('新人', LV, {}), ['預設訊息運用', '問題掌握', '文字品質'], '新人：三個尚可／待加強都沒寫');
eq(G.missingNotes('新人', LV, { '預設訊息運用': '有寫', '問題掌握': '   ', '文字品質': '　' }), ['問題掌握', '文字品質'], '空白（含全形）等於沒寫');
eq(G.missingNotes('新人', LV, { '預設訊息運用': '遲', '問題掌握': '漏', '文字品質': '錯' }), [], '一個字也算（無字數下限）');
eq(G.missingNotes('新人', LV, { '資訊正確性': '寫在優良上沒用' }).indexOf('資訊正確性'), -1, '優良面向不在必填清單');
eq(G.missingNotes('正式', LV, {}), [], '正式不強迫');
eq(G.missingNotes('新人', null, {}), [], '沒有等級不報錯');
eq(G.missingNotes('新人', LV, null).length, 3, '備註物件缺席＝全沒寫');
eq(G.missingText([]), '', '沒有缺就沒有訊息');
eq(G.missingText(['問題掌握', '文字品質']), '不能送出：以下面向選了尚可或待加強，還沒寫備註：「問題掌握」、「文字品質」。', '擋送出的訊息');

eq(G.notesPayload(LV, { '資訊正確性': '優良不送', '預設訊息運用': '  有寫  ', '問題掌握': ' ', '風險意識': '不適用不送', '文字品質': '好' }),
  { '預設訊息運用': '有寫', '文字品質': '好' }, '送資料庫的備註：只留尚可／待加強、去空白、非空');
eq(G.notesPayload(null, { a: 1 }), {}, 'payload 沒有等級');

eq(G.reportNotes(LV, { '預設訊息運用': '有寫', '資訊正確性': '優良不顯示', '問題掌握': '', '文字品質': '好' }),
  [{ dim: '預設訊息運用', level: '尚可', note: '有寫' }, { dim: '文字品質', level: '尚可', note: '好' }], '成績單只顯示非優良且有備註的面向（照七面向順序）');
eq(G.reportNotes(mk(['優', '良', '良', '優', '不及格', '優', '優']), {}), [], '舊單沒有面向備註就不顯示');
eq(G.reportNotes(mk(['優', '良', '良', '優', '不及格', '優', '優']), null), [], '舊單 dim_notes 缺席也不出錯');
eq(G.reportNotes(null, { a: 1 }), [], 'levels 缺席不出錯');

console.log('通過 ' + passed + ' 項');
