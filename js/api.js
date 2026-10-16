/* 名冊系統資料層：登入、讀寫、白話錯誤訊息。不把 session／token 寫進 console。 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  var PAGE = 1000;

  // 把資料庫／網路錯誤換成白話繁體中文（不顯示原始錯誤碼）
  function explain(err) {
    var code = err && err.code ? String(err.code) : '';
    var msg = err && err.message ? String(err.message).toLowerCase() : '';
    if (code === '42501' || code === 'PGRST301' || msg.indexOf('row-level security') >= 0 || msg.indexOf('permission denied') >= 0 || msg.indexOf('jwt') >= 0) {
      return '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';
    }
    if (code === '23505') return '這個員工編號已經存在，請換一個編號。';
    if (code === '23503') return '所選的門市不存在，請重新整理頁面後再試。';
    if (code === '23514') return '資料格式不符（員工編號須為 MI-0000 或 PT-0000，且暱稱與姓名至少填一個）。';
    if (code === '23502') return '有必填欄位沒填，請檢查後再儲存。';
    if (msg.indexOf('failed to fetch') >= 0 || msg.indexOf('networkerror') >= 0 || msg.indexOf('network') >= 0 || msg.indexOf('load failed') >= 0) {
      return '網路連線失敗，請檢查網路後再試一次。';
    }
    return '系統發生問題，請稍後再試；若持續發生請聯絡客服部。';
  }

  function fail(error) { var e = new Error(explain(error)); e.userMessage = e.message; throw e; }

  function wrap(p) {
    return p.then(function (r) { if (r.error) fail(r.error); return r; }, function (e) { fail(e); });
  }

  // 一律用目前頁面所在資料夾的 roster.html 組出完整網址
  function rosterUrl() { return new URL('roster.html', location.href).href; }

  window.Api = {
    explain: explain,
    getSession: function () {
      return sb.auth.getSession().then(function (r) { return r.data ? r.data.session : null; }, function () { return null; });
    },
    onSignedOut: function (cb) {
      sb.auth.onAuthStateChange(function (event) { if (event === 'SIGNED_OUT') cb(); });
    },
    signIn: function () {
      return wrap(sb.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: rosterUrl(), queryParams: { hd: '2motor.tw' } }
      }));
    },
    signOut: function () { return sb.auth.signOut().catch(function () {}); },
    // 自己的 app_users 那一列（查不到回 null）
    loadMe: function (email) {
      return wrap(sb.from('app_users').select('email,role,store_code').eq('email', email.toLowerCase()).maybeSingle())
        .then(function (r) { return r.data || null; });
    },
    loadStores: function () {
      return wrap(sb.from('stores').select('code,name').order('code')).then(function (r) { return r.data || []; });
    },
    // 分頁讀完（避免超過單次上限），不假設資料量
    loadEmployees: function () {
      var all = [];
      function next(from) {
        return wrap(sb.from('employees_with_tenure').select('*').order('id').range(from, from + PAGE - 1)).then(function (r) {
          var rows = r.data || [];
          all = all.concat(rows);
          return rows.length === PAGE ? next(from + PAGE) : all;
        });
      }
      return next(0);
    },
    insertEmployee: function (row) { return wrap(sb.from('employees').insert(row)); },
    // 回傳是否真的改到一列（RLS 擋掉時不會報錯而是 0 列）
    updateEmployee: function (id, patch) {
      return wrap(sb.from('employees').update(patch).eq('id', id).select('id')).then(function (r) {
        if (!r.data || r.data.length === 0) {
          var e = new Error('你沒有這個操作的權限，或這筆資料已不存在，請重新整理頁面。');
          e.userMessage = e.message; throw e;
        }
      });
    }
  };
})();
