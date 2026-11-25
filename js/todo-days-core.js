/*
 * 「待填事項已開單幾天」的共用純函式（不連資料庫、不碰畫面）。
 * 只用來顯示天數與顏色，不會寄信催人。瀏覽器：window.TodoDays；Node：module.exports。
 *
 *   TodoDays.daysSince(dateStrOrIso, nowMs)  整數天（台北日期差；開單當天 0）；無法解析回 null
 *   TodoDays.level(days)                     0–3 天 'gray'、4–7 天 'warn'、超過 7 天 'red'；null 回 'gray'
 *   TodoDays.chipHtml(days)                  <span class="tag gray|warn|red">已開單 N 天</span>；null 回 ''
 */
(function (root) {
  var TZ_MS = 8 * 3600000;   // 台北固定 UTC+8
  var DAY_MS = 86400000;

  function dayNumber(ms) { return Math.floor((ms + TZ_MS) / DAY_MS); }

  function daysSince(dateStrOrIso, nowMs) {
    if (dateStrOrIso == null || dateStrOrIso === '') return null;
    var c = Date.parse(dateStrOrIso);
    if (isNaN(c)) return null;
    var now = typeof nowMs === 'number' ? nowMs : Date.now();
    return dayNumber(now) - dayNumber(c);
  }

  function level(days) {
    if (typeof days !== 'number' || isNaN(days)) return 'gray';
    if (days > 7) return 'red';
    if (days >= 4) return 'warn';
    return 'gray';
  }

  function chipHtml(days) {
    if (typeof days !== 'number' || isNaN(days)) return '';
    return '<span class="tag ' + level(days) + '">已開單 ' + days + ' 天</span>';
  }

  var api = { daysSince: daysSince, level: level, chipHtml: chipHtml };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.TodoDays = api;
})(typeof window !== 'undefined' ? window : this);
