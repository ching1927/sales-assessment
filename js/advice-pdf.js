/*
 * 健檢建議單：組 A4 一頁版面（預覽與 PDF 是同一份 DOM）、一頁填滿、產生 PDF。純邏輯在 js/advice-core.js。
 * 版面與 樣品/健檢與建議單樣品.html 的「建議單」分頁一致：固定 A4（794×1123 px），所有區塊都是 #advDoc 的直接子元素 .blk。
 * html2canvas 1.4.1、jsPDF 2.5.1 只在第一次按下載時才動態載入（cdnjs，固定版本），做法同成績單 PDF（js/report-pdf.js）。
 * 不把建議單內容寫進 console 或瀏覽器儲存。
 * 依賴：AdviceCore、Radar（radar.js）。
 */
(function (root) {
  var Core = root.AdviceCore, Radar = root.Radar;
  var LIBS = ['https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js',
              'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js'];
  var LIB_TIMEOUT = 20000, IMG_TIMEOUT = 5000;
  var LIB_ERR = 'PDF 產生工具載入失敗，請檢查網路後再試一次。';
  var GEN_ERR = '產生 PDF 失敗，請稍後再試一次；若持續發生請聯絡客服部。';
  var OVER_ERR = '建議單內容超出一頁，無法產生 PDF，請聯絡客服部。';
  var PAGE_W = 794, PAGE_H = 1123, TOP = 34, BOT = 44, CONTENT_H = PAGE_H - TOP - BOT, SCALE = 2;
  var TREND_H0 = 200, TREND_MIN = 140,TREND_MAX_EXTRA = 120, GAP0 = 14;
  var LOGO = 'img/logo.png';
  var VCOL = { '優秀': '#16A34A', '及格': '#0669EB', '需複訓': '#D97706', '不及格': '#DC2626' };
  var VBG = { '優秀': 'rgba(22,163,74,.12)', '及格': 'rgba(6,105,235,.12)', '需複訓': 'rgba(217,119,6,.12)', '不及格': 'rgba(220,38,38,.10)' };
  // SVG 單獨轉圖時讀不到頁面的 CSS 變數，所以把用到的 var(--x) 換成固定色碼（與 app.css／tokens.css 的值相同）
  var VARS = { '--accent': '#0669EB', '--accent-soft': 'rgba(6,105,235,.12)', '--accent-deep': '#0553BC', '--ink': '#0A0A0A', '--ink-2': '#4A4F5A',
    '--ink-3': '#94A3B8', '--ink-line': 'rgba(15,23,42,.08)', '--track': 'rgba(15,23,42,.10)', '--warning': '#D97706', '--success': '#16A34A',
    '--danger': '#DC2626', '--surface-solid': '#fff' };

  var CSS = '' +
'#advDoc{width:794px;height:1123px;padding:34px 0 44px;background:#fff;color:#0A0A0A;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang TC","Microsoft JhengHei","Noto Sans TC","Helvetica Neue",sans-serif;font-size:12px;line-height:1.5;text-align:left;overflow:hidden;box-shadow:0 6px 30px rgba(0,0,0,.25)}' +
'#advDoc *{box-sizing:border-box;margin:0}' +
'#advDoc .blk{padding:4px 40px 14px}' +
'#advDoc .hd{display:flex;align-items:center;justify-content:space-between;padding-bottom:14px;border-bottom:3px solid #D9FF00}' +
'#advDoc .hd img{height:44px;width:auto;display:block}' +
'#advDoc .hd .ttl{text-align:right}' +
'#advDoc .hd .ttl b{display:block;font-size:22px;font-weight:800;letter-spacing:.5px}' +
'#advDoc .hd .ttl span{font-size:12px;color:#4A4F5A}' +
'#advDoc .sec{font-size:14px;font-weight:800;margin:0 0 8px;padding-left:9px;border-left:5px solid #0669EB;line-height:1.2}' +
'#advDoc .info{display:grid;grid-template-columns:repeat(3,1fr);gap:8px 16px}' +
'#advDoc .info div{background:#F3F5F8;border-radius:8px;padding:6px 10px}' +
'#advDoc .info small{display:block;font-size:11px;color:#4A4F5A}' +
'#advDoc .info b{font-size:14px}' +
'#advDoc .info .ftag{display:inline-block;margin-left:6px;background:#D9FF00;color:#0A0A0A;font-size:10px;font-weight:800;padding:1px 7px;border-radius:999px;vertical-align:1px}' +
'#advDoc .score{display:flex;align-items:center;gap:22px;background:#0A0A0A;color:#fff;border-radius:14px;padding:12px 24px}' +
'#advDoc .score .big{font-size:44px;font-weight:800;line-height:1;color:#D9FF00}' +
'#advDoc .score .big small{font-size:15px;color:#fff;font-weight:600;margin-left:4px}' +
'#advDoc .score .meta{font-size:12px;color:rgba(255,255,255,.8);line-height:1.7}' +
'#advDoc .vt{display:inline-block;padding:5px 18px;border-radius:999px;font-size:16px;font-weight:700;background:#fff!important}' +
'#advDoc .radarrow{display:grid;grid-template-columns:300px 1fr;gap:18px;align-items:center}' +
'#advDoc .rsvg svg{display:block;width:300px;height:auto}' +
'#advDoc .legend{display:flex;gap:16px;font-size:11px;color:#4A4F5A;justify-content:center;margin-top:2px}' +
'#advDoc .legend i{display:inline-block;width:22px;height:0;border-top:3px solid #0669EB;vertical-align:middle;margin-right:5px}' +
'#advDoc .legend i.dash{border-top:2px dashed #64748B}' +
'#advDoc table.dt{width:100%;border-collapse:collapse;font-size:12px}' +
'#advDoc table.dt th,#advDoc table.dt td{padding:6px 6px;border-bottom:1px solid #E3E7ED;text-align:left;white-space:normal;letter-spacing:0;font-weight:400;color:#0A0A0A;background:none}' +
'#advDoc table.dt th{font-size:11px;color:#4A4F5A;background:#F3F5F8;font-weight:700}' +
'#advDoc table.dt .n{text-align:right;font-variant-numeric:tabular-nums}' +
'#advDoc .up{color:#16A34A;font-weight:700}' +
'#advDoc .down{color:#DC2626;font-weight:700}' +
'#advDoc .flat{color:#4A4F5A}' +
'#advDoc .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}' +
'#advDoc .card{background:#F3F5F8;border-radius:10px;padding:10px 12px}' +
'#advDoc .card small{display:block;font-size:11px;color:#4A4F5A;margin-bottom:2px}' +
'#advDoc .card b{font-size:15px}' +
'#advDoc .card span{display:block;font-size:11px;color:#4A4F5A;margin-top:2px}' +
'#advDoc .firstmsg{background:#F3F5F8;border-radius:10px;padding:22px 14px;text-align:center;font-size:13px;color:#4A4F5A}' +
'#advDoc .trend svg{display:block;width:100%;height:auto}' +
'#advDoc .ft{font-size:11px;color:#94A3B8;text-align:center;border-top:1px solid #E3E7ED;padding-top:10px}';

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function fmt(x) { return String(Math.round(Number(x) * 10) / 10); }
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

  // ===== 圖：七面向雷達（本次實線，疊上一次虛線）與歷年健檢總分折線 =====
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
  // x 軸為健檢年度等距；只畫一條 85 分及格線；實心＝本次。H 為整張圖高度（填滿頁面時會加高）
  function trendSvg(points, curIdx, label, H) {
    var W = 714, L0 = 44, R = 24, T = 36, B = 44, ph = H - T - B, pw = W - L0 - R;
    var mn = Math.min.apply(null, points.map(function (r) { return r.total; }));
    var lo = Math.min(50, Math.floor(mn / 10) * 10), ticks = [];
    for (var v = lo; v <= 100; v += 10) ticks.push(v);
    function Y(val) { return T + (1 - (val - lo) / (100 - lo)) * ph; }
    var n = points.length, xs = points.map(function (_, k) { return n === 1 ? L0 + pw / 2 : L0 + 50 + k * (pw - 100) / (n - 1); });
    var gap = n > 1 ? xs[1] - xs[0] : 999, showVerdict = gap >= 46;
    var s = '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + esc(label) + '"><title>' + esc(label) + '</title>';
    ticks.forEach(function (t) {
      s += '<line x1="' + L0 + '" x2="' + (W - R) + '" y1="' + Y(t) + '" y2="' + Y(t) + '" stroke="var(--track)" stroke-width="1"/>' +
        '<text x="' + (L0 - 8) + '" y="' + (Y(t) + 4) + '" font-size="12" text-anchor="end" fill="var(--ink-2)">' + t + '</text>';
    });
    var pl = Core.PASS_LINE;
    // 標籤位置交給 ReportPdfCore.trendLabelLayout 避讓：及格線文字不壓資料點／折線，資料點標籤不壓及格線文字
    var lay = root.ReportPdfCore.trendLabelLayout({ lineX: { l: L0, r: W - R }, bounds: { l: L0, r: W - 2, t: 2, b: H - B - 2 },
      lines: [{ y: Y(pl), text: '及格線 ' + pl }],
      points: points.map(function (r, k) { return { x: xs[k], y: Y(r.total), score: fmt(r.total), verdict: (showVerdict || k === curIdx) ? (r.verdict || '') : '' }; }) });
    s += '<line x1="' + L0 + '" x2="' + (W - R) + '" y1="' + Y(pl) + '" y2="' + Y(pl) + '" stroke="#DC2626" stroke-width="1.5" stroke-dasharray="6 4"/>' +
      '<text x="' + lay.lines[0].x + '" y="' + lay.lines[0].y + '" font-size="11" font-weight="700" text-anchor="' + lay.lines[0].anchor + '" fill="#DC2626" stroke="var(--surface-solid)" stroke-width="3" paint-order="stroke">及格線 ' + pl + '</text>';
    if (n > 1) s += '<polyline fill="none" stroke="var(--accent)" stroke-width="2" stroke-linejoin="round" points="' + points.map(function (r, k) { return xs[k].toFixed(1) + ',' + Y(r.total).toFixed(1); }).join(' ') + '"/>';
    points.forEach(function (r, k) {
      var x = xs[k], y = Y(r.total), col = VCOL[r.verdict] || '#0669EB', cur = k === curIdx, lb = lay.points[k];
      s += '<circle cx="' + x.toFixed(1) + '" cy="' + y.toFixed(1) + '" r="' + (cur ? 6.5 : 5) + '" fill="' + (cur ? col : 'var(--surface-solid)') + '" stroke="' + col + '" stroke-width="3"/>' +
        '<text x="' + lb.score.x.toFixed(1) + '" y="' + lb.score.y.toFixed(1) + '" font-size="12" font-weight="700" text-anchor="' + lb.score.anchor + '" fill="var(--ink)" stroke="var(--surface-solid)" stroke-width="3" paint-order="stroke">' + fmt(r.total) + '</text>' +
        (lb.verdict ? '<text x="' + lb.verdict.x.toFixed(1) + '" y="' + lb.verdict.y.toFixed(1) + '" font-size="11" text-anchor="' + lb.verdict.anchor + '" fill="var(--ink-2)" stroke="var(--surface-solid)" stroke-width="3" paint-order="stroke">' + esc(r.verdict || '') + '</text>' : '') +
        '<text x="' + x.toFixed(1) + '" y="' + (H - B + 18) + '" font-size="12" font-weight="' + (cur ? 700 : 400) + '" text-anchor="middle" fill="var(--ink-2)">' + esc(r.label || r.date) + (cur ? '（本次）' : '') + '</text>';
    });
    s += '<text x="' + (L0 + pw / 2) + '" y="' + (H - 4) + '" font-size="11" text-anchor="middle" fill="var(--ink-3)">健檢年度與季次　實心＝本次</text>';
    return resolveVars(s + '</svg>');
  }

  // ===== 版面 HTML：回傳一串 .blk 區塊（#advDoc 的直接子元素）=====
  function blk(inner, attrs, cls) { return '<div class="blk' + (cls ? ' ' + cls : '') + '"' + (attrs || '') + '>' + inner + '</div>'; }
  function buildHtml(m, trendH) {
    var h = '', cmp = m.compare;
    h += blk('<div class="hd"><img src="' + LOGO + '" alt="貳輪嶼"><div class="ttl"><b>年度健檢建議單</b><span>產生日期　' + esc(m.generated) + '</span></div></div>');
    h += blk('<div class="sec">考生資料</div><div class="info">' +
      [['姓名', esc(m.person.name)], ['編號', esc(m.person.id)], ['門市', esc(m.person.store)], ['到職日', m.person.hire ? esc(m.person.hire) : '未填到職日'], ['健檢日期', esc(m.date)],
       ['健檢年度與季次', esc(m.label) + (m.first ? '<span class="ftag">首次健檢</span>' : '')]].map(function (x) {
        return '<div><small>' + x[0] + '</small><b>' + x[1] + '</b></div>';
      }).join('') + '</div>', ' style="padding-top:10px"');
    h += blk('<div class="score"><div class="big">' + fmt(m.total) + '<small>分</small></div><div>' + vtag(m.verdict) + '</div>' +
      '<div class="meta">及格線 ' + m.passLine + ' 分：<b style="color:' + (m.pass ? '#D9FF00' : '#FCA5A5') + '">' + (m.pass ? '通過' : '未通過') + '</b><br>' +
      (m.pass ? '本次健檢達及格線' : '未達及格線，只記錄在建議單') + '　計分題組 ' + m.scoredCount + ' 組</div></div>');
    h += blk('<div class="sec">七面向得分率</div><div class="radarrow"><div><div class="rsvg">' +
      radarSvg(m.dims, cmp ? cmp.rows.map(function (r) { return { name: r.name, pct: r.prev }; }) : null) + '</div>' +
      '<div class="legend"><span><i></i>本次</span>' + (cmp ? '<span><i class="dash"></i>上一次</span>' : '') + '</div></div>' +
      '<table class="dt"><thead><tr><th>面向</th><th class="n">本次</th>' + (cmp ? '<th class="n">上一次</th><th class="n">差異</th>' : '') + '</tr></thead><tbody>' +
      m.dims.map(function (d, i) {
        return '<tr><td>' + esc(d.name) + '</td><td class="n">' + pctText(d.pct) + '</td>' + (cmp ? '<td class="n">' + pctText(cmp.rows[i].prev) + '</td><td class="n">' + diffHtml(cmp.rows[i].diff) + '</td>' : '') + '</tr>';
      }).join('') + '</tbody></table></div>');
    var cmpHtml;
    if (!cmp) cmpHtml = '<div class="firstmsg">首次健檢，沒有上一次可比較。</div>';
    else cmpHtml = '<div class="cards"><div class="card"><small>總分差</small><b>' + diffHtml(cmp.totalDiff) + '</b><span>' + fmt(m.prevTotal) + ' → ' + fmt(m.total) + '（' + esc(m.prevLabel) + '）</span></div>' +
      '<div class="card"><small>進步最多面向</small><b>' + (cmp.best ? esc(cmp.best.names.join('、')) : '無') + '</b><span>' + (cmp.best ? '<span class="up">▲ ' + fmt(cmp.best.value) + ' 個百分點</span>' : '沒有面向進步') + '</span></div>' +
      '<div class="card"><small>退步最多面向</small><b>' + (cmp.worst ? esc(cmp.worst.names.join('、')) : '無') + '</b><span>' + (cmp.worst ? '<span class="down">▼ ' + fmt(cmp.worst.value) + ' 個百分點</span>' : '沒有面向退步') + '</span></div></div>';
    h += blk('<div class="sec">與上一次健檢比較</div>' + cmpHtml);
    var t = m.trend, tl = '歷年健檢總分：' + t.points.map(function (x) { return x.label + ' ' + fmt(x.total); }).join('、');
    h += blk('<div class="sec">歷年健檢總分</div>' + trendSvg(t.points, t.curIdx, tl, trendH), ' style="padding-top:8px"', 'trend');
    h += blk('<div class="ft">本建議單由業務考核系統產生，僅供內部使用</div>', ' style="padding-bottom:0"');
    return h;
  }

  // ===== DOM：掛載、量測、一頁填滿 =====
  function ensureStyle() {
    var doc = root.document;
    if (!doc.getElementById('advStyle')) { var st = doc.createElement('style'); st.id = 'advStyle'; st.textContent = CSS; doc.head.appendChild(st); }
  }
  function blocks(docEl) { return Array.prototype.slice.call(docEl.querySelectorAll(':scope > .blk')); }
  function usedHeight(docEl) { return blocks(docEl).reduce(function (s, el) { return s + el.getBoundingClientRect().height; }, 0); }
  function waitImages(el) {
    var imgs = Array.prototype.slice.call(el.querySelectorAll('img'));
    return Promise.all(imgs.map(function (im) {
      if (im.complete && im.naturalWidth) return null;
      return new Promise(function (ok) { im.addEventListener('load', ok); im.addEventListener('error', ok); setTimeout(ok, IMG_TIMEOUT); });   // 圖載不到也不卡住
    }));
  }
  function fill(el, m, trendH) { el.innerHTML = buildHtml(m, trendH); }

  // 把建議單畫進 host（預覽）。回傳 Promise<{ overflow, slack }>；一頁填滿：剩餘高度先給走勢圖，其餘平均加在區塊之間
  function render(host, m) {
    ensureStyle();
    host.innerHTML = '<div id="advDoc"></div>';
    var docEl = host.firstChild;
    fill(docEl, m, TREND_H0);
    return waitImages(docEl).then(function () {
      var gaps = blocks(docEl).length - 1;
      var fit = Core.fitOnePage(usedHeight(docEl), CONTENT_H, gaps, TREND_MAX_EXTRA);
      if (fit.overflow) {   // 字型較高時略超出：先把走勢圖縮矮（不低於 TREND_MIN）再重算
        var h2 = Math.max(TREND_MIN, TREND_H0 + Math.floor(fit.slack));
        fill(docEl, m, h2);
        fit = Core.fitOnePage(usedHeight(docEl), CONTENT_H, gaps, 0);
        if (fit.overflow) return { overflow: true, slack: fit.slack };
      }
      if (fit.trendExtra > 0) {
        fill(docEl, m, TREND_H0 + fit.trendExtra);
        fit = Core.fitOnePage(usedHeight(docEl), CONTENT_H, gaps, 0);
        if (fit.overflow) { fill(docEl, m, TREND_H0); fit = Core.fitOnePage(usedHeight(docEl), CONTENT_H, gaps, 0); }
      }
      blocks(docEl).slice(0, -1).forEach(function (el) { el.style.paddingBottom = (GAP0 + fit.gapExtra) + 'px'; });
      var after = Core.fitOnePage(usedHeight(docEl), CONTENT_H, gaps, 0);   // 套用後再量一次，確認沒有溢出
      return { overflow: after.overflow, slack: after.slack };
    });
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

  // ===== 產生 PDF：把預覽的 #advDoc 轉圖放進一頁 A4 =====
  function makePdf(m) {
    var docEl = root.document.getElementById('advDoc');
    if (!docEl) return Promise.reject(new Error(GEN_ERR));
    return root.html2canvas(docEl, { scale: SCALE, backgroundColor: '#ffffff', useCORS: true, logging: false, scrollX: 0, scrollY: -root.scrollY, width: PAGE_W, height: PAGE_H,
      windowWidth: Math.max(root.document.documentElement.clientWidth, PAGE_W) }).then(function (cv) {
      var pdf = new root.jspdf.jsPDF({ orientation: 'p', unit: 'mm', format: 'a4', compress: true });
      pdf.addImage(cv.toDataURL('image/jpeg', 0.92), 'JPEG', 0, 0, 210, 297);
      pdf.setFontSize(9); pdf.setTextColor(120);
      pdf.text('1 / 1', 105, 291, { align: 'center' });
      return { pdf: pdf, pageCount: pdf.getNumberOfPages(), name: Core.fileName(m) };
    });
  }

  var busy = false;
  // opts: { model, btn, msgEl, isOverflow() }
  function download(opts) {
    if (busy) return Promise.resolve();
    busy = true;
    var btn = opts.btn, msg = opts.msgEl, old = btn ? btn.textContent : '';
    function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'msg ' + (ok ? 'ok' : 'err'); msg.hidden = !t; } }
    say('');
    if (btn) { btn.disabled = true; btn.textContent = '產生中…'; }
    if (opts.isOverflow && opts.isOverflow()) { say(OVER_ERR, false); busy = false; if (btn) { btn.disabled = false; btn.textContent = old; } return Promise.resolve(); }
    return loadLibs().catch(function (e) { e.libFail = true; throw e; }).then(function () { return makePdf(opts.model); }).then(function (o) {
      o.pdf.save(o.name);
      say('已產生：' + o.name + '（共 ' + o.pageCount + ' 頁）', true);
    }).catch(function (err) {
      say((err && err.libFail && err.message) || GEN_ERR, false);
    }).then(function () {
      busy = false;
      if (btn) { btn.disabled = false; btn.textContent = old; }
    });
  }

  root.AdvicePdf = { render: render, download: download, _buildHtml: buildHtml, _radarSvg: radarSvg, _trendSvg: trendSvg, _loadLibs: loadLibs, _makePdf: makePdf, CONTENT_H: CONTENT_H };
})(window);
