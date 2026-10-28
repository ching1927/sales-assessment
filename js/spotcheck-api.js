/*
 * 抽查系統資料層（只給 spotcheck.html 用）：登入檢查、讀取、七個抽查函式。
 * 資料表、函式、參數名稱以 supabase/README_spotcheck.md 為準。
 * 寫入一律走 sb.rpc，不直接對資料表 insert／update／delete；權限由資料庫把關。
 * 資料庫函式丟的繁中訊息（P0001）直接顯示。不把 session／token 寫進 console 或網址列。
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

  window.SpotApi = {
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

    // ---- 讀取（RLS 已依角色過濾）----
    // 每位正式或考核期人員的當月黃單數、當季紅單數、回考核期狀態
    loadStatus: function () {
      return wrap(sb.rpc('spot_status')).then(function (r) { return r.data || []; });
    },
    // 符合抽查對象的人（只有客服部）
    loadCandidates: function () {
      return wrap(sb.rpc('spot_candidates')).then(function (r) { return r.data || []; });
    },
    loadTickets: function () {
      return pageAll(function (from, to) {
        return sb.from('spot_tickets')
          .select('id,kind,employee_id,employee_label,store_code,inspection_id,source_ticket_ids,reason,issued_on,status,void_reason,voided_by,voided_at,coached_on,coach_note,coached_by,coached_at,created_at')
          .order('issued_on', { ascending: false }).order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },
    // 抽查紀錄只取 id 與訊息（LINE 聊天室網址），用來對應黃單的 inspection_id；RLS 已依角色過濾
    loadInspectionMessages: function () {
      return pageAll(function (from, to) {
        return sb.from('spot_inspections').select('id,message').order('id').range(from, to);
      });
    },
    loadProbations: function () {
      return pageAll(function (from, to) {
        return sb.from('spot_probations')
          .select('id,employee_id,employee_label,store_code,red_ticket_ids,triggered_on,status,executed_on,executed_by,passed_assessment_id,cancel_reason,created_at,updated_at')
          .order('triggered_on', { ascending: false }).order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },

    // ---- 寫入（全部走資料庫函式）----
    register: function (employeeId, checkedOn, message, levels, verdict, reason) {
      return wrap(sb.rpc('spot_register', {
        p_employee_id: employeeId, p_checked_on: checkedOn, p_message: message,
        p_levels: levels, p_verdict: verdict, p_reason: reason || null
      })).then(function (r) { return r.data; });
    },
    voidTicket: function (ticketId, reason) {
      return wrap(sb.rpc('spot_void_ticket', { p_ticket_id: ticketId, p_reason: reason }));
    },
    coach: function (ticketId, coachedOn, note) {
      return wrap(sb.rpc('spot_coach', { p_ticket_id: ticketId, p_coached_on: coachedOn, p_note: note }));
    },
    markExecuted: function (probationId) {
      return wrap(sb.rpc('spot_mark_executed', { p_probation_id: probationId }));
    },
    cancelProbation: function (probationId, reason) {
      return wrap(sb.rpc('spot_cancel_probation', { p_probation_id: probationId, p_reason: reason }));
    }
  };
})();
