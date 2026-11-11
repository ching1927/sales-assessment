/*
 * 「已輔導 → 尚未約考」提醒的純函式（不連資料庫、不碰畫面）。規則見 supabase/README_exam_request.md 第六節。
 * 真正的判斷以資料庫為準（supabase/coached_reminder_schema.sql 的 coached_pending()）；
 * 這裡的 isPendingBooking／prefillKind／dueDay 是同一套規則的純函式版本，用來寫測試、對照資料庫行為。
 * 瀏覽器：window.CoachedCore；Node：module.exports。
 *
 * 用法：
 *   CoachedCore.parseFromTicket(search)       網址 ?from_ticket=<單號> -> 單號（小寫 uuid）；格式不對或沒有回 ''
 *   CoachedCore.requestsUrl(ticketId)         導向待考回報頁的網址 'requests.html?from_ticket=<單號>'；單號格式不對回 'requests.html'
 *   CoachedCore.prefillKind(verdict, inProbation)  情況預填：需複訓 -> 複檢；不及格且在考核期 -> 回考核期；其他 -> ''（留空讓店長選）
 *   CoachedCore.isPendingBooking(ticket, reqs)     改善單是否「尚未約考」（見函式說明）
 *   CoachedCore.daysSince(coachedAt, nowMs)   已輔導幾天（台北日期差；輔導當天 0）；無法解析回 null
 *   CoachedCore.dueDay(days, lastRemindedDays) 提醒信第幾天要寄（days＝已輔導天數；lastRemindedDays＝上次寄信時的天數或 null）-> boolean
 *   CoachedCore.byTicket(list)                尚未約考清單 -> { 單號: 列 }
 *   CoachedCore.findPrefill(list, ticketId)   在（資料庫依身分過濾後的）清單裡找該單；找不到回 null（非本店單號就是找不到）
 *   CoachedCore.remindText(row)               黃色提醒條文字「○○ 已輔導完成，記得預約考核」
 *   CoachedCore.subtotal(base, pending)       紅點總數 = 原有數字 + 尚未約考人數（任一邊不是有效數字當 0）
 */
(function (root) {
  var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  var TZ_MS = 8 * 3600000;   // 台北固定 UTC+8
  var DAY_MS = 86400000;

  function parseFromTicket(search) {
    var s = String(search == null ? '' : search);
    var m = /[?&]from_ticket=([^&#]*)/.exec(s);
    if (!m) return '';
    var v;
    try { v = decodeURIComponent(m[1]).trim().toLowerCase(); } catch (e) { return ''; }
    return UUID_RE.test(v) ? v : '';
  }
  function requestsUrl(ticketId) {
    var v = String(ticketId == null ? '' : ticketId).trim().toLowerCase();
    return UUID_RE.test(v) ? 'requests.html?from_ticket=' + v : 'requests.html';
  }

  // 情況預填（與資料庫 coached_pending_rows 的 kind 同一規則）
  function prefillKind(verdict, inProbation) {
    if (verdict === '需複訓') return '複檢';
    if (verdict === '不及格' && inProbation === true) return '回考核期';
    return '';
  }

  // ticket: { id, status, created_at, employee_id }；reqs: [{ employee_id, status, created_at }]
  // 尚未約考＝改善單是「已輔導」，且開單之後這位人員沒有任何「待處理、已排定、已完成」的待考回報
  // （已取消＝已撤回或已退回，不算有效）
  function isPendingBooking(ticket, reqs) {
    if (!ticket || ticket.status !== 'coached') return false;
    var created = Date.parse(ticket.created_at);
    return !(reqs || []).some(function (r) {
      if (!r || r.employee_id !== ticket.employee_id) return false;
      if (r.status !== '待處理' && r.status !== '已排定' && r.status !== '已完成') return false;
      var t = Date.parse(r.created_at);
      return isNaN(created) || isNaN(t) ? true : t >= created;
    });
  }

  function taipeiDayNumber(ms) { return Math.floor((ms + TZ_MS) / DAY_MS); }
  function daysSince(coachedAt, nowMs) {
    var c = Date.parse(coachedAt);
    if (isNaN(c)) return null;
    var now = typeof nowMs === 'number' ? nowMs : Date.now();
    return taipeiDayNumber(now) - taipeiDayNumber(c);
  }

  // 提醒信規則：已輔導滿 2 天才寄第一封；之後距上次寄信滿 2 天再寄。
  function dueDay(days, lastRemindedDays) {
    if (typeof days !== 'number' || isNaN(days) || days < 2) return false;
    if (lastRemindedDays == null) return true;
    return days - lastRemindedDays >= 2;
  }

  function byTicket(list) {
    var m = {};
    (list || []).forEach(function (r) { if (r && r.ticket_id) m[r.ticket_id] = r; });
    return m;
  }
  function findPrefill(list, ticketId) {
    var id = String(ticketId == null ? '' : ticketId).toLowerCase();
    if (!id) return null;
    return byTicket(list)[id] || null;
  }
  function remindText(row) {
    return String((row && (row.employee_label || row.employee_id)) || '') + ' 已輔導完成，記得預約考核';
  }
  function subtotal(base, pending) {
    var a = Number(base), b = Number(pending);
    return (isFinite(a) && a > 0 ? Math.floor(a) : 0) + (isFinite(b) && b > 0 ? Math.floor(b) : 0);
  }

  var api = {
    parseFromTicket: parseFromTicket, requestsUrl: requestsUrl, prefillKind: prefillKind,
    isPendingBooking: isPendingBooking, daysSince: daysSince, dueDay: dueDay,
    byTicket: byTicket, findPrefill: findPrefill, remindText: remindText, subtotal: subtotal
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CoachedCore = api;
})(typeof window !== 'undefined' ? window : this);
