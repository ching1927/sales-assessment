/* 名冊 LINE 權限與技師／公務機純函式測試：node tests/line-core.test.js
 * 全部用假資料。 */
var assert = require('node:assert');
var C = require('../js/line-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

var NAMES = ['總', '同行', '中和', '新莊', '樹林', '桃園', '新竹', '旗艦', '南台中', '台南', '高雄', '花蓮'];
// 故意把順序打亂，驗證依 sort_order 排序
var ACCOUNTS = NAMES.map(function (n, i) { return { code: n, name: n, sort_order: i + 1 }; }).reverse();

// ---- 免考核類別 ----
eq(C.EXEMPT_TITLES, ['技師', '公務機'], '免考核類別');
eq(C.isExempt('技師'), true, '技師免考核');
eq(C.isExempt('公務機'), true, '公務機免考核');
eq(C.isExempt('業務'), false, '業務不免');
eq(C.isExempt('店長'), false, '店長不免');
eq(C.isExempt(''), false, '空字串不免');
eq(C.isExempt(undefined), false, 'undefined 不免');
eq(C.isExempt('技師長'), false, '技師長不是技師（完全比對）');

// ---- 新增時回覆狀態預設 ----
eq(C.defaultPeriod('技師'), '已上線', '技師預設已上線');
eq(C.defaultPeriod('公務機'), '已上線', '公務機預設已上線');
eq(C.defaultPeriod('業務'), '考核期', '業務預設考核期');
eq(C.defaultPeriod('工讀'), '考核期', '工讀維持原預設考核期');

// ---- 「納入考核」欄文字 ----
eq(C.assessText({ job_title: '業務', include_in_assessment: true }), '是', '業務納入');
eq(C.assessText({ job_title: '助理', include_in_assessment: false }), '否', '助理不納入');
eq(C.assessText({ job_title: '技師', include_in_assessment: false }), '否（免健檢）', '技師免健檢');
eq(C.assessText({ job_title: '公務機', include_in_assessment: false }), '否（免健檢）', '公務機免健檢');
eq(C.assessText({ job_title: '技師', include_in_assessment: true }), '是', '技師若被手動打開就顯示是');

// ---- 職稱標籤樣式 ----
eq(C.titleClass('技師'), 'tech', '技師標籤');
eq(C.titleClass('公務機'), 'dev', '公務機標籤');
eq(C.titleClass('業務'), '', '業務無特殊標籤');

// ---- line_access 分組 ----
var rows = [
  { employee_id: 'MI-9001', line_code: '總' }, { employee_id: 'MI-9001', line_code: '中和' },
  { employee_id: 'MI-9002', line_code: '花蓮' }
];
eq(C.groupAccess(rows), { 'MI-9001': ['總', '中和'], 'MI-9002': ['花蓮'] }, '依員編分組');
eq(C.groupAccess([]), {}, '空陣列');
eq(C.groupAccess(null), {}, 'null');

// ---- LINE 摘要 ----
eq(C.lineSummary([], ACCOUNTS), { kind: 'none', items: [] }, '沒有權限');
eq(C.lineSummary(undefined, ACCOUNTS), { kind: 'none', items: [] }, 'undefined 視為沒有');
var some = C.lineSummary(['花蓮', '總', '中和'], ACCOUNTS);
eq(some.kind, 'some', '部分');
eq(some.items.map(function (x) { return x.name; }), ['總', '中和', '花蓮'], '依 sort_order 排序，不依傳入順序');
var all = C.lineSummary(NAMES.slice().reverse(), ACCOUNTS);
eq(all.kind, 'all', '12 個全有＝all');
eq(all.items.length, 12, '全有 12 個項目');
eq(C.lineSummary(NAMES.slice(0, 11), ACCOUNTS).kind, 'some', '少一個不是 all');
eq(C.lineSummary(['不存在的代碼'], ACCOUNTS), { kind: 'none', items: [] }, '不認得的代碼忽略');
eq(C.lineSummary(NAMES.concat(['不存在的代碼']), ACCOUNTS).kind, 'all', '多出不認得的代碼不影響 all');
eq(C.lineSummary(['總', '總'], ACCOUNTS).items.length, 1, '重複代碼只算一個');
eq(C.lineSummary(['總'], []).kind, 'none', '沒有帳號清單時不會誤判 all');

// ---- 類別篩選 ----
eq(C.matchCategory('業務', ''), true, '空＝全部');
eq(C.matchCategory('技師', '技師'), true, '技師對技師');
eq(C.matchCategory('業務/助理', '業務'), true, '選業務，業務/助理也算');
eq(C.matchCategory('業務', '助理'), false, '業務不是助理');
eq(C.matchCategory('業務/助理', '助理'), false, '選助理，業務/助理不算');
eq(C.matchCategory('收車業務', '業務'), false, '選業務，收車業務不算');
eq(C.matchCategory('公務機', '公務機'), true, '公務機對公務機');
eq(C.categoryOptions(), ['技師', '公務機', '店長', '業務', '收車業務', '助理', '工讀'], '類別選項');

// ---- 整列篩選 ----
var P = { id: 'MI-9001', nickname: '甲乙', full_name: '測試甲乙', store_code: 'ZZ-A', job_title: '業務', status: '在職' };
eq(C.matchRow(P, {}, []), true, '無條件通過');
eq(C.matchRow(P, undefined, undefined), true, 'f 與 codes 都沒給也通過');
eq(C.matchRow(P, { store: 'ZZ-A' }, []), true, '門市符合');
eq(C.matchRow(P, { store: 'ZZ-B' }, []), false, '門市不符');
eq(C.matchRow(P, { status: '在職' }, []), true, '狀態符合');
eq(C.matchRow(P, { status: '離職' }, []), false, '狀態不符');
eq(C.matchRow(P, { status: '' }, []), true, '含離職（狀態空字串）通過');
eq(C.matchRow(P, { line: '總' }, ['總', '中和']), true, '有這個 LINE');
eq(C.matchRow(P, { line: '花蓮' }, ['總', '中和']), false, '沒有這個 LINE');
eq(C.matchRow(P, { line: '總' }, []), false, '完全沒權限的人，篩 LINE 時不出現');
eq(C.matchRow(P, { q: 'mi-9001' }, []), true, '搜尋編號不分大小寫');
eq(C.matchRow(P, { q: ' 測試甲 ' }, []), true, '搜尋姓名（去空白）');
eq(C.matchRow(P, { q: '找不到' }, []), false, '搜尋不到');
eq(C.matchRow({ id: 'OF-0001', nickname: '公務機', store_code: 'ZZ-A', job_title: '公務機', status: '在職' }, { q: 'of-0001', category: '公務機' }, []), true, '公務機（沒有姓名欄）可用編號與類別找到');
eq(C.matchRow(P, { store: 'ZZ-A', status: '在職', category: '業務', line: '總', q: '甲' }, ['總']), true, '多條件同時符合');
eq(C.matchRow(P, { store: 'ZZ-A', status: '在職', category: '業務', line: '總', q: '甲' }, ['中和']), false, '多條件其中一個不符');

console.log('通過 ' + passed + ' 項');
