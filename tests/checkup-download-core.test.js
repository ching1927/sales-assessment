/* 健檢單下載管制純函式測試：node tests/checkup-download-core.test.js */
var assert = require('node:assert');
var D = require('../js/checkup-download-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

// ---- 開放日期 ----
eq(D.openDate(2026, 1, 'quarter'), '2026-04-10', 'Q1 → 當年 4/10');
eq(D.openDate(2026, 2, 'quarter'), '2026-07-10', 'Q2 → 當年 7/10');
eq(D.openDate(2026, 3, 'quarter'), '2026-10-10', 'Q3 → 當年 10/10');
eq(D.openDate(2026, 4, 'quarter'), '2027-01-10', 'Q4 季度 → 隔年 1/10（跨年）');
eq(D.openDate(2026, 4, 'year'), '2027-01-10', '年度 → 隔年 1/10');
eq(D.openDate(2026, 1, 'year'), '2027-01-10', '年度不看季次');
eq(D.openDate('2026', '3', 'quarter'), '2026-10-10', '字串年季也可');
eq(D.openDate(2026, 5, 'quarter'), null, '季次 5 不合法');
eq(D.openDate(2026, 0, 'quarter'), null, '季次 0 不合法');
eq(D.openDate(1999, 1, 'quarter'), null, '年度太小不合法');
eq(D.openDate(2026, 1, 'bad'), null, '種類不合法');

// ---- 今天（台北） ----
eq(D.taipeiToday(Date.UTC(2026, 3, 9, 15, 59, 59)), '2026-04-09', 'UTC 15:59 仍是台北 4/9');
eq(D.taipeiToday(Date.UTC(2026, 3, 9, 16, 0, 0)), '2026-04-10', 'UTC 16:00 已是台北 4/10');
eq(D.taipeiToday(Date.UTC(2026, 11, 31, 16, 0, 0)), '2027-01-01', '跨年');

// ---- 是否開放：含當日、前一天不行 ----
eq(D.isOpen('store_manager', 2026, 1, 'quarter', '2026-04-09'), false, '店長 Q1 開放前一天不行');
eq(D.isOpen('store_manager', 2026, 1, 'quarter', '2026-04-10'), true, '店長 Q1 開放當日可以（含頭）');
eq(D.isOpen('store_manager', 2026, 1, 'quarter', '2026-04-11'), true, '店長 Q1 開放後可以');
eq(D.isOpen('store_manager', 2026, 3, 'quarter', '2026-10-09'), false, '店長 Q3 前一天不行');
eq(D.isOpen('store_manager', 2026, 3, 'quarter', '2026-10-10'), true, '店長 Q3 當日可以');
eq(D.isOpen('store_manager', 2026, 4, 'quarter', '2026-12-31'), false, '店長 Q4 當年年底還不行');
eq(D.isOpen('store_manager', 2026, 4, 'quarter', '2027-01-09'), false, '店長 Q4 隔年 1/9 不行');
eq(D.isOpen('store_manager', 2026, 4, 'quarter', '2027-01-10'), true, '店長 Q4 隔年 1/10 可以（跨年）');
eq(D.isOpen('store_manager', 2026, 4, 'year', '2027-01-09'), false, '店長年度 1/9 不行');
eq(D.isOpen('store_manager', 2026, 4, 'year', '2027-01-10'), true, '店長年度 1/10 可以');
eq(D.isOpen('store_manager', 2026, 4, 'quarter', '2026-11-17'), false, '店長 Q4 在 11/17 不行（樣品情境）');
eq(D.isOpen('cs_admin', 2026, 4, 'year', '2026-01-01'), true, '客服部不受限');
eq(D.isOpen('hq_viewer', 2026, 4, 'year', '2026-01-01'), true, '總公司主管比照客服部不受限');
eq(D.isOpen(undefined, 2026, 1, 'quarter', '2026-01-01'), false, '沒有角色視為受限');
eq(D.isOpen('store_manager', 2026, 1, 'quarter', null), false, '沒有今天日期保守不開放');
eq(D.isRestricted('store_manager'), true, '店長受限');
eq(D.isRestricted('cs_admin'), false, '客服部不受限');

// ---- 文字 ----
eq(D.openLabel(2026, 1, 'quarter'), '4/10 開放', 'Q1 標籤');
eq(D.openLabel(2026, 4, 'quarter'), '1/10 開放', 'Q4 標籤是隔年 1/10');
eq(D.openLabel(2026, 4, 'year'), '1/10 開放', '年度標籤');
eq(D.kindLabel('year'), '年度', '年度');
eq(D.kindLabel('quarter'), '季度', '季度');

// ---- ZIP 檔名與路徑 ----
eq(D.zipName({ kind: 'quarter', year: 2026, quarter: 3, storeName: '中和' }), '健檢單_中和_2026Q3.zip', '季度 ZIP 檔名');
eq(D.zipName({ kind: 'year', year: 2026, quarter: 4, storeName: '中和' }), '年度健檢單_中和_2026.zip', '年度 ZIP 檔名');
eq(D.zipName({ kind: 'quarter', year: 2026, quarter: 3, storeName: '' }), '健檢單_全部門市_2026Q3.zip', '全部門市');
eq(D.zipName({ kind: 'quarter', year: 2026, quarter: 3, storeName: 'a/b' }), '健檢單_a_b_2026Q3.zip', '檔名去掉不允許字元');

var sums = [
  { employee_id: 'MI-0002', name: '乙', store_code: '新莊' },
  { employee_id: 'MI-0001', name: '甲', store_code: '中和' },
  { employee_id: 'MI-0003', name: '甲', store_code: '中和' }
];
var groups = D.groupByStore(sums);
eq(groups.map(function (g) { return g.store_code + ':' + g.items.length; }), ['中和:2', '新莊:1'], '依門市順序分組');
var nm = function (s) { return '健檢單_' + s.name + '_2026Q3.pdf'; };
var sn = function (c) { return c + '店'; };
eq(D.zipEntries(groups, nm, sn).map(function (e) { return e.path; }),
  ['中和店/健檢單_甲_2026Q3.pdf', '中和店/健檢單_甲_2026Q3(2).pdf', '新莊店/健檢單_乙_2026Q3.pdf'], '多門市分資料夾、同名加 (2)');
eq(D.zipEntries([groups[0]], nm, sn).map(function (e) { return e.path; }),
  ['健檢單_甲_2026Q3.pdf', '健檢單_甲_2026Q3(2).pdf'], '單一門市不分資料夾');
eq(D.zipEntries([], nm, sn), [], '空清單');

// ---- 下載紀錄文字 ----
eq(D.logContent({ method: '一鍵下載', kind: '季度', year: 2026, quarter: 3, people_count: 4 }), '2026 第3季｜全店 4 人', '一鍵季度');
eq(D.logContent({ method: '一鍵下載', kind: '年度', year: 2026, quarter: 4, people_count: 4 }), '2026 年度｜全店 4 人', '一鍵年度');
eq(D.logContent({ method: '單人下載', kind: '季度', year: 2026, quarter: 3, employee_id: 'MI-0001', employee_name: '小王' }), '小王（MI-0001）｜2026 第3季', '單人');
eq(D.logTime('2026-11-17T02:25:00Z'), '2026-11-17 10:25', '台北時間');

console.log('checkup-download-core：' + passed + ' 項通過');
