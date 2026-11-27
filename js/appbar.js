/* 導覽列頭像：取登入信箱第一個字母（信箱由各頁原本的程式寫入 #whoEmail） */
(function () {
  var email = document.getElementById('whoEmail');
  var av = document.getElementById('whoAvatar');
  if (!email || !av) return;
  function sync() { av.textContent = (email.textContent || '').trim().charAt(0).toUpperCase(); }
  sync();
  new MutationObserver(sync).observe(email, { childList: true, characterData: true, subtree: true });
})();

/* 導覽列「待考回報」紅點：登入後（信箱被各頁寫入 #whoEmail 之後）呼叫資料庫函式 exam_req_badge()，大於 0 才顯示數字。
   （店長＝該回報待考但還沒回報的人數（已包含「已輔導未約考」的人，資料庫 exam_req_badge 已算好，前端不再另外加總）；
   客服部＝待處理回報＋待開通。不靠「已看」，點進頁面不會消。
   另外「成績單&考核後台」分頁有第二顆紅點，呼叫 improve_badge()＝店長還沒回填輔導的回填輔導紀錄數（客服部與店長皆同）；
   「登記&健檢」分頁有第三顆紅點，呼叫 spot_badge()＝異常回覆單還沒回填輔導的張數。）
   任何失敗都安靜忽略，不影響頁面其他功能。各頁的 client 在各自的 api 檔裡沒有對外，所以這裡只從 localStorage 讀
   supabase-js 預設的 sb-<專案代號>-auth-token 取目前的 access_token，建一個「不存 session、不換 token、不監聽登入事件」的 client，
   用 Authorization 標頭帶 token 呼叫 RPC。絕不呼叫 refresh、不寫任何 storage；讀不到或 token 過期（RPC 回錯誤）就當沒有紅點。
   頁面做完動作後可呼叫 window.AppBadge.refresh() 重抓。 */
(function () {
  var tab = document.querySelector('a.ab-tab[href="requests.html"]');
  var email = document.getElementById('whoEmail');
  if (!tab || !email) return;
  var badge = document.createElement('span');
  badge.className = 'ab-badge'; badge.hidden = true; badge.setAttribute('aria-label', '該回報待考但還沒回報的人數（客服部為待處理回報數）');
  tab.appendChild(badge);
  // 「登記&健檢」分頁的紅點（異常回覆單未回填輔導的張數，spot_badge()；不因點進去而消）
  var spotTab = document.querySelector('a.ab-tab[href="spotcheck.html"]');
  var spotBadge = null;
  if (spotTab) {
    spotBadge = document.createElement('span');
    spotBadge.className = 'ab-badge'; spotBadge.hidden = true; spotBadge.setAttribute('aria-label', '異常回覆單未回填輔導的張數');
    spotTab.appendChild(spotBadge);
  }
  // 「成績單&考核後台」分頁的紅點（店長還沒回填輔導的改善單數，improve_badge()；不因點進去而消）
  var impTab = document.querySelector('a.ab-tab[href="backoffice.html"]');
  var impBadge = null;
  if (impTab) {
    impBadge = document.createElement('span');
    impBadge.className = 'ab-badge'; impBadge.hidden = true; impBadge.setAttribute('aria-label', '還沒回填輔導的回填輔導紀錄數量');
    impTab.appendChild(impBadge);
  }
  // 目前 session 的 access_token（supabase-js 預設存在 localStorage 的 sb-<專案代號>-auth-token）；讀不到或解析失敗回 null
  function readToken(cfg) {
    try {
      var ref = String(cfg.SUPABASE_URL).replace(/^https?:\/\//, '').split('.')[0];
      if (!ref) return null;
      var raw = window.localStorage.getItem('sb-' + ref + '-auth-token');
      if (!raw) return null;
      var tok = JSON.parse(raw);
      return tok && typeof tok.access_token === 'string' && tok.access_token ? tok.access_token : null;
    } catch (e) { return null; }
  }
  function getClient() {
    try {
      var cfg = window.APP_CONFIG;
      if (!cfg || !window.supabase) return null;
      var token = readToken(cfg);
      if (!token) return null;
      return window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
        global: { headers: { Authorization: 'Bearer ' + token } }
      });
    } catch (e) { return null; }
  }
  function showOn(el, n) {
    n = Number(n);
    if (!(n > 0)) { el.hidden = true; el.textContent = ''; return; }
    el.textContent = n > 99 ? '99+' : String(Math.floor(n));
    el.hidden = false;
  }
  function show(n) { showOn(badge, n); }
  // 改善單紅點：資料庫還沒有 improve_badge 或呼叫失敗就安靜略過（維持原狀）
  function refreshImp(sb) {
    if (!impBadge) return Promise.resolve();
    return Promise.resolve(sb.rpc('improve_badge')).then(function (r) {
      if (!r || r.error) return;
      showOn(impBadge, r.data);
    }, function () {});
  }
  // 健檢紅點：資料庫還沒有 spot_badge 或呼叫失敗就安靜略過（維持原狀）
  function refreshSpot(sb) {
    if (!spotBadge) return Promise.resolve();
    return Promise.resolve(sb.rpc('spot_badge')).then(function (r) {
      if (!r || r.error) return;
      showOn(spotBadge, r.data);
      // 讓頁內（例如健檢單、預警榜頁）也能拿到張數，顯示「登記歷程」分頁紅點與導引條
      try {
        if (window.AppBadge) window.AppBadge.spot = Number(r.data) > 0 ? Number(r.data) : 0;
        if (typeof window.CustomEvent === 'function' && window.dispatchEvent) window.dispatchEvent(new window.CustomEvent('appbadge-spot', { detail: Number(r.data) > 0 ? Number(r.data) : 0 }));
      } catch (e) {}
    }, function () {});
  }
  // 店長端導覽順序：「待考回報」移到「成績單&考核後台」前面（其他角色順序不變）；查不到角色或失敗就維持原順序
  var reordered = false;
  function reorderForManager(sb) {
    if (reordered || !impTab || !impTab.parentNode || typeof impTab.parentNode.insertBefore !== 'function') return Promise.resolve();
    return Promise.resolve(sb.rpc('roster_my_role')).then(function (r) {
      if (!r || r.error || r.data !== 'store_manager' || reordered) return;
      reordered = true;
      impTab.parentNode.insertBefore(tab, impTab);
    }, function () {});
  }
  function refresh() {
    try {
      var sb = getClient();
      if (!sb) return Promise.resolve();
      reorderForManager(sb);
      // 待考回報數字＝exam_req_badge()（店長端已包含「已輔導未約考」的人，不再另外加總）
      var imp = refreshImp(sb);
      var spot = refreshSpot(sb);
      var both = Promise.all([imp, spot]);
      return Promise.resolve(sb.rpc('exam_req_badge')).then(function (r) {
        if (!r || r.error) return both;
        show(Number(r.data) > 0 ? Number(r.data) : 0); return both;
      }, function () { return both; });
    } catch (e) { return Promise.resolve(); }
  }
  window.AppBadge = { refresh: refresh, set: show };
  var started = false;
  function start() {
    if (started || !(email.textContent || '').trim()) return;
    started = true; refresh();
  }
  start();
  new MutationObserver(start).observe(email, { childList: true, characterData: true, subtree: true });
})();
