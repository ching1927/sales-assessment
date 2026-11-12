/*
 * 抽查系統資料層（只給 spotcheck.html 用）：登入檢查、讀取、七個抽查函式、截圖的 Storage 存取。
 * 資料表、函式、參數名稱以 supabase/README_spotcheck.md 為準。
 * 寫入一律走 sb.rpc，不直接對資料表 insert／update／delete；權限由資料庫把關。
 * 資料庫函式丟的繁中訊息（P0001）直接顯示。不把 session／token 寫進 console 或網址列。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  var PAGE = 1000;
  var BUCKET = 'assess-notes';        // 抽查截圖沿用備註附圖的私有 bucket，路徑 spot/{抽查id}/{uuid}.jpg
  var URL_TTL = 3600, URL_REUSE_MS = 3000 * 1000;
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

  var urlCache = {};

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
    // 抽查紀錄：訊息（LINE 聊天室網址）用來對應黃單的 inspection_id；面向、說明、截圖路徑給畫面顯示；
    // total_score 只有舊紀錄有值（舊制七面向分數）；RLS 已依角色過濾（店長只有自己門市）。不讀 levels、不讀考官信箱。
    loadInspections: function () {
      return pageAll(function (from, to) {
        return sb.from('spot_inspections')
          .select('id,employee_id,employee_label,store_code,checked_on,message,verdict,reason,improve_dims,improve_note,shot_paths,total_score,created_at')
          .order('checked_on', { ascending: false }).order('created_at', { ascending: false }).order('id').range(from, to);
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
    // 登記一次抽查：regId 是前端先產生的抽查 id（截圖路徑的資料夾；同一個 id 只能登記一次，擋重複送出）；
    // verdict 送資料庫的值（適當／不適當）；dims 勾的面向；shotPaths 已上傳的截圖路徑
    register: function (regId, employeeId, checkedOn, message, verdict, reason, dims, note, shotPaths) {
      return wrap(sb.rpc('spot_register_dims', {
        p_inspection_id: regId, p_employee_id: employeeId, p_checked_on: checkedOn, p_message: message,
        p_verdict: verdict, p_reason: reason || null, p_dims: dims || [], p_note: note || null, p_shot_paths: shotPaths || []
      })).then(function (r) { return r.data; });
    },
    // 截圖上傳：檔案已存在（重試時）視為成功
    uploadShot: function (path, blob, mime) {
      return sb.storage.from(BUCKET).upload(path, blob, { contentType: mime, upsert: false }).then(function (r) {
        if (!r.error) return true;
        var m = String(r.error.message || '').toLowerCase(), st = String(r.error.statusCode || r.error.status || '');
        if (st === '409' || m.indexOf('already exists') >= 0 || m.indexOf('duplicate') >= 0) return true;
        fail(r.error);
      }, function (e) { fail(e); });
    },
    // 刪除還沒登記的截圖（永不拋例外）
    removeShots: function (paths) {
      if (!paths || !paths.length) return Promise.resolve(true);
      return sb.storage.from(BUCKET).remove(paths).then(function (r) { return !r.error; }, function () { return false; });
    },
    // 簽名網址（快取；storage 的 RLS 決定誰讀得到：店長只有自己門市）
    signedUrl: function (path) {
      var c = urlCache[path];
      if (c && Date.now() - c.at < URL_REUSE_MS) return Promise.resolve(c.url);
      return wrap(sb.storage.from(BUCKET).createSignedUrl(path, URL_TTL)).then(function (r) {
        var u = r.data && (r.data.signedUrl || r.data.signedURL);
        if (!u) { var e = new Error('圖片暫時無法顯示，請稍後再試。'); e.userMessage = e.message; throw e; }
        urlCache[path] = { url: u, at: Date.now() };
        return u;
      });
    },
    forgetUrl: function (path) { delete urlCache[path]; },
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
