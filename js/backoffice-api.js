/*
 * 考核後台資料層（只給 backoffice.html 用）：登入檢查、名冊、成績單列表、弱項分析資料、改善單讀取與四個改善單函式。
 * 資料表、檢視、函式、參數名稱以 supabase/backoffice_schema.sql、assess_schema.sql、roster_schema.sql 為準。
 * 不查機密表（assessment_item_secrets、assessment_item_images）；權限一律由資料庫 RLS 把關，這裡不自己假設資料量。
 * 不把 session／token 寫進 console 或網址列。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  var PAGE = 1000;
  var STORE_ORDER = ['總公司', '中和', '新莊', '樹林', '桃園中壢', '新竹', '旗艦', '南台中', '太平', '台南', '高雄', '花蓮'];
  function storeRank(code) {
    var i = STORE_ORDER.indexOf(code);
    return i < 0 ? STORE_ORDER.length : i;
  }
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  var NO_PERM = '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';

  // 把錯誤換成白話繁體中文（不顯示原始錯誤碼與內部資訊）
  function explain(err) {
    if (err && err.userMessage) return err.userMessage;
    var code = err && err.code ? String(err.code) : '';
    var raw = err && err.message ? String(err.message) : '';
    var msg = raw.toLowerCase();
    var status = err && (err.status || err.statusCode) ? String(err.status || err.statusCode) : '';
    // 資料庫函式自己丟的白話訊息（P0001，含中文）直接顯示；單純「沒有權限」換成較完整的說明
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

  // 分頁讀完：build(from, to) 回傳一個 supabase 查詢（必須有穩定排序）
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

  window.BackofficeApi = {
    explain: explain,
    storeRank: storeRank,

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
    loadStores: function () {
      return wrap(sb.from('stores').select('code,name').order('code')).then(function (r) {
        return (r.data || []).sort(function (a, b) { return storeRank(a.code) - storeRank(b.code) || cmp(a.code, b.code); });
      });
    },

    // ---- 讀取（RLS 已依角色過濾，全部分頁讀完）----
    // 考生基本資料（店長只會拿到自己門市）
    loadEmployees: function () {
      return pageAll(function (from, to) {
        return sb.from('employees').select('id,nickname,full_name,store_code,hire_date,status,include_in_assessment').order('id').range(from, to);
      });
    },
    // 已送出的成績單（不含機密欄位）
    loadSummaries: function () {
      return pageAll(function (from, to) {
        return sb.from('assessment_summaries')
          .select('id,employee_id,employee_label,store_code,store_name,created_at,submitted_at,tenure,total_score,verdict,weakest_dims,item_count')
          .eq('status', 'submitted').order('submitted_at', { ascending: false }).order('id').range(from, to);
      });
    },
    // 弱項分析資料：每張已送出成績單、每個題組、每個面向一列
    loadDimRates: function () {
      return pageAll(function (from, to) {
        return sb.from('analytics_dim_rates').select('assessment_id,employee_id,store_code,submitted_at,item_id,dim,level_pct')
          .order('assessment_id').order('item_id').order('dim').range(from, to);
      });
    },
    // 改善單（含考生名稱、來源成績單摘要、逾期）
    loadTickets: function () {
      return pageAll(function (from, to) {
        return sb.from('improvement_ticket_view')
          .select('id,assessment_id,employee_id,employee_label,store_code,status,target_dims,due_date,coached_on,coach_note,coached_by,coached_at,closed_by,closed_at,closed_by_assessment_id,close_note,cancelled_by,cancelled_at,cancel_reason,created_at,updated_at,source_assessed_on,source_total_score,source_verdict,source_tenure,is_overdue,days_overdue')
          .order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },

    // ---- 改善單操作（全部走資料庫函式）----
    updatePlan: function (ticketId, dims, dueDate) {
      return wrap(sb.rpc('improve_update_plan', { p_ticket_id: ticketId, p_target_dims: dims, p_due_date: dueDate }));
    },
    markCoached: function (ticketId, coachedOn, note) {
      return wrap(sb.rpc('improve_mark_coached', { p_ticket_id: ticketId, p_coached_on: coachedOn, p_note: note }));
    },
    closeTicket: function (ticketId, recheckAssessmentId, note) {
      return wrap(sb.rpc('improve_close', { p_ticket_id: ticketId, p_recheck_assessment_id: recheckAssessmentId, p_note: note || null }));
    },
    cancelTicket: function (ticketId, reason) {
      return wrap(sb.rpc('improve_cancel', { p_ticket_id: ticketId, p_reason: reason }));
    }
  };
})();
