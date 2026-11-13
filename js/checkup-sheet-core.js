/*
 * 健檢單（每季登記彙整）的純函式（不連資料庫、不碰畫面）。規格見 FEATURES.md「健檢單」。
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
 *   CheckupSheetCore.buildModel(sum, o)              整理成 PDF 要畫的內容；o：{ year, quarter, storeName, nowMs, ctxRows }
 *                                                    ctxRows＝上一季（年度檔另抓全年）的紀錄，用來算上季對比與年度頁
 *   CheckupSheetCore.scoreOf(model)                  面向分數＝1 − 被勾次數 ÷ 登記次數（越外圈越好）；登記 0 筆回 null
 *   CheckupSheetCore.quarterCompareSvg(cur, prev)    單季星狀圖（本季實線、上季虛線；prev 為 null 只畫實線）→ { width, height, svg }
 *   CheckupSheetCore.totalSvg(qs) / lineChartSvg(qs) 全年總合星狀圖 / 各面向四季變化折線圖（qs＝[Q1..Q4 model 或 null]）
 *   CheckupSheetCore.quarterAnalysis / yearAnalysis  單季小結（字串）／年度分析（字串陣列）；建議句在 DIM_ADVICE
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
    // 上一季與年度對比：o.ctxRows＝抓回來的紀錄（第 4 季是全年、其他季是上一季；可含多人，這裡只取這位業務）
    var y = Number(o.year), q = Number(o.quarter), pq = prevQuarterOf(y, q), ctx = o.ctxRows || [];
    var cur = sumModel(sum), yearQs = null, prev = modelFromRows(ctx, sum.employee_id, pq.year, pq.quarter);
    if (q === 4 && o.yearRows) {   // 年度健檢單才需要全年紀錄（o.yearRows）
      yearQs = [1, 2, 3].map(function (k) { return modelFromRows(o.yearRows, sum.employee_id, y, k); });
      yearQs.push(cur);
    }
    return {
      name: sum.name, id: sum.employee_id, store: o.storeName || sum.store_code, quarterText: quarterLabel(o.year, o.quarter),
      year: o.year, quarter: o.quarter, total: sum.total, good: sum.good, weak: sum.weak, counts: sum.counts.slice(), top: sum.top.slice(),
      cur: cur, prev: prev, prevName: Q_NAMES[pq.quarter - 1], isQ4: q === 4, yearQs: yearQs,
      analysis: quarterAnalysis(cur, prev), items: quarterItems(cur, prev), yearItems: yearQs ? yearItems(yearQs) : null, yearAnalysis: yearQs ? yearAnalysis(yearQs) : null,
      records: recs, generated: ymd(typeof o.nowMs === 'number' ? o.nowMs : Date.now())
    };
  }
  function fileName(m) {
    return ('健檢單_' + m.name + '_' + m.year + 'Q' + m.quarter + '.pdf').replace(/[\\\/:*?"<>|]/g, '_');
  }
  function fileNameYear(m) {
    return ('年度健檢單_' + m.name + '_' + m.year + '.pdf').replace(/[\\\/:*?"<>|]/g, '_');
  }

  // ---- 面向分數與各季模型 ----
  // 模型 model（一季的彙整）：{ checks: 當季登記次數（該季總紀錄筆數）, weak: 待加強回覆次數, counts: [七面向被勾次數] }
  // 面向分數 = 1 − 被勾次數 ÷ 登記次數：整季沒被勾＝100%（最外圈），越需要加強越往內縮；登記 0 筆不產生（null）。
  // 舊制紀錄沒有 improve_dims 勾選，視為未被勾（與 dimCounts 一致）。
  var EPS = 1e-9;
  var Q_NAMES = ['第一季', '第二季', '第三季', '第四季'];
  function pct(x) { return Math.round(x * 100); }
  function quarterModel(records) {
    if (!records || !records.length) return null;
    var weak = 0;
    records.forEach(function (r) { if (r && r.verdict === '不適當') weak++; });
    return { checks: records.length, weak: weak, counts: dimCounts(records) };
  }
  function sumModel(sum) { return sum ? { checks: sum.total, weak: sum.weak, counts: sum.counts.slice() } : null; }
  function prevQuarterOf(year, quarter) { return Number(quarter) === 1 ? { year: Number(year) - 1, quarter: 4 } : { year: Number(year), quarter: Number(quarter) - 1 }; }
  // 從一批紀錄（可含多人多季）取出某員工某年某季的模型；沒紀錄回 null
  function modelFromRows(rows, empId, year, quarter) {
    var rg = quarterRange(year, quarter);
    if (!rg) return null;
    return quarterModel((rows || []).filter(function (r) { return r && r.employee_id === empId && r.checked_on >= rg.start && r.checked_on <= rg.end; }));
  }
  // 季度健檢單要多抓的紀錄範圍：上一季（第 1 季的上一季是去年第 4 季）
  function contextRange(year, quarter) {
    var pq = prevQuarterOf(year, quarter);
    return quarterRange(pq.year, pq.quarter);
  }
  // 年度健檢單要抓的範圍：當年 1/1~12/31
  function yearRange(year) { var a = quarterRange(year, 1), z = quarterRange(year, 4); return a && z ? { start: a.start, end: z.end } : null; }
  function scoreOf(m) {
    if (!m || !(m.checks > 0)) return null;
    return DIMS.map(function (_, i) { return 1 - (Number(m.counts[i]) || 0) / m.checks; });
  }
  function totalModel(qs) {
    var t = { checks: 0, weak: 0, counts: DIMS.map(function () { return 0; }) };
    (qs || []).forEach(function (m) {
      if (!m || !(m.checks > 0)) return;
      t.checks += m.checks; t.weak += m.weak;
      m.counts.forEach(function (c, i) { t.counts[i] += c; });
    });
    return t;
  }

  // ---- 星狀圖與折線圖（版面照 樣品/健檢單星狀圖對比樣品.html；顏色固定，可單獨轉圖）----
  var DIM_SUB = SpotDims.DIM_SUBTITLE;
  var GAP = 20, MARGIN = 14;
  function textW(text, fs, bold) {
    var w = 0, t = String(text);
    for (var i = 0; i < t.length; i++) w += t.charCodeAt(i) > 255 ? fs : fs * (bold ? 0.62 : 0.56);
    return w;
  }
  // 副標折行：超過 12 字就折成兩行，優先在逗號後折，否則對半折
  function wrapSub(t) {
    t = String(t || '');
    if (t.length <= 12) return t ? [t] : [];
    var c = t.indexOf('，');
    var cut = (c > 0 && c < t.length - 3 && c <= 12) ? c + 1 : Math.ceil(t.length / 2);
    return [t.slice(0, cut), t.slice(cut)];
  }
  // 副標單行：超過 12 字截成 12 字加「…」（完整副標在年度數值表看得到）
  function singleSub(t) { t = String(t || ''); return t ? [t.length > 12 ? t.slice(0, 12) + '…' : t] : []; }
  // o：{ R: 圖半徑（預設 130）, fs: 標籤字級（預設 17）, sub: 是否顯示副標（預設 true）, labelIdx, labelBold,
  //      weakLine: 紅色虛線多邊形的比例（如 0.6）, emph: { 面向索引: { color, dot, tag } }, tagMode: 'replace'（標籤取代副標）| 'append'（接在副標下）, subSingle: 副標單行截斷 }
  function radarSvg(series, o) {
    o = o || {};
    var n = DIMS.length, R = o.R || 130, fs = o.fs || 17, sfs = Math.round(fs * 0.65 * 10) / 10, lh = sfs * 1.3, lr = R + GAP, showSub = o.sub !== false;
    var live = series.filter(function (s) { return s && s.scores; });
    var li = o.labelIdx != null ? o.labelIdx : series.length - 1;
    var ls = (series[li] && series[li].scores) || (live[live.length - 1] && live[live.length - 1].scores) || DIMS.map(function () { return 1; });
    var mn = Math.min.apply(null, ls);
    function ang(i) { return -Math.PI / 2 + i * 2 * Math.PI / n; }
    var labels = DIMS.map(function (nm, i) {
      var t = nm + '（' + pct(ls[i]) + '%）', hot = o.labelBold !== false && ls[i] - mn < EPS && mn < 1 - EPS;
      var em = o.emph && o.emph[i];
      var subs = showSub ? (o.subSingle ? singleSub(DIM_SUB[nm]) : wrapSub(DIM_SUB[nm])) : [];
      if (em && o.tagMode === 'replace') subs = [];
      var lines = subs.map(function (x) { return { t: x, c: '#6B7280', b: false }; });
      if (em) lines.push({ t: em.tag, c: em.color, b: true });
      subs = lines;
      var ns = subs.length, subH = ns ? sfs * 0.2 + lh * ns : 0;
      var a = ang(i), dx = lr * Math.cos(a), dy = lr * Math.sin(a);
      var anc = dx < -5 ? 'end' : (dx > 5 ? 'start' : 'middle');
      var w = Math.max(textW(t, fs, hot), Math.max.apply(null, subs.map(function (s) { return textW(s.t, sfs, s.b); }).concat([0])));
      var left = anc === 'end' ? dx - w : (anc === 'middle' ? dx - w / 2 : dx), right = anc === 'end' ? dx : (anc === 'middle' ? dx + w / 2 : dx + w);
      var b1;
      if (Math.abs(dx) <= 5) b1 = dy < 0 ? dy - 6 - subH : dy + fs + 2;
      else b1 = dy + (dy > lr * 0.5 ? fs * 0.8 : dy < -lr * 0.5 ? -2 : fs * 0.35);
      var subY = subs.map(function (_, k) { return b1 + sfs * 0.2 + lh * (k + 1); });
      var bottom = ns ? subY[ns - 1] + 4 : b1 + 4;
      return { t: t, hot: hot, color: em ? em.color : '#111', dx: dx, b1: b1, anc: anc, left: left, right: right, subs: subs, subY: subY, bottom: bottom };
    });
    var half = Math.max.apply(null, labels.map(function (l) { return Math.max(Math.abs(l.left), Math.abs(l.right)); }).concat([R])) + MARGIN;
    var top = Math.min.apply(null, labels.map(function (l) { return l.b1 - fs; }).concat([-R])) - MARGIN;
    var bot = Math.max.apply(null, labels.map(function (l) { return l.bottom; }).concat([R])) + MARGIN;
    var W = Math.round(half * 2), cx = W / 2, cy = -top, H = Math.round(cy + bot);
    function pt(i, r) { var a = ang(i); return [cx + r * Math.cos(a), cy + r * Math.sin(a)]; }
    function f(p) { return p[0].toFixed(1) + ',' + p[1].toFixed(1); }
    var g = '';
    [0.25, 0.5, 0.75, 1].forEach(function (k) {
      g += '<polygon points="' + DIMS.map(function (_, i) { return f(pt(i, R * k)); }).join(' ') + '" fill="none" stroke="' + (k === 1 ? '#8F99A8' : '#C3CAD5') + '" stroke-width="' + (k === 1 ? 1.4 : 1) + '"/>';
    });
    var ax = DIMS.map(function (_, i) { var p = pt(i, R); return '<line x1="' + cx + '" y1="' + cy.toFixed(1) + '" x2="' + p[0].toFixed(1) + '" y2="' + p[1].toFixed(1) + '" stroke="#C3CAD5"/>'; }).join('');
    var ring = [0.25, 0.5, 0.75, 1].map(function (k) {
      return '<text x="' + (cx + 4).toFixed(1) + '" y="' + (cy - R * k - 2).toFixed(1) + '" font-size="11" fill="#6B7280" stroke="#fff" stroke-width="3" paint-order="stroke" font-weight="700">' + pct(k) + '%</text>';
    }).join('');
    var body = '';
    series.forEach(function (s) {
      if (!s || !s.scores) return;
      var pts = DIMS.map(function (_, i) { return f(pt(i, R * Math.max(0, Math.min(1, s.scores[i])))); }).join(' ');
      body += '<polygon points="' + pts + '" fill="' + (s.fill || 'none') + '" stroke="' + s.color + '" stroke-width="' + s.width + '" stroke-linejoin="round"' + (s.dash ? ' stroke-dasharray="' + s.dash + '"' : '') + '/>';
      if (s.dots) body += DIMS.map(function (_, i) { var p = pt(i, R * Math.max(0, Math.min(1, s.scores[i]))); return '<circle cx="' + p[0].toFixed(1) + '" cy="' + p[1].toFixed(1) + '" r="' + (s.dotColors && s.dotColors[i] ? 5.5 : 4.5) + '" fill="' + ((s.dotColors && s.dotColors[i]) || s.color) + '"' + (s.dotColors && s.dotColors[i] ? ' stroke="#fff" stroke-width="1.2"' : '') + '/>'; }).join('');
    });
    if (o.weakLine) body += '<polygon points="' + DIMS.map(function (_, i) { return f(pt(i, R * o.weakLine)); }).join(' ') + '" fill="none" stroke="' + COLORS.red + '" stroke-width="1.8" stroke-dasharray="6 4" stroke-linejoin="round"/>';
    series.forEach(function (s) {
      if (!s || !s.scores || !s.dotColors) return;
      body += DIMS.map(function (_, i) { if (!s.dotColors[i]) return ''; var p = pt(i, R * Math.max(0, Math.min(1, s.scores[i]))); return '<circle cx="' + p[0].toFixed(1) + '" cy="' + p[1].toFixed(1) + '" r="5.5" fill="' + s.dotColors[i] + '" stroke="#fff" stroke-width="1.2"/>'; }).join('');
    });
    var lb = labels.map(function (l) {
      var x = (cx + l.dx).toFixed(1);
      return '<text x="' + x + '" y="' + (cy + l.b1).toFixed(1) + '" text-anchor="' + l.anc + '" font-size="' + fs + '" font-weight="' + (l.hot ? '800' : '600') + '" fill="' + l.color + '">' + esc(l.t) + '</text>' +
        l.subs.map(function (s, k) { return '<text x="' + x + '" y="' + (cy + l.subY[k]).toFixed(1) + '" text-anchor="' + l.anc + '" font-size="' + sfs + '"' + (s.b ? ' font-weight="800"' : '') + ' fill="' + s.c + '">' + esc(s.t) + '</text>'; }).join('');
    }).join('');
    var label = '面向分數，越外圈越好：' + DIMS.map(function (nm, i) { return nm + ' ' + pct(ls[i]) + '%'; }).join('、');
    // 不放 <title>：滑鼠移過不會跳出提示框蓋住標籤
    return { width: W, height: H, svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '" role="img" aria-label="' + esc(label) + '" style="font-family:Microsoft JhengHei,PingFang TC,Noto Sans TC,sans-serif">' + g + ax + ring + body + lb + '</svg>' };
  }
  var CUR = { color: '#111', fill: 'rgba(217,255,0,.45)', width: 2.5, dots: true };
  function dotColorsOf(em) { return IDX.map(function (i) { return em[i] ? em[i].dot : null; }); }
  function quarterCompareSvg(cur, prev) {
    var p = scoreOf(prev), em = emphOf(scoreOf(cur), true);
    return radarSvg([
      p ? { scores: p, color: '#0669EB', fill: 'rgba(6,105,235,.05)', width: 2.2, dash: '8 5' } : null,
      { scores: scoreOf(cur), color: CUR.color, fill: CUR.fill, width: CUR.width, dots: true, dotColors: dotColorsOf(em) }
    ], { labelIdx: 1, weakLine: WEAK_LINE, emph: em, tagMode: 'append' });
  }
  function totalSvg(qs) {
    var ts = scoreOf(totalModel(qs)), em = ts ? emphOf(ts) : {};
    return radarSvg([{ scores: ts, color: COLORS.blue, fill: 'rgba(31,111,209,.12)', width: 2.5, dots: true, dotColors: dotColorsOf(em) }],
      { labelIdx: 0, R: 125, fs: 18, weakLine: WEAK_LINE, emph: em, tagMode: 'replace', subSingle: true });
  }

  // 各面向的具體建議（草稿，老闆之後會確認文字；日後只要改這張表）
  var DIM_ADVICE = {
    '資訊正確性': '回覆前先確認車況、價格與流程資料，不確定就先查證再回。',
    '預設訊息運用': '遇到常見問題時，先用公司預設訊息，再依客人情況補一兩句個人化說明。',
    '問題掌握': '回覆前先把客人的問題讀完，用一句話確認需求，再針對重點回答。',
    '主動引導': '回答完後多問一句，帶客人往下一步，例如約看車或留聯絡方式。',
    '風險意識': '不確定的事不先承諾，容易有爭議的地方要提醒並寫清楚。',
    '語氣與禮貌': '多用「您好」「謝謝」「請」，語氣親切，結尾加一句關心。',
    '文字品質': '送出前快速檢查錯字與斷句，分段與條列讓內容好讀。'
  };
  var GOOD = 0.9;   // 分數 >= 90% 算很穩、不算不足
  // ---- 配色與門檻（集中在這裡；Tx 是文字／標籤底色用的深一階顏色，對白底與對應淡底都 >= 4.5:1）----
  var COLORS = {
    green: '#2E7D5B', greenTx: '#226347', greenBg: '#EAF2EE',
    red: '#D64B3C', redTx: '#B53A2D', redBg: '#FBEDEB',
    blue: '#1F6FD1', blueTx: '#1A5CB0', blueBg: '#E9F1FA',
    gold: '#C98A00', goldTx: '#7F5700', goldBg: '#FAF3E6',
    gray: '#9AA0A6', grayTx: '#4A4F5A', grayBg: '#F1F2F3', thanksTx: '#5F6368'
  };
  var STRONG_MIN = 0.85;   // 分數 >= 85% 才算強項
  var WEAK_LINE = 0.6;     // 星狀圖紅色虛線：60% 待加強線；表格低於 60% 標紅
  var DIFF_MIN = 10;       // 與上一季差距（百分點）>= 10 才標 ▲▼、才算進步／退步
  var TAG_COLOR = { '感謝': COLORS.thanksTx, '強項': COLORS.greenTx, '待加強': COLORS.redTx, '進步': COLORS.blueTx, '留意': COLORS.goldTx };
  var IDX = DIMS.map(function (_, i) { return i; });
  function andNames(arr) { return arr.map(function (x) { return '「' + x + '」'; }).join('和'); }
  function listNames(arr) { return arr.map(function (x) { return '「' + x + '」'; }).join('、'); }
  function byScoreAsc(scores, idxs) { return idxs.slice().sort(function (a, b) { return scores[a] - scores[b] || a - b; }); }
  function pdiff(a, b) { return pct(a) - pct(b); }
  // 小結／分析的列：{ tag: 感謝|強項|待加強|進步|留意, text, advice? }；網頁與 PDF 用色塊標籤顯示
  function itemsText(items, sep) { return items.map(function (it) { return it.text + (it.advice ? sep + it.advice : ''); }).join(''); }

  // 單季小結：優秀面向（進步或高分，最多 3 個）鼓勵；不足面向（分數最低，最多 2 個，90% 以上不算）給具體建議；不提次數、不用括號
  function quarterItems(cur, prev) {
    var cs = scoreOf(cur), ps = scoreOf(prev), out = [];
    var up = [];
    if (ps) IDX.forEach(function (i) { var d = cs[i] - ps[i]; if (d >= 0.1 - EPS) up.push({ i: i, d: d }); });
    up.sort(function (a, b) { return b.d - a.d || a.i - b.i; });
    var upIdx = up.map(function (x) { return x.i; }).slice(0, 3);
    var highIdx = IDX.filter(function (i) { return cs[i] >= GOOD - EPS && upIdx.indexOf(i) < 0; });
    highIdx.sort(function (a, b) { return cs[b] - cs[a] || a - b; });
    highIdx = highIdx.slice(0, Math.max(0, 3 - upIdx.length));
    var weak = byScoreAsc(cs, IDX.filter(function (i) { return cs[i] < GOOD - EPS; })).slice(0, 2);
    if (highIdx.length) out.push({ tag: '強項', text: '這季表現很棒，' + andNames(highIdx.map(function (i) { return DIMS[i]; })) + '都做得很穩！' });
    if (upIdx.length) out.push({ tag: '進步', text: andNames(upIdx.map(function (i) { return DIMS[i]; })) + '比上季進步很多，繼續保持！' });
    if (!weak.length) out.push({ tag: '強項', text: out.length ? '七個面向都很穩，繼續保持！' : '七個面向都很穩，表現很棒，繼續保持！' });
    else {
      if (!out.length) out.push({ tag: '感謝', text: '這季有認真在做，每一步都算數，繼續加油！' });
      weak.forEach(function (i) { out.push({ tag: '待加強', text: '「' + DIMS[i] + '」還有進步空間', advice: DIM_ADVICE[DIMS[i]] }); });
    }
    return out;
  }
  function quarterAnalysis(cur, prev) { return itemsText(quarterItems(cur, prev), '，建議：'); }

  // ---- 年度：全年強項／最弱、第四季對第三季進步與退步、折線圖重點三條 ----
  function yearInsights(qs) {
    var tot = totalModel(qs), ts = scoreOf(tot);
    if (!ts) return null;
    var sc = (qs || []).map(scoreOf);
    var mx = Math.max.apply(null, ts), mn = Math.min.apply(null, ts);
    var strong = mx >= STRONG_MIN - EPS ? IDX.filter(function (i) { return mx - ts[i] < EPS; }) : [];
    var weakest = (mn < 1 - EPS && mx - mn > EPS) ? IDX.filter(function (i) { return ts[i] - mn < EPS; }) : [];
    var diffs = null, impC = [], decC = [];
    if (sc[2] && sc[3]) {
      diffs = IDX.map(function (i) { return pdiff(sc[3][i], sc[2][i]); });
      impC = IDX.filter(function (i) { return diffs[i] >= DIFF_MIN; }).sort(function (a, b) { return diffs[b] - diffs[a] || a - b; });
      decC = IDX.filter(function (i) { return diffs[i] <= -DIFF_MIN; }).sort(function (a, b) { return diffs[a] - diffs[b] || a - b; });
    }
    var improve = impC.length ? { i: impC[0], diff: diffs[impC[0]] } : null;
    var decline = decC.length ? { i: decC[0], diff: -diffs[decC[0]] } : null;
    // 折線圖重點三條：全年最低（紅）、Q4 進步最多（藍）、Q4 退步最多（金）；同一面向不畫兩次，重複的改取次要者
    var key = [], used = [];
    function take(cands, kind, color, note) {
      for (var k = 0; k < cands.length; k++) if (used.indexOf(cands[k]) < 0) { used.push(cands[k]); key.push({ i: cands[k], kind: kind, color: color, tx: color === COLORS.red ? COLORS.redTx : color === COLORS.blue ? COLORS.blueTx : COLORS.goldTx, note: note }); return; }
    }
    if (weakest.length) take(byScoreAsc(ts, IDX), 'weak', COLORS.red, '全年最低');
    take(decC, 'decline', COLORS.gold, 'Q4 退步最多');
    take(impC, 'improve', COLORS.blue, 'Q4 進步最多');
    key.sort(function (a, b) { return ['weak', 'improve', 'decline'].indexOf(a.kind) - ['weak', 'improve', 'decline'].indexOf(b.kind); });
    return { tot: tot, ts: ts, sc: sc, strong: strong, weakest: weakest, improve: improve, decline: decline, diffs: diffs, key: key };
  }
  // 年度頁頂端 4 張摘要卡；沒有符合者 text 為 null（畫面顯示「—」）
  function yearCards(qs) {
    var ins = yearInsights(qs), n = function (i) { return DIMS[i]; };
    return [
      { kind: 'strong', title: '全年強項', text: ins && ins.strong.length ? ins.strong.map(n).join('、') + ' ' + pct(ins.ts[ins.strong[0]]) + '%' : null },
      { kind: 'weak', title: '最需要加強', text: ins && ins.weakest.length ? ins.weakest.map(n).join('、') + ' ' + pct(ins.ts[ins.weakest[0]]) + '%' : null },
      { kind: 'improve', title: 'Q4 進步最多', text: ins && ins.improve ? n(ins.improve.i) + ' ▲' + ins.improve.diff : null },
      { kind: 'decline', title: 'Q4 需要留意', text: ins && ins.decline ? n(ins.decline.i) + ' ▼' + ins.decline.diff : null }
    ];
  }
  // 星狀圖標籤強調：強項（綠，>= 85%，並列全列）、最弱（紅）；all＝全部相同時不標最弱
  function emphOf(scores, quarter) {
    var mx = Math.max.apply(null, scores), mn = Math.min.apply(null, scores), out = {};
    IDX.forEach(function (i) {
      if (mx >= STRONG_MIN - EPS && mx - scores[i] < EPS) out[i] = { color: COLORS.greenTx, dot: COLORS.green, tag: quarter ? '★ 本季強項' : '★ 全年強項' };
      else if (mn < 1 - EPS && mx - mn > EPS && scores[i] - mn < EPS) out[i] = { color: COLORS.redTx, dot: COLORS.red, tag: '▲ 最需要加強' };
    });
    return out;
  }
  // 年度分析：帶標籤的條列（感謝、強項、待加強、進步、留意）；不提次數、句子裡不用括號
  function yearItems(qs) {
    var ins = yearInsights(qs), out = [];
    if (!ins) return out;
    var have = [0, 1, 2, 3].filter(function (q) { return !!ins.sc[q]; });
    out.push({ tag: '感謝', text: '這一年辛苦了，優良回覆佔 ' + pct(1 - ins.tot.weak / ins.tot.checks) + '%，謝謝你的用心！' });
    if (ins.strong.length) out.push({ tag: '強項', text: listNames(ins.strong.map(function (i) { return DIMS[i]; })) + '全年都是 ' + pct(ins.ts[ins.strong[0]]) + '%，是你最穩定的地方，請繼續保持。' });
    if (ins.weakest.length && ins.ts[ins.weakest[0]] < GOOD - EPS) {
      var w = ins.weakest[0];
      var allLow = have.length >= 2 && have.every(function (q) { return ins.sc[q][w] - Math.min.apply(null, ins.sc[q]) < EPS; });
      out.push({ tag: '待加強', text: '「' + DIMS[w] + '」全年 ' + pct(ins.ts[w]) + '%，' + (allLow ? (have.length === 4 ? '四季都是最低。' : '每一季都是最低。') : '是全年最低。'), advice: DIM_ADVICE[DIMS[w]] });
    }
    if (ins.improve) {
      var u = ins.improve.i;
      out.push({ tag: '進步', text: '「' + DIMS[u] + '」第四季從 ' + pct(ins.sc[2][u]) + '% 進步到 ' + pct(ins.sc[3][u]) + '%，是本季進步最多的面向，很棒！', advice: '持續保持，' + DIM_ADVICE[DIMS[u]] });
    }
    if (ins.decline) {
      var d = ins.decline.i;
      out.push({ tag: '留意', text: '「' + DIMS[d] + '」第四季降到 ' + pct(ins.sc[3][d]) + '%，比第三季低 ' + ins.decline.diff + ' 個百分點，要多留意。', advice: DIM_ADVICE[DIMS[d]] });
    }
    return out;
  }
  function yearAnalysis(qs) { return yearItems(qs).map(function (it) { return it.text + (it.advice ? '建議：' + it.advice : ''); }); }
  // 全年數值表：格子底色（>= 85% 綠、< 60% 紅）與和上一季的差異（差 >= 10 才標，Q1 不標）
  function yearTableModel(qs) {
    var sc = (qs || []).map(scoreOf), ts = scoreOf(totalModel(qs)) || IDX.map(function () { return 0; });
    function bg(v) { return v >= STRONG_MIN - EPS ? 'green' : v < WEAK_LINE - EPS ? 'red' : ''; }
    return IDX.map(function (i) {
      return {
        name: DIMS[i], sub: DIM_SUB[DIMS[i]], nameRed: ts[i] < WEAK_LINE - EPS,
        cells: [0, 1, 2, 3].map(function (q) {
          if (!sc[q]) return { has: false };
          var diff = null;
          if (q > 0 && sc[q - 1]) { var dd = pdiff(sc[q][i], sc[q - 1][i]); if (Math.abs(dd) >= DIFF_MIN) diff = { dir: dd > 0 ? 'up' : 'down', n: Math.abs(dd) }; }
          return { has: true, pct: pct(sc[q][i]), bg: bg(sc[q][i]), diff: diff };
        }),
        total: { pct: pct(ts[i]), bg: ts[i] < WEAK_LINE - EPS ? 'red' : '' }
      };
    });
  }

  // 七條線同一張折線圖：橫軸 Q1~Q4；預設「重點三條」彩色（全年最低紅、Q4 進步最多藍、Q4 退步最多金），其餘灰色細線。
  var DIM_COLORS = ['#0072B2', '#E69F00', '#D55E00', '#009E73', '#7B3FA0', '#CC79A7', '#333333'];
  var DIM_DASH = ['', '9 5', '', '3 4', '', '11 4 3 4', ''];
  function markerSvg(i, x, y, r, color) {
    var c = color || DIM_COLORS[i], st = 'fill="' + c + '" stroke="#fff" stroke-width="1.5"';
    function P(pts) { return '<polygon points="' + pts.map(function (p) { return (x + p[0] * r).toFixed(1) + ',' + (y + p[1] * r).toFixed(1); }).join(' ') + '" ' + st + '/>'; }
    switch (i) {
      case 0: return '<circle cx="' + x + '" cy="' + y + '" r="' + r + '" ' + st + '/>';
      case 1: return '<rect x="' + (x - r * 0.9) + '" y="' + (y - r * 0.9) + '" width="' + (r * 1.8) + '" height="' + (r * 1.8) + '" ' + st + '/>';
      case 2: return P([[0, -1.15], [1.05, 0.85], [-1.05, 0.85]]);
      case 3: return P([[0, -1.3], [1.15, 0], [0, 1.3], [-1.15, 0]]);
      case 4: return P([[0, 1.15], [1.05, -0.85], [-1.05, -0.85]]);
      case 5: return '<path d="M' + (x - r) + ' ' + (y - r) + 'L' + (x + r) + ' ' + (y + r) + 'M' + (x + r) + ' ' + (y - r) + 'L' + (x - r) + ' ' + (y + r) + '" stroke="' + c + '" stroke-width="3.2" stroke-linecap="round" fill="none"/>';
      default:
        var pts = [];
        for (var k = 0; k < 10; k++) { var a = -Math.PI / 2 + k * Math.PI / 5, rr = k % 2 ? 0.5 : 1.3; pts.push([rr * Math.cos(a), rr * Math.sin(a)]); }
        return P(pts);
    }
  }
  // mode：預設（不給）＝「重點三條」彩色、其餘四條灰色細線；給面向索引＝只畫那一條（該面向自己的顏色）
  function lineChartSvg(qs, mode) {
    var W = 780, H = 520, L = 66, Rt = 270, T = 40, B = 50, pw = W - L - Rt, ph = H - T - B;
    var sc = qs.map(scoreOf), all = [];
    sc.forEach(function (s) { if (s) all = all.concat(s); });
    var mn = all.length ? Math.min.apply(null, all) : 0;
    var r0 = 1 - (mn - 0.05), step = r0 > 0.7 ? 0.2 : 0.1, lo = Math.max(0, 1 - Math.ceil(r0 / step - EPS) * step);   // 下限剛好落在刻度上
    function X(k) { return L + 24 + (pw - 48) * k / 3; }
    function Y(v) { return T + ph * (1 - (v - lo) / (1 - lo)); }
    var single = typeof mode === 'number';
    var ins = yearInsights(qs), keyOf = {};
    if (!single && ins) ins.key.forEach(function (k) { keyOf[k.i] = k; });
    var s = '<text x="' + L + '" y="18" font-size="17" font-weight="700" fill="#4A4F5A">縱軸 ' + pct(lo) + '%~100%（不是從 0 開始）</text>';
    for (var v = 1; v > lo - EPS; v -= step) {
      s += '<line x1="' + L + '" x2="' + (L + pw) + '" y1="' + Y(v).toFixed(1) + '" y2="' + Y(v).toFixed(1) + '" stroke="' + (v >= 1 - EPS ? '#8F99A8' : '#E3E7ED') + '"/>' +
        '<text x="' + (L - 8) + '" y="' + (Y(v) + 5).toFixed(1) + '" text-anchor="end" font-size="18" fill="#4A4F5A">' + pct(v) + '%</text>';
    }
    s += '<line x1="' + L + '" x2="' + (L + pw) + '" y1="' + (T + ph) + '" y2="' + (T + ph) + '" stroke="#8F99A8"/>';
    for (var k = 0; k < 4; k++) s += '<text x="' + X(k) + '" y="' + (H - 14) + '" text-anchor="middle" font-size="20" font-weight="800" fill="' + (sc[k] ? '#111' : '#94A3B8') + '">Q' + (k + 1) + (sc[k] ? '' : '（無）') + '</text>';
    // 線尾標籤位置：由上往下排，相鄰至少隔 24，再整體往上推回圖內（保留引線）
    var drawn = IDX.filter(function (i) { return !single || i === mode; });
    var ends = [];
    drawn.forEach(function (i) {
      var last = -1;
      for (var q = 0; q < 4; q++) if (sc[q]) last = q;
      if (last >= 0) ends.push({ i: i, x: X(last), y: Y(sc[last][i]), ly: Y(sc[last][i]), v: sc[last][i] });
    });
    ends.sort(function (a, b) { return a.y - b.y || a.i - b.i; });
    for (var j = 1; j < ends.length; j++) if (ends[j].ly - ends[j - 1].ly < 24) ends[j].ly = ends[j - 1].ly + 24;
    var over = ends.length ? ends[ends.length - 1].ly - (T + ph) : 0;
    if (over > 0) ends.forEach(function (e) { e.ly -= over; });
    var endOf = {};
    ends.forEach(function (e) { endOf[e.i] = e; });
    function dimGroup(i) {
      var key = keyOf[i], c = single ? DIM_COLORS[i] : key ? key.color : COLORS.gray, tx = single ? DIM_COLORS[i] : key ? key.tx : '#6B7280';
      var hot = single || !!key, w = hot ? 3.2 : 2, dash = single && DIM_DASH[i] ? ' stroke-dasharray="' + DIM_DASH[i] + '"' : '', g = '';
      for (var a = 0; a < 3; a++) if (sc[a] && sc[a + 1]) {
        g += '<line x1="' + X(a).toFixed(1) + '" y1="' + Y(sc[a][i]).toFixed(1) + '" x2="' + X(a + 1).toFixed(1) + '" y2="' + Y(sc[a + 1][i]).toFixed(1) + '" stroke="' + c + '" stroke-width="' + w + '" stroke-linecap="round"' + dash + '/>';
      }
      for (var b = 0; b < 4; b++) if (sc[b]) g += hot ? markerSvg(i, +X(b).toFixed(1), +Y(sc[b][i]).toFixed(1), 6.5, c) : '<circle cx="' + X(b).toFixed(1) + '" cy="' + Y(sc[b][i]).toFixed(1) + '" r="4" fill="' + c + '"/>';
      var e = endOf[i];
      if (e) g += '<line x1="' + (e.x + 9) + '" y1="' + e.y.toFixed(1) + '" x2="' + (e.x + 22) + '" y2="' + e.ly.toFixed(1) + '" stroke="' + c + '" stroke-width="1.2"/>' +
        '<text x="' + (e.x + 26) + '" y="' + (e.ly + 5).toFixed(1) + '" font-size="' + (hot ? 17 : 16) + '" font-weight="' + (hot ? 800 : 500) + '" fill="' + tx + '">' + esc(DIMS[i] + ' ' + pct(e.v) + '%' + (key ? '（' + key.note + '）' : '')) + '</text>';
      return '<g>' + g + '</g>';
    }
    // 灰線先畫、重點線疊在上面
    var grp = drawn.filter(function (i) { return !keyOf[i]; }).map(dimGroup).join('') + drawn.filter(function (i) { return keyOf[i]; }).map(dimGroup).join('');
    return { width: W, height: H, lo: lo, key: ins ? ins.key : [], svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '" role="img" aria-label="全年四季七面向分數折線圖，縱軸 ' + pct(lo) + '% 到 100%，越高越好" style="font-family:Microsoft JhengHei,PingFang TC,Noto Sans TC,sans-serif">' + s + grp + '</svg>' };
  }

  // ---- 登記截圖卡片（季度健檢單的「登記紀錄與截圖」；版面照 樣品/登記截圖卡片公版樣品.html 風格 D1 淺灰）----
  // 每張卡片＝一筆登記的一張截圖；一筆有多張截圖時，第 2、3 張接著做續卡（日期旁標 (2/3)），日期、判定、面向、說明都重複。
  // 沒有截圖的登記：一張沒有截圖框的小卡。顏色集中在這裡（改色只改這一處）。
  var CARD = {
    bg: '#ECEEF1', ok: '#10B981', bad: '#EF4444', mute: '#5B6270', noteTx: '#222222', noteBg: '#FFFFFF', nlBg: '#E6E9ED', shotEdge: '#AEB5C0',
    wkTx: '#4A4F5A', seqBg: '#D9FF00', seqTx: '#111111', capBg: 'rgba(255,255,255,.82)', capTx: '#333333',
    // 七大面向膠囊（依面向順序）：柔和底色＋深色字
    dim: [{ bg: '#DCEBFF', tx: '#0A4FB0' }, { bg: '#D3F2EC', tx: '#0B6B5E' }, { bg: '#E9E0FF', tx: '#5B34B0' }, { bg: '#F0FBB0', tx: '#4E5A00' },
      { bg: '#FFDCD6', tx: '#B0301F' }, { bg: '#FFE8C7', tx: '#9A5200' }, { bg: '#DDE2EA', tx: '#2E3542' }]
  };
  var CARD_H = 470, CARD_GAP = 10;         // 有截圖的卡片固定高度（一頁放 2 張）與卡片間距
  var NOTE_MAX = 72;                       // 說明最多約 2 行，超過截成「…」（html2canvas 不支援 line-clamp，所以用字數截）
  var WK = ['日', '一', '二', '三', '四', '五', '六'];
  function clampNote(t, max) {
    t = String(t == null ? '' : t).replace(/\s+/g, ' ').replace(/^ | $/g, '');
    max = max || NOTE_MAX;
    return t.length > max ? t.slice(0, max) + '…' : t;
  }
  // 'YYYY-MM-DD' -> { md: '11/13', wk: '（五）', text: '11/13（五）' }；星期依實際曆法算
  function cardDate(ymdStr) {
    var p = String(ymdStr || '').split('-'), y = +p[0], mo = +p[1], d = +p[2];
    if (!(y > 0 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31)) return { md: String(ymdStr || ''), wk: '', text: String(ymdStr || '') };
    var wk = '（' + WK[new Date(Date.UTC(y, mo - 1, d)).getUTCDay()] + '）', md = mo + '/' + d;
    return { md: md, wk: wk, text: md + wk };
  }
  // records＝buildModel 的 m.records；回傳卡片陣列（依登記日期順序，每筆的截圖依序）
  function buildCards(records) {
    var out = [];
    (records || []).forEach(function (r) {
      var dt = cardDate(r.date), shots = r.shots || [], n = shots.length;
      var base = {
        recId: r.id, md: dt.md, wk: dt.wk, dateText: dt.text, verdict: r.verdict, isWeak: !!r.isWeak,
        dimIdx: (r.dims || []).map(function (d) { return DIMS.indexOf(d); }).filter(function (i) { return i >= 0; }), dims: (r.dims || []).slice(),
        note: clampNote(r.note), noteCut: String(r.note == null ? '' : r.note).replace(/\s+/g, ' ').replace(/^ | $/g, '').length > NOTE_MAX,
        legacy: r.legacy == null ? null : r.legacy
      };
      function mk(extra) { var c = {}; Object.keys(base).forEach(function (k) { c[k] = base[k]; }); Object.keys(extra).forEach(function (k) { c[k] = extra[k]; }); return c; }
      if (!n) out.push(mk({ shot: null, hasShot: false, k: 0, n: 0, seq: '', cap: '' }));
      else shots.forEach(function (p, k) {
        out.push(mk({ shot: p, hasShot: true, k: k, n: n, seq: n > 1 ? '(' + (k + 1) + '/' + n + ')' : '', cap: n > 1 ? '截圖 ' + (k + 1) + '/' + n : '截圖' }));
      });
    });
    return out;
  }
  // 卡片高度：有截圖＝固定 CARD_H；沒截圖＝依內容估算（略為高估，頁面才不會超出）
  function cardHeight(c) {
    if (c.hasShot) return CARD_H;
    var h = 57 + 24;
    if (c.dimIdx.length) h += 35;
    if (c.note) h += c.note.length > 36 ? 67 : 45;
    if (c.legacy != null) h += 26;
    return h + 6;
  }
  // 分頁：依高度由上往下放，放不下就換頁（一張卡片不會被切成兩半）；有截圖的卡一頁剛好 2 張。
  // o：{ pageH: 一頁可用高度, firstOffset: 第一頁要扣掉的高度（標題）, footH: 最後要留給頁尾的高度 }；回傳 [[卡片…], …]
  function paginateCards(cards, o) {
    o = o || {};
    var pageH = o.pageH || 1045, first = o.firstOffset || 0, foot = o.footH || 0, pages = [], cur = [], used = 0, avail = pageH - first;
    (cards || []).forEach(function (c) {
      var h = cardHeight(c) + CARD_GAP;
      if (cur.length && used + h > avail) { pages.push(cur); cur = []; used = 0; avail = pageH; }
      cur.push(c); used += h;
    });
    if (cur.length) {
      if (cur.length > 1 && used + foot > avail) {   // 最後一頁放不下頁尾：最後一張移到下一頁，頁尾才不會單獨成頁
        var last = cur.pop(); pages.push(cur); cur = [last];
      }
      pages.push(cur);
    }
    return pages;
  }

  var api = {
    quarterRange: quarterRange, quarterLabel: quarterLabel, dimCounts: dimCounts, topDims: topDims,
    summarize: summarize, filterByStore: filterByStore, buildModel: buildModel, fileName: fileName, fileNameYear: fileNameYear, buildCards: buildCards, paginateCards: paginateCards, cardHeight: cardHeight, cardDate: cardDate, clampNote: clampNote, CARD: CARD, CARD_H: CARD_H, CARD_GAP: CARD_GAP, NOTE_MAX: NOTE_MAX, yearRange: yearRange,
    quarterModel: quarterModel, sumModel: sumModel, prevQuarterOf: prevQuarterOf, modelFromRows: modelFromRows, contextRange: contextRange, DIMS: DIMS, scoreOf: scoreOf, totalModel: totalModel,
    radarSvg: radarSvg, quarterCompareSvg: quarterCompareSvg, totalSvg: totalSvg, lineChartSvg: lineChartSvg, markerSvg: markerSvg,
    quarterAnalysis: quarterAnalysis, yearAnalysis: yearAnalysis, quarterItems: quarterItems, yearItems: yearItems, yearInsights: yearInsights, yearCards: yearCards, yearTableModel: yearTableModel, emphOf: emphOf, COLORS: COLORS, TAG_COLOR: TAG_COLOR, STRONG_MIN: STRONG_MIN, WEAK_LINE: WEAK_LINE, DIFF_MIN: DIFF_MIN, DIM_ADVICE: DIM_ADVICE, DIM_SUBTITLE: DIM_SUB, DIM_COLORS: DIM_COLORS, DIM_DASH: DIM_DASH, Q_NAMES: Q_NAMES, pct: pct
  };
  if (isNode) module.exports = api;
  else root.CheckupSheetCore = api;
})(typeof window !== 'undefined' ? window : this);
