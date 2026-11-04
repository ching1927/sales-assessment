/* 每年健檢純函式測試：node tests/checkup-core.test.js
 * 「現在」一律傳固定值，結果可重現。 */
var assert = require('node:assert');
var C = require('../js/checkup-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

// ---- 台北今天所屬年季 ----
eq(C.taipeiYearQuarter(Date.parse('2026-11-04T10:00:00+08:00')), { year: 2026, quarter: 4 }, '11 月是 Q4');
eq(C.taipeiYearQuarter(Date.parse('2026-01-01T00:00:00+08:00')), { year: 2026, quarter: 1 }, '1/1 台北凌晨是 Q1');
eq(C.taipeiYearQuarter(Date.parse('2025-12-31T16:00:00Z')), { year: 2026, quarter: 1 }, 'UTC 12/31 16:00 = 台北 2026/1/1 → Q1');
eq(C.taipeiYearQuarter(Date.parse('2026-03-31T15:59:00Z')), { year: 2026, quarter: 1 }, 'UTC 3/31 15:59 = 台北 3/31 23:59 → Q1');
eq(C.taipeiYearQuarter(Date.parse('2026-03-31T16:00:00Z')), { year: 2026, quarter: 2 }, 'UTC 3/31 16:00 = 台北 4/1 → Q2');
eq(C.taipeiYearQuarter(Date.parse('2026-06-30T16:00:00Z')), { year: 2026, quarter: 3 }, '台北 7/1 → Q3');
eq(C.taipeiYearQuarter(Date.parse('2026-09-30T16:00:00Z')), { year: 2026, quarter: 4 }, '台北 10/1 → Q4');
eq(C.yearOptions(Date.parse('2026-11-04T10:00:00+08:00')), [2027, 2026, 2025, 2024], '年度選項');

// ---- 門市排序 ----
eq(C.storeRank('中和'), 1, '中和排第 2 位（索引 1）');
eq(C.storeRank('不存在'), C.STORE_ORDER.length, '不在清單排最後');
var sr = C.sortStores([{ store_code: '高雄' }, { store_code: '花蓮' }, { store_code: '新莊' }, { store_code: '中和' }, { store_code: '某新店' }]);
eq(sr.map(function (r) { return r.store_code; }), ['中和', '新莊', '高雄', '花蓮', '某新店'], '依 STORE_ORDER 排');

// ---- 季次表統計 ----
var QROWS = [
  { store_code: '中和', store_name: '中和', quarter: 1, headcount: 10 },
  { store_code: '新莊', store_name: '新莊', quarter: 1, headcount: 8 },
  { store_code: '新竹', store_name: '新竹', quarter: 2, headcount: 5 },
  { store_code: '台南', store_name: '台南', quarter: 4, headcount: 6 }
];
eq(C.quarterStats(QROWS, {}), [
  { quarter: 1, stores: 2, people: 18 }, { quarter: 2, stores: 1, people: 5 },
  { quarter: 3, stores: 0, people: 0 }, { quarter: 4, stores: 1, people: 6 }], '無改選的統計');
eq(C.quarterStats(QROWS, { '中和': 3 }), [
  { quarter: 1, stores: 1, people: 8 }, { quarter: 2, stores: 1, people: 5 },
  { quarter: 3, stores: 1, people: 10 }, { quarter: 4, stores: 1, people: 6 }], '改選後即時重算');
eq(C.quarterStats(QROWS, { '中和': 9, '不存在': 2 }), C.quarterStats(QROWS, {}), '非法季次與不存在門市忽略');
eq(C.quarterStats([{ store_code: 'X', quarter: 2, headcount: null }], null)[1], { quarter: 2, stores: 1, people: 0 }, 'headcount 為 null 當 0');
eq(C.quarterStats(null, null).length, 4, 'null 列仍回 4 季');
eq(C.changedStores(QROWS, { '中和': 3, '新莊': 1 }), [{ store: '中和', quarter: 3 }], '只列真的有改的');
eq(C.changedStores(QROWS, {}), [], '沒改回空');

// ---- 名單門市篩選選項 ----
var ROSTER = [
  { employee_id: 'MI-0002', store_code: '新莊', store_name: '新莊' },
  { employee_id: 'MI-0001', store_code: '中和', store_name: '中和' },
  { employee_id: 'MI-0009', store_code: '台南', store_name: '台南' }   // 排定後台南改了季次，仍在名單
];
eq(C.rosterStoreOptions(ROSTER, QROWS, 1).map(function (o) { return o.store_code; }), ['中和', '新莊', '台南'], '該季門市＋名單內出現的門市');
eq(C.rosterStoreOptions([], QROWS, 2).map(function (o) { return o.store_code; }), ['新竹'], '沒有名單只列該季門市');
eq(C.rosterStoreOptions([], QROWS, 3), [], '該季沒有門市');

// ---- 名單篩選與排序 ----
eq(C.filterRoster(ROSTER, '').length, 3, '不篩選');
eq(C.filterRoster(ROSTER, '中和').map(function (r) { return r.employee_id; }), ['MI-0001'], '依門市篩');
eq(C.sortRoster([
  { employee_id: 'MI-0005', store_code: '新莊' }, { employee_id: 'MI-0003', store_code: '新莊' }, { employee_id: 'MI-0007', store_code: '中和' }
]).map(function (r) { return r.employee_id; }), ['MI-0007', 'MI-0003', 'MI-0005'], '門市順序再員工編號');
var orig = [{ employee_id: 'b', store_code: '中和' }, { employee_id: 'a', store_code: '中和' }];
C.sortRoster(orig);
eq(orig[0].employee_id, 'b', '排序不改動原陣列');

// ---- 狀態與判定標籤 ----
eq(C.statusInfo('待排定'), { label: '待排定', cls: 'reg' }, '待排定標籤');
eq(C.statusInfo('已排定'), { label: '已排定', cls: 'new' }, '已排定標籤');
eq(C.statusInfo('已完成'), { label: '已完成', cls: 'on' }, '已完成標籤');
eq(C.statusInfo('怪狀態').label, '怪狀態', '未知狀態照原文');
eq(C.verdictCls('優秀'), 'on', '優秀');
eq(C.verdictCls('及格'), 'on', '及格');
eq(C.verdictCls('需複訓'), 'unk', '需複訓');
eq(C.verdictCls('不及格'), 'out', '不及格');
eq(C.formatScore(88.25), '88.3', '分數小數 1 位');
eq(C.formatScore('92'), '92', '字串分數');
eq(C.formatScore(null), '—', '無分數');

// ---- 排定時間格式（台北）----
eq(C.formatScheduled('2026-11-12T06:00:00+00:00'), '2026-11-12 14:00', 'UTC 轉台北');
eq(C.formatScheduled('2026-11-12T14:05:00+08:00'), '2026-11-12 14:05', '帶 +08:00');
eq(C.formatScheduled('2026-11-12T16:30:00Z'), '2026-11-13 00:30', '跨日');
eq(C.formatScheduled(null), '—', 'null');
eq(C.formatScheduled('壞掉'), '—', '無法解析');

// ---- 日期＋時間 -> ISO ----
eq(C.scheduleToIso('2026-11-12', '14:00'), '2026-11-12T14:00:00+08:00', '正常');
eq(C.scheduleToIso('2026-11-12', '09:05:00'), '2026-11-12T09:05:00+08:00', '時間含秒');
eq(C.scheduleToIso('2026-02-30', '14:00'), null, '不存在的日期');
eq(C.scheduleToIso('', '14:00'), null, '沒填日期');
eq(C.scheduleToIso('2026-11-12', ''), null, '沒填時間');
eq(C.scheduleToIso('2026-11-12', '24:00'), null, '24 點');
eq(C.scheduleToIso('2026-11-12', '12:60'), null, '60 分');

// ---- 備註 ----
eq(C.noteError(''), '', '空備註可');
eq(C.noteError('a'.repeat(500)), '', '500 字可');
eq(C.noteError('a'.repeat(501)), '備註最多 500 字。', '501 字不可');
eq(C.noteError('  ' + 'a'.repeat(500) + '  '), '', '去頭尾空白後算');

// ---- 連結合約 ----
eq(C.beginUrl('MI-0047', 2026, 4), 'assess.html?mode=checkup&emp=MI-0047&year=2026&quarter=4', '開始健檢網址格式');
eq(C.adviceUrl('3f2a-uuid'), 'advice.html?assessment=3f2a-uuid', '建議單網址格式');
eq(C.beginUrl('A B&C', 2026, 1), 'assess.html?mode=checkup&emp=A%20B%26C&year=2026&quarter=1', '員編特殊字元會編碼');

// ---- 各狀態、各角色的操作 ----
function kinds(o) { return o.buttons.map(function (b) { return b.kind; }); }
var TODO = { employee_id: 'MI-0001', status: '待排定', assessment_id: null, assessment_status: null, checkup_id: null };
var SCHED = { employee_id: 'MI-0002', status: '已排定', assessment_id: null, assessment_status: null, checkup_id: 'ck-1' };
var DRAFT = { employee_id: 'MI-0003', status: '已排定', assessment_id: 'as-d', assessment_status: 'draft', checkup_id: 'ck-2' };
var DONE = { employee_id: 'MI-0004', status: '已完成', assessment_id: 'as-9', assessment_status: 'submitted', checkup_id: 'ck-3' };

eq(kinds(C.rosterActions(TODO, 'cs_admin', 2026, 4)), ['schedule'], '客服部：待排定只有排定');
eq(kinds(C.rosterActions(SCHED, 'cs_admin', 2026, 4)), ['unschedule', 'begin'], '客服部：已排定無草稿 取消排定＋開始健檢');
eq(C.rosterActions(SCHED, 'cs_admin', 2026, 4).buttons[1].href, 'assess.html?mode=checkup&emp=MI-0002&year=2026&quarter=4', '開始健檢連結');
eq(C.rosterActions(SCHED, 'cs_admin', 2026, 4).hint, '', '無草稿沒有提示');
var d = C.rosterActions(DRAFT, 'cs_admin', 2026, 4);
eq(kinds(d), ['continue'], '客服部：有草稿只有繼續健檢，不可取消排定');
eq(d.buttons[0].href, 'assess.html?mode=checkup&emp=MI-0003&year=2026&quarter=4', '繼續健檢連結');
eq(/放棄草稿/.test(d.hint), true, '有草稿提示先放棄草稿');
var dn = C.rosterActions(DONE, 'cs_admin', 2026, 4);
eq(kinds(dn), ['advice'], '客服部：已完成查看建議單');
eq(dn.buttons[0].href, 'advice.html?assessment=as-9', '建議單連結');
eq(kinds(C.rosterActions(DONE, 'hq_viewer', 2026, 4)), ['advice'], '主管：已完成可查看建議單');
eq(kinds(C.rosterActions(DONE, 'store_manager', 2026, 4)), ['advice'], '店長：已完成可查看建議單');
['hq_viewer', 'store_manager', null].forEach(function (role) {
  eq(kinds(C.rosterActions(TODO, role, 2026, 4)), [], String(role) + '：待排定無按鈕');
  eq(kinds(C.rosterActions(SCHED, role, 2026, 4)), [], String(role) + '：已排定無按鈕');
  eq(kinds(C.rosterActions(DRAFT, role, 2026, 4)), [], String(role) + '：草稿中無按鈕');
});
eq(kinds(C.rosterActions({ employee_id: 'X', status: '已完成', assessment_id: null }, 'cs_admin', 2026, 4)), [], '已完成但沒有成績單編號就沒有連結');
eq(C.rosterActions(null, 'cs_admin', 2026, 4), { buttons: [], hint: '' }, 'null 列');

console.log('通過 ' + passed + ' 項');
