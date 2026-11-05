/*
 * 考核後台「近期考核」分頁的純函式（不連資料庫、不碰畫面）。規則照原成績單頁（reports.html），再加上老闆確認樣品的日期區間、類型、分頁。
 * 瀏覽器：window.RecentReportsCore；Node：module.exports。
 *
 * 用法：
 *   RecentReportsCore.PAGE_SIZE                    每次顯示筆數（20）
 *   RecentReportsCore.dateOf(r)                    成績單的時間：送出時間，沒有就用建立時間（ISO 字串）
 *   RecentReportsCore.stamp(iso)                   ISO -> 'YYYY-MM-DD HH:mm'（台北）；無法解析回 ''
 *   RecentReportsCore.taipeiDate(iso)              ISO -> 'YYYY-MM-DD'（台北日期）
 *   RecentReportsCore.visibleRows(rows, me)        依身分過濾並由新到舊排序（客服部全部；其他只有已送出；店長再限自己門市）
 *   RecentReportsCore.applyFilters(rows, f, me)    f = { store, from, to, verdict, kind, q }；日期為台北日期、起訖含當天；店長忽略門市下拉
 *   RecentReportsCore.paginate(list, shown)        -> { rows, n, total, hasMore }
 *   RecentReportsCore.countText(n, total)          '顯示 N / 共 M 筆'
 *   RecentReportsCore.statusInfo(r)                -> { cls, text }（已作廢／暫存中／已送出）
 *   RecentReportsCore.verdictInfo(r)               -> { cls, text }（判定，或「尚未結算」）
 *   RecentReportsCore.isCheckup(r)                 是否健檢列
 *   RecentReportsCore.checkupLabel(r)              '健檢 2026 Q3'（沒年度只有 '健檢'）
 *   RecentReportsCore.hasAdviceLink(r)             健檢且已送出才有「建議單」連結
 *   RecentReportsCore.adviceUrl(r)                 'advice.html?assessment=<id>'
 *   RecentReportsCore.canVoid(r, me)               客服部且已送出（未作廢）才能作廢
 *   RecentReportsCore.fmt(x) / fmtSize(bytes)      數字（四捨五入一位）／檔案大小
 *   RecentReportsCore.safeNoteUrl(u)               只接受 http／https 的備註網址，否則回 ''
 */
(function (root) {
  var PAGE_SIZE = 20;
  var VCLS = { '優秀': 'on', '及格': 'new', '需複訓': 'unk', '不及格': 'out' };

  function isCS(me) { return !!me && me.role === 'cs_admin'; }
  function isManager(me) { return !!me && me.role === 'store_manager'; }

  function dateOf(r) { return r.submitted_at || r.created_at; }
  function stamp(iso) {
    var t = new Date(iso);
    if (!iso || isNaN(t.getTime())) return '';
    return t.toLocaleString('sv-SE', { timeZone: 'Asia/Taipei' }).slice(0, 16);
  }
  function taipeiDate(iso) { return stamp(iso).slice(0, 10); }

  // 非客服部只看已送出（資料庫規則本來就只給這些，這裡再擋一次）；店長再限自己門市；由新到舊
  function visibleRows(rows, me) {
    var out = (rows || []).filter(function (r) {
      if (!isCS(me) && r.status !== 'submitted') return false;
      if (isManager(me) && r.store_code !== me.store_code) return false;
      return true;
    });
    out.sort(function (a, b) { var x = dateOf(a), y = dateOf(b); return x < y ? 1 : x > y ? -1 : 0; });
    return out;
  }

  function applyFilters(rows, f, me) {
    f = f || {};
    var q = String(f.q || '').trim().toLowerCase();
    var store = isManager(me) ? '' : (f.store || '');
    return (rows || []).filter(function (r) {
      var d = taipeiDate(dateOf(r));
      if (store && r.store_code !== store) return false;
      if (f.from && d < f.from) return false;
      if (f.to && d > f.to) return false;
      if (f.verdict && r.verdict !== f.verdict) return false;
      if (f.kind && (r.kind === 'checkup' ? 'checkup' : 'exam') !== f.kind) return false;
      if (q && (r.employee_id + ' ' + r.employee_label).toLowerCase().indexOf(q) < 0) return false;
      return true;
    });
  }

  function paginate(list, shown) {
    var total = list.length, n = Math.min(Math.max(0, shown), total);
    return { rows: list.slice(0, n), n: n, total: total, hasMore: n < total };
  }
  function countText(n, total) { return '顯示 ' + n + ' / 共 ' + total + ' 筆'; }

  function statusInfo(r) {
    if (r.status === 'voided') return { cls: 'out', text: '已作廢' };
    if (r.status === 'draft') return { cls: 'unk', text: '暫存中' };
    return { cls: 'on', text: '已送出' };
  }
  function verdictInfo(r) {
    return r.verdict ? { cls: VCLS[r.verdict] || 'reg', text: r.verdict } : { cls: 'reg', text: '尚未結算' };
  }
  function isCheckup(r) { return r.kind === 'checkup'; }
  function checkupLabel(r) {
    return '健檢' + (r.checkup_year ? ' ' + r.checkup_year + (r.checkup_quarter ? ' Q' + r.checkup_quarter : '') : '');
  }
  function hasAdviceLink(r) { return isCheckup(r) && r.status === 'submitted'; }
  function adviceUrl(r) { return 'advice.html?assessment=' + encodeURIComponent(r.id); }
  function canVoid(r, me) { return isCS(me) && r.status === 'submitted'; }

  function fmt(x) { return String(Math.round(Number(x) * 10) / 10); }
  function fmtSize(b) { return b < 1048576 ? Math.max(1, Math.round(b / 1024)) + ' KB' : (b / 1048576).toFixed(1) + ' MB'; }
  function safeNoteUrl(u) {
    var s = u == null ? '' : String(u);
    return /^https?:\/\//i.test(s) ? s : '';
  }

  // 弱項分析雷達圖旁的數值表：rows 為七面向平均得分率（含 weak 旗標），cmpRows 為全公司對照（可為 null）。
  // 回傳依得分率由高到低排列（無資料排最後、同分維持原順序），每列多 co（全公司得分率）與 diff（所選範圍減全公司，取小數 1 位）。
  function radarRows(rows, cmpRows) {
    var out = (rows || []).map(function (r, i) {
      var c = cmpRows && cmpRows[i] ? cmpRows[i].pct : null;
      // 差異以畫面上顯示的 1 位小數相減，避免兩欄看起來一樣卻出現 ▼0.1
      var d = r.pct !== null && r.pct !== undefined && c !== null && c !== undefined ? Math.round((Math.round(r.pct * 10) / 10 - Math.round(c * 10) / 10) * 10) / 10 : null;
      return { name: r.name, pct: r.pct, weak: !!r.weak, n: r.n, co: cmpRows ? c : null, diff: d, i: i };
    });
    out.sort(function (a, b) {
      var x = a.pct === null ? -1 : a.pct, y = b.pct === null ? -1 : b.pct;
      return y - x || a.i - b.i;
    });
    return out.map(function (r) { delete r.i; return r; });
  }
  // 是否畫「全公司平均」對照線：選了單一門市，且手上的成績單涵蓋兩家以上門市（店長被 RLS 限制只看到自己門市時不畫）
  function canCompare(scope, storeCodes) {
    if (!scope) return false;
    var seen = {};
    (storeCodes || []).forEach(function (s) { seen[s] = 1; });
    return Object.keys(seen).length > 1;
  }

  var api = {
    radarRows: radarRows, canCompare: canCompare,
    PAGE_SIZE: PAGE_SIZE, VCLS: VCLS,
    dateOf: dateOf, stamp: stamp, taipeiDate: taipeiDate,
    visibleRows: visibleRows, applyFilters: applyFilters, paginate: paginate, countText: countText,
    statusInfo: statusInfo, verdictInfo: verdictInfo, isCheckup: isCheckup, checkupLabel: checkupLabel,
    hasAdviceLink: hasAdviceLink, adviceUrl: adviceUrl, canVoid: canVoid,
    fmt: fmt, fmtSize: fmtSize, safeNoteUrl: safeNoteUrl
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.RecentReportsCore = api;
})(typeof window !== 'undefined' ? window : this);
