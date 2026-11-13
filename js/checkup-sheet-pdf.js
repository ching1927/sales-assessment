/*
 * 健檢單 PDF 下載（checkup.html「健檢單」分頁每列的「下載 PDF」）。純邏輯在 js/checkup-sheet-core.js。
 * 流程：整理內容（CheckupSheetCore.buildModel）→ 截圖走簽名網址轉成圖檔資料 → 組 A4 版面 DOM
 *       → ReportPdfCore.layoutPages 分頁（紀錄頭、每張截圖各自一個區塊，不切半；截圖一張一列、接近內容欄全寬、等比不裁切）→ html2canvas 轉圖 → jsPDF 逐頁輸出。
 * html2canvas 1.4.1、jsPDF 2.5.1 只在第一次按下載時才動態載入（cdnjs，固定版本），做法同成績單 PDF（js/report-pdf.js）。
 * 不把健檢單內容寫進 console 或瀏覽器儲存。版面照 樣品/健檢單星狀圖對比樣品.html；第 4 季多「年度對比與分析」頁（接在第一頁小結之後、從新頁開始，登記紀錄再從新頁接續）；固定 A4（794×1123 px）。
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
  var CARD_FOOT_H = 36;      // 頁尾區塊高度（分頁時要留給它）
  var CARD_TITLE_H = 48;     // 「登記紀錄」標題區塊高度（第一頁要扣掉）

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
'#csDoc .chart svg,#csDoc .line svg{display:block}' +
'#csDoc .line{padding-left:78px}' +   /* (內容欄 714 − 圖寬 557) / 2 */
'#csDoc .legend{text-align:center;font-size:13px;color:#4A4F5A;margin-top:4px}' +
'#csDoc .legend span{display:inline-block;margin:0 11px;vertical-align:middle}' +
'#csDoc .legend svg{display:inline-block;vertical-align:middle;margin-right:7px}' +
'#csDoc .legend .tag0{padding:2px 10px;border-radius:999px;font-size:12px;font-weight:700;background:#F3F5F8}' +
'#csDoc .hint{font-size:13px;color:#4A4F5A;text-align:center;margin-top:4px}' +
'#csDoc .hint b{color:#0A0A0A}' +
'#csDoc .analysis{border:1px solid #E3E7ED;border-radius:14px;padding:14px 16px;font-size:14px;line-height:1.75;background:#FAFBFC}' +
'#csDoc .cards{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}' +
'#csDoc .card{border-radius:8px;padding:10px 12px;min-height:74px}' +
'#csDoc .card small{display:block;font-size:11px;font-weight:800;margin-bottom:4px}' +
'#csDoc .card b{display:block;font-size:15px;line-height:1.4}' +
'#csDoc .chips{text-align:center;margin-top:6px}' +
'#csDoc .chip{display:inline-block;border:1.5px solid #C3CAD5;border-radius:999px;padding:3px 11px;margin:3px 3px;font-size:12px;font-weight:700;background:#fff}' +
'#csDoc .chip svg{display:inline-block;vertical-align:middle;margin-right:5px}' +
'#csDoc .chip.on{background:#0A0A0A;color:#D9FF00;border-color:#0A0A0A}' +
'#csDoc .alist .arow{display:grid;grid-template-columns:56px 1fr;gap:12px;padding:8px 0;border-bottom:1px dashed #E3E7ED;font-size:14px;line-height:1.7}' +
'#csDoc .alist .arow:last-child{border-bottom:none}' +
'#csDoc .atag{display:block;height:24px;line-height:24px;border-radius:4px;color:#fff;font-size:12px;font-weight:800;text-align:center;margin-top:2px}' +
'#csDoc .adv{color:#4A4F5A;font-size:13px;margin-top:2px}' +
'#csDoc td.bg-green{background:#EAF2EE}' +
'#csDoc td.bg-red{background:#FBEDEB;color:#B53A2D;font-weight:800}' +
'#csDoc td.rn{color:#B53A2D;font-weight:800}' +
'#csDoc small.df{font-size:10px;font-weight:800;margin-left:4px}' +
'#csDoc small.df.up{color:#226347}#csDoc small.df.down{color:#B53A2D}' +
'#csDoc .tlegend{font-size:12px;color:#4A4F5A;margin-top:8px}' +
'#csDoc .tlegend span{display:inline-block;margin-right:18px}' +
'#csDoc .tlegend i{display:inline-block;width:12px;height:12px;border:1px solid;vertical-align:middle;margin-right:5px}' +
'#csDoc table.yt{width:100%;border-collapse:collapse;font-size:13px;margin-top:6px}' +
'#csDoc table.yt th,#csDoc table.yt td{border-bottom:1px solid #E3E7ED;padding:5px 6px;text-align:center}' +
'#csDoc table.yt th:first-child,#csDoc table.yt td:first-child{text-align:left}' +
'#csDoc table.yt th{background:#F3F5F8;font-weight:700}' +
'#csDoc table.yt td.tot{font-weight:800;background:rgba(217,255,0,.25)}' +
'#csDoc table.yt td.na{color:#94A3B8}' +
'#csDoc td small.sub{display:block;font-size:11px;color:#94A3B8;font-weight:400}' +
'#csDoc .blk[data-type=card]{padding:0 40px 10px}' +
'#csDoc .ccard{position:relative;border-radius:14px;overflow:hidden;background:#ECEEF1;padding-left:8px;display:flex;flex-direction:column}' +
'#csDoc .ccard.hasshot{height:470px}' +
'#csDoc .cstripe{position:absolute;left:0;top:0;bottom:0;width:8px}' +
'#csDoc .chead{display:flex;align-items:center;justify-content:space-between;padding:10px 14px;border-bottom:1px solid #D5D8DD}' +
'#csDoc .cdate{display:flex;align-items:baseline}' +
'#csDoc .cdate b{font-size:30px;font-weight:800;line-height:1.1;letter-spacing:.5px;color:#111}' +
'#csDoc .cdate .wk{font-size:18px;font-weight:700;color:#4A4F5A;margin-left:8px}' +
'#csDoc .cdate .seq{font-size:16px;font-weight:800;color:#111;background:#D9FF00;border:1.5px solid #111;border-radius:999px;padding:0 10px;margin-left:10px;align-self:center;line-height:1.35}' +
'#csDoc .cbadge{display:block;color:#fff;font-size:19px;font-weight:800;border-radius:999px;padding:4px 16px 4px 11px;line-height:23px;white-space:nowrap}' +
'#csDoc .cbadge svg{display:inline-block;vertical-align:middle;width:23px;height:23px;margin-right:6px}' +
'#csDoc .cbody{display:flex;flex-direction:column;padding:10px 14px 12px 10px;flex:1;min-height:0}' +
'#csDoc .cbody > * + *{margin-top:8px}' +
'#csDoc .dimrow{display:flex;flex-wrap:wrap;align-items:center}' +
'#csDoc .dimrow .lab{font-size:12px;font-weight:800;letter-spacing:1px;color:#5B6270;margin-right:8px;white-space:nowrap}' +
'#csDoc .dimtag{font-size:15px;font-weight:800;border-radius:10px;padding:3px 14px;line-height:1.4;margin:2px 8px 2px 0}' +
'#csDoc .cnote{background:#fff;border-radius:10px;padding:7px 14px;font-size:15px;line-height:1.5;color:#222;overflow-wrap:anywhere}' +
'#csDoc .cnote .nl{display:inline-block;font-size:12px;font-weight:800;color:#5B6270;background:#E6E9ED;border-radius:6px;padding:0 7px;margin-right:8px;line-height:1.5;vertical-align:1px}' +
'#csDoc .clegacy{font-size:11px;color:#7B8494;line-height:1.4}' +
'#csDoc .cframe{flex:1;min-height:0;position:relative}' +
'#csDoc .cframe img{position:absolute;display:block;border:1px solid #AEB5C0;border-radius:8px;box-shadow:0 4px 14px rgba(17,24,39,.25)}' +
'#csDoc .cframe .fail{position:absolute;left:14px;right:14px;top:14px;bottom:30px;border:1px dashed #AEB5C0;border-radius:8px;background:rgba(255,255,255,.55);display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;color:#5B6270}' +
'#csDoc .cframe .fail b{font-size:16px;font-weight:700}' +
'#csDoc .cframe .fail small{font-size:12px;margin-top:4px}' +
'#csDoc .cframe .cap{position:absolute;right:2px;bottom:0;font-size:12px;font-weight:700;color:#333;background:rgba(255,255,255,.82);border-radius:999px;padding:1px 10px}' +
'#csDoc .pfoot{font-size:11px;color:#94A3B8;border-top:1px solid #E3E7ED;padding-top:10px;text-align:center}';

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }

  // ===== 版面 HTML：回傳一串 .blk 區塊（#csDoc 的直接子元素）；imgs 是 { 路徑: { src: 圖檔資料網址, w, h } | null }（null 代表載入失敗）=====
  var CHART_W = 714;   // 圖寬＝內容欄全寬（單季與全年綜合星狀圖）
  var LINE_W = 557;    // 折線圖寬度（內容欄 714 的約 78%）；用固定留白置中，不靠 margin:auto（html2canvas 轉圖時會偏移）
  var C = Core.COLORS;
  var SCALE_HINT = '圖的算法：分數 ＝ 1 − 被勾次數 ÷ 登記次數。<b>越外圈越好</b>（外圈 100％＝整季沒被勾；圓心 0％＝每次紀錄都被勾），越往內縮越需要加強。';
  function sized(L, w) {   // 依寬度縮放 SVG 的顯示大小（viewBox 不變）
    return L.svg.replace(' width="' + L.width + '" height="' + L.height + '"', ' width="' + w + '" height="' + Math.round(L.height * w / L.width) + '"');
  }
  function lineSwatch(color, w, dash) { return '<svg width="38" height="12"><line x1="2" y1="6" x2="36" y2="6" stroke="' + color + '" stroke-width="' + w + '"' + (dash ? ' stroke-dasharray="' + dash + '"' : '') + '/></svg>'; }
  function curSwatch() { return '<svg width="38" height="14"><rect x="2" y="1" width="34" height="12" fill="rgba(217,255,0,.45)"/><line x1="2" y1="7" x2="36" y2="7" stroke="#111" stroke-width="2.5"/></svg>'; }
  function blk(type, inner, attrs) { return '<div class="blk" data-type="' + type + '"' + (attrs || '') + '>' + inner + '</div>'; }
  // 帶色塊標籤的條列（小結與年度分析共用）
  function itemsHtml(items) {
    return '<div class="alist">' + items.map(function (it) {
      return '<div class="arow"><span class="atag" style="background:' + Core.TAG_COLOR[it.tag] + '">' + esc(it.tag) + '</span><div class="atxt">' + esc(it.text) +
        (it.advice ? '<div class="adv">建議：' + esc(it.advice) + '</div>' : '') + '</div></div>';
    }).join('') + '</div>';
  }
  var CARD_STYLE = {
    strong: ['全年強項', C.greenBg, C.green, C.greenTx], weak: ['最需要加強', C.redBg, C.red, C.redTx],
    improve: ['Q4 進步最多', C.blueBg, C.blue, C.blueTx], decline: ['Q4 需要留意', C.goldBg, C.gold, C.goldTx]
  };
  function cardsHtml(qs) {
    return '<div class="cards">' + Core.yearCards(qs).map(function (c) {
      var st = CARD_STYLE[c.kind];
      return '<div class="card" style="background:' + st[1] + ';border-left:4px solid ' + st[2] + '"><small style="color:' + st[3] + '">' + esc(c.title) + '</small><b' + (c.text ? '' : ' class="none"') + ' style="color:' + (c.text ? '#111' : '#6B7280') + '">' + esc(c.text || '—') + '</b></div>';
    }).join('') + '</div>';
  }
  function chipsHtml() {
    return '<div class="chips"><span class="chip on">重點三條</span>' + Core.DIMS.map(function (d, i) {
      return '<span class="chip"><svg width="26" height="16" viewBox="0 0 26 16"><line x1="1" y1="8" x2="25" y2="8" stroke="' + Core.DIM_COLORS[i] + '" stroke-width="3"' + (Core.DIM_DASH[i] ? ' stroke-dasharray="' + Core.DIM_DASH[i] + '"' : '') + '/>' + Core.markerSvg(i, 13, 8, 5) + '</svg>' + esc(d) + '</span>';
    }).join('') + '</div>';
  }
  function tableHtml(qs) {
    var tot = Core.totalModel(qs), tm = Core.yearTableModel(qs);
    var rows = tm.map(function (r) {
      return '<tr><td' + (r.nameRed ? ' class="rn"' : '') + '>' + esc(r.name) + '<small class="sub">' + esc(r.sub) + '</small></td>' + r.cells.map(function (c) {
        if (!c.has) return '<td class="na">—</td>';
        return '<td class="' + (c.bg ? 'bg-' + c.bg : '') + '">' + c.pct + '%' + (c.diff ? '<small class="df ' + c.diff.dir + '">' + (c.diff.dir === 'up' ? '▲' : '▼') + c.diff.n + '</small>' : '') + '</td>';
      }).join('') + '<td class="tot' + (r.total.bg ? ' bg-' + r.total.bg : '') + '">' + r.total.pct + '%</td></tr>';
    }).join('');
    return '<table class="yt"><thead><tr><th>面向（分數，越高越好）</th><th>Q1</th><th>Q2</th><th>Q3</th><th>Q4</th><th>全年綜合</th></tr></thead><tbody>' + rows +
      '<tr><td>登記次數</td>' + qs.map(function (q) { return q && q.checks > 0 ? '<td>' + q.checks + '</td>' : '<td class="na">—</td>'; }).join('') + '<td class="tot">' + tot.checks + '</td></tr></tbody></table>' +
      '<div class="tlegend"><span><i style="background:' + C.greenBg + ';border-color:' + C.green + '"></i>85% 以上（綠底）</span><span><i style="background:' + C.redBg + ';border-color:' + C.red + '"></i>低於 60%（紅底）</span><span>▲▼ 為與上一季相比</span></div>';
  }
  var FOOT_HTML = function (m) { return blk('blk', '<div class="pfoot">本單由系統自動彙整，僅供改善參考，不計分。　產生日期 ' + esc(m.generated) + '　由 貳輪嶼 製作</div>', ' style="padding-top:14px"'); };
  // 年度健檢單（只有第四季才有）：頁首、4 張摘要卡、全年綜合星狀圖、四季折線圖、全年數值表、年度分析
  function buildYearHtml(m) {
    var qs = m.yearQs, h = '';
    h += blk('blk', '<div class="ph"><img class="logo" src="' + LOGO + '" alt=""><small>年度對比與分析</small><h3>' + esc(m.name) + '　年度健檢單</h3><p>' +
      esc(m.store) + '　／　' + esc(m.year) + ' 年全年　／　員編 ' + esc(m.id) + '</p></div>');
    h += blk('blk', cardsHtml(qs));
    h += blk('blk', '<div class="ptitle">全年綜合（全年被勾次數 ÷ 全年登記次數）</div><div class="chart">' + sized(Core.totalSvg(qs), CHART_W) + '</div>' +
      '<div class="hint">藍色範圍越往外越好，<b style="color:' + C.redTx + '">紅色虛線是 60% 待加強線</b>，落在線內的面向優先改善。</div>');
    h += blk('blk', '<div class="ptitle">各面向四季變化</div><div class="line">' + sized(Core.lineChartSvg(qs), LINE_W) + '</div>' + chipsHtml() +
      '<div class="hint">預設只上色三條重點線，其他為灰色。</div>');
    h += blk('blk', '<div class="ptitle">全年數值表</div>' + tableHtml(qs));
    h += blk('blk', '<div class="ptitle">年度分析</div><div class="analysis">' + itemsHtml(m.yearItems) + '</div>');
    h += FOOT_HTML(m);
    return h;
  }
  // ===== 登記截圖卡片（風格 D1 淺灰；每張截圖一張卡片）；笑臉與驚嘆號用 SVG，不用 emoji =====
  var ICON_SMILE = '<svg viewBox="0 0 34 34" aria-hidden="true"><circle cx="17" cy="17" r="15" fill="none" stroke="#fff" stroke-width="3"/><circle cx="11.5" cy="13.5" r="2.3" fill="#fff"/><circle cx="22.5" cy="13.5" r="2.3" fill="#fff"/><path d="M9.5 20.5c1.8 4.2 4.6 5.8 7.5 5.8s5.7-1.6 7.5-5.8" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/></svg>';
  var ICON_EXC = '<svg viewBox="0 0 34 34" aria-hidden="true"><circle cx="17" cy="17" r="15" fill="#fff"/><path d="M17 8.5v10" stroke="' + Core.CARD.bad + '" stroke-width="4" stroke-linecap="round"/><circle cx="17" cy="25" r="2.4" fill="' + Core.CARD.bad + '"/></svg>';
  function cardHtml(c, imgs, newPage) {
    var K = Core.CARD, col = c.isWeak ? K.bad : K.ok;
    var badge = '<span class="cbadge" style="background:' + col + '">' + (c.isWeak ? ICON_EXC : ICON_SMILE) + esc(c.verdict) + '</span>';
    var head = '<div class="chead"><div class="cdate"><b>' + esc(c.md) + '</b><span class="wk">' + esc(c.wk) + '</span>' + (c.seq ? '<span class="seq">' + esc(c.seq) + '</span>' : '') + '</div>' + badge + '</div>';
    var dims = c.dimIdx.length ? '<div class="dimrow"><span class="lab">可改善面向</span>' + c.dimIdx.map(function (i) { return '<span class="dimtag" style="background:' + K.dim[i].bg + ';color:' + K.dim[i].tx + '">' + esc(Core.DIMS[i]) + '</span>'; }).join('') + '</div>' : '';
    var note = c.note ? '<div class="cnote"><span class="nl">說明</span>' + esc(c.note) + '</div>' : '';
    var legacy = c.legacy != null ? '<div class="clegacy">舊制分數 ' + esc(c.legacy) + '</div>' : '';
    var frame = '';
    if (c.hasShot) {
      var im = imgs && imgs[c.shot];
      frame = '<div class="cframe">' + (im && im.src ? '<img alt="' + esc(c.cap) + '" src="' + im.src + '" data-w="' + im.w + '" data-h="' + im.h + '">' : '<div class="fail"><b>截圖載入失敗</b><small>可私訊客服部確認聊天室網址</small></div>') + '<span class="cap">' + esc(c.cap) + '</span></div>';
    }
    return blk('card', '<div class="ccard' + (c.hasShot ? ' hasshot' : '') + '" style="border-left:0"><div class="cstripe" style="background:' + col + '"></div>' + head + '<div class="cbody">' + dims + note + legacy + frame + '</div></div>', newPage ? ' data-break="1"' : '');
  }

  // 季度健檢單（所有季都有，含第四季）：頁首、登記次數、單季星狀圖（含上季對比）、小結、當季登記紀錄與截圖
  function buildQuarterHtml(m, imgs) {
    imgs = imgs || {};
    var h = '', hasPrev = !!(m.prev && m.prev.checks > 0);
    h += blk('blk', '<div class="ph"><img class="logo" src="' + LOGO + '" alt=""><small>每季健檢單</small><h3>' + esc(m.name) + '　健檢單</h3><p>' +
      esc(m.store) + '　／　' + esc(m.quarterText) + '　／　員編 ' + esc(m.id) + '</p></div>');
    h += blk('blk', '<div class="stats"><div class="stat"><b>' + m.total + '</b><span>本季登記次數</span></div>' +
      '<div class="stat ok"><b>' + m.good + '</b><span>優良回覆</span></div><div class="stat bad"><b>' + m.weak + '</b><span>待加強回覆</span></div></div>');
    h += blk('blk', '<div class="ptitle">面向分數星狀圖（越外圈越好）' + (hasPrev ? '　對比：' + esc(m.prevName) : '') + '</div><div class="chart">' + sized(Core.quarterCompareSvg(m.cur, hasPrev ? m.prev : null), CHART_W) + '</div>' +
      '<div class="legend"><span>' + curSwatch() + '實線＝本季（' + m.cur.checks + ' 次紀錄）</span>' +
      (hasPrev ? '<span>' + lineSwatch('#0669EB', 2.2, '8 5') + '虛線＝上一季，對比：' + esc(m.prevName) + '（' + m.prev.checks + ' 次紀錄）</span>' : '<span class="tag0">上季無紀錄，只畫本季實線</span>') +
      '<span>' + lineSwatch(C.red, 1.8, '6 4') + '紅色虛線＝60% 待加強線</span></div>' +
      '<div class="hint">' + SCALE_HINT + '</div>');
    h += blk('blk', '<div class="ptitle">本季小結</div><div class="analysis">' + itemsHtml(m.items) + '</div>');
    h += blk('title', '<div class="ptitle" style="margin-top:4px">登記紀錄（共 ' + m.total + ' 筆）</div>', ' data-break="1"');
    // 登記紀錄：一張截圖一張卡片；分頁由 Core.paginateCards 決定（每頁第一張卡片強制換頁，一頁 2 張，卡片不會被切半）
    var CARDS = Core.paginateCards(Core.buildCards(m.records), { pageH: CONTENT_H, firstOffset: CARD_TITLE_H, footH: CARD_FOOT_H });
    CARDS.forEach(function (pg, pi) {
      pg.forEach(function (c, ci) { h += cardHtml(c, imgs, pi > 0 && ci === 0); });
    });
    h += blk('blk', '<div class="pfoot">本單由系統自動彙整，僅供改善參考，不計分。　產生日期 ' + esc(m.generated) + '　由 貳輪嶼 製作</div>', ' style="padding-top:6px"');
    return h;
  }

  // kind：'quarter'（季度健檢單，預設）或 'year'（年度健檢單，只有第四季）
  function buildHtml(m, imgs, kind) { return kind === 'year' ? buildYearHtml(m) : buildQuarterHtml(m, imgs); }

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
      return { el: el, top: rc.top - top0, h: rc.height, type: el.getAttribute('data-type'), forceBreak: el.hasAttribute('data-break'),
        keepNext: el.getAttribute('data-type') === 'title' || el.hasAttribute('data-keep') };
    });
  }
  // 卡片裡的截圖：在截圖框內等比縮放置中（contain，不裁切）；四周留 14px，下方多留 16px 給「截圖 n/N」小膠囊
  function fitCards(docEl) {
    Array.prototype.forEach.call(docEl.querySelectorAll('.cframe'), function (fr) {
      var im = fr.querySelector('img[data-w]');
      if (!im) return;
      var fw = fr.clientWidth, fh = fr.clientHeight, w = +im.getAttribute('data-w'), h = +im.getAttribute('data-h'), M = 14, CAP = 16;
      var k = Math.min((fw - 2 * M) / w, (fh - 2 * M - CAP) / h), W = Math.round(w * k), H = Math.round(h * k);
      im.style.width = W + 'px'; im.style.height = H + 'px';
      im.style.left = Math.round((fw - W) / 2) + 'px'; im.style.top = Math.round((fh - CAP - H) / 2) + 'px';
    });
  }
  function paginate(docEl) {
    fitCards(docEl);
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
  function makePdf(m, imgs, kind) {
    var wrap = mount(buildHtml(m, imgs, kind)), docEl = wrap.firstChild;
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
        return { pdf: pdf, pageCount: lay.pages.length, name: kind === 'year' ? Core.fileNameYear(m) : Core.fileName(m), overflow: lay.overflow };
      });
    }).then(function (o) { wrap.remove(); return o; }, function (e) { wrap.remove(); throw e; });
  }

  // 上一季（年度檔另抓全年）的紀錄：沿用 CheckupApi.sheetInspections；店長只讀得到自己門市（RLS）
  function fetchContext(opts) {
    var rg = opts.kind === 'year' ? Core.yearRange(opts.year) : Core.contextRange(opts.year, opts.quarter);
    return root.CheckupApi.sheetInspections(rg.start, rg.end).catch(function (e) {
      var er = new Error('讀取上一季（年度）紀錄失敗：' + ((e && e.userMessage) || GEN_ERR)); er.userMessage = er.message; throw er;
    });
  }

  // 季度與年度兩顆按鈕各自有「產生中」狀態；實際轉圖共用同一份隱藏 DOM，所以排隊一個一個做
  var busy = { quarter: false, year: false }, queue = Promise.resolve();
  // opts: { sum（CheckupSheetCore.summarize 的一筆）, year, quarter, storeName, kind: 'quarter'|'year', btn, msgEl }
  function run(opts) {
    var kind = opts.kind === 'year' ? 'year' : 'quarter';
    if (busy[kind]) return Promise.resolve();
    busy[kind] = true;
    opts._old = opts.btn ? opts.btn.textContent : '';
    if (opts.btn) { opts.btn.disabled = true; opts.btn.textContent = '產生中…'; }   // 排隊中也先顯示
    var job = queue.then(function () { return runOne(opts, kind); });
    queue = job.catch(function () {});
    return job;
  }
  function runOne(opts, kind) {
    var btn = opts.btn, msg = opts.msgEl, old = opts._old;
    function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'msg ' + (ok ? 'info' : 'err'); msg.hidden = !t; } }
    say('');
    var libs = loadLibs().catch(function (e) { e.libFail = true; throw e; });
    var m;
    return Promise.all([fetchContext(opts), libs]).then(function (c) {
      m = Core.buildModel(opts.sum, { year: opts.year, quarter: opts.quarter, storeName: opts.storeName, nowMs: Date.now(), ctxRows: c[0], yearRows: kind === 'year' ? c[0] : null });
      return loadImages(m);
    }).then(function (imgsRes) {
      var r = [imgsRes];
      var miss = 0;
      Object.keys(r[0]).forEach(function (p) { if (!r[0][p]) miss++; });
      return makePdf(m, r[0], kind).then(function (o) { o.miss = miss; return o; });
    }).then(function (o) {
      o.pdf.save(o.name);
      say('已產生：' + o.name + '（共 ' + o.pageCount + ' 頁）' + (o.miss ? '；有 ' + o.miss + ' 張截圖無法載入，已在 PDF 內標示。' : ''), true);
    }).catch(function (err) {
      say((err && err.libFail && err.message) || (err && err.userMessage) || GEN_ERR, false);
    }).then(function () {
      busy[kind] = false;
      if (btn) { btn.disabled = false; btn.textContent = old; }
    });
  }

  root.CheckupSheetPdf = { run: run, _buildHtml: buildHtml, _buildQuarterHtml: buildQuarterHtml, _buildYearHtml: buildYearHtml, _makePdf: makePdf, _loadLibs: loadLibs, _loadImages: loadImages, _paginate: paginate, _mount: mount, CONTENT_H: CONTENT_H };
})(window);
