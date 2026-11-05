/* 近期考核純函式測試：node tests/recent-reports-core.test.js */
var assert = require('node:assert');
var C = require('../js/recent-reports-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

var CS = { role: 'cs_admin', store_code: null };
var HQ = { role: 'hq_viewer', store_code: null };
var MGR = { role: 'store_manager', store_code: '新莊' };

function row(id, o) {
  var base = { id: id, employee_id: 'MI-' + id, employee_label: '同仁' + id, store_code: '中和', created_at: '2026-10-01T02:00:00Z', submitted_at: '2026-10-01T02:00:00Z',
    status: 'submitted', verdict: '及格', kind: 'exam', tenure: '正式', total_score: 88, checkup_year: null, checkup_quarter: null };
  for (var k in o) base[k] = o[k];
  return base;
}
var ROWS = [
  row('a', { submitted_at: '2026-10-03T02:00:00Z', store_code: '新莊', verdict: '優秀' }),
  row('b', { submitted_at: '2026-10-01T02:00:00Z', store_code: '新莊', employee_label: '小明', kind: 'checkup', checkup_year: 2026, checkup_quarter: 3 }),
  row('c', { submitted_at: '2026-10-05T02:00:00Z', store_code: '中和', verdict: '不及格' }),
  row('d', { submitted_at: null, created_at: '2026-10-04T02:00:00Z', status: 'draft', verdict: null, total_score: null, store_code: '新莊' }),
  row('e', { submitted_at: '2026-10-02T02:00:00Z', status: 'voided', store_code: '新莊' })
];

// ---- 常數與時間 ----
eq(C.PAGE_SIZE, 20, '每次 20 筆');
eq(C.dateOf(ROWS[3]), '2026-10-04T02:00:00Z', '草稿用建立時間');
eq(C.dateOf(ROWS[0]), '2026-10-03T02:00:00Z', '已送出用送出時間');
eq(C.stamp('2026-10-03T02:00:00Z'), '2026-10-03 10:00', '台北時間 +8');
eq(C.taipeiDate('2026-10-03T17:00:00Z'), '2026-10-04', '跨日以台北日期為準');
eq(C.stamp(''), '', '空字串回空');
eq(C.stamp('not a date'), '', '壞格式回空');

// ---- 身分過濾與排序 ----
eq(C.visibleRows(ROWS, CS).map(function (r) { return r.id; }), ['c', 'd', 'a', 'e', 'b'], '客服部看全部，新到舊');
eq(C.visibleRows(ROWS, HQ).map(function (r) { return r.id; }), ['c', 'a', 'b'], '主管只看已送出（排除草稿與作廢）');
eq(C.visibleRows(ROWS, MGR).map(function (r) { return r.id; }), ['a', 'b'], '店長只看自己門市已送出');
eq(C.visibleRows([], CS), [], '空陣列');
eq(C.visibleRows(null, CS), [], 'null 當空');
eq(ROWS.map(function (r) { return r.id; }), ['a', 'b', 'c', 'd', 'e'], '不改動原陣列順序');

// ---- 篩選 ----
var CSV = C.visibleRows(ROWS, CS);
eq(C.applyFilters(CSV, {}, CS).length, 5, '無條件全部');
eq(C.applyFilters(CSV, { store: '新莊' }, CS).map(function (r) { return r.id; }), ['d', 'a', 'e', 'b'], '門市篩選');
eq(C.applyFilters(C.visibleRows(ROWS, MGR), { store: '中和' }, MGR).map(function (r) { return r.id; }), ['a', 'b'], '店長忽略門市下拉');
eq(C.applyFilters(CSV, { verdict: '優秀' }, CS).map(function (r) { return r.id; }), ['a'], '判定篩選');
eq(C.applyFilters(CSV, { kind: 'checkup' }, CS).map(function (r) { return r.id; }), ['b'], '類型：健檢');
eq(C.applyFilters(CSV, { kind: 'exam' }, CS).map(function (r) { return r.id; }), ['c', 'd', 'a', 'e'], '類型：一般考核');
eq(C.applyFilters(CSV, { from: '2026-10-03' }, CS).map(function (r) { return r.id; }), ['c', 'd', 'a'], '起日含當天');
eq(C.applyFilters(CSV, { to: '2026-10-02' }, CS).map(function (r) { return r.id; }), ['e', 'b'], '訖日含當天');
eq(C.applyFilters(CSV, { from: '2026-10-02', to: '2026-10-03' }, CS).map(function (r) { return r.id; }), ['a', 'e'], '日期區間');
eq(C.applyFilters(CSV, { from: '2026-10-05', to: '2026-10-05' }, CS).map(function (r) { return r.id; }), ['c'], '同一天');
eq(C.applyFilters(CSV, { from: '2026-10-06' }, CS), [], '沒有符合');
// 日期以台北日期算：UTC 10/03 17:00 = 台北 10/04 01:00
var late = [row('z', { submitted_at: '2026-10-03T17:00:00Z' })];
eq(C.applyFilters(late, { from: '2026-10-04' }, CS).length, 1, '台北已是 10/04');
eq(C.applyFilters(late, { to: '2026-10-03' }, CS).length, 0, '台北已過 10/03');
// 搜尋：編號、姓名、暱稱（employee_label）；不分大小寫、去頭尾空白
eq(C.applyFilters(CSV, { q: '小明' }, CS).map(function (r) { return r.id; }), ['b'], '搜尋姓名');
eq(C.applyFilters(CSV, { q: ' mi-c ' }, CS).map(function (r) { return r.id; }), ['c'], '搜尋編號（不分大小寫、去空白）');
eq(C.applyFilters(CSV, { q: '同仁' }, CS).length, 4, '搜尋共同字');
eq(C.applyFilters(CSV, { q: 'zzz' }, CS), [], '搜尋不到');
eq(C.applyFilters(CSV, { store: '新莊', verdict: '優秀', q: 'a' }, CS).map(function (r) { return r.id; }), ['a'], '組合條件');

// ---- 分頁 ----
var many = []; for (var i = 0; i < 45; i++) many.push(row('r' + i));
var p1 = C.paginate(many, 20);
eq([p1.n, p1.total, p1.hasMore, p1.rows.length], [20, 45, true, 20], '第一頁 20/45');
var p2 = C.paginate(many, 40);
eq([p2.n, p2.hasMore], [40, true], '載入更多後 40');
var p3 = C.paginate(many, 60);
eq([p3.n, p3.total, p3.hasMore, p3.rows.length], [45, 45, false, 45], '全部載完');
eq(C.paginate([], 20).hasMore, false, '空列表沒有載入更多');
eq(C.countText(20, 45), '顯示 20 / 共 45 筆', '計數文字');
eq(C.countText(0, 0), '顯示 0 / 共 0 筆', '計數 0');

// ---- 標籤 ----
eq(C.statusInfo({ status: 'voided' }), { cls: 'out', text: '已作廢' }, '已作廢');
eq(C.statusInfo({ status: 'draft' }), { cls: 'unk', text: '暫存中' }, '暫存中');
eq(C.statusInfo({ status: 'submitted' }), { cls: 'on', text: '已送出' }, '已送出');
eq(C.verdictInfo({ verdict: '優秀' }), { cls: 'on', text: '優秀' }, '優秀');
eq(C.verdictInfo({ verdict: '及格' }).cls, 'new', '及格');
eq(C.verdictInfo({ verdict: '需複訓' }).cls, 'unk', '需複訓');
eq(C.verdictInfo({ verdict: '不及格' }).cls, 'out', '不及格');
eq(C.verdictInfo({ verdict: null }), { cls: 'reg', text: '尚未結算' }, '尚未結算');
eq(C.verdictInfo({ verdict: '怪' }).cls, 'reg', '未知判定退回灰色');

// ---- 健檢 ----
eq(C.isCheckup({ kind: 'checkup' }), true, '健檢列');
eq(C.isCheckup({ kind: 'exam' }), false, '一般考核');
eq(C.checkupLabel({ checkup_year: 2026, checkup_quarter: 3 }), '健檢 2026 Q3', '健檢標籤');
eq(C.checkupLabel({ checkup_year: 2026, checkup_quarter: null }), '健檢 2026', '沒有季次');
eq(C.checkupLabel({}), '健檢', '沒有年度');
eq(C.hasAdviceLink({ kind: 'checkup', status: 'submitted' }), true, '已送出健檢有建議單');
eq(C.hasAdviceLink({ kind: 'checkup', status: 'draft' }), false, '健檢草稿沒有建議單');
eq(C.hasAdviceLink({ kind: 'checkup', status: 'voided' }), false, '作廢健檢沒有建議單');
eq(C.hasAdviceLink({ kind: 'exam', status: 'submitted' }), false, '一般考核沒有建議單');
eq(C.adviceUrl({ id: 'a b&c' }), 'advice.html?assessment=a%20b%26c', '建議單網址要編碼');

// ---- 作廢權限 ----
eq(C.canVoid(ROWS[0], CS), true, '客服部可作廢已送出');
eq(C.canVoid(ROWS[3], CS), false, '草稿不可作廢');
eq(C.canVoid(ROWS[4], CS), false, '已作廢不可再作廢');
eq(C.canVoid(ROWS[0], HQ), false, '主管不可作廢');
eq(C.canVoid(ROWS[0], MGR), false, '店長不可作廢');
eq(C.canVoid(ROWS[0], null), false, '沒有身分不可作廢');

// ---- 格式 ----
eq(C.fmt(88.04), '88', '四捨五入一位');
eq(C.fmt(77.55), '77.6', '77.55 -> 77.6');
eq(C.fmt('62'), '62', '字串數字');
eq(C.fmtSize(500), '1 KB', '小於 1KB 顯示 1 KB');
eq(C.fmtSize(2048), '2 KB', 'KB');
eq(C.fmtSize(1572864), '1.5 MB', 'MB');
eq(C.safeNoteUrl('https://example.com/a'), 'https://example.com/a', 'https 可');
eq(C.safeNoteUrl('HTTP://example.com'), 'HTTP://example.com', 'http 大寫可');
eq(C.safeNoteUrl('javascript:alert(1)'), '', 'javascript 不可');
eq(C.safeNoteUrl(null), '', 'null 回空');
eq(C.safeNoteUrl(''), '', '空字串回空');

// 弱項分析雷達圖數值表
var RR = [{ name: 'A', pct: 70, weak: false, n: 3 }, { name: 'B', pct: 50, weak: true, n: 3 }, { name: 'C', pct: null, weak: false, n: 0 }, { name: 'D', pct: 90, weak: false, n: 3 }, { name: 'E', pct: 70, weak: false, n: 3 }];
var RC = [{ name: 'A', pct: 65.5 }, { name: 'B', pct: 60 }, { name: 'C', pct: 80 }, { name: 'D', pct: 90 }, { name: 'E', pct: 75 }];
var sr = C.radarRows(RR, RC);
eq(sr.map(function (r) { return r.name; }), ['D', 'A', 'E', 'B', 'C'], '雷達表由高到低、同分維持原序、無資料最後');
eq(sr.map(function (r) { return r.diff; }), [0, 4.5, -5, -10, null], '差異＝所選範圍減全公司（小數 1 位）；無資料為 null');
eq(sr.filter(function (r) { return r.weak; }).map(function (r) { return r.name; }), ['B'], '最弱旗標保留');
eq(sr[0].co, 90, '全公司得分率帶入');
eq(C.radarRows([{ name: 'X', pct: 82.94 }], [{ name: 'X', pct: 82.86 }])[0].diff, 0, '顯示相同的兩個值差異為 0（先取 1 位小數再相減）');
var sn = C.radarRows(RR, null);
eq(sn.map(function (r) { return r.co; }), [null, null, null, null, null], '無對照時 co 為 null');
eq(sn.map(function (r) { return r.diff; }), [null, null, null, null, null], '無對照時 diff 為 null');
eq(RR[0].name, 'A', '不改動傳入陣列順序');
eq(C.radarRows([], null), [], '空陣列');
eq(C.canCompare('', ['a', 'b']), false, '全公司不畫對照');
eq(C.canCompare('a', ['a', 'b', 'a']), true, '單一門市且資料含多門市就畫');
eq(C.canCompare('a', ['a', 'a']), false, '店長只看得到自己門市不畫');
eq(C.canCompare('a', []), false, '沒資料不畫');
eq(C.canCompare('a', undefined), false, 'undefined 不報錯');

console.log('通過 ' + passed + ' 項');
