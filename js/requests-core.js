/*
 * 待考回報的純函式（不連資料庫、不碰畫面）。規則見 supabase/README_exam_request.md。
 * 瀏覽器：window.RequestsCore；Node：module.exports。
 *
 * 用法：
 *   RequestsCore.KINDS / KIND_LABEL           三種情況（新人、回考核期、複檢）與顯示名稱
 *   RequestsCore.taipeiToday(nowMs)           台北今天 'YYYY-MM-DD'
 *   RequestsCore.addDays(dateStr, n)          日期加減天數
 *   RequestsCore.validateDates(dates, today)  1～3 個、不重複、不早於 today -> { ok, error, dates(由早到晚) }
 *   RequestsCore.videoError(kind, video)      新人必須 video === true，否則回錯誤字串；其他情況回 ''
 *   RequestsCore.videoValue(kind, checked)    送資料庫的 p_video：新人 true／false，其他情況 null
 *   RequestsCore.noteError(note)              備註（去頭尾空白後）超過 500 字回錯誤字串，否則 ''
 *   RequestsCore.validateRequest(o)           整份回報驗證 -> { ok, error, dates, video, note, ticketId }
 *   RequestsCore.taipeiLocalToIso(local)      datetime-local 值（台北時間）-> 'YYYY-MM-DDTHH:mm:ss+08:00'；格式不對回 null
 *   RequestsCore.isoToTaipeiLocal(iso)        ISO 時間 -> 台北時間的 datetime-local 值；無法解析回 ''
 *   RequestsCore.formatTaipei(iso)            ISO 時間 -> 'YYYY-MM-DD HH:mm'（台北）；無法解析回 ''
 *   RequestsCore.scheduleAtError(local, nowMs) 排定時間不可早於「現在往前 1 小時」；回錯誤字串或 ''
 *   RequestsCore.markReported(rows)           未結案（待處理、已排定）回報 -> { 員編: { status, kind, scheduled_at } }
 *   RequestsCore.reportedFirst(list, map, idOf) 已回報的人排前面（兩邊各自維持原順序）
 *   RequestsCore.safeHttpUrl(u)               只接受 http／https 網址，否則回 ''
 */
(function (root) {
  var KINDS = ['新人', '回考核期', '複檢'];
  var KIND_LABEL = { '新人': '新人考核', '回考核期': '回考核期再考', '複檢': '改善單複檢' };
  var MAX_DATES = 3;
  var MAX_NOTE = 500;
  var TZ_MS = 8 * 3600000;       // 台北固定 UTC+8（沒有日光節約）
  var BACK_MS = 3600000;         // 排定時間可早於現在的上限：1 小時

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  // 嚴格的日期格式與日曆檢查（2026-02-30 不算）
  function isDateStr(s) {
    if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
    var y = +s.slice(0, 4), m = +s.slice(5, 7), d = +s.slice(8, 10);
    var t = new Date(Date.UTC(y, m - 1, d));
    return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
  }
  function parts(ms) {
    var t = new Date(ms + TZ_MS);
    return { y: t.getUTCFullYear(), mo: t.getUTCMonth() + 1, d: t.getUTCDate(), h: t.getUTCHours(), mi: t.getUTCMinutes() };
  }
  function dateOf(p) { return p.y + '-' + pad(p.mo) + '-' + pad(p.d); }

  function taipeiToday(nowMs) {
    return dateOf(parts(typeof nowMs === 'number' ? nowMs : Date.now()));
  }
  function addDays(dateStr, n) {
    if (!isDateStr(dateStr)) return '';
    var ms = Date.UTC(+dateStr.slice(0, 4), +dateStr.slice(5, 7) - 1, +dateStr.slice(8, 10)) + n * 86400000;
    var t = new Date(ms);
    return t.getUTCFullYear() + '-' + pad(t.getUTCMonth() + 1) + '-' + pad(t.getUTCDate());
  }

  function validateDates(dates, today) {
    if (!isDateStr(today)) return { ok: false, error: '無法確認今天的日期，請重新整理頁面。' };
    if (!Array.isArray(dates) || dates.length === 0) return { ok: false, error: '請至少選一個希望考核日期（最多 3 個）。' };
    if (dates.length > MAX_DATES) return { ok: false, error: '希望考核日期最多 ' + MAX_DATES + ' 個。' };
    for (var i = 0; i < dates.length; i++) {
      if (!isDateStr(dates[i])) return { ok: false, error: '希望考核日期格式不正確，請重新選擇。' };
    }
    var seen = {};
    for (var j = 0; j < dates.length; j++) {
      if (seen[dates[j]]) return { ok: false, error: '希望考核日期不能重複。' };
      seen[dates[j]] = 1;
    }
    for (var k = 0; k < dates.length; k++) {
      if (dates[k] < today) return { ok: false, error: '希望考核日期不能早於今天。' };
    }
    return { ok: true, error: '', dates: dates.slice().sort() };
  }

  function videoError(kind, video) {
    if (kind === '新人' && video !== true) return '新人必須先看完「線上回覆實戰全攻略」影片，請勾選後再送出。';
    return '';
  }
  function videoValue(kind, checked) {
    return kind === '新人' ? !!checked : null;
  }

  function charCount(s) { return Array.from(s).length; }   // 以字元計，與資料庫 length() 一致（一個中文字算 1）
  function noteError(note) {
    var n = String(note == null ? '' : note).trim();
    var len = charCount(n);
    return len > MAX_NOTE ? '備註最多 ' + MAX_NOTE + ' 字（目前 ' + len + ' 字）。' : '';
  }

  // o: { kind, employeeId, ticketId, dates, video(boolean), note, today }
  function validateRequest(o) {
    o = o || {};
    if (KINDS.indexOf(o.kind) < 0) return { ok: false, error: '請選擇回報情況。' };
    if (!o.employeeId) return { ok: false, error: '請選擇人員。' };
    if (o.kind === '複檢' && !o.ticketId) return { ok: false, error: '複檢必須指定改善單，請重新選擇人員。' };
    var d = validateDates(o.dates, o.today);
    if (!d.ok) return { ok: false, error: d.error };
    var ve = videoError(o.kind, o.video);
    if (ve) return { ok: false, error: ve };
    var ne = noteError(o.note);
    if (ne) return { ok: false, error: ne };
    return {
      ok: true, error: '', dates: d.dates, video: videoValue(o.kind, o.video),
      note: String(o.note == null ? '' : o.note).trim(), ticketId: o.kind === '複檢' ? o.ticketId : null
    };
  }

  // datetime-local 的值（台北時間）轉成帶 +08:00 的 ISO 字串
  function taipeiLocalToIso(local) {
    var m = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(String(local == null ? '' : local).trim());
    if (!m || !isDateStr(m[1])) return null;
    var h = +m[2], mi = +m[3], s = m[4] == null ? 0 : +m[4];
    if (h > 23 || mi > 59 || s > 59) return null;
    return m[1] + 'T' + pad(h) + ':' + pad(mi) + ':' + pad(s) + '+08:00';
  }
  function isoToTaipeiLocal(iso) {
    var ms = Date.parse(iso);
    if (isNaN(ms)) return '';
    var p = parts(ms);
    return dateOf(p) + 'T' + pad(p.h) + ':' + pad(p.mi);
  }
  function formatTaipei(iso) {
    var ms = Date.parse(iso);
    if (isNaN(ms)) return '';
    var p = parts(ms);
    return dateOf(p) + ' ' + pad(p.h) + ':' + pad(p.mi);
  }
  function scheduleAtError(local, nowMs) {
    var iso = taipeiLocalToIso(local);
    if (!iso) return '請選擇考核日期與時間。';
    var now = typeof nowMs === 'number' ? nowMs : Date.now();
    if (Date.parse(iso) < now - BACK_MS) return '排定時間不能早於現在往前 1 小時。';
    return '';
  }

  // 已有未結案回報的人：同一人有多筆時，已排定優先於待處理
  function markReported(rows) {
    var map = {};
    (rows || []).forEach(function (r) {
      if (!r || !r.employee_id) return;
      if (r.status !== '待處理' && r.status !== '已排定') return;
      var cur = map[r.employee_id];
      if (!cur || (cur.status === '待處理' && r.status === '已排定')) {
        map[r.employee_id] = { status: r.status, kind: r.kind, scheduled_at: r.scheduled_at || null };
      }
    });
    return map;
  }
  function reportedFirst(list, map, idOf) {
    var get = typeof idOf === 'function' ? idOf : function (x) { return x.id; };
    var a = [], b = [];
    (list || []).forEach(function (x) { (map && map[get(x)] ? a : b).push(x); });
    return a.concat(b);
  }

  function safeHttpUrl(u) {
    var s = String(u == null ? '' : u).trim();
    return /^https?:\/\/\S+$/i.test(s) ? s : '';
  }

  var api = {
    KINDS: KINDS, KIND_LABEL: KIND_LABEL, MAX_DATES: MAX_DATES, MAX_NOTE: MAX_NOTE,
    isDateStr: isDateStr, taipeiToday: taipeiToday, addDays: addDays,
    validateDates: validateDates, videoError: videoError, videoValue: videoValue, noteError: noteError,
    validateRequest: validateRequest,
    taipeiLocalToIso: taipeiLocalToIso, isoToTaipeiLocal: isoToTaipeiLocal, formatTaipei: formatTaipei, scheduleAtError: scheduleAtError,
    markReported: markReported, reportedFirst: reportedFirst, safeHttpUrl: safeHttpUrl
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.RequestsCore = api;
})(typeof window !== 'undefined' ? window : this);
