/* 導覽列「抽查」換成「健檢」：各頁的導覽列是寫死在各自的 html 裡，這裡統一把指向 spotcheck.html 的分頁改成指向 checkup.html 的「健檢」
   （圖示換成愛心、文字換成「健檢」，其餘分頁、目前頁標示、紅點都不動）。抽查頁本身改從健檢頁內的連結進入；第三期整併後這段可拿掉。 */
(function () {
  var tab = document.querySelector('a.ab-tab[href="spotcheck.html"]');
  if (!tab) return;
  tab.setAttribute('href', 'checkup.html');
  tab.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z"/></svg>健檢';
})();

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
   任何失敗都安靜忽略，不影響頁面其他功能。各頁的 client 在各自的 api 檔裡沒有對外，所以這裡只從 localStorage 讀
   supabase-js 預設的 sb-<專案代號>-auth-token 取目前的 access_token，建一個「不存 session、不換 token、不監聽登入事件」的 client，
   用 Authorization 標頭帶 token 呼叫 RPC。絕不呼叫 refresh、不寫任何 storage；讀不到或 token 過期（RPC 回錯誤）就當沒有紅點。
   頁面做完動作後可呼叫 window.AppBadge.refresh() 重抓。 */
(function () {
  var tab = document.querySelector('a.ab-tab[href="requests.html"]');
  var email = document.getElementById('whoEmail');
  if (!tab || !email) return;
  var badge = document.createElement('span');
  badge.className = 'ab-badge'; badge.hidden = true; badge.setAttribute('aria-label', '待處理數量');
  tab.appendChild(badge);
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
  function show(n) {
    n = Number(n);
    if (!(n > 0)) { badge.hidden = true; badge.textContent = ''; return; }
    badge.textContent = n > 99 ? '99+' : String(Math.floor(n));
    badge.hidden = false;
  }
  function refresh() {
    try {
      var sb = getClient();
      if (!sb) return Promise.resolve();
      return Promise.resolve(sb.rpc('exam_req_badge')).then(function (r) { if (r && !r.error) show(r.data); }, function () {});
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
