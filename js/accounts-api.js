/*
 * 帳號管理資料層（只給 accounts.html 用）：登入檢查、帳號清單、新增／修改／移除、操作紀錄、白話錯誤訊息。
 * 資料表、檢視、欄位名稱以 supabase/accounts_schema.sql 與 roster_schema.sql 為準。
 * 護欄（至少留一位客服部、不能移除或降級自己、信箱網域）由資料庫把關，這裡只負責把訊息白話顯示。
 * 不把 session／token 寫進 console 或網址列。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  var PAGE = 1000;
  var AUDIT_PAGE = 50;
  var STORE_ORDER = ['總公司', '中和', '新莊', '樹林', '桃園中壢', '新竹', '旗艦', '南台中', '太平', '台南', '高雄', '花蓮'];
  function storeRank(code) {
    var i = STORE_ORDER.indexOf(code);
    return i < 0 ? STORE_ORDER.length : i;
  }
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  var NO_PERM = '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';

  // 把錯誤換成白話繁體中文（不顯示原始錯誤碼）
  function explain(err) {
    if (err && err.userMessage) return err.userMessage;
    var code = err && err.code ? String(err.code) : '';
    var raw = err && err.message ? String(err.message) : '';
    var msg = raw.toLowerCase();
    var status = err && (err.status || err.statusCode) ? String(err.status || err.statusCode) : '';
    // 資料庫護欄自己丟的白話訊息（P0001，含中文）直接顯示
    if (code === 'P0001' && /[一-鿿]/.test(raw)) return raw;
    if (code === '42501' || code === 'PGRST301' || msg.indexOf('row-level security') >= 0 || msg.indexOf('permission denied') >= 0 ||
        msg.indexOf('jwt') >= 0 || status === '401' || status === '403') return NO_PERM;
    if (code === '23505') return '這個信箱已經有帳號了';
    if (code === '23503') return '所選的門市或員工不存在，請重新整理頁面後再試。';
    if (code === '23514') return '資料格式不符（店長必須選門市，其他角色不能有門市），請檢查後再儲存。';
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
  function userError(text) { var e = new Error(text); e.userMessage = text; return e; }

  // 分頁讀完：build(from, to) 回傳一個 supabase 查詢
  function pageAll(build) {
    var all = [];
    function next(from) {
      return wrap(build(from, from + PAGE - 1)).then(function (r) {
        var rows = r.data || [];
        all = all.concat(rows);
        if (rows.length === PAGE) return next(from + PAGE);
        return all;
      });
    }
    return next(0);
  }

  window.AccountsApi = {
    explain: explain,
    storeRank: storeRank,
    getSession: function () {
      return sb.auth.getSession().then(function (r) { return r.data ? r.data.session : null; }, function () { return null; });
    },
    onSignedOut: function (cb) {
      sb.auth.onAuthStateChange(function (event) { if (event === 'SIGNED_OUT') cb(); });
    },
    signOut: function () { return sb.auth.signOut().catch(function () {}); },
    // 自己的 app_users 那一列（查不到回 null）
    loadMe: function (email) {
      return wrap(sb.from('app_users').select('email,role,store_code').eq('email', email.toLowerCase()).maybeSingle())
        .then(function (r) { return r.data || null; });
    },
    loadStores: function () {
      return wrap(sb.from('stores').select('code,name').order('code')).then(function (r) {
        return (r.data || []).sort(function (a, b) { return storeRank(a.code) - storeRank(b.code) || cmp(a.code, b.code); });
      });
    },
    // 帳號清單（檢視 accounts_list）：email, role, store_code, employee_id, nickname, full_name
    loadAccounts: function () {
      return pageAll(function (from, to) {
        return sb.from('accounts_list').select('email,role,store_code,employee_id,nickname,full_name').order('email').range(from, to);
      });
    },
    // 員工清單（下拉與操作紀錄名稱對照用）：依門市順序再依員編
    loadEmployees: function () {
      return pageAll(function (from, to) {
        return sb.from('employees').select('id,nickname,full_name,store_code').order('id').range(from, to);
      }).then(function (rows) {
        return rows.sort(function (a, b) { return storeRank(a.store_code) - storeRank(b.store_code) || cmp(a.id, b.id); });
      });
    },
    // 操作紀錄：新到舊，每次 50 筆；beforeId 為上一批最舊的 id（沒有就從最新開始）
    loadAudit: function (beforeId) {
      var q = sb.from('app_users_audit').select('id,at,by_email,action,email,old_row,new_row').order('id', { ascending: false }).limit(AUDIT_PAGE);
      if (beforeId != null) q = q.lt('id', beforeId);
      return wrap(q).then(function (r) { return r.data || []; });
    },
    AUDIT_PAGE: AUDIT_PAGE,
    insertAccount: function (row) { return wrap(sb.from('app_users').insert(row)); },
    // 回傳是否真的改到一列（RLS 擋掉時不會報錯而是 0 列）
    updateAccount: function (email, patch) {
      return wrap(sb.from('app_users').update(patch).eq('email', email).select('email')).then(function (r) {
        if (!r.data || r.data.length === 0) throw userError('這個帳號已不存在，或你沒有修改的權限，請重新整理頁面。');
      });
    },
    deleteAccount: function (email) {
      return wrap(sb.from('app_users').delete().eq('email', email).select('email')).then(function (r) {
        if (!r.data || r.data.length === 0) throw userError('這個帳號已不存在，或你沒有移除的權限，請重新整理頁面。');
      });
    }
  };
})();
