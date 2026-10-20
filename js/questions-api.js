/*
 * 題庫管理資料層（只給 questions.html 用）：登入檢查、題庫讀寫、白話錯誤訊息。
 * 函式名稱、參數、回傳以 supabase/bank_schema.sql 為準（bank_list_questions、bank_save_question、
 * bank_delete_question、bank_rename_category、bank_reset），分類剩餘題數沿用 assess_categories()。
 * 題庫內容（含考點）屬機密：不寫進 console、網址、localStorage、sessionStorage。
 * 權限（只有客服部）由資料庫把關，這裡只負責把訊息白話顯示。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);

  var NO_PERM = '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';

  // 把錯誤換成白話繁體中文（不顯示原始錯誤碼與內部資訊）
  function explain(err) {
    if (err && err.userMessage) return err.userMessage;
    var code = err && err.code ? String(err.code) : '';
    var raw = err && err.message ? String(err.message) : '';
    var msg = raw.toLowerCase();
    var status = err && (err.status || err.statusCode) ? String(err.status || err.statusCode) : '';
    // 資料庫自己丟的白話訊息（P0001，含中文）直接顯示；「沒有權限」換成較完整的說明
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

  function normSteps(v) {
    if (!Array.isArray(v)) return [];
    return v.map(function (s) {
      s = s && typeof s === 'object' ? s : {};
      return { action: s.action == null ? '' : String(s.action), point: s.point == null ? '' : String(s.point) };
    });
  }

  window.QuestionsApi = {
    explain: explain,
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
    // 全部題組：{ id, category, code, title, steps:[{action,point}], drawn }
    listQuestions: function () {
      return wrap(sb.rpc('bank_list_questions')).then(function (r) {
        return (r.data || []).map(function (q) {
          return {
            id: Number(q.id), category: q.category, code: q.code || '', title: q.title,
            steps: normSteps(q.steps), drawn: !!q.drawn
          };
        });
      });
    },
    // 各分類：{ category, total, remaining }
    categories: function () {
      return wrap(sb.rpc('assess_categories')).then(function (r) { return r.data || []; });
    },
    // id 為 null＝新增；回傳題組 id
    saveQuestion: function (id, category, code, title, steps) {
      return wrap(sb.rpc('bank_save_question', {
        p_id: id == null ? null : id, p_category: category, p_code: code, p_title: title, p_steps: steps
      })).then(function (r) { return Number(r.data); });
    },
    deleteQuestion: function (id) {
      return wrap(sb.rpc('bank_delete_question', { p_id: id }));
    },
    // 回傳受影響題數（新名稱已存在＝合併）
    renameCategory: function (oldName, newName) {
      return wrap(sb.rpc('bank_rename_category', { p_old: oldName, p_new: newName })).then(function (r) { return Number(r.data) || 0; });
    },
    // category 為 null＝全部分類
    resetBank: function (category) {
      return wrap(sb.rpc('bank_reset', { p_category: category == null ? null : category }));
    }
  };
})();
