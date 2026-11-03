/*
 * 待考回報資料層（只給 requests.html 用）：登入檢查、讀取、八個資料庫函式。
 * 資料表、函式、參數名稱以 supabase/README_exam_request.md 為準。
 * 寫入一律走 sb.rpc，不直接對資料表 insert／update／delete；權限由資料庫把關。
 * 資料庫函式丟的繁中訊息（P0001）直接顯示。不把 session／token 寫進 console 或網址列。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  var PAGE = 1000;
  var MAIL_LIMIT = 100;   // 寄信紀錄只讀最近 100 筆
  var STORE_ORDER = ['總公司', '中和', '新莊', '樹林', '桃園中壢', '新竹', '旗艦', '南台中', '太平', '台南', '高雄', '花蓮'];
  function storeRank(code) {
    var i = STORE_ORDER.indexOf(code);
    return i < 0 ? STORE_ORDER.length : i;
  }
  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }

  var NO_PERM = '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';

  // 把錯誤換成白話繁體中文（資料庫函式自己丟的中文訊息直接顯示）
  function explain(err) {
    if (err && err.userMessage) return err.userMessage;
    var code = err && err.code ? String(err.code) : '';
    var raw = err && err.message ? String(err.message) : '';
    var msg = raw.toLowerCase();
    var status = err && (err.status || err.statusCode) ? String(err.status || err.statusCode) : '';
    if (code === 'P0001' && /[一-鿿]/.test(raw)) return raw === '沒有權限' ? NO_PERM : raw;
    if (code === '23505') return '這位同仁已經有未結案的回報，請重新整理頁面確認。';
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

  window.RequestsApi = {
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

    // ---- 讀取（RLS 已依角色過濾：客服部、主管全部，店長自己門市）----
    // withEmails：只有客服部才取回報人與處理人信箱（requested_by、handled_by）；店長與主管不取
    loadRequests: function (withEmails) {
      var cols = 'id,kind,employee_id,employee_label,store_code,' + (withEmails ? 'requested_by,' : '') + 'requested_role,desired_dates,video_done,note,improvement_ticket_id,status,scheduled_at,reply_note,' + (withEmails ? 'handled_by,' : '') + 'cancel_by,cancel_reason,assessment_id,mgr_seen,created_at,updated_at';
      return pageAll(function (from, to) {
        return sb.from('exam_requests')
          .select(cols)
          .order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },
    // 寄信紀錄（只有客服部能讀）；不取信件內文，只取最近 MAIL_LIMIT 筆
    loadMail: function () {
      return wrap(sb.from('mail_outbox')
        .select('id,kind,request_id,to_emails,subject,status,last_error,created_at,updated_at')
        .order('created_at', { ascending: false }).order('id').limit(MAIL_LIMIT)).then(function (r) { return r.data || []; });
    },
    // 待開通回覆權限清單（只有客服部用；RLS：客服部、總公司主管全部，店長自己門市）。不取 done_by（操作人信箱）
    loadActivations: function () {
      return pageAll(function (from, to) {
        return sb.from('reply_activations')
          .select('id,employee_id,employee_label,store_code,assessment_id,passed_on,status,done_on,created_at')
          .order('passed_on', { ascending: false }).order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },
    // 依情況列出可回報的人（店長只有自己門市；複檢每張可複檢的改善單一列）
    candidates: function (kind) {
      return wrap(sb.rpc('exam_req_candidates', { p_kind: kind })).then(function (r) { return r.data || []; });
    },

    // ---- 寫入（全部走資料庫函式）----
    create: function (kind, employeeId, dates, video, note, ticketId) {
      return wrap(sb.rpc('exam_req_create', {
        p_kind: kind, p_employee_id: employeeId, p_dates: dates, p_video: video,
        p_note: note || '', p_ticket_id: ticketId || null
      })).then(function (r) { return r.data; });
    },
    withdraw: function (id) {
      return wrap(sb.rpc('exam_req_withdraw', { p_id: id }));
    },
    // atIso：帶 +08:00 的 ISO 字串
    schedule: function (id, atIso, note) {
      return wrap(sb.rpc('exam_req_schedule', { p_id: id, p_at: atIso, p_note: note || '' }));
    },
    returnRequest: function (id, reason) {
      return wrap(sb.rpc('exam_req_return', { p_id: id, p_reason: reason }));
    },
    markSeen: function () {
      return wrap(sb.rpc('exam_req_mark_seen'));
    },
    badge: function () {
      return wrap(sb.rpc('exam_req_badge')).then(function (r) { return Number(r.data) || 0; });
    },
    mailSync: function () {
      return wrap(sb.rpc('mail_outbox_sync'));
    },
    // 客服部在 LINE 官方帳號開通後留紀錄（待開通 -> 已開通，資料庫記日期與操作人；已開通者會被拒絕）
    markActivationDone: function (id) {
      return wrap(sb.rpc('activation_mark_done', { p_id: id }));
    }
  };
})();
