/* 考試接健檢純函式測試：node tests/assess-checkup-core.test.js */
var assert = require('node:assert');
var C = require('../js/assess-checkup-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

eq(C.PASS_LINE, 85, '及格線 85');
eq(C.LIST_URL, 'checkup.html', '健檢名單網址');

// ---- 網址參數 ----
var ok = C.parseParams('?mode=checkup&emp=MI-9011&year=2026&quarter=4');
eq([ok.isCheckup, ok.ok, ok.emp, ok.year, ok.quarter, ok.error], [true, true, 'MI-9011', 2026, 4, ''], '正常網址');
eq(C.parseParams('?mode=checkup&emp=MI-0001&year=2026&quarter=1').quarter, 1, '第 1 季');
eq(C.parseParams('mode=checkup&emp=MI-0001&year=2100&quarter=4').ok, true, '沒有問號、年度上限 2100');
eq(C.parseParams('?mode=checkup&emp=%20MI-0001%20&year=2026&quarter=2').emp, 'MI-0001', '員編去頭尾空白');

// 一般考核：沒有 mode 或 mode 不是 checkup
eq(C.parseParams('').isCheckup, false, '空網址是一般考核');
eq(C.parseParams('?emp=MI-1&year=2026&quarter=4').isCheckup, false, '沒有 mode 是一般考核');
eq(C.parseParams('?mode=exam').isCheckup, false, 'mode 非 checkup 是一般考核');
eq(C.parseParams('?mode=Checkup').isCheckup, false, 'mode 大小寫須完全相符');
eq(C.parseParams(null).isCheckup, false, 'null 是一般考核');

// 缺漏
['?mode=checkup', '?mode=checkup&year=2026&quarter=4', '?mode=checkup&emp=MI-1&quarter=4', '?mode=checkup&emp=MI-1&year=2026', '?mode=checkup&emp=&year=2026&quarter=4'].forEach(function (s) {
  var r = C.parseParams(s);
  eq([r.isCheckup, r.ok, /缺少/.test(r.error)], [true, false, true], '缺漏：' + s);
});
// 格式錯誤
eq(C.parseParams('?mode=checkup&emp=MI-1&year=26&quarter=4').ok, false, '年度非 4 位數');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=1999&quarter=4').ok, false, '年度小於 2000');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2101&quarter=4').ok, false, '年度大於 2100');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2026abc&quarter=4').ok, false, '年度含文字');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2026&quarter=0').ok, false, '季次 0');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2026&quarter=5').ok, false, '季次 5');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2026&quarter=1.5').ok, false, '季次小數');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2026&quarter=12').ok, false, '季次 12');
eq(C.parseParams('?mode=checkup&emp=MI%201&year=2026&quarter=4').ok, false, '員編含空白');
eq(C.parseParams('?mode=checkup&emp=%3Cb%3E&year=2026&quarter=4').ok, false, '員編含特殊字元');
eq(C.parseParams('?mode=checkup&emp=MI-1&year=2026&quarter=0').error.length > 0, true, '格式錯誤有白話訊息');

// ---- 標題與連結 ----
eq(C.titleOf(2026, 4), '健檢（2026 年 第 4 季）', '標題');
eq(C.checkupUrl('MI-9011', 2026, 4), 'assess.html?mode=checkup&emp=MI-9011&year=2026&quarter=4', '健檢網址合約');
eq(C.adviceUrl('3f2a-bb'), 'advice.html?assessment=3f2a-bb', '建議單網址合約');
eq(C.adviceUrl('a b'), 'advice.html?assessment=a%20b', '建議單網址編碼');

// ---- 及格判斷 ----
eq(C.passed(85, 85), true, '剛好 85 通過');
eq(C.passed(84.9, 85), false, '84.9 未通過');
eq(C.passed(100, 85), true, '100 通過');
eq(C.passed(90, null), true, '缺及格線用 85（通過）');
eq(C.passed(80, undefined), false, '缺及格線用 85（未通過）');
eq(C.passed('88.5', '85'), true, '字串數字');

console.log('通過 ' + passed + ' 項');
