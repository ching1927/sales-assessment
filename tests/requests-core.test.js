/* 待考回報純函式測試：node tests/requests-core.test.js
 * 「今天」與「現在」一律傳固定值，結果可重現。 */
var assert = require('node:assert');
var C = require('../js/requests-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

var TODAY = '2026-11-03';

// ---- 常數 ----
eq(C.KINDS, ['新人', '複檢'], '兩種情況（回考核期已停用）');
eq(C.KIND_LABEL['回考核期'], '回考核期再考', '舊紀錄的「回考核期」仍有顯示名稱');
eq(C.KIND_LABEL['複檢'], '改善單複檢', '複檢顯示名稱');
eq(C.MAX_DATES, 3, '日期上限 3');
eq(C.MAX_NOTE, 500, '備註上限 500');

// ---- 日期格式 ----
eq(C.isDateStr('2026-11-03'), true, '正常日期');
eq(C.isDateStr('2026-02-30'), false, '2/30 不存在');
eq(C.isDateStr('2028-02-29'), true, '閏年 2/29');
eq(C.isDateStr('2026-13-01'), false, '13 月');
eq(C.isDateStr('2026-1-3'), false, '沒補零');
eq(C.isDateStr(''), false, '空字串');
eq(C.isDateStr(null), false, 'null');

// ---- 台北今天 ----
eq(C.taipeiToday(Date.parse('2026-11-03T00:30:00+08:00')), '2026-11-03', '台北凌晨 00:30 仍是當天');
eq(C.taipeiToday(Date.parse('2026-11-02T16:30:00Z')), '2026-11-03', 'UTC 前一天 16:30 = 台北隔天');
eq(C.taipeiToday(Date.parse('2026-11-03T15:59:00Z')), '2026-11-03', 'UTC 15:59 仍是台北當天');
eq(C.taipeiToday(Date.parse('2026-11-03T16:00:00Z')), '2026-11-04', 'UTC 16:00 = 台北隔天 00:00');

// ---- 日期加減 ----
eq(C.addDays('2026-11-03', 3), '2026-11-06', '加 3 天');
eq(C.addDays('2026-12-30', 3), '2027-01-02', '跨年');
eq(C.addDays('2026-02-27', 2), '2026-03-01', '跨月（非閏年）');
eq(C.addDays('壞掉', 1), '', '壞日期回空字串');

// ---- 日期驗證 ----
var v = C.validateDates(['2026-11-05'], TODAY);
eq(v.ok, true, '1 個日期通過');
eq(v.dates, ['2026-11-05'], '1 個日期內容');
eq(C.validateDates(['2026-11-03'], TODAY).ok, true, '今天可以（不早於今天）');
eq(C.validateDates(['2026-11-02'], TODAY).error, '希望考核日期不能早於今天。', '昨天不行');
eq(C.validateDates(['2026-11-09', '2026-11-05', '2026-11-07'], TODAY).dates, ['2026-11-05', '2026-11-07', '2026-11-09'], '3 個通過且由早到晚');
eq(C.validateDates(['2026-11-05', '2026-11-06', '2026-11-07', '2026-11-08'], TODAY).error, '希望考核日期最多 3 個。', '4 個不行');
eq(C.validateDates([], TODAY).error, '請至少選一個希望考核日期（最多 3 個）。', '0 個不行');
eq(C.validateDates(null, TODAY).ok, false, 'null 不行');
eq(C.validateDates(['2026-11-05', '2026-11-05'], TODAY).error, '希望考核日期不能重複。', '重複不行');
eq(C.validateDates(['2026-11-05', '2026-11-02'], TODAY).error, '希望考核日期不能早於今天。', '其中一個過去不行');
eq(C.validateDates(['2026-02-30'], TODAY).error, '希望考核日期格式不正確，請重新選擇。', '不存在的日期');
eq(C.validateDates(['abc'], TODAY).ok, false, '亂字串');
eq(C.validateDates(['2026-11-05'], '壞').ok, false, '今天壞掉時不放行');
var arr = ['2026-11-08', '2026-11-05'];
C.validateDates(arr, TODAY);
eq(arr, ['2026-11-08', '2026-11-05'], '不改動傳入陣列');

// ---- 新人影片規則 ----
eq(C.videoError('新人', true), '', '新人勾選通過');
eq(C.videoError('新人', false) !== '', true, '新人沒勾不通過');
eq(C.videoError('新人', undefined) !== '', true, '新人沒給值不通過');
eq(C.videoError('新人', 'true') !== '', true, '新人只認布林 true');
eq(C.videoError('回考核期', false), '', '回考核期不適用');
eq(C.videoError('複檢', false), '', '複檢不適用');
eq(C.videoValue('新人', true), true, '新人送 true');
eq(C.videoValue('回考核期', true), null, '回考核期送 null');
eq(C.videoValue('複檢', false), null, '複檢送 null');

// ---- 備註長度 ----
eq(C.noteError(''), '', '空備註可以');
eq(C.noteError(null), '', 'null 備註可以');
eq(C.noteError('字'.repeat(500)), '', '500 字可以');
eq(C.noteError('字'.repeat(501)), '備註最多 500 字（目前 501 字）。', '501 字不行');
eq(C.noteError('  ' + '字'.repeat(500) + '  '), '', '頭尾空白不算');
eq(C.noteError('😀'.repeat(500)), '', '表情符號一個算 1 字');

// ---- 整份回報驗證 ----
function base(o) {
  var r = { kind: '新人', employeeId: 'MI-0001', dates: ['2026-11-06'], video: true, note: '  已完成訓練  ', today: TODAY };
  Object.keys(o || {}).forEach(function (k) { r[k] = o[k]; });
  return r;
}
var ok1 = C.validateRequest(base());
eq(ok1.ok, true, '新人完整回報通過');
eq(ok1.video, true, '新人 video 為 true');
eq(ok1.note, '已完成訓練', '備註去頭尾空白');
eq(ok1.ticketId, null, '非複檢沒有改善單');
eq(C.validateRequest(base({ kind: '壞' })).error, '請選擇回報情況。', '情況不對');
eq(C.validateRequest(base({ employeeId: '' })).error, '請選擇人員。', '沒選人');
eq(C.validateRequest(base({ dates: [] })).ok, false, '沒日期');
eq(C.validateRequest(base({ video: false })).ok, false, '新人沒勾影片');
eq(C.validateRequest(base({ note: '字'.repeat(501) })).ok, false, '備註太長');
var rc = C.validateRequest(base({ kind: '回考核期', video: false }));
eq(rc.ok, false, '回考核期已停用，不能再新增回報');
eq(rc.error, '請選擇回報情況。', '回考核期回報會被擋下並提示重新選擇');
eq(C.validateRequest(base({ kind: '複檢', video: false })).ok, false, '複檢缺改善單');
var rr = C.validateRequest(base({ kind: '複檢', video: false, ticketId: 'T-1' }));
eq(rr.ok, true, '複檢帶改善單通過');
eq(rr.ticketId, 'T-1', '複檢回傳改善單 id');

// ---- 台北時間 datetime-local <-> ISO ----
eq(C.taipeiLocalToIso('2026-11-05T14:00'), '2026-11-05T14:00:00+08:00', 'local 轉 ISO');
eq(C.taipeiLocalToIso('2026-11-05T14:00:30'), '2026-11-05T14:00:30+08:00', '帶秒數');
eq(C.taipeiLocalToIso('2026-11-05T24:00'), null, '24 點不合法');
eq(C.taipeiLocalToIso('2026-11-05T14:60'), null, '60 分不合法');
eq(C.taipeiLocalToIso('2026-02-30T10:00'), null, '不存在的日期');
eq(C.taipeiLocalToIso(''), null, '空值');
eq(C.taipeiLocalToIso('2026-11-05 14:00'), null, '用空白分隔不收');
eq(C.isoToTaipeiLocal('2026-11-05T06:00:00Z'), '2026-11-05T14:00', 'UTC 轉台北');
eq(C.isoToTaipeiLocal('2026-11-05T14:00:00+08:00'), '2026-11-05T14:00', '+08:00 原樣');
eq(C.isoToTaipeiLocal('2026-11-05T20:00:00Z'), '2026-11-06T04:00', '跨日');
eq(C.isoToTaipeiLocal('壞'), '', '無法解析回空字串');
eq(C.isoToTaipeiLocal(C.taipeiLocalToIso('2026-12-31T23:59')), '2026-12-31T23:59', '來回轉換一致');
eq(C.formatTaipei('2026-11-05T06:05:00Z'), '2026-11-05 14:05', '顯示格式');
eq(C.formatTaipei(null), '', 'null 顯示空');

// ---- 排定時間限制（不可早於現在往前 1 小時）----
var NOW = Date.parse('2026-11-03T10:00:00+08:00');
eq(C.scheduleAtError('2026-11-03T09:00', NOW), '', '剛好往前 1 小時可以');
eq(C.scheduleAtError('2026-11-03T08:59', NOW) !== '', true, '超過 1 小時不行');
eq(C.scheduleAtError('2026-11-05T14:00', NOW), '', '未來可以');
eq(C.scheduleAtError('', NOW), '請選擇考核日期與時間。', '沒填');
eq(C.scheduleAtError('亂寫', NOW), '請選擇考核日期與時間。', '格式錯');

// ---- 已回報標記與排序（assess.html 用）----
var reqs = [
  { employee_id: 'B', status: '待處理', kind: '新人', scheduled_at: null },
  { employee_id: 'C', status: '已排定', kind: '複檢', scheduled_at: '2026-11-05T06:00:00Z' },
  { employee_id: 'D', status: '已完成', kind: '新人' },
  { employee_id: 'E', status: '已取消', kind: '新人' },
  { employee_id: 'B', status: '已排定', kind: '回考核期', scheduled_at: '2026-11-06T06:00:00Z' },
  { employee_id: null, status: '待處理', kind: '新人' }
];
var map = C.markReported(reqs);
eq(Object.keys(map).sort(), ['B', 'C'], '只標待處理與已排定');
eq(map.B.status, '已排定', '同一人已排定優先');
eq(map.B.scheduled_at, '2026-11-06T06:00:00Z', '帶排定時間');
eq(C.markReported(null), {}, 'null 回空');
var people = [{ id: 'A' }, { id: 'B' }, { id: 'C' }, { id: 'F' }];
eq(C.reportedFirst(people, map).map(function (p) { return p.id; }), ['B', 'C', 'A', 'F'], '已回報排前面且各自維持原順序');
eq(C.reportedFirst(people, {}).map(function (p) { return p.id; }), ['A', 'B', 'C', 'F'], '沒人回報維持原順序');
eq(C.reportedFirst(people, map).length, 4, '不掉人');

// ---- 連結安全 ----
eq(C.safeHttpUrl('https://example.com/a'), 'https://example.com/a', 'https 可');
eq(C.safeHttpUrl('http://example.com'), 'http://example.com', 'http 可');
eq(C.safeHttpUrl('javascript:alert(1)'), '', 'javascript 不可');
eq(C.safeHttpUrl('https://a.com/ b'), '', '含空白不可');
eq(C.safeHttpUrl(null), '', 'null 回空');

console.log('通過 ' + passed + ' 項');
