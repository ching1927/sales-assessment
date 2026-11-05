/*
 * 成績單 PDF 的純邏輯（不連資料庫、不碰畫面、不連網）。規格見 FEATURES.md「成績單 PDF 下載」。
 * 瀏覽器：window.ReportPdfCore；Node：module.exports。依賴 scoring.js（Scoring）。
 *
 * 用法：
 *   ReportPdfCore.taipeiToday(nowMs)             台北今天 'YYYY-MM-DD'
 *   ReportPdfCore.taipeiDate(iso)                ISO 時間 -> 台北日期；無法解析回 ''
 *   ReportPdfCore.eligibleAssessments(rows)      該考生全部考核列 -> 只留「已送出、未作廢」，由舊到新（同時間依 id）
 *                                                -> [{ id, ts, date, total, verdict, tenure }]
 *   ReportPdfCore.dimRates(items)                題組 -> 七面向得分率（加考題不計入；與 Scoring.scoreAssessment 同一套算法）
 *                                                -> { ok, rows:[{name, pct}] } 或 { ok:false, error }
 *   ReportPdfCore.compare(cur, prev, curTotal, prevTotal)  與上一次比較（沒有 prev 回 null）
 *                                                -> { totalDiff, rows:[{name, cur, prev, diff}], best, worst }
 *                                                   best／worst = { names:[...], value } 或 null（沒有進步／退步面向）
 *   ReportPdfCore.trendSeries(list, currentId)   歷次走勢（全部歷次）-> { points:[...], curIdx }
 *   ReportPdfCore.itemRows(items, opts)          每題得分列；opts.showTitle 為 false（非客服部）時完全不帶題名
 *   ReportPdfCore.buildReport(input)             把資料整理成 PDF 要畫的內容 -> { ok, model } 或 { ok:false, error }
  *   ReportPdfCore.layoutPages(blocks, contentH)  分頁分配：以區塊／表格列為單位，不切半；換頁處重印表頭；算各頁剩餘高度分配
 *   ReportPdfCore.trendLabelLayout(o)            走勢圖標籤避讓（合格線文字與資料點標籤互相、與折線、資料點都不重疊）-> { lines, points }
 *
 * 等級：優 100%、良 70%、待加強 40%、不及格 0%（見 scoring.js）。差異一律以「十分位整數」比較，避免浮點誤差。
 */
(function (root) {
  var Scoring = (typeof module !== 'undefined' && module.exports) ? require('./scoring.js') : root.Scoring;
  var DIMS = Scoring.DIMENSIONS;
  var TZ_MS = 8 * 3600000;   // 台北固定 UTC+8

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function dateOfMs(ms) {
    var d = new Date(ms + TZ_MS);
    return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
  }
  function taipeiToday(nowMs) { return dateOfMs(typeof nowMs === 'number' ? nowMs : Date.now()); }
  function taipeiDate(iso) {
    var t = Date.parse(iso);
    return isNaN(t) ? '' : dateOfMs(t);
  }
  function tenth(x) { return Math.round(Number(x) * 10); }
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  // 已送出且未作廢的考核，由舊到新
  function eligibleAssessments(rows) {
    var out = [];
    (rows || []).forEach(function (r) {
      if (!r || r.status !== 'submitted' || r.voided_at) return;
      if (r.total_score == null) return;
      var iso = r.submitted_at || r.created_at, ts = Date.parse(iso);
      if (isNaN(ts)) return;
      out.push({ id: r.id, ts: ts, date: taipeiDate(iso), total: Number(r.total_score), verdict: r.verdict || '', tenure: r.tenure || '' });
    });
    out.sort(function (a, b) { return a.ts - b.ts || cmp(a.id, b.id); });
    return out;
  }

  // 七面向得分率：只用核心題組（加考題不計入），完全交給 Scoring.scoreAssessment
  function dimRates(items) {
    var core = (items || []).filter(function (it) { return !it.isExtra; });
    if (!core.length) return { ok: false, error: '這張成績單沒有可計分的題組。' };
    var res = Scoring.scoreAssessment(core.map(function (it) { return it.levels || {}; }), '正式');
    if (!res.ok) return { ok: false, error: '成績單的評分資料不完整，無法計算面向得分率。' };
    return { ok: true, rows: DIMS.map(function (d) { return { name: d.name, pct: res.dimAverages[d.name] }; }) };
  }

  function extremes(rows, sign) {
    // sign=1 找進步最多（diff 最大且 > 0）；sign=-1 找退步最多（diff 最小且 < 0）。以十分位整數比較。
    var vals = rows.map(function (r) { return r.t; });
    var v = sign > 0 ? Math.max.apply(null, vals) : Math.min.apply(null, vals);
    if (sign > 0 ? v <= 0 : v >= 0) return null;
    return { names: rows.filter(function (r) { return r.t === v; }).map(function (r) { return r.name; }), value: Math.abs(v) / 10 };
  }
  function compare(cur, prev, curTotal, prevTotal) {
    if (!prev) return null;
    var rows = cur.map(function (c, i) {
      var p = prev[i], diffT = (c.pct == null || p.pct == null) ? null : tenth(c.pct) - tenth(p.pct);
      return { name: c.name, cur: c.pct, prev: p.pct, diff: diffT == null ? null : diffT / 10, t: diffT };
    });
    var comparable = rows.filter(function (r) { return r.t != null; });
    return {
      totalDiff: (tenth(curTotal) - tenth(prevTotal)) / 10,
      rows: rows.map(function (r) { return { name: r.name, cur: r.cur, prev: r.prev, diff: r.diff }; }),
      best: extremes(comparable, 1),
      worst: extremes(comparable, -1)
    };
  }

  // 歷次走勢：畫全部歷次（不限於該份成績單之前），標出本份
  function trendSeries(list, currentId) {
    var curIdx = -1;
    var points = list.map(function (r, i) {
      if (r.id === currentId) curIdx = i;
      return { id: r.id, date: r.date, total: r.total, verdict: r.verdict, isCurrent: r.id === currentId };
    });
    return { points: points, curIdx: curIdx };
  }

  // 每題得分列：核心題組依 seq 在前，加考題在後。非客服部（showTitle 不為 true）完全不帶 title 欄位。
  function itemRows(items, opts) {
    var showTitle = !!(opts && opts.showTitle);
    var sorted = (items || []).slice().sort(function (a, b) {
      return (a.isExtra ? 1 : 0) - (b.isExtra ? 1 : 0) || (a.seq - b.seq);
    });
    var n = 0;
    return sorted.map(function (it) {
      var row = {
        no: it.isExtra ? null : ++n,
        isExtra: !!it.isExtra,
        category: it.category || '',
        code: it.code || '',
        levels: DIMS.map(function (d) { return (it.levels || {})[d.name] || '—'; }),
        score: it.item_score == null ? null : Number(it.item_score)
      };
      if (showTitle) row.title = it.title || '';
      return row;
    });
  }

  // input: { person:{name,id,hire}, storeName, assessments:[該考生全部考核列], currentId,
  //          itemsByAssessment:{ id:[題組] }, showTitle, nowMs }
  function buildReport(input) {
    var list = eligibleAssessments(input.assessments);
    var idx = -1;
    list.forEach(function (r, i) { if (r.id === input.currentId) idx = i; });
    if (idx < 0) return { ok: false, error: '找不到這張成績單，可能已作廢或尚未送出。' };
    var cur = list[idx], prev = idx > 0 ? list[idx - 1] : null;
    var raw = (input.assessments || []).filter(function (a) { return a.id === cur.id; })[0] || {};
    var items = (input.itemsByAssessment || {})[cur.id] || [];
    var rates = dimRates(items);
    if (!rates.ok) return { ok: false, error: rates.error };
    var prevRates = null;
    if (prev) {
      prevRates = dimRates((input.itemsByAssessment || {})[prev.id] || []);
      if (!prevRates.ok) return { ok: false, error: '上一次成績單的資料不完整，無法比較：' + prevRates.error };
    }
    var passLine = raw.pass_line || Scoring.verdictFor(cur.total, cur.tenure).passLine;
    var coreN = items.filter(function (it) { return !it.isExtra; }).length;
    var rows = itemRows(items, { showTitle: input.showTitle });
    var model = {
      generated: taipeiToday(input.nowMs),
      person: {
        name: (input.person && input.person.name) || '',
        id: (input.person && input.person.id) || '',
        store: input.storeName || '',
        hire: raw.hire_date_snapshot || (input.person && input.person.hire) || ''
      },
      tenure: cur.tenure, date: cur.date,
      total: cur.total, verdict: cur.verdict, passLine: passLine,
      scoredCount: coreN, extraCount: items.length - coreN,
      dims: rates.rows,
      prevDate: prev ? prev.date : '', prevTotal: prev ? prev.total : null,
      compare: compare(rates.rows, prevRates && prevRates.rows, cur.total, prev ? prev.total : 0),
      showTitle: !!input.showTitle,
      items: rows,
      hasExtra: rows.some(function (r) { return r.isExtra; }),
      trend: trendSeries(list, cur.id)
    };
    return { ok: true, model: model };
  }

  /*
   * 分頁分配。blocks：依序的區塊 [{ h, type, forceBreak, keepNext }]
   *   type：'blk'（一般區塊）、'title'（表格標題）、'thead'（表頭）、'row'（表格列）
   *   forceBreak：此區塊一定從新的一頁開始（第 1 頁固定內容結束處）
   *   keepNext：此區塊必須和下一個區塊同頁（標題→表頭→第一列不能被拆開；走勢圖→頁尾也綁在一起）
   * 規則：放不下就換頁；換頁後若接著是表格列，先重印表頭（rep:true）；一個區塊本身就超過一頁高度時照放並標記 overflow。
   * 每頁再算剩餘高度的分配：有表格列的頁，先把列加高（每列最多 26px、最多用掉 60% 剩餘），其餘平均加在區塊之間。
   * 回傳 { pages:[{ items:[{i, rep?}], used, slack, overflow, rowExtra, gapExtra }], overflow }
   *   gapExtra：每個「一般區塊」（不含該頁最後一項、不含 title／thead／row）要額外加的 paddingBottom px
   */
  var ROW_EXTRA_MAX = 26;
  function layoutPages(blocks, contentH) {
    var pages = [], cur = [], used = 0, lastThead = -1;
    function flush() { pages.push({ items: cur, used: used }); cur = []; used = 0; }
    for (var i = 0; i < blocks.length; i++) {
      var b = blocks[i];
      if (b.forceBreak && cur.length) flush();
      var need = b.h, j = i;
      while (blocks[j].keepNext && j + 1 < blocks.length) { j++; need += blocks[j].h; }
      if (cur.length && used + need > contentH) flush();
      if (b.type === 'row' && cur.length === 0 && lastThead >= 0) { cur.push({ i: lastThead, rep: true }); used += blocks[lastThead].h; }
      cur.push({ i: i }); used += b.h;
      if (b.type === 'thead') lastThead = i;
      else if (b.type !== 'row') lastThead = -1;
    }
    if (cur.length) flush();
    var any = false;
    pages.forEach(function (pg) {
      pg.overflow = pg.used > contentH;
      if (pg.overflow) any = true;
      var slack = contentH - pg.used, rows = pg.items.filter(function (x) { return !x.rep && blocks[x.i].type === 'row'; }).length;
      pg.rowExtra = 0; pg.gapExtra = 0;
      if (slack > 0) {
        if (rows) { pg.rowExtra = Math.min(ROW_EXTRA_MAX, slack * 0.6 / rows); slack -= pg.rowExtra * rows; }
        var gaps = pg.items.slice(0, -1).filter(function (x) { return !x.rep && blocks[x.i].type === 'blk'; }).length;
        if (gaps) pg.gapExtra = slack / gaps;
        pg.slack = slack;
      } else pg.slack = 0;
    });
    return { pages: pages, overflow: any };
  }

  // ===== 走勢圖標籤避讓（純幾何，不碰畫面）=====
  // 輸入 o：{ points:[{x,y,score,verdict,fs}], lines:[{y,text}], bounds:{l,r,t,b}, lineX:{l,r} }
  //   points.verdict 為空字串＝不畫判定；lines 為合格線（y 為像素）；bounds 是標籤可用範圍；lineX 是合格線左右端 x
  // 回傳 { lines:[{x,y,anchor}], points:[{score:{x,y,anchor}, verdict:{x,y,anchor}|null}] }
  // 做法：先放合格線文字（避開資料點、折線），再放資料點標籤（避開合格線文字、其他標籤，並盡量不壓到合格線）。
  // 候選位置依序嘗試（點標籤：上、下、右、左；線標籤：右上、右下、左上、左下），取罰分最低者。
  function tw(text, fs, bold) {
    var w = 0, s = String(text);
    for (var i = 0; i < s.length; i++) w += s.charCodeAt(i) > 255 ? fs : fs * (bold ? 0.62 : 0.56);
    return w;
  }
  function textRect(x, b, anchor, text, fs, bold) {
    var w = tw(text, fs, bold), l = anchor === 'start' ? x : anchor === 'end' ? x - w : x - w / 2;
    return { l: l, r: l + w, t: b - fs * 0.95, b: b + fs * 0.15 };
  }
  function hit(a, c, pad) { return a.l < c.r + pad && c.l < a.r + pad && a.t < c.b + pad && c.t < a.b + pad; }
  function trendLabelLayout(o) {
    var pts = o.points, lines = o.lines || [], bd = o.bounds, lx = o.lineX;
    var markers = pts.map(function (p) { return { l: p.x - 8, r: p.x + 8, t: p.y - 8, b: p.y + 8 }; });
    var samples = [];
    for (var i = 0; i + 1 < pts.length; i++) for (var k = 0; k <= 40; k++) samples.push({ x: pts[i].x + (pts[i + 1].x - pts[i].x) * k / 40, y: pts[i].y + (pts[i + 1].y - pts[i].y) * k / 40 });
    function onPoly(r) { var n = 0; samples.forEach(function (s) { if (s.x > r.l - 2 && s.x < r.r + 2 && s.y > r.t - 2 && s.y < r.b + 2) n++; }); return n; }
    function crossLines(r) { var n = 0; lines.forEach(function (ln) { if (ln.y > r.t + 1 && ln.y < r.b - 1) n++; }); return n; }
    function outside(r) { return r.l < bd.l || r.r > bd.r || r.t < bd.t || r.b > bd.b; }
    // 1) 合格線文字
    var placedLines = [], lineRects = [];
    lines.forEach(function (ln) {
      var cands = [['end', lx.r - 2, ln.y - 5], ['end', lx.r - 2, ln.y + 14], ['start', lx.l + 4, ln.y - 5], ['start', lx.l + 4, ln.y + 14]], best = null;
      cands.forEach(function (c, ci) {
        var r = textRect(c[1], c[2], c[0], ln.text, 11, true), pen = ci;
        markers.forEach(function (m) { if (hit(r, m, 2)) pen += 1000; });
        lineRects.forEach(function (q) { if (hit(r, q, 2)) pen += 1000; });
        pts.forEach(function (p) { var d = p.verdict ? 33 : 21; if (hit(r, { l: p.x - 22, r: p.x + 22, t: p.y - d, b: p.y - 6 }, 0)) pen += 8; });
        pen += onPoly(r) * 20 + crossLines(r) * 30 + (outside(r) ? 1000 : 0);
        if (!best || pen < best.pen) best = { pen: pen, c: c, r: r };
      });
      placedLines.push({ x: best.c[1], y: best.c[2], anchor: best.c[0] }); lineRects.push(best.r);
    });
    // 2) 資料點標籤
    var taken = lineRects.slice(), out = [];
    pts.forEach(function (p) {
      var fs = p.fs || 12, hasV = !!p.verdict, cands = [];
      cands.push({ s: ['middle', p.x, p.y - 23], v: hasV ? ['middle', p.x, p.y - 11] : null });
      cands.push({ s: ['middle', p.x, p.y + 23], v: hasV ? ['middle', p.x, p.y + 36] : null });
      cands.push({ s: ['start', p.x + 12, hasV ? p.y - 1 : p.y + 4], v: hasV ? ['start', p.x + 12, p.y + 12] : null });
      cands.push({ s: ['end', p.x - 12, hasV ? p.y - 1 : p.y + 4], v: hasV ? ['end', p.x - 12, p.y + 12] : null });
      var best = null;
      cands.forEach(function (c, ci) {
        var rs = [textRect(c.s[1], c.s[2], c.s[0], p.score, fs, true)];
        if (c.v) rs.push(textRect(c.v[1], c.v[2], c.v[0], p.verdict, 11, false));
        var u = { l: Math.min.apply(null, rs.map(function (r) { return r.l; })), r: Math.max.apply(null, rs.map(function (r) { return r.r; })),
          t: Math.min.apply(null, rs.map(function (r) { return r.t; })), b: Math.max.apply(null, rs.map(function (r) { return r.b; })) };
        var pen = ci * 2;
        taken.forEach(function (q) { if (hit(u, q, 1)) pen += 1000; });
        markers.forEach(function (m) { if (hit(u, m, 0)) pen += 1000; });
        pen += onPoly(u) * 20 + crossLines(u) * 30 + (outside(u) ? 1000 : 0);
        if (!best || pen < best.pen) best = { pen: pen, c: c, u: u };
      });
      taken.push(best.u);
      out.push({ score: { x: best.c.s[1], y: best.c.s[2], anchor: best.c.s[0] }, verdict: best.c.v ? { x: best.c.v[1], y: best.c.v[2], anchor: best.c.v[0] } : null });
    });
    return { lines: placedLines, points: out };
  }

  var api = {
    DIMS: DIMS,
    ROW_EXTRA_MAX: ROW_EXTRA_MAX,
    taipeiToday: taipeiToday, taipeiDate: taipeiDate,
    eligibleAssessments: eligibleAssessments, dimRates: dimRates, compare: compare,
    trendSeries: trendSeries, itemRows: itemRows, buildReport: buildReport, layoutPages: layoutPages, trendLabelLayout: trendLabelLayout
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.ReportPdfCore = api;
})(typeof window !== 'undefined' ? window : this);
