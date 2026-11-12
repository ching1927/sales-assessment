/*
 * 健檢單（每季抽查彙整）的純函式（不連資料庫、不碰畫面）。規格見 FEATURES.md「健檢單」。
 * 瀏覽器：window.CheckupSheetCore；Node：module.exports。依賴 spotdims-core.js（SpotDims）、checkup-core.js（CheckupCore）。
 *
 * 規則（老闆已核可）：
 *   * 季次一律用日曆季：Q1＝1–3 月、Q2＝4–6 月、Q3＝7–9 月、Q4＝10–12 月；以抽查日期 checked_on 落在該季計。
 *   * 該季沒有抽查紀錄的人不出現；不另存健檢單，清單與 PDF 都用 spot_inspections 該季資料現算。
 *   * 判定資料庫值仍是適當／不適當，畫面一律走 SpotDims.verdictLabel（優良回覆／待加強回覆）。
 *   * 面向「被勾次數」只算新制勾選（improve_dims）；舊制紀錄沒有勾選就是 0，並標舊制分數。
 *
 * 用法：
 *   CheckupSheetCore.quarterRange(2026, 3)           { start:'2026-07-01', end:'2026-09-30' }；年季不合法回 null
 *   CheckupSheetCore.quarterLabel(2026, 3)           '2026 年第 3 季（7–9 月）'
 *   CheckupSheetCore.summarize(rows)                 抽查紀錄 -> 每人一筆摘要（見下），依門市順序、員編排序
 *       { employee_id, name, store_code, total, good, weak, counts[7], top[], records[] }
 *   CheckupSheetCore.filterByStore(list, store)      門市篩選（空字串＝全部）
 *   CheckupSheetCore.dimCounts(records)              七面向被勾次數（依 SpotDims.DIMS 順序）
 *   CheckupSheetCore.topDims(counts)                 被勾最多的面向名稱（並列全列；全為 0 回空陣列）
 *   CheckupSheetCore.buildModel(sum, o)              整理成 PDF 要畫的內容；o：{ year, quarter, storeName, nowMs }
 *   CheckupSheetCore.starSvg(counts)                 七面向被勾次數星狀圖 SVG 字串（固定色碼，可單獨轉圖）
 *   CheckupSheetCore.starLayout(counts)              同 starSvg，另回傳 { width, height, svg }（viewBox 寬高）
 *   CheckupSheetCore.starScaleMax(counts)            星狀圖外圈代表的次數（至少 3）
 *   CheckupSheetCore.fitShot(w, h, maxW, maxH)       截圖在框內等比放大／縮小後的 { w, h }（不裁切）
 *   CheckupSheetCore.fileName(model)                 PDF 檔名（去掉檔名不允許的字元）
 */
(function (root) {
  var isNode = typeof module !== 'undefined' && module.exports;
  var SpotDims = isNode ? require('./spotdims-core.js') : root.SpotDims;
  var CheckupCore = isNode ? require('./checkup-core.js') : root.CheckupCore;
  var DIMS = SpotDims.DIMS;
  var MAX_SHOTS = SpotDims.MAX_SHOTS;
  var TZ_MS = 8 * 3600000;

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; });
  }

  // ---- 日曆季 ----
  function quarterRange(year, quarter) {
    var y = Number(year), q = Number(quarter);
    if (!(y >= 2000 && y <= 2100) || Math.floor(y) !== y || !(q >= 1 && q <= 4) || Math.floor(q) !== q) return null;
    var m1 = (q - 1) * 3 + 1, last = new Date(Date.UTC(y, q * 3, 0)).getUTCDate();
    return { start: y + '-' + pad(m1) + '-01', end: y + '-' + pad(q * 3) + '-' + pad(last) };
  }
  function quarterLabel(year, quarter) {
    var m1 = (Number(quarter) - 1) * 3 + 1;
    return year + ' 年第 ' + quarter + ' 季（' + m1 + '–' + (m1 + 2) + ' 月）';
  }

  // ---- 彙整 ----
  function dimCounts(records) {
    var c = DIMS.map(function () { return 0; });
    (records || []).forEach(function (r) {
      SpotDims.normalizeDims(r && r.improve_dims).forEach(function (d) { c[DIMS.indexOf(d)]++; });
    });
    return c;
  }
  function topDims(counts) {
    var mx = Math.max.apply(null, (counts || []).concat([0]));
    if (mx <= 0) return [];
    return DIMS.filter(function (d, i) { return counts[i] === mx; });
  }
  function recordCmp(a, b) {
    return cmp(a.checked_on, b.checked_on) || cmp(String(a.created_at || ''), String(b.created_at || '')) || cmp(a.id, b.id);
  }
  function summarize(rows) {
    var by = {}, order = [];
    (rows || []).forEach(function (r) {
      if (!r || !r.employee_id || !r.checked_on) return;
      if (!by[r.employee_id]) { by[r.employee_id] = []; order.push(r.employee_id); }
      by[r.employee_id].push(r);
    });
    var out = order.map(function (id) {
      var recs = by[id].slice().sort(recordCmp), last = recs[recs.length - 1];
      var good = 0, weak = 0;
      recs.forEach(function (r) { if (r.verdict === '適當') good++; else if (r.verdict === '不適當') weak++; });
      var counts = dimCounts(recs);
      return { employee_id: id, name: last.employee_label || id, store_code: last.store_code, total: recs.length, good: good, weak: weak,
        counts: counts, top: topDims(counts), records: recs };
    });
    return CheckupCore.sortStores(out, 'store_code', 'employee_id');
  }
  function filterByStore(list, store) {
    return (list || []).filter(function (s) { return !store || s.store_code === store; });
  }

  // ---- PDF 內容 ----
  function ymd(ms) { var d = new Date(ms + TZ_MS); return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate()); }
  function buildModel(sum, o) {
    o = o || {};
    var recs = (sum.records || []).map(function (r) {
      var shots = (Array.isArray(r.shot_paths) ? r.shot_paths : []).filter(function (p) { return typeof p === 'string' && p.indexOf('spot/') === 0; }).slice(0, MAX_SHOTS);
      return {
        id: r.id, date: r.checked_on, verdict: SpotDims.verdictLabel(r.verdict), isWeak: r.verdict === '不適當',
        dims: SpotDims.normalizeDims(r.improve_dims), note: String(r.improve_note == null ? '' : r.improve_note).replace(/^\s+|\s+$/g, ''),
        legacy: SpotDims.legacyScore(r), shots: shots
      };
    });
    return {
      name: sum.name, id: sum.employee_id, store: o.storeName || sum.store_code, quarterText: quarterLabel(o.year, o.quarter),
      year: o.year, quarter: o.quarter, total: sum.total, good: sum.good, weak: sum.weak, counts: sum.counts.slice(), top: sum.top.slice(),
      records: recs, generated: ymd(typeof o.nowMs === 'number' ? o.nowMs : Date.now())
    };
  }
  function fileName(m) {
    return ('健檢單_' + m.name + '_' + m.year + 'Q' + m.quarter + '.pdf').replace(/[\\\/:*?"<>|]/g, '_');
  }

  // ---- 星狀圖：半徑＝被勾次數／max(3, 最大次數)，越外圈越需要加強；顏色固定（單獨轉圖讀不到頁面 CSS 變數）----
  // 版面：圖心在 viewBox 水平正中央，viewBox 左右對稱；標籤寬度依字數估算，左右兩側都預留（含數字，不裁切）；
  //       字級 15（單位）× 顯示縮放，PDF 內約 11pt 以上；右半邊標籤靠左對齊（start）、左半邊靠右對齊（end）、正上方置中。
  var STAR_FS = 15, STAR_R = 105, STAR_GAP = 18, STAR_MARGIN = 14;
  function textW(text, fs, bold) {
    var w = 0, t = String(text);
    for (var i = 0; i < t.length; i++) w += t.charCodeAt(i) > 255 ? fs : fs * (bold ? 0.62 : 0.56);
    return w;
  }
  function starScaleMax(counts) { return Math.max(3, Math.max.apply(null, (counts || []).concat([0]))); }
  // 回傳 { svg, width, height }：viewBox 寬高（單位），讓外層依寬度決定顯示大小
  function starLayout(counts) {
    var n = DIMS.length, c = DIMS.map(function (_, i) { return Number(counts && counts[i]) || 0; });
    var mx = Math.max.apply(null, c), max = starScaleMax(c);
    var R = STAR_R, fs = STAR_FS, lr = R + STAR_GAP;
    function ang(i) { return -Math.PI / 2 + i * 2 * Math.PI / n; }
    var labels = DIMS.map(function (nm, i) {
      var t = nm + '（' + c[i] + '）', hot = c[i] === mx && c[i] > 0, a = ang(i), dx = lr * Math.cos(a), dy = lr * Math.sin(a);
      var anc = dx < -5 ? 'end' : (dx > 5 ? 'start' : 'middle'), w = textW(t, fs, hot);
      var left = anc === 'end' ? dx - w : (anc === 'middle' ? dx - w / 2 : dx), right = anc === 'end' ? dx : (anc === 'middle' ? dx + w / 2 : dx + w);
      // 文字基線：上半部往上靠、下半部往下靠，避免壓到圖形
      var by = dy + (Math.abs(dx) <= 5 ? (dy < 0 ? -4 : fs + 2) : (dy > lr * 0.5 ? fs * 0.8 : dy < -lr * 0.5 ? -2 : fs * 0.35));
      return { t: t, hot: hot, dx: dx, by: by, anc: anc, left: left, right: right };
    });
    var half = Math.max.apply(null, labels.map(function (l) { return Math.max(Math.abs(l.left), Math.abs(l.right)); }).concat([R])) + STAR_MARGIN;
    var top = Math.min.apply(null, labels.map(function (l) { return l.by - fs; }).concat([-R])) - STAR_MARGIN;
    var bot = Math.max.apply(null, labels.map(function (l) { return l.by + 4; }).concat([R])) + STAR_MARGIN;
    var W = Math.round(half * 2), cx = W / 2, cy = -top, H = Math.round(cy + bot);
    function pt(i, r) { var a = ang(i); return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; }
    function f(p) { return p[0].toFixed(1) + ',' + p[1].toFixed(1); }
    var g = '';
    [1 / 3, 2 / 3, 1].forEach(function (k) {
      g += '<polygon points="' + DIMS.map(function (_, i) { return f(pt(i, R * k)); }).join(' ') + '" fill="none" stroke="#C3CAD5" stroke-width="1"/>';
    });
    var ax = DIMS.map(function (_, i) { var p = pt(i, R); return '<line x1="' + cx + '" y1="' + cy.toFixed(1) + '" x2="' + p[0].toFixed(1) + '" y2="' + p[1].toFixed(1) + '" stroke="#C3CAD5"/>'; }).join('');
    var poly = mx > 0 ? '<polygon points="' + DIMS.map(function (_, i) { return f(pt(i, R * c[i] / max)); }).join(' ') + '" fill="rgba(217,255,0,.45)" stroke="#111" stroke-width="2.5" stroke-linejoin="round"/>' : '';
    var dots = DIMS.map(function (_, i) {
      if (!c[i]) return '';
      var p = pt(i, R * c[i] / max);
      return '<circle cx="' + p[0].toFixed(1) + '" cy="' + p[1].toFixed(1) + '" r="4.5" fill="#111"/>';
    }).join('');
    var lb = labels.map(function (l) {
      return '<text x="' + (cx + l.dx).toFixed(1) + '" y="' + (cy + l.by).toFixed(1) + '" text-anchor="' + l.anc + '" font-size="' + fs + '" font-weight="' + (l.hot ? '800' : '500') + '" fill="#111">' + esc(l.t) + '</text>';
    }).join('');
    var label = '可改善面向被勾次數：' + DIMS.map(function (nm, i) { return nm + ' ' + c[i]; }).join('、');
    return { width: W, height: H, svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '" role="img" aria-label="' + esc(label) + '" style="font-family:Microsoft JhengHei,PingFang TC,Noto Sans TC,sans-serif">' +
      '<title>' + esc(label) + '</title>' + g + ax + poly + dots + lb + '</svg>' };
  }
  function starSvg(counts) { return starLayout(counts).svg; }

  // ---- 截圖尺寸：保持原比例、不裁切，在 maxW×maxH 內盡量放大（寬度優先；太高就縮到 maxH）----
  function fitShot(w, h, maxW, maxH) {
    w = Number(w); h = Number(h); maxW = Number(maxW); maxH = Math.max(Number(maxH) || 0, 120);
    if (!(w > 0) || !(h > 0) || !(maxW > 0)) return { w: 0, h: 0 };
    var k = Math.min(maxW / w, maxH / h);
    return { w: Math.round(w * k), h: Math.round(h * k) };
  }

  var api = {
    quarterRange: quarterRange, quarterLabel: quarterLabel, dimCounts: dimCounts, topDims: topDims,
    summarize: summarize, filterByStore: filterByStore, buildModel: buildModel, fileName: fileName, starSvg: starSvg,
    starLayout: starLayout, starScaleMax: starScaleMax, fitShot: fitShot
  };
  if (isNode) module.exports = api;
  else root.CheckupSheetCore = api;
})(typeof window !== 'undefined' ? window : this);
