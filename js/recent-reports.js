/*
 * 考核後台「近期考核」分頁（原成績單頁 reports.html 的全部功能）。
 * 用法：RecentReports.init({ api: AssessApi, me: 目前登入者列, stores: [{code,name}], onFatal: 可選 })
 * 所有內部名稱都包在這個 IIFE 裡，與 backoffice.html 共用的狀態一律從 init 的參數傳入，不靠全域同名變數。
 * 需要的元素（backoffice.html 提供）：#rStore #rFrom #rTo #rVerdict #rKind #rSearch #rCount #rBody #rEmpty #rMore #rMoreBtn #rNote #rMsg #rLoading #rDlg
 * 純邏輯（篩選、搜尋、分頁、狀態與標籤）在 js/recent-reports-core.js，這裡只管畫面與資料讀寫。
 * 不把簽名網址或圖片路徑寫進 console。
 */
(function () {
  var C = window.RecentReportsCore;
  var DIMS = Scoring.DIMENSIONS, NA = Scoring.NOT_APPLICABLE;
  var ROLE_NOTE_CS = '客服部可看全部成績單，包含暫存中與已作廢，並可作廢已送出的成績單。';
  var ROLE_NOTE_OTHER = '只顯示已送出且未作廢的成績單；考官備註與備註附圖主管與店長也看得到；題組名稱、步驟與考點只有客服部看得到。';

  function $(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  var api = null, me = null, storeName = {};
  var all = [];            // 讀回來的全部成績單（原樣）
  var visible = [];        // 依身分過濾、由新到舊
  var shown = C.PAGE_SIZE;
  var started = false;

  function isCS() { return !!me && me.role === 'cs_admin'; }
  function isManager() { return !!me && me.role === 'store_manager'; }
  function errText(e) { return (e && e.userMessage) || api.explain(e); }
  function showMsg(t) { var m = $('rMsg'); m.textContent = t; m.hidden = !t; }

  // ====== 列表 ======
  function filters() {
    return { store: $('rStore').value, from: $('rFrom').value, to: $('rTo').value, verdict: $('rVerdict').value, kind: $('rKind').value, q: $('rSearch').value };
  }
  function statusTag(r) { var s = C.statusInfo(r); return '<span class="tag ' + s.cls + '">' + s.text + '</span>'; }
  function verdictTag(r) { var v = C.verdictInfo(r); return '<span class="tag ' + v.cls + '">' + esc(v.text) + '</span>'; }

  function rowHtml(r) {
    var cs = isCS(), chk = C.isCheckup(r);
    var ops = C.hasAdviceLink(r)
      ? '<a class="btn sm" href="' + esc(C.adviceUrl(r)) + '">建議單</a>'
      : '<button type="button" class="btn sm" data-detail="' + esc(r.id) + '">詳情</button>';
    return '<tr class="clickrow' + (r.status === 'voided' ? ' off' : '') + '" tabindex="0" data-id="' + esc(r.id) + '">' +
      '<td class="mono">' + esc(C.stamp(C.dateOf(r))) + '</td>' +
      '<td>' + esc(r.employee_label) + ' <span class="mono sub">' + esc(r.employee_id) + '</span></td>' +
      '<td>' + esc(r.store_name || storeName[r.store_code] || r.store_code) + '</td>' +
      '<td>' + (chk ? '<span class="tag chk">' + esc(C.checkupLabel(r)) + '</span>' : esc(r.tenure)) +
        (cs && r.tenure_source === '手動指定' ? ' <span class="tag unk">手動指定</span>' : '') +
        (cs && r.tenure_source === '考核期' ? ' <span class="tag out">考核期</span>' : '') + '</td>' +
      '<td class="num">' + (r.total_score == null ? '—' : esc(C.fmt(r.total_score))) + '</td>' +
      '<td>' + verdictTag(r) + '</td>' +
      '<td>' + statusTag(r) + '</td>' +
      '<td class="stick">' + ops + '</td></tr>';
  }

  function render() {
    var list = C.applyFilters(visible, filters(), me), p = C.paginate(list, shown);
    $('rBody').innerHTML = p.rows.map(rowHtml).join('');
    $('rEmpty').hidden = p.total > 0;
    $('rMore').hidden = !p.hasMore;
    $('rCount').textContent = C.countText(p.n, p.total);
  }
  function resetAndRender() { shown = C.PAGE_SIZE; render(); }

  function reload() {
    return api.loadSummaries().then(function (data) {
      all = data;
      visible = C.visibleRows(all, me);
      render();
    });
  }

  // ====== 圖片（簽名網址，過期自動重取）======
  function imgsHtml(it) {
    var list = (it.imgs || []).map(function (m, i) {
      var u = api.peekUrl(m.path);
      return '<div class="thumb"><button type="button" class="tb" data-zoom="' + esc(m.path) + '" data-alt="備註附圖 ' + (i + 1) + '" aria-label="放大檢視備註附圖 ' + (i + 1) + '"><img data-path="' + esc(m.path) + '"' + (u ? ' src="' + esc(u) + '"' : '') + ' alt="備註附圖 ' + (i + 1) + '"></button>' +
        '<div class="sz">備註附圖 ' + (i + 1) + '・' + C.fmtSize(m.size || 0) + '</div></div>';
    }).join('');
    return '<h3 style="font-size:14px;margin:12px 0 0">附圖</h3>' + (list ? '<div class="thumbs">' + list + '</div>' : '<p style="font-size:13px;color:var(--ink-2)">（無附圖）</p>');
  }
  function hydrateImages(root) {
    Array.prototype.forEach.call(root.querySelectorAll('img[data-path]'), function (img) {
      if (img.getAttribute('src')) return;
      api.signedUrl(img.getAttribute('data-path')).then(function (u) { if (img.isConnected) img.src = u; }, function () {});
    });
  }

  // ====== 詳細內容 ======
  function weakSpans(list) { return (list || []).map(function (w) { return '<span class="wk">' + esc(w) + '</span>'; }).join('') || '—'; }

  // 七面向雷達圖：各面向在所有題組的平均得分率（不適用、未評不計入）；最弱面向以資料庫算出的 weakest_dims 為準
  function radarBlock(items, weak) {
    var rows = DIMS.map(function (d) {
      var s = 0, n = 0;
      (items || []).forEach(function (it) {
        var lv = (it.levels || {})[d.name], p = Scoring.LEVELS[lv];
        if (lv !== NA && p !== undefined) { s += p; n++; }
      });
      return { name: d.name, pct: n ? s / n : null, weak: (weak || []).indexOf(d.name) >= 0 };
    });
    if (rows.every(function (r) { return r.pct === null; })) return '';
    return '<div class="chartwrap radar">' + Radar.svg(rows, '七面向得分率：' + rows.map(function (r) { return r.name + ' ' + (r.pct === null ? '無資料' : C.fmt(r.pct) + '%'); }).join('、')) + '</div>';
  }

  // 備註網址：只有 http／https 開頭才渲染成連結（其他如 javascript: 一律不成為連結）
  function noteUrlLink(it) {
    var u = C.safeNoteUrl(it.note_url);
    return u ? '<br><a href="' + esc(u) + '" target="_blank" rel="noopener noreferrer">備註網址</a>' : '';
  }
  function remarkHtml(it) {
    return '<div class="remark"><b>考官備註：</b>' + (it.note ? esc(it.note) : '（無）') + noteUrlLink(it) + '</div>' + imgsHtml(it);
  }
  function stepsHtml(it) {
    return '<details><summary class="link" style="cursor:pointer">步驟與考點</summary><ul style="list-style:none">' +
      (it.steps || []).map(function (s, k) {
        s = s && typeof s === 'object' ? s : {};
        return '<li class="stepli"><b>步驟 ' + (k + 1) + ' 考官操作</b><br>' + esc(s.action != null ? s.action : s.op) + '<br><b>考點</b><br>' + esc(s.point) + '</li>';
      }).join('') + '</ul></details>';
  }

  // 弱項追加題區塊（不算入總分、判定、最弱面向與雷達圖，只當輔導參考）
  function extraHead() {
    return '<div class="extra-sec"><h3>弱項追加題・不算入總分</h3><p class="exnote">追加題只記在成績單上當輔導參考，不算入總分、判定、最弱面向與上方雷達圖。</p>';
  }
  function extraDimRows(it, full) {
    var dp = it.dim_points || {};
    return DIMS.map(function (d) {
      var lv = (it.levels || {})[d.name], pt = dp[d.name];
      return full
        ? '<tr><td>' + esc(d.name) + '</td><td class="num">' + d.weight + '</td><td>' + (lv ? esc(lv) : '未評') + '</td><td class="num">' + (lv === NA ? '不適用' : (pt == null ? '—' : esc(C.fmt(pt)))) + '</td></tr>'
        : '<tr><td>' + esc(d.name) + '</td><td class="num">' + (pt == null ? '不適用' : esc(C.fmt(pt)) + ' / ' + d.weight) + '</td></tr>';
    }).join('');
  }
  // 客服部版：含題組名稱與步驟、考點
  function extrasCS(extras) {
    if (!extras.length) return '';
    var h = extraHead();
    extras.forEach(function (it, i) {
      h += '<div class="item"><span class="tag extra">追加題・不算總分</span> <span class="tag new">' + esc(it.category) + '</span> <span class="mono" style="font-size:13px">' + esc(it.code) + '</span> ' +
        '<b style="float:right">追加題分數 ' + (it.item_score == null ? '—' : esc(C.fmt(it.item_score))) + '</b><h4>追加題 ' + (i + 1) + '：' + esc(it.title) + '</h4>' + stepsHtml(it) +
        '<div class="scroll" style="margin-top:8px"><table><thead><tr><th>面向</th><th class="num">配分</th><th>等級</th><th class="num">得分</th></tr></thead><tbody>' + extraDimRows(it, true) + '</tbody></table></div>' +
        remarkHtml(it) + '</div>';
    });
    return h + '</div>';
  }
  // 主管／店長版：不含題組名稱、步驟、考點
  function extrasLimited(extras) {
    if (!extras.length) return '';
    var h = extraHead();
    extras.forEach(function (it, i) {
      h += '<div class="item"><span class="tag extra">追加題 ' + (i + 1) + '・不算總分</span> <span class="tag new">' + esc(it.category) + '</span> <span class="mono" style="font-size:13px">' + esc(it.code) + '</span> ' +
        '<b style="float:right">追加題分數 ' + (it.item_score == null ? '—' : esc(C.fmt(it.item_score))) + '</b><div class="scroll" style="margin-top:8px"><table><thead><tr><th>面向</th><th class="num">得分</th></tr></thead><tbody>' + extraDimRows(it, false) + '</tbody></table></div>' +
        remarkHtml(it) + '</div>';
    });
    return h + '</div>';
  }

  // 客服部：完整內容（題組名稱、步驟、考點、備註、作廢鈕都只在這個函式裡產生）
  function detailCS(r, items) {
    var weak = r.weakest_dims || [];
    var core = items.filter(function (x) { return !x.isExtra; }), extras = items.filter(function (x) { return !!x.isExtra; });
    var h = '<div class="dlg"><h2>成績單詳細內容</h2>';
    if (r.status === 'voided') h += '<div class="void-box">已作廢。原因：' + esc(r.void_reason || '') + '</div>';
    if (r.status === 'draft') h += '<div class="msg warn">這是暫存中的草稿，尚未結算送出。</div>';
    h += '<dl class="kv"><dt>日期</dt><dd>' + esc(C.stamp(C.dateOf(r))) + '</dd><dt>考官</dt><dd>' + esc(r.examiner_email) + '</dd>' +
      '<dt>考生</dt><dd>' + esc(r.employee_label) + '（' + esc(r.employee_id) + '）' + esc(r.store_name || r.store_code) + '</dd>' +
      '<dt>考核時身分</dt><dd>' + esc(r.tenure) + (C.isCheckup(r) ? ' <span class="tag chk">年度健檢</span>' : '') + (r.tenure_source === '手動指定' ? ' <span class="tag unk">手動指定</span>' : '') + (r.tenure_source === '考核期' ? ' <span class="tag out">考核期</span>' : '') + '</dd>' +
      '<dt>狀態</dt><dd>' + statusTag(r) + '</dd>' +
      '<dt>總分</dt><dd>' + (r.total_score == null ? '尚未結算' : esc(C.fmt(r.total_score)) + (r.pass_line ? '（合格線 ' + esc(r.pass_line) + ' 分）' : '')) + '</dd>' +
      '<dt>判定</dt><dd>' + (r.verdict ? '<span class="vbox ' + (C.VCLS[r.verdict] || 'unk') + '">' + esc(r.verdict) + '</span>' : '—') + '</dd>' +
      '<dt>最弱面向</dt><dd>' + weakSpans(weak) + '</dd></dl>' + radarBlock(core, weak);
    core.forEach(function (it, i) {
      var dp = it.dim_points || {};
      h += '<div class="item"><span class="tag new">' + esc(it.category) + '</span> <span class="mono" style="font-size:13px">' + esc(it.code) + '</span> ' +
        '<b style="float:right">題組分數 ' + (it.item_score == null ? '—' : esc(C.fmt(it.item_score))) + '</b><h4>題組 ' + (i + 1) + '：' + esc(it.title) + '</h4>' + stepsHtml(it) +
        '<div class="scroll" style="margin-top:8px"><table><thead><tr><th>面向</th><th class="num">配分</th><th>等級</th><th class="num">得分</th></tr></thead><tbody>' +
        DIMS.map(function (d) {
          var lv = it.levels[d.name], pt = dp[d.name];
          var isW = weak.indexOf(d.name) >= 0;
          return '<tr' + (isW ? ' class="weakrow"' : '') + '><td>' + esc(d.name) + (isW ? '（最弱）' : '') + '</td><td class="num">' + d.weight + '</td><td>' + (lv ? esc(lv) : '未評') + '</td><td class="num">' + (lv === NA ? '不適用' : (pt == null ? '—' : esc(C.fmt(pt)))) + '</td></tr>';
        }).join('') + '</tbody></table></div>' + remarkHtml(it) + '</div>';
    });
    h += extrasCS(extras);
    h += '<div class="actions">' + (C.canVoid(r, me) ? '<button class="btn danger" type="button" data-void="' + esc(r.id) + '">作廢這張成績單</button>' : '') +
      '<button class="btn" type="button" data-close="1">關閉</button></div></div>';
    return h;
  }

  // 總公司主管／店長：只有日期、考生、身分、總分、判定、最弱面向、題組分類／代號／分數／七面向分數、考官備註與附圖
  // （不產生題組名稱、步驟、考點、考官信箱、作廢鈕；也不查機密表；考官備註來自 assessment_items.note）
  function detailLimited(r, items) {
    var core = items.filter(function (x) { return !x.isExtra; }), extras = items.filter(function (x) { return !!x.isExtra; });
    var h = '<div class="dlg"><h2>成績單</h2><dl class="kv"><dt>日期</dt><dd>' + esc(C.stamp(C.dateOf(r))) + '</dd>' +
      '<dt>考生</dt><dd>' + esc(r.employee_label) + '（' + esc(r.employee_id) + '）' + esc(r.store_name || r.store_code) + '</dd>' +
      '<dt>考生身分</dt><dd>' + esc(r.tenure) + (C.isCheckup(r) ? ' <span class="tag chk">年度健檢</span>' : '') + '</dd>' +
      '<dt>總分</dt><dd>' + (r.total_score == null ? '—' : esc(C.fmt(r.total_score)) + (r.pass_line ? '（合格線 ' + esc(r.pass_line) + ' 分）' : '')) + '</dd>' +
      '<dt>判定</dt><dd>' + (r.verdict ? '<span class="vbox ' + (C.VCLS[r.verdict] || 'unk') + '">' + esc(r.verdict) + '</span>' : '—') + '</dd>' +
      '<dt>最弱面向</dt><dd>' + weakSpans(r.weakest_dims) + '</dd></dl>' + radarBlock(core, r.weakest_dims);
    core.forEach(function (it) {
      var dp = it.dim_points || {};
      h += '<div class="item"><span class="tag new">' + esc(it.category) + '</span> <span class="mono" style="font-size:13px">' + esc(it.code) + '</span> ' +
        '<b style="float:right">題組分數 ' + (it.item_score == null ? '—' : esc(C.fmt(it.item_score))) + '</b><div class="scroll" style="margin-top:8px"><table><thead><tr><th>面向</th><th class="num">得分</th></tr></thead><tbody>' +
        DIMS.map(function (d) {
          var pt = dp[d.name];
          return '<tr><td>' + esc(d.name) + '</td><td class="num">' + (pt == null ? '不適用' : esc(C.fmt(pt)) + ' / ' + d.weight) + '</td></tr>';
        }).join('') + '</tbody></table></div>' + remarkHtml(it) + '</div>';
    });
    h += extrasLimited(extras);
    h += '<div class="actions"><button class="btn" type="button" data-close="1">關閉</button></div></div>';
    return h;
  }

  // ====== 詳情視窗 ======
  var dlg = null, openToken = 0, openRow = null, downOnBackdrop = false;
  function closeDetail() {
    openToken++; openRow = null;
    removeVoidDlg(); removeLightbox();
    if (dlg.open) dlg.close();
    dlg.innerHTML = '';
  }

  function openDetail(id) {
    var r = visible.filter(function (x) { return x.id === id; })[0];
    if (!r) return;
    var token = ++openToken; openRow = r;
    dlg.innerHTML = '<div class="dlg"><h2>成績單詳細內容</h2><p role="status">載入中…</p><div class="actions"><button class="btn" type="button" data-close="1">關閉</button></div></div>';
    if (!dlg.open) dlg.showModal();
    var cs = isCS();
    (cs ? api.loadItemsFull(r.id) : api.loadItemsLimited(r.id)).then(function (items) {
      if (token !== openToken) return;
      dlg.innerHTML = cs ? detailCS(r, items) : detailLimited(r, items);
      hydrateImages(dlg);
    }, function (err) {
      if (token !== openToken) return;
      dlg.innerHTML = '<div class="dlg"><h2>成績單詳細內容</h2><div class="msg err" role="alert">' + esc(errText(err)) + '</div><div class="actions"><button class="btn" type="button" data-close="1">關閉</button></div></div>';
    });
  }

  // ====== 放大檢視（點擊時才建立，關閉就移除）======
  var lb = null;
  function removeLightbox() { if (lb) { var x = lb; lb = null; if (x.open) x.close(); x.remove(); } }
  function openLightbox(path, alt) {
    api.signedUrl(path).then(function (u) {
      removeLightbox();
      lb = document.createElement('dialog');
      lb.className = 'lb rr';
      lb.innerHTML = '<div class="dlg"><img alt="' + esc(alt) + '"><div class="actions"><button class="btn" type="button" id="lbClose">關閉</button></div></div>';
      var img = lb.querySelector('img');
      img.addEventListener('error', function () {
        if (img.getAttribute('data-retry')) return;
        img.setAttribute('data-retry', '1');
        api.forgetUrl(path);
        api.signedUrl(path).then(function (n) { img.src = n; }, function () {});
      });
      img.src = u;
      document.body.appendChild(lb);
      lb.querySelector('#lbClose').addEventListener('click', removeLightbox);
      lb.addEventListener('click', function (e) { if (e.target === lb) removeLightbox(); });
      lb.addEventListener('close', removeLightbox);
      lb.showModal();
    }, function (err) { showMsg(errText(err)); });
  }

  // ====== 作廢（只有客服部；對話框在點擊時才建立，其他身分的 DOM 裡不存在）======
  var voidDlg = null;
  function removeVoidDlg() { if (voidDlg) { var x = voidDlg; voidDlg = null; if (x.open) x.close(); x.remove(); } }
  function openVoidDlg(id) {
    if (!isCS()) return;
    var r = visible.filter(function (x) { return x.id === id; })[0];
    if (!r || !C.canVoid(r, me)) return;
    removeVoidDlg();
    voidDlg = document.createElement('dialog');
    voidDlg.className = 'rr';
    voidDlg.innerHTML = '<form class="dlg" novalidate><h2>作廢成績單</h2>' +
      '<p>作廢不會刪除紀錄，會保留作廢原因；店長與總公司主管將看不到這張成績單，之後可重新評分。</p>' +
      '<p style="margin-top:8px"><b>' + esc(r.employee_label) + '（' + esc(r.employee_id) + '）' + esc(C.stamp(C.dateOf(r))) + '</b></p>' +
      '<label class="field">作廢原因（必填）<textarea class="ctrl" id="vReason" placeholder="例如：考官誤選考生"></textarea></label>' +
      '<label class="chk"><input type="checkbox" id="vSure"><span>我確認要作廢這張成績單</span></label>' +
      '<div class="msg err" id="vErr" role="alert" hidden></div>' +
      '<div class="actions"><button class="btn" type="button" id="vNo">取消</button><button class="btn danger" type="submit" id="vYes" disabled>確認作廢</button></div></form>';
    document.body.appendChild(voidDlg);
    var reason = voidDlg.querySelector('#vReason'), sure = voidDlg.querySelector('#vSure'), yes = voidDlg.querySelector('#vYes'), err = voidDlg.querySelector('#vErr');
    var working = false;
    function sync() { yes.disabled = working || !(reason.value.trim() && sure.checked); }
    reason.addEventListener('input', sync); sure.addEventListener('change', sync);
    voidDlg.querySelector('#vNo').addEventListener('click', removeVoidDlg);
    voidDlg.querySelector('form').addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!isCS() || working) return;
      var t = reason.value.trim();
      if (!t || !sure.checked) { err.textContent = '請填作廢原因並勾選確認。'; err.hidden = false; return; }
      working = true; sync(); err.hidden = true;
      api.voidReport(r.id, t).then(function () {
        removeVoidDlg();
        return reload().then(function () { openDetail(r.id); }, function (er) {
          closeDetail();
          showMsg('已作廢，但重新載入列表失敗：' + errText(er) + ' 請重新整理頁面。');
        });
      }).catch(function (er) {
        working = false; sync();
        if (voidDlg) { err.textContent = errText(er); err.hidden = false; }
      });
    });
    voidDlg.showModal();
  }

  // ====== 啟動 ======
  function fillStoreSelect(stores) {
    $('rStore').innerHTML = '<option value="">全部門市</option>' +
      stores.map(function (s) { return '<option value="' + esc(s.code) + '">' + esc(s.name) + '</option>'; }).join('');
  }

  function wire() {
    dlg = $('rDlg');
    dlg.addEventListener('close', function () { if (!dlg.open) { openToken++; openRow = null; dlg.innerHTML = ''; } });
    // 點視窗外的空白處也能關閉（按下與放開都要在空白處，避免在內容裡拖曳選字時誤關）
    dlg.addEventListener('mousedown', function (e) { downOnBackdrop = (e.target === dlg); });
    dlg.addEventListener('click', function (e) {
      if (e.target === dlg && downOnBackdrop) { downOnBackdrop = false; closeDetail(); return; }
      if (e.target.closest('[data-close]')) { closeDetail(); return; }
      var z = e.target.closest('[data-zoom]');
      if (z) { openLightbox(z.dataset.zoom, z.dataset.alt || ''); return; }
      var v = e.target.closest('[data-void]');
      if (v && isCS()) openVoidDlg(v.dataset.void);
    });
    // 圖片載入失敗（簽名網址過期）自動重取一次
    document.addEventListener('error', function (e) {
      var img = e.target;
      if (!img || img.tagName !== 'IMG' || !img.hasAttribute('data-path') || img.getAttribute('data-retry')) return;
      img.setAttribute('data-retry', '1');
      var path = img.getAttribute('data-path');
      api.forgetUrl(path);
      api.signedUrl(path).then(function (u) { img.src = u; }, function () {});
    }, true);

    $('rBody').addEventListener('click', function (e) {
      if (e.target.closest('a')) return;      // 「建議單」連結照常跳轉，不開詳情
      var tr = e.target.closest('tr[data-id]');
      if (tr) openDetail(tr.dataset.id);
    });
    $('rBody').addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && e.target.matches && e.target.matches('tr[data-id]')) openDetail(e.target.dataset.id);
    });
    $('rMoreBtn').addEventListener('click', function () { shown += C.PAGE_SIZE; render(); });
    ['rStore', 'rFrom', 'rTo', 'rVerdict', 'rKind'].forEach(function (id) {
      $(id).addEventListener('change', resetAndRender);
      $(id).addEventListener('input', resetAndRender);
    });
    $('rSearch').addEventListener('input', resetAndRender);
  }

  function init(opts) {
    if (started) return;
    started = true;
    api = opts.api; me = opts.me;
    storeName = {};
    (opts.stores || []).forEach(function (s) { storeName[s.code] = s.name; });
    wire();
    fillStoreSelect(opts.stores || []);
    $('rStore').hidden = isManager();
    $('rNote').textContent = isCS() ? ROLE_NOTE_CS : ROLE_NOTE_OTHER;
    $('rLoading').hidden = false;
    $('rCount').textContent = '';
    $('rEmpty').hidden = true; $('rMore').hidden = true;
    reload().then(function () { $('rLoading').hidden = true; }, function (e) {
      $('rLoading').hidden = true;
      showMsg('近期考核載入失敗：' + errText(e) + ' 請重新整理頁面。');
    });
  }

  window.RecentReports = { init: init, reload: function () { return reload(); } };
})();
