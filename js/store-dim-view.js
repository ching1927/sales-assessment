/*
 * 各門市面向分析：畫面與下載（checkup.html「異常回覆預警榜」分頁，切到「各門市面向分析」時）。純邏輯在 js/store-dim-core.js。
 * 同一份 HTML 同時用在網頁上顯示與下載（PNG 圖片、A4 橫向一頁 PDF），所以看到什麼就下載到什麼。
 * html2canvas、jsPDF 只在第一次按下載時才動態載入（沿用 CheckupSheetPdf 的載入器）。
 * 不把排名內容寫進 console 或瀏覽器儲存。版面照 樣品/各門市面向星狀圖樣品.html（改成一張大星狀圖＋下方數字表）。
 * 依賴：StoreDimCore、CheckupSheetPdf（只用 _loadLibs）。
 *
 * m：{ from, to（'YYYY-MM' 起訖月）, sortKey（'total' 或 0~6，只影響表格列順序）, rows（StoreDimCore.rank 的結果）,
 *      store（門市代碼；空字串或找不到＝全公司）, generated（YYYY-MM-DD）}
 */
(function (root) {
  var Core = root.StoreDimCore;
  var PAGE_W = 1123, SCALE = 2, MARGIN = 34;   // 欄位多，下載用 A4 橫向寬度
  var LOGO = 'img/logo.png';
  var LIB_ERR = '下載工具載入失敗，請檢查網路後再試一次。';
  var GEN_ERR = '產生檔案失敗，請稍後再試一次；若持續發生請聯絡客服部。';

  var CSS = '' +
'.sdm{background:#fff;color:#111;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang TC","Microsoft JhengHei","Noto Sans TC","Helvetica Neue",sans-serif;font-size:14px;line-height:1.5;text-align:left}' +
'.sdm *{box-sizing:border-box;margin:0}' +
'.sdm .hd{background:#0A0A0A;color:#fff;padding:10px 24px;border-radius:8px;position:relative;margin-bottom:14px;overflow:hidden}' +
'.sdm .hd::after{content:"";position:absolute;left:0;top:0;bottom:0;width:6px;background:#D9FF00}' +
'.sdm .hd small{color:#D9FF00;font-weight:700;letter-spacing:1.5px;font-size:11px}' +
'.sdm .hd h3{font-size:20px;font-weight:800;line-height:1.3}' +
'.sdm .hd p{font-size:12.5px;color:rgba(255,255,255,.75);padding-right:90px}' +
'.sdm .hd .logo{position:absolute;right:20px;top:12px;height:30px;width:auto}' +
'.sdm .sum{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}' +
'.sdm .sc{border-radius:8px;padding:8px 12px}' +
'.sdm .sc small{display:block;font-size:11.5px;font-weight:800}' +
'.sdm .sc b{font-size:16px;line-height:1.4;display:block}' +
'.sdm .sc.g{background:#EAF2EE;color:#226347}.sdm .sc.r{background:#FBEDEB;color:#B53A2D}.sdm .sc.b{background:#EAF1FB;color:#1F5FB4}' +
'.sdm .tw{overflow-x:auto}' +
'.sdm table{min-width:900px;width:100%;border-collapse:collapse;font-size:14px}' +
'.sdm th{background:#F3F5F8;font-size:12.5px;padding:8px 6px;text-align:center;border-bottom:1px solid #E3E7ED;white-space:nowrap}' +
'.sdm td{padding:8px 6px;border-bottom:1px solid #E3E7ED;text-align:center;white-space:nowrap}' +
'.sdm th.nm,.sdm td.nm{text-align:left}' +
'.sdm td.nm{font-weight:700}' +
'.sdm td.rk{font-weight:900;font-size:17px;width:50px}' +
'.sdm .cell{border-radius:6px;padding:5px 2px;font-weight:700;min-width:62px}' +
'.sdm .cell small{display:block;font-weight:500;font-size:11px;opacity:.75}' +
'.sdm th.sel{background:#FFF3C4}' +
'.sdm td.sel{background:#FFFBD6;font-weight:700}' +
'.sdm tr.me td.nm{background:#FFFBD6}' +
'.sdm .you{font-size:11px;color:#8A6D00;font-weight:800;margin-left:8px}' +
'.sdm .top{font-size:12px;font-weight:800;color:#B53A2D}' +
'.sdm .none{color:#94A3B8;font-weight:400}' +
'.sdm .hint{font-size:12px;color:#6B7280;margin-top:10px;line-height:1.7}' +
'.sdm .rd{display:flex;flex-wrap:wrap;gap:16px 28px;align-items:center;margin-bottom:14px}' +
'.sdm .rd .chart{flex:1 1 300px;max-width:500px;min-width:0}' +
'.sdm .rd .chart svg{display:block;width:100%;height:auto}' +
'.sdm .rd .side{flex:1 1 300px;min-width:0}' +
'.sdm .rd .side .sum{grid-template-columns:1fr;margin:12px 0 0}' +
'.sdm .rd h4{font-size:20px;font-weight:800;line-height:1.3}' +
'.sdm .rd .wk{font-size:14px;color:#4A4F5A;margin-top:4px;line-height:1.7}' +
'.sdm .rd .wk b{color:#B53A2D}' +
'.sdm .leg{display:flex;gap:16px;font-size:12.5px;color:#4A4F5A;margin-top:8px;flex-wrap:wrap}' +
'.sdm .leg i{display:inline-block;width:22px;height:0;border-top:3px solid #1F6FD1;vertical-align:middle;margin-right:6px}' +
'.sdm .leg i.d{border-top:2px dashed #94A3B8}' +
'.sdm .rd .empty{min-height:200px;display:grid;place-items:center;color:#94A3B8;font-size:15px;text-align:center;border:1px dashed #D3D9E2;border-radius:12px;padding:16px}' +
'.sdm .gen{font-size:11px;color:#94A3B8;border-top:1px solid #E3E7ED;padding-top:10px;margin-top:16px;text-align:center}';

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  function ensureStyle() {
    var doc = root.document;
    if (doc.getElementById('sdmStyle')) return;
    var st = doc.createElement('style'); st.id = 'sdmStyle'; st.textContent = CSS; doc.head.appendChild(st);
  }

  // 紅色深淺＝比例相對全表最大比例
  function heat(p, max) {
    var a = max ? p / max : 0;
    return 'background:rgba(220,38,38,' + (0.08 + a * 0.5).toFixed(2) + ');color:' + (a > 0.7 ? '#7F1D1D' : '#1f2937');
  }
  function cardHtml(cls, title, g) {
    return '<div class="sc ' + cls + '"><small>' + esc(title) + '</small><b>' + (g ? esc(g.names.join('、')) + '　' + esc(g.value) : '—') + '</b></div>';
  }

  // 星狀圖：半徑＝1 − 被勾比例（越往外越穩、凹進去＝弱項）；紅點＝最弱面向。base 有值時多畫全公司灰色虛線
  function radarSvg(item, base, label) {
    var R = 135, cx = 220, cy = 192, n = 7, rad = Core.radii(item), wk = Core.weakest(item);
    function pt(i, k) { var a = -Math.PI / 2 + i * 2 * Math.PI / n; return [cx + R * k * Math.cos(a), cy + R * k * Math.sin(a)]; }
    function poly(vals) { return vals.map(function (v, i) { var p = pt(i, Math.max(0, Math.min(1, v))); return p[0].toFixed(1) + ',' + p[1].toFixed(1); }).join(' '); }
    var g = '';
    [0.25, 0.5, 0.75, 1].forEach(function (k) {
      g += '<polygon points="' + poly([k, k, k, k, k, k, k]) + '" fill="none" stroke="' + (k === 1 ? '#8F99A8' : '#D3D9E2') + '"/>';
    });
    for (var i = 0; i < n; i++) { var p = pt(i, 1); g += '<line x1="' + cx + '" y1="' + cy + '" x2="' + p[0].toFixed(1) + '" y2="' + p[1].toFixed(1) + '" stroke="#D3D9E2"/>'; }
    if (base) g += '<polygon points="' + poly(base) + '" fill="none" stroke="#94A3B8" stroke-width="2.4" stroke-dasharray="7 5"/>';
    g += '<polygon points="' + poly(rad) + '" fill="rgba(31,111,209,.18)" stroke="#1F6FD1" stroke-width="3"/>';
    rad.forEach(function (v, i) {
      var p = pt(i, v), w = wk.idx.indexOf(i) >= 0;
      g += '<circle cx="' + p[0].toFixed(1) + '" cy="' + p[1].toFixed(1) + '" r="' + (w ? 7 : 4.5) + '" fill="' + (w ? '#DC2626' : '#1F6FD1') + '" stroke="#fff" stroke-width="1.5"/>';
    });
    Core.SHORT.forEach(function (t, i) {
      var p = pt(i, 1.16), a = p[0] < cx - 4 ? 'end' : p[0] > cx + 4 ? 'start' : 'middle', w = wk.idx.indexOf(i) >= 0;
      g += '<text x="' + p[0].toFixed(1) + '" y="' + (p[1] + 5).toFixed(1) + '" font-size="15" text-anchor="' + a + '" fill="' + (w ? '#B53A2D' : '#334155') + '" font-weight="' + (w ? 800 : 600) + '">' + esc(t) + '</text>';
    });
    return '<svg viewBox="0 0 440 384" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="' + esc(label) + ' 面向星狀圖">' + g + '</svg>';
  }

  function sheetHtml(m) {
    var key = Core.normKey(m.sortKey), rows = m.rows || [], sm = Core.summary(rows, key), mx = Core.maxRate(rows), lab = Core.keyLabel(key);
    var isTotal = key === 'total';
    var label = Core.monthLabel(m.from, m.to);
    var item = Core.pickItem(rows, m.store), isAll = !item.store_code, wk = Core.weakest(item);
    var head = '<tr><th>名次</th><th class="nm">門市</th><th>待加強回覆筆數</th>' +
      Core.DIMS.map(function (d, i) { return '<th class="' + (key === i ? 'sel' : '') + '">' + esc(d) + '</th>'; }).join('') +
      (isTotal ? '<th class="sel">合計</th>' : '') + '<th>最常被勾</th></tr>';
    var body = rows.map(function (r) {
      var cells = r.counts.map(function (c, i) {
        if (r.rates[i] == null) return '<td><span class="none">—</span></td>';
        return '<td><div class="cell" style="' + heat(r.rates[i], mx) + '">' + Core.formatPct(c, r.weak) + '<small>' + c + ' 次</small></div></td>';
      }).join('');
      return '<tr class="' + (r.mine ? 'me' : '') + '"><td class="rk">' + (r.rank == null ? '<span class="none">—</span>' : r.rank) + '</td>' +
        '<td class="nm">' + esc(r.store_name) + (r.mine ? '<span class="you">← 你的門市</span>' : '') + '</td><td>' + r.weak + '</td>' + cells +
        (isTotal ? '<td class="sel">' + (r.weak > 0 ? '平均每筆勾 ' + esc(Core.formatAvg(r)) + ' 個面向' : '<span class="none">—</span>') + '</td>' : '') +
        '<td class="top">' + (r.tops.length ? esc(r.tops.join('、')) : '—') + '</td></tr>';
    }).join('');
    var top = sm.topDim ? { names: sm.topDim.names, value: sm.topDim.count + ' 次' } : null;
    var chart, summary;
    if (item.weak > 0) {
      var base = isAll ? null : Core.radii(Core.companyTotal(rows));
      chart = radarSvg(item, base, item.store_name) +
        '<div class="leg"><span><i></i>' + (isAll ? '全公司' : '該門市') + '</span>' + (base ? '<span><i class="d"></i>全公司</span>' : '') + '</div>';
      summary = '<div class="wk">期間：' + esc(label) + '<br>待加強回覆：<b>' + item.weak + '</b> 筆<br>最弱面向：<b>' +
        (wk.names.length ? esc(wk.names.join('、')) + '（' + Math.round(wk.rate * 100) + '%）' : '—') + '</b></div>';
    } else {
      chart = '<div class="empty">這段期間沒有待加強回覆</div>';
      summary = '<div class="wk">期間：' + esc(label) + '<br>待加強回覆：<b>0</b> 筆</div>';
    }
    return '<div class="hd"><img class="logo" src="' + LOGO + '" alt=""><small>STORE DIMENSION RADAR</small><h3>各門市面向分析｜' + esc(label) + '</h3>' +
      '<p>登記時被勾選的「可改善面向」，依門市彙整；越往外＝該面向越少被勾（越穩），凹進去的地方＝弱項，紅點＝最弱面向。</p></div>' +
      '<div class="rd"><div class="chart">' + chart + '</div><div class="side"><h4>' + esc(item.store_name) + (!isAll && item.mine ? '<span class="you">← 你的門市</span>' : '') + '</h4>' + summary +
      '<div class="sum">' + cardHtml('g', '被勾比例最低（' + lab + '）', sm.best) + cardHtml('r', '被勾比例最高（' + lab + '）', sm.worst) +
      cardHtml('b', '全公司最常被勾的面向', top) + '</div></div></div>' +
      '<div class="tw"><table><thead>' + head + '</thead><tbody>' + body + '</tbody></table></div>' +
      '<p class="hint">・星狀圖半徑＝1 − 被勾比例；表格紅色越深＝該面向被勾的比例越高（越需要加強）；表格依「排序依據」排列，不影響星狀圖。<br>' +
      '・比例＝該面向被勾次數 ÷ 該門市期間內有勾面向的待加強回覆筆數；只算待加強回覆，優良回覆勾的面向、舊制紀錄不計入。<br>' +
      '・「全部面向合計」＝各面向被勾次數加總 ÷ 筆數，即平均每筆勾幾個面向，可能大於 1。<br>' +
      '・只顯示各門市彙總，不含登記內容與人員姓名。</p>' +
      '<p class="gen">本表由系統自動彙整，僅供改善參考，不計分。　產生日期 ' + esc(m.generated || '') + '　由 貳輪嶼 製作</p>';
  }

  // ===== 下載（作法同 StoreRankingView）=====
  function waitImages(el) {
    return Promise.all(Array.prototype.map.call(el.querySelectorAll('img'), function (im) {
      if (im.complete && im.naturalWidth) return null;
      return new Promise(function (ok) { im.addEventListener('load', ok); im.addEventListener('error', ok); setTimeout(ok, 5000); });
    }));
  }
  // 掛一份固定寬的隱藏版面、轉成 canvas（scale 2），轉完就移掉
  function capture(m) {
    ensureStyle();
    var doc = root.document, wrap = doc.createElement('div');
    wrap.setAttribute('aria-hidden', 'true');
    wrap.style.cssText = 'position:fixed;left:-10000px;top:0;width:' + PAGE_W + 'px;pointer-events:none';
    wrap.innerHTML = '<div class="sdm" style="width:' + PAGE_W + 'px;padding:' + MARGIN + 'px 40px">' + sheetHtml(m) + '</div>';
    doc.body.appendChild(wrap);
    var el = wrap.firstChild;
    return root.CheckupSheetPdf._loadLibs().catch(function () { throw new Error(LIB_ERR); }).then(function () {
      return waitImages(el);
    }).then(function () {
      return root.html2canvas(el, { scale: SCALE, backgroundColor: '#ffffff', useCORS: true, logging: false, scrollX: 0, scrollY: 0, width: PAGE_W, windowWidth: PAGE_W });
    }).then(function (cv) { wrap.remove(); return cv; }, function (e) { wrap.remove(); throw e; });
  }
  function fail(e) {
    var er = new Error((e && e.message === LIB_ERR) ? LIB_ERR : GEN_ERR); er.userMessage = er.message; throw er;
  }
  function downloadPng(m) {
    var name = Core.monthFileBase(m.from, m.to) + '.png';
    return capture(m).then(function (cv) {
      return new Promise(function (ok, bad) {
        cv.toBlob(function (blob) {
          if (!blob) { bad(new Error('blob')); return; }
          var url = root.URL.createObjectURL(blob), a = root.document.createElement('a');
          a.href = url; a.download = name; root.document.body.appendChild(a); a.click(); a.remove();
          setTimeout(function () { root.URL.revokeObjectURL(url); }, 4000);
          ok(name);
        }, 'image/png');
      });
    }).catch(fail);
  }
  // A4 橫向一頁：寬度撐滿頁面、高度依比例；內容太高時等比縮小（置中）放進一頁
  function downloadPdf(m) {
    var name = Core.monthFileBase(m.from, m.to) + '.pdf';
    return capture(m).then(function (cv) {
      var pdf = new root.jspdf.jsPDF({ orientation: 'l', unit: 'mm', format: 'a4', compress: true });
      var w = 297, h = cv.height / cv.width * 297;
      if (h > 210) { w = w * 210 / h; h = 210; }
      pdf.addImage(cv.toDataURL('image/jpeg', 0.92), 'JPEG', (297 - w) / 2, 0, w, h);
      pdf.save(name);
      return name;
    }).catch(fail);
  }

  root.StoreDimView = { html: sheetHtml, ensureStyle: ensureStyle, downloadPng: downloadPng, downloadPdf: downloadPdf };
})(window);
