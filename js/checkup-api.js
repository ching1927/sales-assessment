/*
 * 每年健檢資料層（只給 checkup.html 用）：登入檢查與五個資料庫函式。
 * 函式、參數、欄位以 supabase/README_checkup.md 第三節為準。
 * 寫入一律走 sb.rpc；權限由資料庫把關。資料庫函式丟的繁中訊息（P0001）直接顯示。
 * 不把 session／token 寫進 console 或網址列。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);

  var NO_PERM = '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';

  // 把錯誤換成白話繁體中文（資料庫函式自己丟的中文訊息直接顯示）
  function explain(err) {
    if (err && err.userMessage) return err.userMessage;
    var code = err && err.code ? String(err.code) : '';
    var raw = err && err.message ? String(err.message) : '';
    var msg = raw.toLowerCase();
    var status = err && (err.status || err.statusCode) ? String(err.status || err.statusCode) : '';
    if (code === 'P0001' && /[一-鿿]/.test(raw)) return raw === '沒有權限' ? NO_PERM : raw;
    if (code === '42501' || code === 'PGRST301' || msg.indexOf('row-level security') >= 0 || msg.indexOf('permission denied') >= 0 ||
        msg.indexOf('jwt') >= 0 || status === '401' || status === '403') return NO_PERM;
    if (msg.indexOf('failed to fetch') >= 0 || msg.indexOf('networkerror') >= 0 || msg.indexOf('network') >= 0 || msg.indexOf('load failed') >= 0) {
      return '網路連線失敗，請檢查網路後再試一次。';
    }
    return '系統發生問題，請稍後再試；若持續發生請聯絡客服部。';
  }

  function fail(error) { var e = new Error(explain(error)); e.userMessage = e.message; throw e; }
  function wrap(p) {
    return p.then(function (r) { if (r.error) fail(r.error); return r; }, function (e) { fail(e); });
  }

  window.CheckupApi = {
    explain: explain,

    // ---- 登入與身分 ----
    getSession: function () {
      return sb.auth.getSession().then(function (r) { return r.data ? r.data.session : null; }, function () { return null; });
    },
    onSignedOut: function (cb) {
      sb.auth.onAuthStateChange(function (event) { if (event === 'SIGNED_OUT') cb(); });
    },
    signOut: function () { return sb.auth.signOut().catch(function () {}); },
    loadMe: function (email) {
      return wrap(sb.from('app_users').select('email,role,store_code').eq('email', email.toLowerCase()).maybeSingle())
        .then(function (r) { return r.data || null; });
    },

    // ---- 讀取（資料庫函式已依角色過濾，前端照單全收）----
    quarters: function () {
      return wrap(sb.rpc('checkup_quarters_list')).then(function (r) { return r.data || []; });
    },
    roster: function (year, quarter) {
      return wrap(sb.rpc('checkup_roster', { p_year: year, p_quarter: quarter })).then(function (r) { return r.data || []; });
    },

    // ---- 寫入（只有客服部）----
    setQuarter: function (store, quarter) {
      return wrap(sb.rpc('checkup_quarter_set', { p_store: store, p_quarter: quarter }));
    },
    // atIso：帶 +08:00 的 ISO 字串；note 空字串送 null
    schedule: function (employeeId, year, quarter, atIso, note) {
      return wrap(sb.rpc('checkup_schedule', {
        p_employee: employeeId, p_year: year, p_quarter: quarter, p_scheduled_at: atIso, p_note: note || null
      })).then(function (r) { return r.data; });
    },
    unschedule: function (checkupId) {
      return wrap(sb.rpc('checkup_unschedule', { p_checkup_id: checkupId }));
    }
  };
})();
