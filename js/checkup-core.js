/*
 * 每年健檢的純函式（不連資料庫、不碰畫面）。規則與欄位見 supabase/README_checkup.md 第三節。
 * 瀏覽器：window.CheckupCore；Node：module.exports。
 *
 * 用法：
 *   CheckupCore.taipeiYearQuarter(nowMs)         台北今天所在的 { year, quarter }
 *   CheckupCore.yearOptions(nowMs)               年度下拉選項（新到舊）
 *   CheckupCore.storeRank(code) / sortStores(rows, key)  門市排序（STORE_ORDER，不在清單的排最後）
 *   CheckupCore.quarterStats(rows, pending)      各季 { quarter, stores, people }；pending 為 { 門市代碼: 季次 } 的尚未儲存選擇
 *   CheckupCore.changedStores(rows, pending)     尚未儲存且與資料庫不同的 [{ store, quarter }]
 *   CheckupCore.rosterStoreOptions(roster, quarterRows, quarter)  名單頁門市篩選選項（該季門市＋名單內實際出現的門市）
 *   CheckupCore.filterRoster(rows, store) / sortRoster(rows)      名單篩選與排序（門市順序、員工編號）
 *   CheckupCore.statusInfo(status)               狀態 -> { label, cls }
 *   CheckupCore.verdictCls(verdict)              判定 -> 標籤樣式
 *   CheckupCore.formatScore(score)               分數顯示（小數 1 位）；無分數回 '—'
 *   CheckupCore.formatScheduled(iso)             排定時間 -> 'YYYY-MM-DD HH:mm'（台北）；無法解析回 '—'
 *   CheckupCore.scheduleToIso(date, time)        日期＋時間（台北）-> 'YYYY-MM-DDTHH:mm:00+08:00'；格式不對回 null
 *   CheckupCore.noteError(note)                  備註（去頭尾空白後）超過 500 字回錯誤字串，否則 ''
 *   CheckupCore.beginUrl(emp, year, quarter)     assess.html?mode=checkup&emp=…&year=…&quarter=…（與任務 3 的合約）
 *   CheckupCore.adviceUrl(assessmentId)          advice.html?assessment=…（與任務 4 的合約）
 *   CheckupCore.rosterActions(row, role, year, quarter)  該列可用的操作 -> { buttons: [{ kind, label, href? }], hint }
 */
(function (root) {
  var STORE_ORDER = ['總公司', '中和', '新莊', '樹林', '桃園中壢', '新竹', '旗艦', '南台中', '太平', '台南', '高雄', '花蓮'];
  var QUARTERS = [1, 2, 3, 4];
  var MAX_NOTE = 500;
  var TZ_MS = 8 * 3600000;   // 台北固定 UTC+8（沒有日光節約）

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
  function num(n) { n = Number(n); return isFinite(n) ? n : 0; }

  // ---- 時間 ----
  function taipeiYearQuarter(nowMs) {
    var t = new Date((typeof nowMs === 'number' ? nowMs : Date.now()) + TZ_MS);
    return { year: t.getUTCFullYear(), quarter: Math.floor(t.getUTCMonth() / 3) + 1 };
  }
  function yearOptions(nowMs) {
    var y = taipeiYearQuarter(nowMs).year;
    return [y + 1, y, y - 1, y - 2];
  }
  function formatScheduled(iso) {
    var ms = Date.parse(iso);
    if (isNaN(ms)) return '—';
    var t = new Date(ms + TZ_MS);
    return t.getUTCFullYear() + '-' + pad(t.getUTCMonth() + 1) + '-' + pad(t.getUTCDate()) + ' ' + pad(t.getUTCHours()) + ':' + pad(t.getUTCMinutes());
  }
  function isDateStr(s) {
    if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
    var y = +s.slice(0, 4), m = +s.slice(5, 7), d = +s.slice(8, 10);
    var t = new Date(Date.UTC(y, m - 1, d));
    return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
  }
  function scheduleToIso(date, time) {
    if (!isDateStr(date) || typeof time !== 'string') return null;
    var m = /^(\d{2}):(\d{2})(?::\d{2})?$/.exec(time);
    if (!m || +m[1] > 23 || +m[2] > 59) return null;
    return date + 'T' + m[1] + ':' + m[2] + ':00+08:00';
  }
  function noteError(note) {
    return String(note == null ? '' : note).trim().length > MAX_NOTE ? '備註最多 ' + MAX_NOTE + ' 字。' : '';
  }

  // ---- 門市排序 ----
  function storeRank(code) {
    var i = STORE_ORDER.indexOf(code);
    return i < 0 ? STORE_ORDER.length : i;
  }
  // 依 STORE_ORDER 排；同門市再依 secondKey 排（沒給就不再排）。回傳新陣列
  function sortStores(rows, key, secondKey) {
    var k = key || 'store_code';
    return (rows || []).slice().sort(function (a, b) {
      return storeRank(a[k]) - storeRank(b[k]) || cmp(a[k], b[k]) || (secondKey ? cmp(a[secondKey], b[secondKey]) : 0);
    });
  }

  // ---- 門市季次表 ----
  function pendingQuarter(row, pending) {
    var p = pending && pending[row.store_code];
    return p >= 1 && p <= 4 ? Number(p) : Number(row.quarter);
  }
  function quarterStats(rows, pending) {
    return QUARTERS.map(function (q) {
      var s = 0, p = 0;
      (rows || []).forEach(function (r) {
        if (pendingQuarter(r, pending) === q) { s++; p += num(r.headcount); }
      });
      return { quarter: q, stores: s, people: p };
    });
  }
  function changedStores(rows, pending) {
    var out = [];
    (rows || []).forEach(function (r) {
      var q = pendingQuarter(r, pending);
      if (q !== Number(r.quarter)) out.push({ store: r.store_code, quarter: q });
    });
    return out;
  }

  // ---- 健檢名單 ----
  function rosterStoreOptions(roster, quarterRows, quarter) {
    var seen = {}, out = [];
    function add(code, name) { if (code && !seen[code]) { seen[code] = true; out.push({ store_code: code, store_name: name || code }); } }
    (quarterRows || []).forEach(function (r) { if (Number(r.quarter) === Number(quarter)) add(r.store_code, r.store_name); });
    (roster || []).forEach(function (r) { add(r.store_code, r.store_name); });   // 排定後門市改季次者仍在名單內，不讓他從篩選消失
    return sortStores(out, 'store_code');
  }
  function filterRoster(rows, store) {
    return (rows || []).filter(function (r) { return !store || r.store_code === store; });
  }
  function sortRoster(rows) { return sortStores(rows, 'store_code', 'employee_id'); }

  var STATUS = {
    '待排定': { label: '待排定', cls: 'reg' },
    '已排定': { label: '已排定', cls: 'new' },
    '已完成': { label: '已完成', cls: 'on' }
  };
  function statusInfo(status) { return STATUS[status] || { label: String(status || '—'), cls: 'reg' }; }
  function verdictCls(v) {
    return v === '優秀' || v === '及格' ? 'on' : v === '需複訓' ? 'unk' : v === '不及格' ? 'out' : 'reg';
  }
  function formatScore(s) {
    if (s == null || s === '' || !isFinite(Number(s))) return '—';
    return String(Math.round(Number(s) * 10) / 10);
  }

  // ---- 連結（兩個任務之間的合約，格式不可更改）----
  function beginUrl(emp, year, quarter) {
    return 'assess.html?mode=checkup&emp=' + encodeURIComponent(emp) + '&year=' + encodeURIComponent(year) + '&quarter=' + encodeURIComponent(quarter);
  }
  function adviceUrl(assessmentId) {
    return 'advice.html?assessment=' + encodeURIComponent(assessmentId);
  }

  // 每一列可用的操作（只有客服部能排定、取消、開始；其他角色最多「查看建議單」）
  function rosterActions(row, role, year, quarter) {
    var out = { buttons: [], hint: '' };
    if (!row) return out;
    var cs = role === 'cs_admin';
    var advice = row.status === '已完成' && row.assessment_id
      ? { kind: 'advice', label: '查看建議單', href: adviceUrl(row.assessment_id) } : null;
    if (row.status === '待排定') {
      if (cs) out.buttons.push({ kind: 'schedule', label: '排定' });
    } else if (row.status === '已排定') {
      if (cs) {
        if (row.assessment_status === 'draft') {
          out.buttons.push({ kind: 'continue', label: '繼續健檢', href: beginUrl(row.employee_id, year, quarter) });
          out.hint = '已開始健檢；要取消排定，請先到考核頁放棄草稿。';
        } else {
          out.buttons.push({ kind: 'unschedule', label: '取消排定' });
          out.buttons.push({ kind: 'begin', label: '開始健檢', href: beginUrl(row.employee_id, year, quarter) });
        }
      }
    } else if (row.status === '已完成') {
      if (advice) out.buttons.push(advice);
    }
    return out;
  }

  var api = {
    STORE_ORDER: STORE_ORDER, QUARTERS: QUARTERS, MAX_NOTE: MAX_NOTE,
    taipeiYearQuarter: taipeiYearQuarter, yearOptions: yearOptions, formatScheduled: formatScheduled,
    scheduleToIso: scheduleToIso, noteError: noteError,
    storeRank: storeRank, sortStores: sortStores,
    quarterStats: quarterStats, changedStores: changedStores,
    rosterStoreOptions: rosterStoreOptions, filterRoster: filterRoster, sortRoster: sortRoster,
    statusInfo: statusInfo, verdictCls: verdictCls, formatScore: formatScore,
    beginUrl: beginUrl, adviceUrl: adviceUrl, rosterActions: rosterActions
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CheckupCore = api;
})(typeof window !== 'undefined' ? window : this);
