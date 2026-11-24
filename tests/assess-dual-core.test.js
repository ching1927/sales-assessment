/* 雙考官純函式測試：node tests/assess-dual-core.test.js */
var assert = require('node:assert');
var C = require('../js/assess-dual-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

var FULL = { a: '優良', b: '優良', c: '尚可', d: '優良', e: '優良', f: '待加強', g: '不適用' };
function it(id, cat, slot, levels) { return { id: id, cat: cat, slot: slot, levels: levels || {}, note: '', noteUrl: '', dimNotes: {}, imgs: [] }; }
var ITEMS = [it('i1', '基礎', 1, FULL), it('i2', '基礎', 1, { a: '優良' }), it('i3', '基礎', 1), it('i4', '進階', 2, FULL), it('i5', '進階', 2, FULL), it('i6', '綜合', 2)];

// ---- 功能尚未啟用的判斷 ----
eq(C.isNotEnabled({ code: 'PGRST202', message: 'x' }), true, 'PGRST202');
eq(C.isNotEnabled({ message: 'Could not find the function public.assess_start_dual' }), true, '找不到函式訊息');
eq(C.isNotEnabled({ code: 'P0001', message: '只有考官名單內的客服人員可以開始雙考官考核' }), false, '中文拒絕不是未啟用');
eq(C.isNotEnabled(null), false, 'null');

// ---- 進度 ----
eq(C.levelsDone(FULL), true, '七面向齊');
eq(C.levelsDone({ a: '優良' }), false, '只評一個面向');
eq(C.levelsDone(null), false, 'null levels');
eq(C.progress(ITEMS, 1), { done: 1, total: 3 }, '考官1 進度');
eq(C.progress(ITEMS, 2), { done: 2, total: 3 }, '考官2 進度');
eq(C.totalProgress(ITEMS), { done: 3, total: 6 }, '整體進度');
eq(C.scopeDesc(ITEMS, 1), '基礎 3', '考官1 範圍');
eq(C.scopeDesc(ITEMS, 2), '進階 2＋綜合 1', '考官2 範圍');
eq(C.groupLabel(ITEMS, ITEMS[1]), '基礎 2', '題組標籤 基礎 2');
eq(C.groupLabel(ITEMS, ITEMS[4]), '進階 2', '題組標籤 進階 2');
eq(C.groupLabel(ITEMS, ITEMS[5]), '綜合 1', '題組標籤 綜合 1');

// ---- 考官狀態 ----
var EX = { my_slot: 2, slots: [
  { slot: 1, name: 'UNA', scope: '基礎', submittedAt: null, lastSavedAt: '2026-11-24T04:30:00Z' },
  { slot: 2, name: 'PENNY', scope: '進階＋綜合', submittedAt: null, lastSavedAt: null }] };
var D = C.makeDual(EX);
eq([D.mySlot, D.otherSlot, D.myName, D.otherName, D.mySubmitted, D.otherSubmitted], [2, 1, 'PENNY', 'UNA', false, false], 'makeDual');
eq(C.slotTitle(D, 1), '考官1 UNA', '考官標題');
eq(C.makeDual({ my_slot: null, slots: EX.slots }), null, '不是考官回 null');
eq(C.makeDual({ my_slot: 1, slots: [EX.slots[0]] }), null, '少一位回 null');
eq(JSON.stringify(D).indexOf('@'), -1, '狀態裡不含信箱');

// ---- 可不可以改 ----
eq(C.editable(D, ITEMS[3]), true, '自己的題組可改');
eq(C.editable(D, ITEMS[0]), false, '對方題組不可改');
var D2 = C.makeDual({ my_slot: 2, slots: [EX.slots[0], { slot: 2, name: 'PENNY', scope: '進階＋綜合', submittedAt: '2026-11-24T05:00:00Z' }] });
eq(C.editable(D2, ITEMS[3]), false, '已交卷後自己的也不可改');
eq(C.editable(null, ITEMS[0]), true, '單人模式一律可改');

// ---- 交卷條件 ----
eq(C.canSubmit(ITEMS, 2), { ok: false, missing: ['綜合 1'], total: 3 }, '考官2 還差綜合 1');
eq(C.canSubmit(ITEMS, 1), { ok: false, missing: ['基礎 2', '基礎 3'], total: 3 }, '考官1 還差兩題');
var all2 = ITEMS.map(function (x) { return x.slot === 2 ? it(x.id, x.cat, 2, FULL) : x; });
eq(C.canSubmit(all2, 2).ok, true, '考官2 全評完可交');
eq(C.canSubmit([], 1).ok, false, '沒有題組不可交');

// ---- 輪詢合併：不覆蓋自己的題組 ----
var mineEdited = ITEMS.map(function (x) { return x.id === 'i6' ? Object.assign({}, x, { note: '我還沒存的備註', levels: { a: '優良' } }) : x; });
var fresh = ITEMS.map(function (x) {
  if (x.id === 'i2') return Object.assign({}, x, { levels: FULL, note: '對方新寫的備註', dimNotes: { c: '回答不夠具體' } });
  if (x.id === 'i6') return Object.assign({}, x, { note: '資料庫舊值', levels: {} });
  return x;
});
var merged = C.mergeOther(mineEdited, fresh, 2);
eq(merged[1].note, '對方新寫的備註', '對方備註更新');
eq(merged[1].levels, FULL, '對方等級更新');
eq(merged[1].dimNotes, { c: '回答不夠具體' }, '對方面向備註更新');
eq(merged[5].note, '我還沒存的備註', '自己未存的備註不被覆蓋');
eq(merged[5].levels, { a: '優良' }, '自己未存的等級不被覆蓋');
eq(mineEdited[1].note, '', '原陣列不被改動');
eq(C.mergeOther(mineEdited, [], 2).length, 6, '抓不到新資料時維持原樣');

// ---- 指紋 ----
var s1 = C.otherSignature(ITEMS, D), s2 = C.otherSignature(merged, D);
eq(s1 === s2, false, '對方內容變了，指紋不同');
eq(C.otherSignature(ITEMS, D) === s1, true, '內容相同，指紋相同');

// ---- 時間文字 ----
var NOW = Date.parse('2026-11-24T05:00:00Z');   // 台北 13:00
eq(C.relTime('2026-11-24T04:59:40Z', NOW), '剛剛', '20 秒前');
eq(C.relTime('2026-11-24T04:30:00Z', NOW), '30 分鐘前', '30 分鐘前');
eq(C.relTime('2026-11-24T01:05:00Z', NOW), '09:05', '同一天顯示時間');
eq(C.relTime('2026-11-22T01:05:00Z', NOW), '11-22 09:05', '不同天顯示日期');
eq(C.relTime(null, NOW), '', '空值');
eq(C.hm('2026-11-24T04:30:00Z'), '12:30', '台北時間 HH:MM');
eq(C.savedText('2026-11-24T04:30:00Z'), '已自動暫存 12:30', '暫存提示');
eq(C.savedText(null), '', '沒暫存過');
eq(C.coEditText(D, NOW), '另一位考官也在這張考核上，最後更新：考官1 UNA 30 分鐘前', '共同編輯提示');
eq(C.coEditText(C.makeDual({ my_slot: 1, slots: [{ slot: 1, name: 'UNA' }, { slot: 2, name: 'PENNY' }] }), NOW), '另一位考官也在這張考核上，最後更新：考官2 PENNY 尚未有更新', '對方還沒暫存');

// ---- 草稿清單 ----
var row = { assessment_id: 'a1', my_slot: 2, my_scope: '進階＋綜合', opened_by_me: false, other_name: 'UNA',
  my_progress: { done: 1, total: 3 }, other_progress: { done: 3, total: 3 }, my_submitted_at: null, other_submitted: true };
eq(C.draftInfo(row), { id: 'a1', label: '考官2・進階＋綜合', openedByMe: false, otherName: 'UNA', myProg: '1 / 3', otherProg: '3 / 3', mySubmitted: false, otherSubmitted: true }, '草稿清單整理');

// ---- RPC 回傳整理 ----
eq(C.parseStart({ assessment_id: 'a1', existing: false, my_slot: 1 }), { aid: 'a1', existing: false, mySlot: 1 }, 'startDual 回傳');
eq(C.parseStart(null), null, 'startDual 空回傳');
eq(C.parseSubmit({ done: false, waiting_for_slot: 1 }), { done: false, waitingForSlot: 1 }, 'submitPart 等待對方');
eq(C.parseSubmit([{ done: true, waiting_for_slot: null }]), { done: true, waitingForSlot: null }, 'submitPart 完成');

// ---- FE-3：送出頁、撤回、放棄、範例圖片 ----
var DM = C.makeDual({ my_slot: 1, slots: [{ slot: 1, name: 'UNA', scope: '基礎' }, { slot: 2, name: 'PENNY', scope: '進階＋綜合' }] });   // ITEMS：考官1 還差 2 題、考官2 還差 1 題
var V = C.submitView(ITEMS, DM);
eq([V.canSubmit, V.canUnsubmit, V.hint, V.waiting], [false, false, '還差 2 題未完成', ''], '送出頁：未完成不能送出');
eq([V.mine.missing, V.mine.done, V.mine.total, V.mine.scope], [['基礎 2', '基礎 3'], 1, 3, '基礎 3'], '送出頁：自己缺哪些');
eq([V.other.missing, V.other.done, V.other.scope], [['綜合 1'], 2, '進階 2＋綜合 1'], '送出頁：對方進度');
var ALLDONE = ITEMS.map(function (x) { return it(x.id, x.cat, x.slot, FULL); });
var V2 = C.submitView(ALLDONE, DM);
eq([V2.canSubmit, V2.hint, V2.mine.missing], [true, '你負責的題組都評完了，可以送出。', []], '送出頁：全部完成可送出');
var DS = C.makeDual({ my_slot: 1, slots: [{ slot: 1, name: 'UNA', submittedAt: '2026-11-24T05:00:00Z' }, { slot: 2, name: 'PENNY' }] });
var V3 = C.submitView(ALLDONE, DS);
eq([V3.canSubmit, V3.canUnsubmit, V3.waiting, V3.hint], [false, true, '已送出，等待考官2 PENNY', ''], '送出頁：已送出等待對方、可撤回');
var DS2 = C.makeDual({ my_slot: 1, slots: [{ slot: 1, name: 'UNA', submittedAt: 'x' }, { slot: 2, name: 'PENNY', submittedAt: 'y' }] });
eq(C.submitView(ALLDONE, DS2).waiting, '兩位考官都已送出，系統正在合併成績單。', '送出頁：兩位都送出');
eq(C.submitView([], DM).hint, '沒有你負責的題組，無法送出。', '送出頁：沒有題組');
eq(C.editable(DS, ALLDONE[0]), false, '已送出後自己題組唯讀');
eq(C.editable(C.makeDual({ my_slot: 1, slots: [{ slot: 1, name: 'UNA' }, { slot: 2, name: 'PENNY', submittedAt: 'y' }] }), ALLDONE[0]), true, '對方送出不影響自己編輯');

var MSG = '已有考官送出自己的題組，不能直接放棄這張考核；請先撤回送出';
eq([C.needUnsubmit(MSG), C.needUnsubmit('只有草稿可以放棄'), C.needUnsubmit(null)], [true, false, false], '放棄被擋：辨識「請先撤回送出」');
eq(C.abandonGuide(MSG, true).indexOf('按「撤回送出」') > 0 && C.abandonGuide(MSG, true).indexOf(MSG) === 0, true, '放棄被擋：自己已送出的引導');
eq(C.abandonGuide(MSG, false).indexOf('請先請已送出的考官') > 0, true, '放棄被擋：對方送出的引導');
eq([C.alreadyDone('這張考核已經完成（或已作廢），不能撤回送出'), C.alreadyDone('你還沒有送出自己的題組，不需要撤回')], [true, false], '撤回被擋：整張已完成');

var SEC = [{ item_id: 'i1', question_id: 11 }, { item_id: 'i2', question_id: 12 }, { item_id: 'i3', question_id: '11' }];
var IMGS = [{ id: 'g2', question_id: 11, storage_path: '11/b.jpg', mime: 'image/jpeg', size_bytes: 200, sort_order: 2 },
  { id: 'g1', question_id: 11, storage_path: '11/a.png', mime: 'image/png', size_bytes: 100, sort_order: 1 }];
var GS = C.groupSamples(SEC, IMGS);
eq(GS.i1.map(function (g) { return g.path; }), ['11/a.png', '11/b.jpg'], '範例圖片依 sort_order 排序');
eq(GS.i2, [], '沒有圖的題組是空陣列');
eq(GS.i3.length, 2, 'question_id 數字與字串視為同一題');
eq(GS.i1[0], { id: 'g1', path: '11/a.png', mime: 'image/png', size: 100 }, '範例圖片欄位轉換');
eq(C.groupSamples(null, null), {}, '範例圖片空輸入');

console.log('assess-dual-core：' + passed + ' 項通過');
