/*
 * 健檢單 PDF 下載（checkup.html「健檢單」分頁每列的「下載 PDF」）。純邏輯在 js/checkup-sheet-core.js。
 * 流程：整理內容（CheckupSheetCore.buildModel）→ 截圖走簽名網址轉成圖檔資料 → 組 A4 版面 DOM
 *       → ReportPdfCore.layoutPages 分頁（紀錄頭、每張截圖各自一個區塊，不切半；截圖一張一列、接近內容欄全寬、等比不裁切）→ html2canvas 轉圖 → jsPDF 逐頁輸出。
 * html2canvas 1.4.1、jsPDF 2.5.1 只在第一次按下載時才動態載入（cdnjs，固定版本），做法同成績單 PDF（js/report-pdf.js）。
 * 不把健檢單內容寫進 console 或瀏覽器儲存。版面照 樣品/健檢改版樣品.html 的 B 分頁；固定 A4（794×1123 px）。
 * 依賴：CheckupSheetCore、ReportPdfCore（只用 layoutPages）、CheckupApi（signedUrl）。
 */
(function (root) {
  var Core = root.CheckupSheetCore, PageCore = root.ReportPdfCore;
  var LIBS = ['https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js',
              'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js'];
  var LIB_TIMEOUT = 20000, IMG_TIMEOUT = 8000, IMG_PARALLEL = 6;
  var LIB_ERR = 'PDF 產生工具載入失敗，請檢查網路後再試一次。';
  var GEN_ERR = '產生 PDF 失敗，請稍後再試一次；若持續發生請聯絡客服部。';
  var PAGE_W = 794, PAGE_H = 1123, TOP = 34, BOT = 44, CONTENT_H = PAGE_H - TOP - BOT, SCALE = 2;
  var LOGO = 'img/logo.png';
  var SHOT_W = 606;          // 截圖寬度上限＝內容欄寬（794 − 左右 40 − 日期欄 96 − 間距 12）；一張一列，等比放大、不裁切
  var SHOT_PAD = 16;          // 截圖區塊上下留白（與 CSS 相同）

  var CSS = '' +
'#csWrap{position:fixed;left:-10000px;top:0;width:794px;pointer-events:none}' +
'#csDoc{width:794px;background:#fff;color:#111;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang TC","Microsoft JhengHei","Noto Sans TC","Helvetica Neue",sans-serif;font-size:12px;line-height:1.5;text-align:left}' +
'#csDoc *{box-sizing:border-box;margin:0}' +
'#csDoc .blk{padding:4px 40px 12px}' +
'#csDoc .blk[data-type=row]{padding-top:0;padding-bottom:0}' +
'#csDoc .ph{background:#0A0A0A;color:#fff;padding:20px 28px;position:relative;border-radius:6px;overflow:hidden}' +
'#csDoc .ph::after{content:"";position:absolute;left:0;top:0;bottom:0;width:6px;background:#D9FF00}' +
'#csDoc .ph small{color:#D9FF00;font-weight:700;letter-spacing:1.5px;font-size:11px}' +
'#csDoc .ph h3{font-size:22px;margin:4px 0 2px;line-height:1.3;font-weight:800}' +
'#csDoc .ph p{font-size:13px;color:rgba(255,255,255,.75)}' +
'#csDoc .ph .logo{position:absolute;right:24px;top:18px;height:34px;width:auto}' +
'#csDoc .stats{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}' +
'#csDoc .stat{border:1px solid #E3E7ED;border-radius:14px;padding:12px 14px}' +
'#csDoc .stat b{display:block;font-size:26px;font-weight:800;line-height:1.2}' +
'#csDoc .stat span{font-size:12px;color:#4A4F5A;font-weight:600}' +
'#csDoc .stat.ok b{color:#16A34A}#csDoc .stat.bad b{color:#DC2626}' +
'#csDoc .ptitle{font-size:14px;font-weight:800;margin:0 0 6px;padding-left:8px;border-left:4px solid #D9FF00;line-height:1.3}' +
'#csDoc .star{padding-left:77px}' +        /* (內容欄 714 − 圖寬 560) / 2：用固定留白置中，不靠 margin:auto（html2canvas 轉圖時會偏移） */
'#csDoc .star svg{display:block}' +
'#csDoc .tophint{font-size:13px;color:#4A4F5A;text-align:center;margin-top:2px}' +
'#csDoc .tophint b{color:#0A0A0A}' +
'#csDoc .rec{display:grid;grid-template-columns:96px 1fr;gap:12px;padding:12px 0;border-top:1px solid #E3E7ED;font-size:13px;line-height:1.6}' +
'#csDoc .rec .d b{display:block;font-size:14px;margin-bottom:4px}' +
'#csDoc .tag{display:inline-block;padding:2px 10px;border-radius:999px;font-size:11px;font-weight:700}' +
'#csDoc .tag.ok{background:rgba(22,163,74,.12);color:#16A34A}#csDoc .tag.bad{background:rgba(220,38,38,.10);color:#DC2626}' +
'#csDoc .tag.old{background:#F3F5F8;color:#4A4F5A;margin-top:4px}' +
'#csDoc .dimtags{display:flex;flex-wrap:wrap;gap:4px;margin-bottom:6px}' +
'#csDoc .dimtags .tag{background:#0A0A0A;color:#D9FF00;padding:2px 8px}' +
'#csDoc .none{color:#4A4F5A;font-size:12px}' +
'#csDoc .why{color:#4A4F5A;overflow-wrap:anywhere}' +
'#csDoc .blk[data-type=shot]{padding:6px 40px 8px 148px}' +
'#csDoc .shot img{display:block;border-radius:6px;border:1px solid #E3E7ED}' +
'#csDoc .shot .bad{width:606px;height:56px;border-radius:6px;border:1px dashed #C3CAD5;background:#F3F5F8;display:flex;align-items:center;justify-content:center;font-size:12px;color:#94A3B8}' +
'#csDoc .pfoot{font-size:11px;color:#94A3B8;border-top:1px solid #E3E7ED;padding-top:10px;text-align:center}';

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function mmdd(d) { return String(d).slice(5).replace('-', '/'); }

  // ===== 版面 HTML：回傳一串 .blk 區塊（#csDoc 的直接子元素）；imgs 是 { 路徑: { src: 圖檔資料網址, w, h } | null }（null 代表載入失敗）=====
  var STAR_W = 560;   // 星狀圖顯示寬度（內容欄 714 的約 78%）
  function starHtml(counts) {
    var L = Core.starLayout(counts), h = Math.round(L.height * STAR_W / L.width);
    return L.svg.replace(' width="' + L.width + '" height="' + L.height + '"', ' width="' + STAR_W + '" height="' + h + '"');
  }
  function blk(type, inner, attrs) { return '<div class="blk" data-type="' + type + '"' + (attrs || '') + '>' + inner + '</div>'; }
  function buildHtml(m, imgs) {
    imgs = imgs || {};
    var h = '';
    h += blk('blk', '<div class="ph"><img class="logo" src="' + LOGO + '" alt=""><small>每季健檢單</small><h3>' + esc(m.name) + '　健檢單</h3><p>' +
      esc(m.store) + '　／　' + esc(m.quarterText) + '　／　員編 ' + esc(m.id) + '</p></div>');
    h += blk('blk', '<div class="stats"><div class="stat"><b>' + m.total + '</b><span>本季抽查次數</span></div>' +
      '<div class="stat ok"><b>' + m.good + '</b><span>優良回覆</span></div><div class="stat bad"><b>' + m.weak + '</b><span>待加強回覆</span></div></div>');
    h += blk('blk', '<div class="ptitle">可改善面向星狀圖（被勾次數，越外圈越需要加強）</div><div class="star">' + starHtml(m.counts) + '</div>' +
      '<div class="tophint">' + (m.top.length ? '被勾最多：<b>' + esc(m.top.join('、')) + '</b>（外圈＝' + Core.starScaleMax(m.counts) + ' 次）' : '本季沒有勾選可改善面向（外圈＝' + Core.starScaleMax(m.counts) + ' 次）') + '</div>');
    h += blk('title', '<div class="ptitle" style="margin-top:4px">抽查紀錄（共 ' + m.total + ' 筆）</div>');
    m.records.forEach(function (r) {
      // 紀錄頭（日期、判定、面向、說明）一個區塊；每張截圖各自一個區塊（一張一列，換頁時整張移到下一頁，不會切在中間）
      h += blk('row', '<div class="rec"><div class="d"><b>' + esc(mmdd(r.date)) + '</b><span class="tag ' + (r.isWeak ? 'bad' : 'ok') + '">' + esc(r.verdict) + '</span>' +
        (r.legacy != null ? '<br><span class="tag old">舊制分數 ' + esc(r.legacy) + '</span>' : '') + '</div><div>' +
        (r.dims.length ? '<div class="dimtags">' + r.dims.map(function (d) { return '<span class="tag">' + esc(d) + '</span>'; }).join('') + '</div>' : '<div class="none">這次沒有勾可改善面向</div>') +
        (r.note ? '<div class="why">' + esc(r.note) + '</div>' : '') + '</div></div>', r.shots.length ? ' data-head="1" data-keep="1"' : ' data-head="1"');
      r.shots.forEach(function (p, k) {
        var im = imgs[p];
        h += blk('shot', im && im.src
          ? '<div class="shot"><img alt="截圖 ' + (k + 1) + '" src="' + im.src + '" data-w="' + im.w + '" data-h="' + im.h + '" style="width:' + SHOT_W + 'px;height:auto"></div>'
          : '<div class="shot"><div class="bad">截圖無法載入</div></div>');
      });
    });
    h += blk('blk', '<div class="pfoot">本單由系統自動彙整，僅供改善參考，不計分。　產生日期 ' + esc(m.generated) + '　由 貳輪嶼 製作</div>', ' style="padding-top:14px"');
    return h;
  }

  // ===== DOM：掛載、量測、分頁 =====
  function mount(html) {
    var doc = root.document;
    if (!doc.getElementById('csStyle')) { var st = doc.createElement('style'); st.id = 'csStyle'; st.textContent = CSS; doc.head.appendChild(st); }
    var wrap = doc.createElement('div'); wrap.id = 'csWrap'; wrap.setAttribute('aria-hidden', 'true');
    wrap.innerHTML = '<div id="csDoc">' + html + '</div>';
    doc.body.appendChild(wrap);
    return wrap;
  }
  function waitImages(el) {   // 只有 LOGO 是網址圖；截圖已是資料網址（背景圖，瀏覽器需要一點時間解碼，量測不受影響）
    var imgs = Array.prototype.slice.call(el.querySelectorAll('img'));
    return Promise.all(imgs.map(function (im) {
      if (im.complete && im.naturalWidth) return null;
      return new Promise(function (ok) { im.addEventListener('load', ok); im.addEventListener('error', ok); setTimeout(ok, 5000); });
    }));
  }
  function measure(docEl) {
    var top0 = docEl.getBoundingClientRect().top;
    return Array.prototype.slice.call(docEl.querySelectorAll(':scope > .blk')).map(function (el) {
      var rc = el.getBoundingClientRect();
      return { el: el, top: rc.top - top0, h: rc.height, type: el.getAttribute('data-type'), forceBreak: false,
        keepNext: el.getAttribute('data-type') === 'title' || el.hasAttribute('data-keep') };
    });
  }
  // 截圖尺寸：第一張要和前面的紀錄頭（以及緊接在前的標題）排在同一頁，所以可用高度要扣掉它們；其餘整頁高度都可用
  function sizeShots(docEl) {
    var blks = Array.prototype.slice.call(docEl.querySelectorAll(':scope > .blk'));
    blks.forEach(function (el, i) {
      var im = el.querySelector('img[data-w]');
      if (!im) return;
      var used = 0, prev = blks[i - 1];
      if (prev && prev.hasAttribute('data-head') && prev.hasAttribute('data-keep')) {
        used += prev.getBoundingClientRect().height;
        var pp = blks[i - 2];
        if (pp && pp.getAttribute('data-type') === 'title') used += pp.getBoundingClientRect().height;
      }
      if (i === blks.length - 2) used += blks[i + 1].getBoundingClientRect().height;   // 最後一張要留頁尾的位置，頁尾才不會單獨成一頁
      var sz = Core.fitShot(+im.getAttribute('data-w'), +im.getAttribute('data-h'), SHOT_W, CONTENT_H - used - SHOT_PAD - 2);
      im.style.width = sz.w + 'px'; im.style.height = sz.h + 'px';
    });
  }
  function paginate(docEl) {
    sizeShots(docEl);
    var bl = measure(docEl);
    var lay = PageCore.layoutPages(bl, CONTENT_H);
    return {
      overflow: lay.overflow,
      pages: lay.pages.map(function (pg) { return pg.items.map(function (x) { var b = bl[x.i]; return { el: b.el, top: b.top, h: b.h }; }); })
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

  // ===== 截圖：簽名網址 → 圖檔資料網址＋原始寬高（取不到就留空，版面顯示「截圖無法載入」，不讓整份 PDF 失敗）=====
  function naturalSize(src) {
    return new Promise(function (ok) {
      var im = new root.Image(), done = false;
      function fin(r) { if (!done) { done = true; ok(r); } }
      im.onload = function () { fin({ src: src, w: im.naturalWidth || 0, h: im.naturalHeight || 0 }); };
      im.onerror = function () { fin(null); };
      setTimeout(function () { fin(null); }, IMG_TIMEOUT);
      im.src = src;
    }).then(function (r) { return r && r.w > 0 && r.h > 0 ? r : null; });
  }
  function fetchImage(path) {
    return root.CheckupApi.signedUrl(path).then(function (u) {
      var ctl = typeof AbortController === 'function' ? new AbortController() : null, tm = setTimeout(function () { if (ctl) ctl.abort(); }, IMG_TIMEOUT);
      return root.fetch(u, ctl ? { signal: ctl.signal } : undefined).then(function (res) {
        clearTimeout(tm);
        if (!res.ok) throw new Error('img');
        return res.blob();
      }).then(function (blob) {
        return new Promise(function (ok, bad) { var fr = new root.FileReader(); fr.onload = function () { ok(String(fr.result)); }; fr.onerror = bad; fr.readAsDataURL(blob); });
      });
    }).then(function (d) { return /^data:image\//.test(d) ? naturalSize(d) : null; }, function () { return null; });
  }
  // 回傳 { 路徑: { src, w, h } | null }（null＝載入失敗）
  function loadImages(m) {
    var paths = [], out = {};
    m.records.forEach(function (r) { r.shots.forEach(function (p) { if (paths.indexOf(p) < 0) paths.push(p); }); });
    var i = 0;
    function worker() {
      if (i >= paths.length) return Promise.resolve();
      var p = paths[i++];
      return fetchImage(p).then(function (d) { out[p] = d; }).then(worker);
    }
    var ws = [];
    for (var k = 0; k < Math.min(IMG_PARALLEL, paths.length); k++) ws.push(worker());
    return Promise.all(ws).then(function () { return out; });
  }

  // ===== 產生 PDF =====
  // 一頁一頁轉圖：把該頁的區塊複製到一個小容器再 html2canvas（截圖多、單的很長時，整份一張大畫布會超過瀏覽器畫布上限）
  function renderPage(blocks) {
    var doc = root.document, holder = doc.createElement('div');
    holder.id = 'csWrap'; holder.setAttribute('aria-hidden', 'true');
    var inner = doc.createElement('div'); inner.id = 'csDoc';
    blocks.forEach(function (b) { inner.appendChild(b.el.cloneNode(true)); });
    holder.appendChild(inner); doc.body.appendChild(holder);
    return root.html2canvas(inner, { scale: SCALE, backgroundColor: '#ffffff', useCORS: true, logging: false, scrollX: 0, scrollY: 0, width: PAGE_W, windowWidth: PAGE_W })
      .then(function (cv) { holder.remove(); return cv; }, function (e) { holder.remove(); throw e; });
  }
  function makePdf(m, imgs) {
    var wrap = mount(buildHtml(m, imgs)), docEl = wrap.firstChild;
    return waitImages(docEl).then(function () {
      var lay = paginate(docEl);
      wrap.remove();   // 量完就移掉；下面用複製的區塊逐頁轉圖
      var pdf = new root.jspdf.jsPDF({ orientation: 'p', unit: 'mm', format: 'a4', compress: true });
      return lay.pages.reduce(function (p, pg, pi) {
        return p.then(function () {
          return renderPage(pg).then(function (full) {
            var cv = root.document.createElement('canvas'); cv.width = PAGE_W * SCALE; cv.height = PAGE_H * SCALE;
            var cx = cv.getContext('2d'); cx.fillStyle = '#fff'; cx.fillRect(0, 0, cv.width, cv.height);
            cx.drawImage(full, 0, 0, full.width, Math.min(full.height, cv.height - TOP * SCALE), 0, TOP * SCALE, cv.width, Math.min(full.height, cv.height - TOP * SCALE));
            if (pi > 0) pdf.addPage('a4', 'p');
            pdf.addImage(cv.toDataURL('image/jpeg', 0.92), 'JPEG', 0, 0, 210, 297);
            pdf.setFontSize(9); pdf.setTextColor(120);
            pdf.text((pi + 1) + ' / ' + lay.pages.length, 105, 291, { align: 'center' });
          });
        });
      }, Promise.resolve()).then(function () {
        return { pdf: pdf, pageCount: lay.pages.length, name: Core.fileName(m), overflow: lay.overflow };
      });
    }).then(function (o) { wrap.remove(); return o; }, function (e) { wrap.remove(); throw e; });
  }

  var busy = false;
  // opts: { sum（CheckupSheetCore.summarize 的一筆）, year, quarter, storeName, btn, msgEl }
  function run(opts) {
    if (busy) return Promise.resolve();
    busy = true;
    var btn = opts.btn, msg = opts.msgEl, old = btn ? btn.textContent : '';
    function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'msg ' + (ok ? 'info' : 'err'); msg.hidden = !t; } }
    say('');
    if (btn) { btn.disabled = true; btn.textContent = '產生中…'; }
    var m = Core.buildModel(opts.sum, { year: opts.year, quarter: opts.quarter, storeName: opts.storeName, nowMs: Date.now() });
    var libs = loadLibs().catch(function (e) { e.libFail = true; throw e; });
    return Promise.all([loadImages(m), libs]).then(function (r) {
      var miss = 0;
      Object.keys(r[0]).forEach(function (p) { if (!r[0][p]) miss++; });
      return makePdf(m, r[0]).then(function (o) { o.miss = miss; return o; });
    }).then(function (o) {
      o.pdf.save(o.name);
      say('已產生：' + o.name + '（共 ' + o.pageCount + ' 頁）' + (o.miss ? '；有 ' + o.miss + ' 張截圖無法載入，已在 PDF 內標示。' : ''), true);
    }).catch(function (err) {
      say((err && err.libFail && err.message) || (err && err.userMessage) || GEN_ERR, false);
    }).then(function () {
      busy = false;
      if (btn) { btn.disabled = false; btn.textContent = old; }
    });
  }

  root.CheckupSheetPdf = { run: run, _buildHtml: buildHtml, _makePdf: makePdf, _loadLibs: loadLibs, _loadImages: loadImages, _paginate: paginate, _mount: mount, CONTENT_H: CONTENT_H };
})(window);
