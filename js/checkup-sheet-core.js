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
 *   CheckupSheetCore.totalSvg(qs, R) 全年總合星狀圖（qs＝[Q1..Q4 model 或 null]）；fitYearChart(qs) 依第 1 頁剩餘高度挑最大半徑
 *   CheckupSheetCore.yearTableModel(qs) / sparkRange(matrix) / sparkSvg(scores, range)  年度第 2 頁總表與迷你折線
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
  //      emph: { 面向索引: { color, dot, tag } }, tagMode: 'replace'（標籤取代副標）| 'append'（接在副標下）, subSingle: 副標單行截斷 }
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
  function quarterCompareSvg(cur, prev, R) {
    var p = scoreOf(prev), em = emphOf(scoreOf(cur), true);
    return radarSvg([
      p ? { scores: p, color: '#0669EB', fill: 'rgba(6,105,235,.05)', width: 2.2, dash: '8 5' } : null,
      { scores: scoreOf(cur), color: CUR.color, fill: CUR.fill, width: CUR.width, dots: true, dotColors: dotColorsOf(em) }
    ], { labelIdx: 1, emph: em, tagMode: 'append', R: R || 130 });   // R：星狀圖半徑（預設 130；第 1 頁由 fitQuarterChart 依剩餘高度挑最大的）
  }
  function totalSvg(qs, R) {
    var ts = scoreOf(totalModel(qs)), em = ts ? emphOf(ts) : {};
    return radarSvg([{ scores: ts, color: COLORS.blue, fill: 'rgba(31,111,209,.12)', width: 2.5, dots: true, dotColors: dotColorsOf(em) }],
      { labelIdx: 0, R: R || 160, fs: 18, emph: em, tagMode: 'replace', subSingle: true });
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
  var WEAK_LINE = 0.6;     // 全年數值表：低於 60% 標紅底（星狀圖上沒有 60% 虛線）
  var DIFF_MIN = 10;       // 與上一季差距（百分點）>= 10 才標 ▲▼、才算進步／退步
  var TAG_COLOR = { '感謝': COLORS.thanksTx, '強項': COLORS.greenTx, '待加強': COLORS.redTx, '進步': COLORS.blueTx, '留意': COLORS.goldTx };
  var IDX = DIMS.map(function (_, i) { return i; });
  function andNames(arr) { return arr.map(function (x) { return '「' + x + '」'; }).join('和'); }
  function listNames(arr) { return arr.map(function (x) { return '「' + x + '」'; }).join('、'); }
  function byScoreAsc(scores, idxs) { return idxs.slice().sort(function (a, b) { return scores[a] - scores[b] || a - b; }); }
  function pdiff(a, b) { return pct(a) - pct(b); }
  // 小結／分析的列：{ tag: 感謝|強項|待加強|進步|留意, text, advice? }；網頁與 PDF 用色塊標籤顯示
  function itemsText(items, sep) { return items.map(function (it) { return it.text + (it.advice ? sep + it.advice : ''); }).join(''); }

  // ---- 第 1 頁版面預算：第 1 頁固定＝頁首＋摘要卡＋星狀圖＋本季小結；登記卡片從第 2 頁開始 ----
  // 小結最多 SUMMARY_MAX_ROWS 列（優先序：強項、待加強、進步、留意；超出者捨棄後面的）；每列＝一行文字，需建議的多一行建議句
  var SUMMARY_MAX_ROWS = 5, SUMMARY_ROW_H = 29, SUMMARY_ADV_H = 17, SUMMARY_FIXED_H = 54;   // 單位 px（A4 794 寬版面）；FIXED＝小標題＋外框上下內距＋區塊內距
  var QCHART_W = 714;                      // 單季星狀圖顯示寬度＝頁面內容欄全寬
  var PAGE1 = { content: 1045, head: 92, stats: 50, chartExtra: 104, safety: 10 };   // 第 1 頁可用高度、頁首、摘要卡、圖的標題＋圖例＋說明列所佔高度
  var ITEM_RANK = { '強項': 0, '待加強': 1, '進步': 2, '留意': 3, '感謝': 4 };
  function capItems(items) {
    if (items.length <= SUMMARY_MAX_ROWS) return items;
    var keep = items.map(function (it, i) { return { i: i, r: ITEM_RANK[it.tag] == null ? 9 : ITEM_RANK[it.tag] }; })
      .sort(function (a, b) { return a.r - b.r || a.i - b.i; }).slice(0, SUMMARY_MAX_ROWS).map(function (x) { return x.i; });
    return items.filter(function (_, i) { return keep.indexOf(i) >= 0; });
  }
  function summaryHeight(items) { return SUMMARY_FIXED_H + (items || []).reduce(function (a, it) { return a + SUMMARY_ROW_H + (it.advice ? SUMMARY_ADV_H : 0); }, 0); }
  function chartHeight(L) { return Math.round(L.height * QCHART_W / L.width); }   // 單季星狀圖實際顯示高度
  function summaryBudget(chartH) { return PAGE1.content - PAGE1.head - PAGE1.stats - PAGE1.chartExtra - chartH - PAGE1.safety; }   // 第 1 頁留給小結的高度
  // 最壞小結：單季最多 4 列（強項、進步不帶建議，待加強 2 列各帶最長建議）
  function worstSummaryItems() {
    var longest = Object.keys(DIM_ADVICE).reduce(function (a, k) { return DIM_ADVICE[k].length > a.length ? DIM_ADVICE[k] : a; }, '');
    return [{ tag: '強項', text: 'x' }, { tag: '進步', text: 'x' }, { tag: '待加強', text: 'x', advice: longest }, { tag: '待加強', text: 'x', advice: longest }];
  }
  // 以最壞小結為預算，剩下的高度全給星狀圖：寬度撐滿內容欄，半徑挑「放得進去的最大值」（回傳 { R, width, height, L }）
  function quarterChartMaxH() { return summaryBudget(0) - summaryHeight(worstSummaryItems()); }
  function fitQuarterChart(cur, prev) {
    var maxH = quarterChartMaxH(), L;
    for (var R = 210; R >= 100; R -= 2) {
      L = quarterCompareSvg(cur, prev, R);
      var h = L.height * QCHART_W / L.width;
      if (h <= maxH) return { R: R, width: QCHART_W, height: Math.round(h), L: L };
    }
    L = quarterCompareSvg(cur, prev, 100);
    return { R: 100, width: Math.floor(maxH * L.width / L.height), height: maxH, L: L };   // 極端情況：連半徑 100 都放不下，就縮小顯示寬度
  }

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
    return capItems(out);
  }
  function quarterAnalysis(cur, prev) { return itemsText(quarterItems(cur, prev), '，建議：'); }

  // ---- 年度：全年強項／最弱、第四季對第三季進步與退步 ----
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
    return { tot: tot, ts: ts, sc: sc, strong: strong, weakest: weakest, improve: improve, decline: decline, diffs: diffs };
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
    var ins = yearInsights(qs), strongL = ins ? ins.strong : [], weakL = ins ? ins.weakest : [];
    var weakIdx = weakL.length ? weakL.slice().sort(function (x, y) { return ts[x] - ts[y] || x - y; })[0] : -1;
    function bg(v) { return v >= STRONG_MIN - EPS ? 'green' : v < WEAK_LINE - EPS ? 'red' : ''; }
    return IDX.map(function (i) {
      return {
        name: DIMS[i], sub: DIM_SUB[DIMS[i]], nameRed: ts[i] < WEAK_LINE - EPS,
        nameCls: i === weakIdx || (weakL.indexOf(i) >= 0 && ts[i] < WEAK_LINE - EPS) ? 'rn' : (strongL.indexOf(i) >= 0 ? 'gn' : ''),   // 全年最低紅字、全年強項綠字
        tags: [].concat(
          i === weakIdx ? [{ t: '全年最低', bg: COLORS.redBg, tx: COLORS.redTx }] : [],
          ins && ins.improve && ins.improve.i === i ? [{ t: 'Q4 進步最多', bg: COLORS.blueBg, tx: COLORS.blueTx }] : [],
          ins && ins.decline && ins.decline.i === i ? [{ t: 'Q4 退步最多', bg: COLORS.goldBg, tx: COLORS.goldTx }] : [],
          strongL.indexOf(i) >= 0 ? [{ t: '全年強項', bg: COLORS.greenBg, tx: COLORS.greenTx }] : []),
        scores: [0, 1, 2, 3].map(function (q) { return sc[q] ? sc[q][i] : null; }),
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

  // ---- 年度健檢單固定兩頁：第 1 頁＝頁首＋摘要卡＋全年綜合星狀圖＋年度分析；第 2 頁＝各面向四季變化總表（含迷你折線）----
  // 迷你折線共用刻度：預設 40%~100%；有任何分數低於 40% 才把下限往下延伸到 10% 的整數（缺資料的季略過）
  function sparkRange(matrix) {
    var all = [].concat.apply([], (matrix || []).filter(Boolean)), lo = 0.4;
    if (all.length) { var m = Math.min.apply(null, all); if (m < 0.4 - EPS) lo = Math.floor(m * 10 + EPS) / 10; }
    return { min: lo, max: 1 };
  }
  // 一個面向的迷你折線（四季分數 scores＝[Q1..Q4，缺資料為 null]；range 全表共用）：寬 190、高 66、線寬 2.5、端點 3.5、Q4 點 5.5，Q1 與 Q4 旁標分數；缺資料季不畫點、線斷開
  var SPARK = { w: 190, h: 66, pxl: 42, pxr: 38, pyt: 19, pyb: 6 };
  function sparkSvg(scores, range) {
    var SW = SPARK.w, SH = SPARK.h, lo = range.min, hi = range.max;
    function sx(k) { return SPARK.pxl + (SW - SPARK.pxl - SPARK.pxr) * k / 3; }
    function sy(v) { return SPARK.pyt + (SH - SPARK.pyt - SPARK.pyb) * (1 - (v - lo) / (hi - lo)); }
    var s = '<svg xmlns="http://www.w3.org/2000/svg" width="' + SW + '" height="' + SH + '" viewBox="0 0 ' + SW + ' ' + SH + '" style="overflow:visible;font-family:Microsoft JhengHei,PingFang TC,Noto Sans TC,sans-serif">';
    var mid = sy((lo + hi) / 2).toFixed(1);
    s += '<line x1="' + sx(0).toFixed(1) + '" x2="' + sx(3).toFixed(1) + '" y1="' + mid + '" y2="' + mid + '" stroke="#F0F2F5" stroke-width="1"/>';
    for (var a = 0; a < 3; a++) if (scores[a] != null && scores[a + 1] != null) s += '<line x1="' + sx(a).toFixed(1) + '" y1="' + sy(scores[a]).toFixed(1) + '" x2="' + sx(a + 1).toFixed(1) + '" y2="' + sy(scores[a + 1]).toFixed(1) + '" stroke="' + COLORS.blue + '" stroke-width="2.5" stroke-linecap="round"/>';
    for (var b = 0; b < 4; b++) if (scores[b] != null) s += '<circle cx="' + sx(b).toFixed(1) + '" cy="' + sy(scores[b]).toFixed(1) + '" r="' + (b === 3 ? 5.5 : 3.5) + '" fill="' + COLORS.blue + '"/>';
    if (scores[0] != null) s += '<text x="' + (sx(0) - 6).toFixed(1) + '" y="' + (sy(scores[0]) - 6).toFixed(1) + '" text-anchor="end" font-size="12" fill="#6B7280">' + pct(scores[0]) + '%</text>';
    if (scores[3] != null) s += '<text x="' + (sx(3) + 7).toFixed(1) + '" y="' + (sy(scores[3]) - 7).toFixed(1) + '" text-anchor="start" font-size="12" fill="#6B7280">' + pct(scores[3]) + '%</text>';
    return s + '</svg>';
  }
  // 第 1 頁高度預算（px，A4 794 寬版面）：全年綜合星狀圖的半徑「放得進去的最大值」，最小半徑底線 150（真的放不下才到 140）
  var YEAR1 = { content: 1045, head: 92, cards: 92, chartTitle: 40, analysisFixed: 58, safety: 10, maxW: 754, minR: 150, floorR: 140 };
  function yearRowHeight(it) { return 30 + (it.text.length > 40 ? 20 : 0) + (it.advice ? 19 + (('建議：' + it.advice).length > 46 ? 16 : 0) : 0); }
  function yearItemsHeight(items) { return YEAR1.analysisFixed + (items || []).reduce(function (a, it) { return a + yearRowHeight(it); }, 0); }
  function yearChartMaxH(items) { return YEAR1.content - YEAR1.head - YEAR1.cards - YEAR1.chartTitle - yearItemsHeight(items) - YEAR1.safety; }
  function fitYearChart(qs) {
    var maxH = yearChartMaxH(yearItems(qs)), W = YEAR1.maxW, L, R;
    for (R = 260; R >= YEAR1.floorR; R -= 2) {
      L = totalSvg(qs, R);
      if (L.width <= W && L.height <= maxH) return { R: R, L: L, width: L.width, height: L.height, maxH: maxH };
    }
    L = totalSvg(qs, YEAR1.floorR);   // 極端情況：連 140 都放不下，只縮小顯示尺寸
    var k = Math.min(W / L.width, maxH / L.height, 1);
    return { R: YEAR1.floorR, L: L, width: Math.round(L.width * k), height: Math.round(L.height * k), maxH: maxH };
  }

  // ---- 登記截圖卡片（季度健檢單的「登記紀錄與截圖」；版面照 樣品/登記截圖卡片公版樣品.html 風格 D1 淺灰）----
  // 每張卡片＝一筆登記的一張截圖；一筆有多張截圖時，第 2、3 張接著做續卡（日期旁標 (2/3)），日期、判定、面向、說明都重複。
  // 沒有截圖的登記：一張沒有截圖框的小卡。顏色集中在這裡（改色只改這一處）。
  var CARD = {
    bg: '#FAFBFC', line: '#E8EAEE', edge: '#DDE0E5', ok: '#10B981', bad: '#EF4444', mute: '#5B6270', noteTx: '#222222', noteBg: '#FFFFFF', nlBg: '#E6E9ED', shotEdge: '#AEB5C0',
    wkTx: '#4A4F5A', seqBg: '#D9FF00', seqTx: '#111111', capBg: 'rgba(255,255,255,.82)', capTx: '#333333',
    // 七大面向膠囊（依面向順序）：柔和底色＋深色字
    dim: [{ bg: '#DCEBFF', tx: '#0A4FB0' }, { bg: '#D3F2EC', tx: '#0B6B5E' }, { bg: '#E9E0FF', tx: '#5B34B0' }, { bg: '#F0FBB0', tx: '#4E5A00' },
      { bg: '#FFDCD6', tx: '#B0301F' }, { bg: '#FFE8C7', tx: '#9A5200' }, { bg: '#DDE2EA', tx: '#2E3542' }]
  };
  var CARD_H = 470, CARD_GAP = 10;         // 有截圖的卡片固定高度（一頁放 2 張）與卡片間距
  var NOTE_MAX = 72;                       // 說明最多約 2 行，超過截成「…」（html2canvas 不支援 line-clamp，所以用字數截）
  // 小結之後的「往下滑看本季登記詳細紀錄」提醒：有卡片頁、且第一頁小結之後剩餘空白高度大於門檻才顯示
  var HINT_MIN_GAP = 260, HINT_TEXT = '往下滑看本季登記詳細紀錄';
  function showScrollHint(gapPx, cardCount) { return Number(cardCount) > 0 && Number(gapPx) > HINT_MIN_GAP; }
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
        note: clampNote(r.note), noteCut: String(r.note == null ? '' : r.note).replace(/\s+/g, ' ').replace(/^ | $/g, '').length > NOTE_MAX
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
    summarize: summarize, filterByStore: filterByStore, buildModel: buildModel, fileName: fileName, fileNameYear: fileNameYear, buildCards: buildCards, capItems: capItems, fitQuarterChart: fitQuarterChart, quarterChartMaxH: quarterChartMaxH, worstSummaryItems: worstSummaryItems, summaryHeight: summaryHeight, summaryBudget: summaryBudget, chartHeight: chartHeight, SUMMARY_MAX_ROWS: SUMMARY_MAX_ROWS, QCHART_W: QCHART_W, PAGE1: PAGE1, showScrollHint: showScrollHint, HINT_MIN_GAP: HINT_MIN_GAP, HINT_TEXT: HINT_TEXT, paginateCards: paginateCards, cardHeight: cardHeight, cardDate: cardDate, clampNote: clampNote, CARD: CARD, CARD_H: CARD_H, CARD_GAP: CARD_GAP, NOTE_MAX: NOTE_MAX, yearRange: yearRange,
    quarterModel: quarterModel, sumModel: sumModel, prevQuarterOf: prevQuarterOf, modelFromRows: modelFromRows, contextRange: contextRange, DIMS: DIMS, scoreOf: scoreOf, totalModel: totalModel,
    radarSvg: radarSvg, quarterCompareSvg: quarterCompareSvg, totalSvg: totalSvg, sparkRange: sparkRange, sparkSvg: sparkSvg, SPARK: SPARK, fitYearChart: fitYearChart, yearItemsHeight: yearItemsHeight, yearChartMaxH: yearChartMaxH, YEAR1: YEAR1,
    quarterAnalysis: quarterAnalysis, yearAnalysis: yearAnalysis, quarterItems: quarterItems, yearItems: yearItems, yearInsights: yearInsights, yearCards: yearCards, yearTableModel: yearTableModel, emphOf: emphOf, COLORS: COLORS, TAG_COLOR: TAG_COLOR, STRONG_MIN: STRONG_MIN, WEAK_LINE: WEAK_LINE, DIFF_MIN: DIFF_MIN, DIM_ADVICE: DIM_ADVICE, DIM_SUBTITLE: DIM_SUB, Q_NAMES: Q_NAMES, pct: pct
  };
  if (isNode) module.exports = api;
  else root.CheckupSheetCore = api;
})(typeof window !== 'undefined' ? window : this);
