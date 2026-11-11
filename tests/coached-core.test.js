/* 「已輔導 → 尚未約考」純函式測試：node tests/coached-core.test.js
 * 「現在」一律傳固定值，結果可重現。全部是假資料。 */
var assert = require('node:assert');
var C = require('../js/coached-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

var ID = '3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e';

// ---- 網址參數 ----
eq(C.parseFromTicket('?from_ticket=' + ID), ID, '正常單號');
eq(C.parseFromTicket('?x=1&from_ticket=' + ID + '&y=2'), ID, '夾在其他參數中');
eq(C.parseFromTicket('?from_ticket=' + ID.toUpperCase()), ID, '大寫轉小寫');
eq(C.parseFromTicket('?from_ticket=' + ID + '#abc'), ID, '後面接 hash');
eq(C.parseFromTicket(''), '', '沒有參數');
eq(C.parseFromTicket(null), '', 'null');
eq(C.parseFromTicket('?from_ticket='), '', '空值');
eq(C.parseFromTicket('?from_ticket=abc'), '', '不是 uuid');
eq(C.parseFromTicket('?from_ticket=' + ID + 'x'), '', '尾巴多字元');
eq(C.parseFromTicket('?from_ticket=' + encodeURIComponent("'; drop table x;--")), '', '惡意字串');
eq(C.parseFromTicket('?from_ticket=%E0%A4%A'), '', '壞的百分比編碼不丟例外');
eq(C.parseFromTicket('?xfrom_ticket=' + ID), '', '參數名稱必須完整（xfrom_ticket 不算）');
eq(C.requestsUrl(ID), 'requests.html?from_ticket=' + ID, '導向網址');
eq(C.requestsUrl(ID.toUpperCase()), 'requests.html?from_ticket=' + ID, '導向網址小寫化');
eq(C.requestsUrl('zzz'), 'requests.html', '單號壞掉就導向一般頁');
eq(C.requestsUrl(null), 'requests.html', 'null 導向一般頁');
eq(C.requestsUrl(ID).indexOf('姓名'), -1, '網址不含姓名');

// ---- 情況預填 ----
eq(C.prefillKind('需複訓', false), '複檢', '需複訓→複檢');
eq(C.prefillKind('需複訓', true), '複檢', '需複訓且在考核期仍是複檢');
eq(C.prefillKind('不及格', true), '回考核期', '不及格且在考核期→回考核期');
eq(C.prefillKind('不及格', false), '', '不及格但不在考核期→留空（系統不允許以回考核期回報）');
eq(C.prefillKind('不及格', null), '', '不及格、考核期未知→留空');
eq(C.prefillKind('及格', true), '', '及格→留空');
eq(C.prefillKind('優秀', false), '', '優秀→留空');
eq(C.prefillKind(null, true), '', '沒有判定→留空');
eq(C.prefillKind(undefined, undefined), '', '全空→留空');

// ---- 尚未約考判斷 ----
var T = { id: 't1', status: 'coached', employee_id: 'MI-1', created_at: '2026-11-01T02:00:00Z' };
function rq(status, at, emp) { return { employee_id: emp || 'MI-1', status: status, created_at: at || '2026-11-05T02:00:00Z' }; }
eq(C.isPendingBooking(T, []), true, '已輔導且沒有任何回報→尚未約考');
eq(C.isPendingBooking(T, null), true, 'reqs 為 null 也不丟例外');
eq(C.isPendingBooking(T, [rq('待處理')]), false, '有待處理→已約考');
eq(C.isPendingBooking(T, [rq('已排定')]), false, '有已排定→已約考');
eq(C.isPendingBooking(T, [rq('已完成')]), false, '有已完成→已約考');
eq(C.isPendingBooking(T, [rq('已取消')]), true, '只有已取消（撤回或退回）→仍尚未約考');
eq(C.isPendingBooking(T, [rq('已取消'), rq('待處理')]), false, '退回後又送出→已約考');
eq(C.isPendingBooking(T, [rq('待處理', '2026-10-30T02:00:00Z')]), true, '開單之前的舊回報不算');
eq(C.isPendingBooking(T, [rq('待處理', '2026-11-01T02:00:00Z')]), false, '與開單同一刻算（>=）');
eq(C.isPendingBooking(T, [rq('待處理', null, 'MI-2')]), true, '別人的回報不算');
eq(C.isPendingBooking({ id: 't', status: 'open', employee_id: 'MI-1', created_at: T.created_at }, []), false, '待改善不算');
eq(C.isPendingBooking({ id: 't', status: 'closed', employee_id: 'MI-1', created_at: T.created_at }, []), false, '已結案不算');
eq(C.isPendingBooking({ id: 't', status: 'cancelled', employee_id: 'MI-1', created_at: T.created_at }, []), false, '已取消（作廢）不算');
eq(C.isPendingBooking(null, []), false, 'ticket 為 null');

// ---- 天數（台北日期差） ----
var NOW = Date.parse('2026-11-12T01:00:00Z');   // 台北 11-12 09:00
eq(C.daysSince('2026-11-10T07:00:00Z', NOW), 2, '11-10 15:00 輔導，11-12 09:00 → 2 天');
eq(C.daysSince('2026-11-12T00:30:00Z', NOW), 0, '當天 → 0 天');
eq(C.daysSince('2026-11-11T16:30:00Z', NOW), 0, '台北已是 11-12 00:30 → 0 天（以台北日期算）');
eq(C.daysSince('2026-11-11T15:30:00Z', NOW), 1, '台北 11-11 23:30 → 1 天');
eq(C.daysSince('不是日期', NOW), null, '壞日期回 null');
eq(C.daysSince('2026-11-10T07:00:00Z', Date.parse('2026-11-14T01:00:00Z')), 4, '第 4 天');

// ---- 提醒信到期（第 2 天起，每 2 天一封） ----
eq(C.dueDay(0, null), false, '第 0 天不寄');
eq(C.dueDay(1, null), false, '第 1 天不寄');
eq(C.dueDay(2, null), true, '第 2 天寄第一封');
eq(C.dueDay(3, null), true, '第一封漏寄，第 3 天補寄');
eq(C.dueDay(3, 2), false, '第 2 天寄過，第 3 天不寄');
eq(C.dueDay(4, 2), true, '第 4 天寄第二封');
eq(C.dueDay(5, 4), false, '第 5 天不寄');
eq(C.dueDay(6, 4), true, '第 6 天寄');
eq(C.dueDay(9, 6), true, '漏跑：隔 3 天補寄');
eq(C.dueDay(NaN, null), false, 'NaN 不寄');
eq(C.dueDay('2', null), false, '非數字不寄');

// ---- 清單查找（資料庫依身分過濾過；找不到＝非本店或不是尚未約考） ----
var L = [{ ticket_id: ID, employee_id: 'MI-1', employee_label: '假員甲', kind: '複檢' }, { ticket_id: 'zzz', employee_id: 'MI-2', employee_label: '假員乙', kind: '' }];
eq(C.findPrefill(L, ID).employee_id, 'MI-1', '找得到本店單');
eq(C.findPrefill(L, ID.toUpperCase()).employee_id, 'MI-1', '大寫也找得到');
eq(C.findPrefill(L, '3f2b8c1e-0000-4b6c-8d7e-9f0a1b2c3d4e'), null, '找不到（非本店單號被忽略）');
eq(C.findPrefill([], ID), null, '空清單');
eq(C.findPrefill(null, ID), null, 'null 清單');
eq(C.findPrefill(L, ''), null, '沒有單號');
eq(Object.keys(C.byTicket(L)).length, 2, 'byTicket 兩筆');
eq(C.remindText(L[0]), '假員甲 已輔導完成，記得預約考核', '提醒條文字');
eq(C.remindText({ employee_id: 'MI-9' }), 'MI-9 已輔導完成，記得預約考核', '沒有名稱用員編');
eq(C.remindText(null), ' 已輔導完成，記得預約考核', 'null 不丟例外');
eq(/計時|倒數|監控/.test(C.remindText(L[0])), false, '提醒條不含禁用字眼');

// ---- 紅點總數 ----
eq(C.subtotal(2, 3), 5, '2 + 3');
eq(C.subtotal(0, 0), 0, '0 + 0');
eq(C.subtotal(4, 0), 4, '只有原數字');
eq(C.subtotal(0, 2), 2, '只有尚未約考');
eq(C.subtotal(null, 2), 2, 'null 當 0');
eq(C.subtotal('x', 'y'), 0, '非數字當 0');
eq(C.subtotal(-1, 2), 2, '負數當 0');

console.log('通過 ' + passed + ' 項');
