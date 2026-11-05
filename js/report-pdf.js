/*
 * 成績單 PDF 下載（考核後台「歷次成績單」每列的「下載 PDF」）。純邏輯在 js/report-pdf-core.js。
 * 流程：取資料（BackofficeApi，權限由資料庫把關）→ ReportPdfCore.buildReport → 組 A4 版面 DOM
 *       → ReportPdfCore.layoutPages 分頁 → html2canvas 轉圖 → jsPDF 逐頁輸出。
 * html2canvas 1.4.1、jsPDF 2.5.1 只在第一次按下載時才動態載入（cdnjs，固定版本）。
 * 不把成績單內容寫進 console 或瀏覽器儲存。
 * 版面與 樣品/成績單PDF樣品.html 一致：固定 A4（794×1123 px），所有區塊都是 #rpdfDoc 的直接子元素 .blk。
 */
(function (root) {
  var Core = root.ReportPdfCore, Scoring = root.Scoring, Radar = root.Radar;
  var LIBS = ['https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js',
              'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js'];
  var LIB_TIMEOUT = 20000, IMG_TIMEOUT = 5000;
  var LIB_ERR = 'PDF 產生工具載入失敗，請檢查網路後再試一次。';
  var GEN_ERR = '產生 PDF 失敗，請稍後再試一次；若持續發生請聯絡客服部。';
  var PAGE_W = 794, PAGE_H = 1123, TOP = 34, BOT = 44, CONTENT_H = PAGE_H - TOP - BOT, SCALE = 2;
  var LOGO = 'img/logo.png';
  var SHORT = ['資訊', '預設', '掌握', '引導', '風險', '語氣', '文字'];
  var LVCLS = { '優': 'o', '良': 'g', '待加強': 'w', '不及格': 'f' };
  var VCOL = { '優秀': '#16A34A', '及格': '#0669EB', '需複訓': '#D97706', '不及格': '#DC2626' };
  var VBG = { '優秀': 'rgba(22,163,74,.12)', '及格': 'rgba(6,105,235,.12)', '需複訓': 'rgba(217,119,6,.12)', '不及格': 'rgba(220,38,38,.10)' };
  // SVG 單獨轉圖時讀不到頁面的 CSS 變數，所以把用到的 var(--x) 換成固定色碼（與 app.css／tokens.css 的值相同）
  var VARS = { '--accent': '#0669EB', '--accent-soft': 'rgba(6,105,235,.12)', '--accent-deep': '#0553BC', '--ink': '#0A0A0A', '--ink-2': '#4A4F5A',
    '--ink-3': '#94A3B8', '--ink-line': 'rgba(15,23,42,.08)', '--track': 'rgba(15,23,42,.10)', '--warning': '#D97706', '--success': '#16A34A',
    '--danger': '#DC2626', '--surface-solid': '#fff' };

  var CSS = '' +
'#rpdfWrap{position:fixed;left:-10000px;top:0;width:794px;pointer-events:none}' +
'#rpdfDoc{width:794px;background:#fff;color:#0A0A0A;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang TC","Microsoft JhengHei","Noto Sans TC","Helvetica Neue",sans-serif;font-size:12px;line-height:1.5;text-align:left}' +
'#rpdfDoc *{box-sizing:border-box}' +
'#rpdfDoc .blk{padding:4px 40px 14px}' +
'#rpdfDoc .blk[data-type=row],#rpdfDoc .blk[data-type=thead]{padding-top:0}' +
'#rpdfDoc .hd{display:flex;align-items:center;justify-content:space-between;padding-bottom:14px;border-bottom:3px solid #D9FF00}' +
'#rpdfDoc .hd img{height:44px;width:auto;display:block}' +
'#rpdfDoc .hd .ttl{text-align:right}' +
'#rpdfDoc .hd .ttl b{display:block;font-size:22px;font-weight:800;letter-spacing:.5px}' +
'#rpdfDoc .hd .ttl span{font-size:12px;color:#4A4F5A}' +
'#rpdfDoc .sec{font-size:14px;font-weight:800;margin:0 0 8px;padding-left:9px;border-left:5px solid #0669EB;line-height:1.2}' +
'#rpdfDoc .info{display:grid;grid-template-columns:repeat(3,1fr);gap:8px 16px}' +
'#rpdfDoc .info div{background:#F3F5F8;border-radius:8px;padding:7px 10px}' +
'#rpdfDoc .info small{display:block;font-size:11px;color:#4A4F5A}' +
'#rpdfDoc .info b{font-size:14px}' +
'#rpdfDoc .score{display:flex;align-items:center;gap:22px;background:#0A0A0A;color:#fff;border-radius:14px;padding:14px 24px}' +
'#rpdfDoc .score .big{font-size:46px;font-weight:800;line-height:1;color:#D9FF00}' +
'#rpdfDoc .score .big small{font-size:15px;color:#fff;font-weight:600;margin-left:4px}' +
'#rpdfDoc .score .meta{font-size:12px;color:rgba(255,255,255,.8);line-height:1.7}' +
'#rpdfDoc .vt{display:inline-block;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:700}' +
'#rpdfDoc .score .vt{font-size:16px;padding:5px 18px;background:#fff!important}' +
'#rpdfDoc .radarrow{display:grid;grid-template-columns:392px 1fr;gap:14px;align-items:center}' +
'#rpdfDoc .rsvg svg{display:block;width:392px;height:auto}' +
'#rpdfDoc .legend{display:flex;gap:16px;font-size:11px;color:#4A4F5A;justify-content:center;margin-top:2px}' +
'#rpdfDoc .legend i{display:inline-block;width:22px;height:0;border-top:3px solid #0669EB;vertical-align:middle;margin-right:5px}' +
'#rpdfDoc .legend i.dash{border-top:2px dashed #64748B}' +
'#rpdfDoc table.dt{width:100%;border-collapse:collapse;font-size:12px}' +
'#rpdfDoc table.dt th,#rpdfDoc table.dt td{padding:6px 6px;border-bottom:1px solid #E3E7ED;text-align:left;white-space:normal;letter-spacing:0;font-weight:400;color:#0A0A0A;background:none}' +
'#rpdfDoc table.dt th{font-size:11px;color:#4A4F5A;background:#F3F5F8;font-weight:700}' +
'#rpdfDoc table.dt .n{text-align:right;font-variant-numeric:tabular-nums}' +
'#rpdfDoc .up{color:#16A34A;font-weight:700}' +
'#rpdfDoc .down{color:#DC2626;font-weight:700}' +
'#rpdfDoc .flat{color:#4A4F5A}' +
'#rpdfDoc .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}' +
'#rpdfDoc .card{background:#F3F5F8;border-radius:10px;padding:10px 12px}' +
'#rpdfDoc .card small{display:block;font-size:11px;color:#4A4F5A;margin-bottom:2px}' +
'#rpdfDoc .card b{font-size:15px}' +
'#rpdfDoc .card span{display:block;font-size:11px;color:#4A4F5A;margin-top:2px}' +
'#rpdfDoc .firstmsg{background:#F3F5F8;border-radius:10px;padding:50px 14px;text-align:center;font-size:13px;color:#4A4F5A}' +
'#rpdfDoc .qrow{display:grid;grid-template-columns:40px 44px minmax(0,1fr) repeat(7,42px) 44px;align-items:center;border-bottom:1px solid #E3E7ED}' +
'#rpdfDoc .qrow>*{padding:9px 3px;min-width:0}' +
'#rpdfDoc .qrow.h{background:#F3F5F8;font-size:11px;color:#4A4F5A;font-weight:700;border-bottom:none}' +
'#rpdfDoc .qrow.h .dm{text-align:center;font-size:10px;line-height:1.2}' +
'#rpdfDoc .qrow .lv{text-align:center;font-size:11px;font-weight:700}' +
'#rpdfDoc .qrow .sc{text-align:right;font-weight:800;font-size:13px;font-variant-numeric:tabular-nums}' +
'#rpdfDoc .qrow.extra{background:#FFF8E6}' +
'#rpdfDoc .qrow .code{font-size:11px;color:#4A4F5A}' +
'#rpdfDoc .lv-o{color:#16A34A}#rpdfDoc .lv-g{color:#0669EB}#rpdfDoc .lv-w{color:#D97706}#rpdfDoc .lv-f{color:#DC2626}' +
'#rpdfDoc .xtag{display:inline-block;background:#D9FF00;color:#0A0A0A;font-size:10px;font-weight:800;padding:1px 6px;border-radius:999px}' +
'#rpdfDoc .qnote{font-size:11px;color:#4A4F5A;padding-top:6px}' +
'#rpdfDoc .trend svg{display:block;width:100%;height:auto}' +
'#rpdfDoc .ft{font-size:11px;color:#94A3B8;text-align:center;border-top:1px solid #E3E7ED;padding-top:10px}';

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function fmt(x) { return String(Math.round(Number(x) * 10) / 10); }
  function dayNum(s) { var p = s.split('-'); return Math.round(Date.UTC(+p[0], +p[1] - 1, +p[2]) / 864e5); }
  function vtag(v) { return '<span class="vt" style="color:' + (VCOL[v] || '#4A4F5A') + ';background:' + (VBG[v] || 'rgba(15,23,42,.10)') + '">' + esc(v) + '</span>'; }
  function diffHtml(d) {
    if (d == null) return '<span class="flat">—</span>';
    if (d > 0) return '<span class="up">▲ ' + fmt(d) + '</span>';
    if (d < 0) return '<span class="down">▼ ' + fmt(-d) + '</span>';
    return '<span class="flat">持平</span>';
  }
  function pctText(p) { return p == null ? '—' : fmt(p) + '%'; }
  function resolveVars(s) {
    s = s.replace(/var\((--[\w-]+)(?:,\s*([^)]+))?\)/g, function (m, n, f) { return VARS[n] || (f && f.trim()) || '#000'; });
    return s.replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" style="font-family:\'Microsoft JhengHei\',\'PingFang TC\',\'Noto Sans TC\',sans-serif" ');
  }

  // ===== 圖：雷達（本次，疊上一次虛線）與歷次走勢 =====
  function weakFlags(rows) {
    var vals = rows.filter(function (r) { return r.pct !== null; }).map(function (r) { return r.pct; });
    var mn = Math.min.apply(null, vals);
    return rows.map(function (r) { return { name: r.name, pct: r.pct, weak: r.pct !== null && r.pct === mn }; });
  }
  var DATA_POLY = /<polygon points="[^"]+" fill="var\(--accent-soft\)" stroke="var\(--accent\)"[^>]*\/>/;
  function radarSvg(cur, prev) {
    var s = Radar.svg(weakFlags(cur), '七面向得分率：' + cur.map(function (r) { return r.name + ' ' + pctText(r.pct); }).join('、'));
    if (prev) {
      var m = Radar.svg(weakFlags(prev), '上一次').match(DATA_POLY);
      if (m) {
        var pts = m[0].match(/points="([^"]+)"/)[1];
        var dash = '<polygon points="' + pts + '" fill="none" stroke="#64748B" stroke-width="2" stroke-dasharray="6 4" stroke-linejoin="round"/>';
        s = s.replace(DATA_POLY, function (cm) { return dash + cm; });
      }
    }
    return resolveVars(s);
  }
  function trendSvg(points, curIdx, label) {
    var W = 600, H = 380, L0 = 44, R = 20, T = 40, B = 50, pw = W - L0 - R, ph = H - T - B;
    function Y(v) { return T + (1 - v / 100) * ph; }
    var n = points.length, xs = [], lo = L0 + 36, hi = W - R - 36;
    var d0 = dayNum(points[0].date), d1 = dayNum(points[n - 1].date);
    points.forEach(function (r) { xs.push(n === 1 || d1 === d0 ? (lo + hi) / 2 : lo + (dayNum(r.date) - d0) / (d1 - d0) * (hi - lo)); });
    for (var i = 1; i < n; i++) xs[i] = Math.max(xs[i], xs[i - 1] + 64);
    if (xs[n - 1] > hi + 0.5 && n > 1) xs = xs.map(function (_, k) { return lo + k * (hi - lo) / (n - 1); });
    var gap = n > 1 ? Math.min.apply(null, xs.slice(1).map(function (x, k) { return x - xs[k]; })) : 999;
    var step = Math.max(1, Math.ceil(36 / Math.max(gap, 1)));   // 點太密時日期標籤隔幾個才標一個（本份一定標）
    var showVerdict = gap >= 46;
    var s = '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + esc(label) + '"><title>' + esc(label) + '</title>';
    [0, 20, 40, 60, 80, 100].forEach(function (v) {
      s += '<line x1="' + L0 + '" x2="' + (W - R) + '" y1="' + Y(v) + '" y2="' + Y(v) + '" stroke="var(--track)" stroke-width="1"/>' +
        '<text x="' + (L0 - 8) + '" y="' + (Y(v) + 4) + '" font-size="12" text-anchor="end" fill="var(--ink-2)">' + v + '</text>';
    });
    // 標籤位置交給 ReportPdfCore.trendLabelLayout 避讓：合格線文字不壓資料點／折線，資料點標籤不壓合格線文字
    var PL = [[70, '新人合格線 70'], [85, '正式合格線 85']];
    var lay = Core.trendLabelLayout({ lineX: { l: L0, r: W - R }, bounds: { l: L0, r: W - 2, t: 2, b: H - B - 2 },
      lines: PL.map(function (l) { return { y: Y(l[0]), text: l[1] }; }),
      points: points.map(function (r, k) { return { x: xs[k], y: Y(r.total), score: fmt(r.total), verdict: (showVerdict || k === curIdx) ? (r.verdict || '') : '' }; }) });
    PL.forEach(function (l, li) {
      s += '<line x1="' + L0 + '" x2="' + (W - R) + '" y1="' + Y(l[0]) + '" y2="' + Y(l[0]) + '" stroke="var(--ink-3)" stroke-width="1.5" stroke-dasharray="6 4"/>' +
        '<text x="' + lay.lines[li].x + '" y="' + lay.lines[li].y + '" font-size="11" text-anchor="' + lay.lines[li].anchor + '" fill="var(--ink-2)" stroke="var(--surface-solid)" stroke-width="3" paint-order="stroke">' + l[1] + '</text>';
    });
    if (n > 1) s += '<polyline fill="none" stroke="var(--accent)" stroke-width="2" stroke-linejoin="round" points="' + points.map(function (r, k) { return xs[k].toFixed(1) + ',' + Y(r.total).toFixed(1); }).join(' ') + '"/>';
    points.forEach(function (r, k) {
      var x = xs[k], y = Y(r.total), col = VCOL[r.verdict] || '#0669EB', cur = k === curIdx, lb = lay.points[k];
      s += '<circle cx="' + x.toFixed(1) + '" cy="' + y.toFixed(1) + '" r="' + (cur ? 6.5 : 5) + '" fill="' + (cur ? col : 'var(--surface-solid)') + '" stroke="' + col + '" stroke-width="3"/>' +
        '<text x="' + lb.score.x.toFixed(1) + '" y="' + lb.score.y.toFixed(1) + '" font-size="12" font-weight="700" text-anchor="' + lb.score.anchor + '" fill="var(--ink)" stroke="var(--surface-solid)" stroke-width="3" paint-order="stroke">' + fmt(r.total) + '</text>' +
        (lb.verdict ? '<text x="' + lb.verdict.x.toFixed(1) + '" y="' + lb.verdict.y.toFixed(1) + '" font-size="11" text-anchor="' + lb.verdict.anchor + '" fill="var(--ink-2)" stroke="var(--surface-solid)" stroke-width="3" paint-order="stroke">' + esc(r.verdict || '') + '</text>' : '') +
        (k % step === 0 || cur ? '<text x="' + x.toFixed(1) + '" y="' + (H - B + 18) + '" font-size="12" text-anchor="middle" fill="var(--ink-2)">' + esc(r.date.slice(5).replace('-', '/')) + '</text>' : '');
    });
    s += '<text x="' + (L0 + pw / 2) + '" y="' + (H - 6) + '" font-size="11" text-anchor="middle" fill="var(--ink-3)">考核日期（月/日）　實心＝本份成績單</text>';
    return resolveVars(s + '</svg>');
  }

  // ===== 版面 HTML：回傳一串 .blk 區塊（#rpdfDoc 的直接子元素）。data-type 對應 ReportPdfCore.layoutPages 的 type =====
  function blk(type, inner, attrs, cls) { return '<div class="blk' + (cls ? ' ' + cls : '') + '" data-type="' + type + '"' + (attrs || '') + '>' + inner + '</div>'; }
  function buildHtml(m) {
    var h = '', prev = m.compare, rows = m.dims;
    h += blk('blk', '<div class="hd"><img src="' + LOGO + '" alt="貳輪嶼"><div class="ttl"><b>業務考核成績單</b><span>產生日期　' + esc(m.generated) + '</span></div></div>');
    h += blk('blk', '<div class="sec">考生資料</div><div class="info">' +
      [['姓名', m.person.name], ['編號', m.person.id], ['門市', m.person.store], ['到職日', m.person.hire || '未填到職日'], ['考核時身分', m.tenure], ['考核日期', m.date]].map(function (x) {
        return '<div><small>' + x[0] + '</small><b>' + esc(x[1]) + '</b></div>';
      }).join('') + '</div>', ' style="padding-top:14px"');
    h += blk('blk', '<div class="score"><div class="big">' + fmt(m.total) + '<small>分</small></div><div>' + vtag(m.verdict) + '</div>' +
      '<div class="meta">合格線 ' + esc(m.passLine) + ' 分（' + esc(m.tenure) + '）<br>計分題組 ' + m.scoredCount + ' 組' + (m.extraCount ? '，另有加考 ' + m.extraCount + ' 組（不計入）' : '') + '</div></div>');
    h += blk('blk', '<div class="sec">七面向得分率</div><div class="radarrow"><div><div class="rsvg">' + radarSvg(rows, prev ? prev.rows.map(function (r) { return { name: r.name, pct: r.prev }; }) : null) + '</div>' +
      '<div class="legend"><span><i></i>本次</span>' + (prev ? '<span><i class="dash"></i>上一次</span>' : '') + '</div></div>' +
      '<table class="dt"><thead><tr><th>面向</th><th class="n">本次</th>' + (prev ? '<th class="n">上一次</th><th class="n">差異</th>' : '') + '</tr></thead><tbody>' +
      rows.map(function (d, i) {
        return '<tr><td>' + esc(d.name) + '</td><td class="n">' + pctText(d.pct) + '</td>' + (prev ? '<td class="n">' + pctText(prev.rows[i].prev) + '</td><td class="n">' + diffHtml(prev.rows[i].diff) + '</td>' : '') + '</tr>';
      }).join('') + '</tbody></table></div>');
    var cmpHtml;
    if (!prev) cmpHtml = '<div class="firstmsg">首次考核，沒有上一次可比較。</div>';
    else cmpHtml = '<div class="cards"><div class="card"><small>總分差</small><b>' + diffHtml(prev.totalDiff) + '</b><span>' + fmt(m.prevTotal) + ' → ' + fmt(m.total) + '（' + esc(m.prevDate) + '）</span></div>' +
      '<div class="card"><small>進步最多面向</small><b>' + (prev.best ? esc(prev.best.names.join('、')) : '無') + '</b><span>' + (prev.best ? '<span class="up">▲ ' + fmt(prev.best.value) + ' 個百分點</span>' : '沒有面向進步') + '</span></div>' +
      '<div class="card"><small>退步最多面向</small><b>' + (prev.worst ? esc(prev.worst.names.join('、')) : '無') + '</b><span>' + (prev.worst ? '<span class="down">▼ ' + fmt(prev.worst.value) + ' 個百分點</span>' : '沒有面向退步') + '</span></div></div>';
    h += blk('blk', '<div class="sec">與上一次比較</div>' + cmpHtml);
    // 每題得分：標題、表頭、每一列各自是一個區塊，換頁才不會切到列
    h += blk('title', '<div class="sec">每題得分</div>', ' data-break="1"');
    h += blk('thead', '<div class="qrow h" style="padding-bottom:0"><div>題組</div><div>分類</div><div>' + (m.showTitle ? '題目' : '題組編號') + '</div>' +
      SHORT.map(function (s) { return '<div class="dm">' + s + '</div>'; }).join('') + '<div style="text-align:right">得分</div></div>');
    m.items.forEach(function (it) {
      var main = m.showTitle ? esc(it.title || '（無題名）') : esc(it.code || '—'), sub = m.showTitle ? esc(it.code) : esc(it.category);
      h += blk('row', '<div class="qrow' + (it.isExtra ? ' extra' : '') + '"><div>' + (it.isExtra ? '<span class="xtag">加考</span>' : it.no) + '</div><div>' + esc(it.category) + '</div>' +
        '<div>' + main + '<div class="code">' + sub + '</div></div>' +
        it.levels.map(function (lv) { return '<div class="lv lv-' + (LVCLS[lv] || 'x') + '">' + esc(lv) + '</div>'; }).join('') +
        '<div class="sc">' + (it.score == null ? '—' : fmt(it.score)) + '</div></div>');
    });
    h += blk('blk', '<div class="qnote">等級：優 100％、良 70％、待加強 40％、不及格 0％；面向由左至右依序為資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識、語氣與禮貌、文字品質。' +
      (m.hasExtra ? '<br><b>加考題（弱項追加題）不計入總分與判定，也不計入面向得分率。</b>' : '') + '</div>');
    var t = m.trend, tl = '歷次總分走勢：' + t.points.map(function (x) { return x.date + ' ' + fmt(x.total); }).join('、');
    h += blk('blk', '<div class="sec">歷次總分走勢</div>' + trendSvg(t.points, t.curIdx, tl), ' style="padding-top:8px" data-keep="1"', 'trend');
    h += blk('blk', '<div class="ft">本成績單由業務考核系統產生，僅供內部使用</div>', ' style="padding-bottom:0"');
    return h;
  }

  // ===== DOM：掛載、量測、分頁、套用間距 =====
  function mount(html) {
    var doc = root.document;
    if (!doc.getElementById('rpdfStyle')) { var st = doc.createElement('style'); st.id = 'rpdfStyle'; st.textContent = CSS; doc.head.appendChild(st); }
    var wrap = doc.createElement('div'); wrap.id = 'rpdfWrap'; wrap.setAttribute('aria-hidden', 'true');
    wrap.innerHTML = '<div id="rpdfDoc">' + html + '</div>';
    doc.body.appendChild(wrap);
    return wrap;
  }
  function waitImages(el) {
    var imgs = Array.prototype.slice.call(el.querySelectorAll('img'));
    return Promise.all(imgs.map(function (im) {
      if (im.complete && im.naturalWidth) return null;
      return new Promise(function (ok) { im.addEventListener('load', ok); im.addEventListener('error', ok); setTimeout(ok, IMG_TIMEOUT); });   // 圖載不到也不卡住
    }));
  }
  function measure(docEl) {
    var top0 = docEl.getBoundingClientRect().top;
    return Array.prototype.slice.call(docEl.querySelectorAll(':scope > .blk')).map(function (el) {
      var rc = el.getBoundingClientRect();
      return { el: el, top: rc.top - top0, h: rc.height, type: el.getAttribute('data-type'), forceBreak: el.hasAttribute('data-break'),
        keepNext: el.getAttribute('data-type') === 'title' || el.getAttribute('data-type') === 'thead' || el.hasAttribute('data-keep') };
    });
  }
  // 回傳 { pages:[[{el, top, h, rep}]], overflow }
  function paginate(docEl) {
    var bl = measure(docEl);
    var lay = Core.layoutPages(bl, CONTENT_H);
    lay.pages.forEach(function (pg) {
      pg.items.forEach(function (x) {
        if (x.rep) return;
        var b = bl[x.i], el = b.el;
        if (b.type === 'row') {
          if (pg.rowExtra > 0) Array.prototype.forEach.call(el.firstChild.children, function (c) { c.style.paddingTop = c.style.paddingBottom = (9 + pg.rowExtra / 2) + 'px'; });
        }
      });
      pg.items.slice(0, -1).forEach(function (x) {
        if (x.rep || bl[x.i].type !== 'blk' || !(pg.gapExtra > 0)) return;
        var el = bl[x.i].el, pb = parseFloat(root.getComputedStyle(el).paddingBottom) || 0;
        el.style.paddingBottom = (pb + pg.gapExtra) + 'px';
      });
    });
    var bl2 = measure(docEl);   // 間距調整後重新量測，輸出用這份座標
    return {
      overflow: lay.overflow,
      pages: lay.pages.map(function (pg) { return pg.items.map(function (x) { var b = bl2[x.i]; return { top: b.top, h: b.h, rep: !!x.rep }; }); })
    };
  }

  // ===== 動態載入 html2canvas、jsPDF（第一次按下載才載）=====
  var libsPromise = null;
  function ready() { return !!(root.html2canvas && root.jspdf && root.jspdf.jsPDF); }
  function loadScript(src) {
    return new Promise(function (ok, bad) {
      var s = root.document.createElement('script'), done = false;
      function fin(err) { if (done) return; done = true; clearTimeout(tm); if (err) { s.remove(); bad(new Error(LIB_ERR)); } else ok(); }
      var tm = setTimeout(function () { fin(true); }, LIB_TIMEOUT);
      s.src = src; s.async = true; s.onload = function () { fin(false); }; s.onerror = function () { fin(true); };
      root.document.head.appendChild(s);
    });
  }
  function loadLibs() {
    if (ready()) return Promise.resolve();
    if (!libsPromise) {
      libsPromise = Promise.all(LIBS.map(loadScript)).then(function () { if (!ready()) throw new Error(LIB_ERR); }, function (e) { libsPromise = null; throw e; });
    }
    return libsPromise;
  }

  // ===== 產生 PDF =====
  function fileName(m) { return ('成績單_' + m.person.name + '_' + m.date + '.pdf').replace(/[\\\/:*?"<>|]/g, '_'); }
  function makePdf(m) {
    var wrap = mount(buildHtml(m)), docEl = wrap.firstChild;
    return waitImages(docEl).then(function () {
      var lay = paginate(docEl);
      return root.html2canvas(docEl, { scale: SCALE, backgroundColor: '#ffffff', useCORS: true, logging: false, scrollX: 0, scrollY: 0, width: PAGE_W, windowWidth: PAGE_W }).then(function (full) {
        var pdf = new root.jspdf.jsPDF({ orientation: 'p', unit: 'mm', format: 'a4', compress: true });
        lay.pages.forEach(function (pg, pi) {
          var cv = root.document.createElement('canvas'); cv.width = PAGE_W * SCALE; cv.height = PAGE_H * SCALE;
          var cx = cv.getContext('2d'); cx.fillStyle = '#fff'; cx.fillRect(0, 0, cv.width, cv.height);
          var y = TOP * SCALE;
          pg.forEach(function (b) {
            var sy = Math.round(b.top * SCALE), sh = Math.round(b.h * SCALE);
            cx.drawImage(full, 0, sy, full.width, sh, 0, y, cv.width, sh); y += sh;
          });
          if (pi > 0) pdf.addPage('a4', 'p');
          pdf.addImage(cv.toDataURL('image/jpeg', 0.92), 'JPEG', 0, 0, 210, 297);
          pdf.setFontSize(9); pdf.setTextColor(120);
          pdf.text((pi + 1) + ' / ' + lay.pages.length, 105, 291, { align: 'center' });
        });
        return { pdf: pdf, pageCount: lay.pages.length, name: fileName(m), overflow: lay.overflow };
      });
    }).then(function (o) { wrap.remove(); return o; }, function (e) { wrap.remove(); throw e; });
  }

  // ===== 取資料 =====
  // opts: { person:{name,id,hire}, assessmentId, withTitle(只有客服部 true), storeName(code)->名稱 }
  function loadModel(opts) {
    var Api = root.BackofficeApi;
    return Api.loadEmployeeAssessments(opts.person.id).then(function (rows) {
      var list = Core.eligibleAssessments(rows), idx = -1;
      list.forEach(function (r, i) { if (r.id === opts.assessmentId) idx = i; });
      if (idx < 0) { var e = new Error('找不到這張成績單，可能已作廢或尚未送出。'); e.userMessage = e.message; throw e; }
      var ids = [list[idx].id].concat(idx > 0 ? [list[idx - 1].id] : []);
      var raw = rows.filter(function (a) { return a.id === opts.assessmentId; })[0] || {};
      return Api.loadReportItems(ids, !!opts.withTitle).then(function (itemsBy) {
        var res = Core.buildReport({ person: opts.person, storeName: opts.storeName ? opts.storeName(raw.store_code) : '', assessments: rows,
          currentId: opts.assessmentId, itemsByAssessment: itemsBy, showTitle: !!opts.withTitle, nowMs: Date.now() });
        if (!res.ok) { var e2 = new Error(res.error); e2.userMessage = res.error; throw e2; }
        return res.model;
      });
    });
  }

  var busy = false;
  function run(opts) {
    if (busy) return Promise.resolve();
    busy = true;
    var btn = opts.btn, msg = opts.msgEl, old = btn ? btn.textContent : '';
    function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'msg ' + (ok ? 'ok' : 'err'); msg.hidden = !t; } }
    say('');
    if (btn) { btn.disabled = true; btn.textContent = '產生中…'; }
    var libs = loadLibs().catch(function (e) { e.libFail = true; throw e; });
    return Promise.all([loadModel(opts), libs]).then(function (r) { return makePdf(r[0]); }).then(function (o) {
      o.pdf.save(o.name);
      say('已產生：' + o.name + '（共 ' + o.pageCount + ' 頁）', true);
    }).catch(function (err) {
      say((err && err.userMessage) || (err && err.libFail && err.message) || GEN_ERR, false);
    }).then(function () {
      busy = false;
      if (btn) { btn.disabled = false; btn.textContent = old; }
    });
  }

  root.ReportPdf = { run: run, _buildHtml: buildHtml, _radarSvg: radarSvg, _trendSvg: trendSvg, _loadLibs: loadLibs, _makePdf: makePdf, _paginate: paginate, _mount: mount, _waitImages: waitImages, CONTENT_H: CONTENT_H };
})(window);
