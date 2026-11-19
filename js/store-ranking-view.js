/*
 * 各門市異常回覆預警榜：畫面與下載（checkup.html「異常回覆預警榜」分頁）。純邏輯在 js/store-ranking-core.js。
 * 同一份 HTML 同時用在網頁上顯示與下載（PNG 圖片、A4 一頁 PDF），所以看到什麼就下載到什麼。
 * html2canvas 1.4.1、jsPDF 2.5.1 只在第一次按下載時才動態載入（沿用 CheckupSheetPdf 的載入器，cdnjs、固定版本）。
 * 不把排名內容寫進 console 或瀏覽器儲存。版面照 樣品/黃單門市排名樣品.html。
 * 依賴：StoreRankingCore、CheckupSheetPdf（只用 _loadLibs）。
 */
(function (root) {
  var Core = root.StoreRankingCore;
  var PAGE_W = 794, PAGE_H = 1123, SCALE = 2, MARGIN = 34;
  var LOGO = 'img/logo.png';
  var LIB_ERR = '下載工具載入失敗，請檢查網路後再試一次。';
  var GEN_ERR = '產生檔案失敗，請稍後再試一次；若持續發生請聯絡客服部。';

  var CSS = '' +
'.srk{background:#fff;color:#111;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang TC","Microsoft JhengHei","Noto Sans TC","Helvetica Neue",sans-serif;font-size:14px;line-height:1.5;text-align:left}' +
'.srk *{box-sizing:border-box;margin:0}' +
'.srk .hd{background:#0A0A0A;color:#fff;padding:10px 24px;border-radius:8px;position:relative;margin-bottom:14px;overflow:hidden}' +
'.srk .hd::after{content:"";position:absolute;left:0;top:0;bottom:0;width:6px;background:#D9FF00}' +
'.srk .hd small{color:#D9FF00;font-weight:700;letter-spacing:1.5px;font-size:11px}' +
'.srk .hd h3{font-size:20px;font-weight:800;line-height:1.3}' +
'.srk .hd p{font-size:12.5px;color:rgba(255,255,255,.75);padding-right:90px}' +
'.srk .hd .logo{position:absolute;right:20px;top:12px;height:30px;width:auto}' +
'.srk .sum{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}' +
'.srk .sc{border-radius:8px;padding:8px 12px}' +
'.srk .sc small{display:block;font-size:11.5px;font-weight:800}' +
'.srk .sc b{font-size:16px;line-height:1.4;display:block}' +
'.srk .sc.g{background:#EAF2EE;color:#226347}.srk .sc.r{background:#FBEDEB;color:#B53A2D}.srk .sc.b{background:#EAF1FB;color:#1F5FB4}' +
'.srk table{width:100%;border-collapse:collapse;font-size:15px}' +
'.srk th{background:#F3F5F8;font-size:12.5px;padding:8px 6px;text-align:center;border-bottom:1px solid #E3E7ED;white-space:nowrap}' +
'.srk td{padding:8px 6px;border-bottom:1px solid #E3E7ED;text-align:center;white-space:nowrap}' +
'.srk th.nm,.srk td.nm{text-align:left}' +
'.srk td.nm{font-weight:700}' +
'.srk td.rk{font-weight:900;font-size:17px;width:54px}' +
'.srk td.bc{width:34%;text-align:left;min-width:140px}' +
'.srk .track{background:#F3F5F8;border-radius:6px;height:16px;overflow:hidden}' +
'.srk .fill{height:100%;border-radius:6px;background:#1F6FD1}' +
'.srk tr.me td{background:#FFFBD6}' +
'.srk .you{font-size:11px;color:#8A6D00;font-weight:800;margin-left:10px}' +
'.srk tr.best td.rk{color:#226347}.srk tr.worst td.rk{color:#B53A2D}' +
'.srk tr.best .fill{background:#10B981}.srk tr.worst .fill{background:#EF4444}' +
'.srk .none{color:#94A3B8;font-weight:400}' +
'.srk .hint{font-size:12px;color:#6B7280;margin-top:10px;line-height:1.7}' +
'.srk .gen{font-size:11px;color:#94A3B8;border-top:1px solid #E3E7ED;padding-top:10px;margin-top:16px;text-align:center}';

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  function ensureStyle() {
    var doc = root.document;
    if (doc.getElementById('srkStyle')) return;
    var st = doc.createElement('style'); st.id = 'srkStyle'; st.textContent = CSS; doc.head.appendChild(st);
  }

  // m: { year, period, sortKey, ranked（StoreRankingCore.rank 的結果）, generated（YYYY-MM-DD）}
  function cardHtml(cls, title, g, tail) {
    return '<div class="sc ' + cls + '"><small>' + title + '</small><b>' + (g ? esc(g.names.join('、')) + '　' + esc(g.value) : '—') + '</b></div>' + (tail || '');
  }
  function sheetHtml(m) {
    var key = m.sortKey === 'tot' ? 'tot' : 'avg', ranked = m.ranked || [], sm = Core.summary(ranked, key);
    var rks = ranked.filter(function (r) { return r.rank != null; }).map(function (r) { return r.rank; });
    var bestRk = rks.length ? rks[0] : null, worstRk = sm.worst ? rks[rks.length - 1] : null;
    var rows = ranked.map(function (r) {
      var cls = (r.mine ? 'me ' : '') + (bestRk != null && r.rank === bestRk ? 'best ' : '') + (worstRk != null && r.rank === worstRk ? 'worst' : '');
      return '<tr class="' + cls.trim() + '"><td class="rk">' + (r.rank == null ? '<span class="none">—</span>' : r.rank) + '</td>' +
        '<td class="nm">' + esc(r.store_name) + (r.mine ? '<span class="you">← 你的門市</span>' : '') + '</td>' +
        '<td>' + r.tickets + '</td><td>' + r.headcount + '</td><td><b>' + (r.avg == null ? '<span class="none">—</span>' : Core.formatAvg(r)) + '</b></td>' +
        '<td class="bc"><div class="track"><div class="fill" style="width:' + r.barPct + '%"></div></div></td></tr>';
    }).join('');
    return '<div class="hd"><img class="logo" src="' + LOGO + '" alt=""><small>REPLY ALERT BOARD</small><h3>各門市異常回覆預警榜｜' + esc(Core.periodLabel(m.year, m.period)) + '</h3>' +
      '<p>異常回覆＝判定為待加強回覆的單；被作廢的不算；依開單當時所屬門市計算。名次越前＝' + (key === 'avg' ? '平均每人異常回覆越少' : '異常回覆越少') + '。</p></div>' +
      '<div class="sum">' + cardHtml('g', '異常回覆最少', sm.best) + cardHtml('r', '異常回覆最多', sm.worst) +
      '<div class="sc b"><small>全公司異常回覆</small><b>' + sm.total + ' 張</b></div></div>' +
      '<table><thead><tr><th>名次</th><th class="nm">門市</th><th>異常回覆張數</th><th>人數</th><th>平均每人</th><th>視覺比較（' + (key === 'avg' ? '平均每人' : '異常回覆總張數') + '）</th></tr></thead><tbody>' + rows + '</tbody></table>' +
      '<p class="hint">・名次：' + (key === 'avg' ? '平均每人張數' : '異常回覆總張數') + '少的在前，相同並列。<br>・人數＝目前在職且已上線的業務人數。<br>・只顯示各門市的張數彙總，不含異常回覆內容與人員姓名。</p>' +
      '<p class="gen">本表由系統自動彙整，僅供改善參考，不計分。　產生日期 ' + esc(m.generated || '') + '　由 貳輪嶼 製作</p>';
  }

  // ===== 下載 =====
  function waitImages(el) {
    return Promise.all(Array.prototype.map.call(el.querySelectorAll('img'), function (im) {
      if (im.complete && im.naturalWidth) return null;
      return new Promise(function (ok) { im.addEventListener('load', ok); im.addEventListener('error', ok); setTimeout(ok, 5000); });
    }));
  }
  // 掛一份固定 794px 寬的隱藏版面、轉成 canvas（scale 2），轉完就移掉
  function capture(m) {
    ensureStyle();
    var doc = root.document, wrap = doc.createElement('div');
    wrap.setAttribute('aria-hidden', 'true');
    wrap.style.cssText = 'position:fixed;left:-10000px;top:0;width:' + PAGE_W + 'px;pointer-events:none';
    wrap.innerHTML = '<div class="srk" style="width:' + PAGE_W + 'px;padding:' + MARGIN + 'px 40px">' + sheetHtml(m) + '</div>';
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
    var name = Core.fileBase(m.year, m.period) + '.png';
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
  // A4 一頁：寬度撐滿頁面、高度依比例；內容太高時等比縮小（置中）放進一頁
  function downloadPdf(m) {
    var name = Core.fileBase(m.year, m.period) + '.pdf';
    return capture(m).then(function (cv) {
      var pdf = new root.jspdf.jsPDF({ orientation: 'p', unit: 'mm', format: 'a4', compress: true });
      var w = 210, h = cv.height / cv.width * 210;
      if (h > 297) { w = w * 297 / h; h = 297; }
      pdf.addImage(cv.toDataURL('image/jpeg', 0.92), 'JPEG', (210 - w) / 2, 0, w, h);
      pdf.save(name);
      return name;
    }).catch(fail);
  }

  root.StoreRankingView = { html: sheetHtml, ensureStyle: ensureStyle, downloadPng: downloadPng, downloadPdf: downloadPdf, PAGE_H: PAGE_H };
})(window);
