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

  // ---- 題組範例圖片（supabase/question_images_schema.sql；bucket question-samples）----
  var IMG_BUCKET = 'question-samples', IMG_URL_TTL = 3600, IMG_URL_REUSE_MS = 50 * 60 * 1000;
  var IC = window.QuestionImagesCore;
  var imgUrlCache = {};
  var UNAVAILABLE_TEXT = '範例圖片功能尚未啟用';
  // 圖片相關呼叫的包裝：資料庫還沒啟用時丟出 unavailable=true 的錯誤，其他錯誤同 wrap
  function imgFail(error) {
    var un = IC.isUnavailable(error);
    var e = new Error(un ? UNAVAILABLE_TEXT : explain(error));
    e.userMessage = e.message;
    if (un) e.unavailable = true;
    throw e;
  }
  function wrapImg(p) {
    return p.then(function (r) {
      if (r.error) imgFail(r.error);
      return r;
    }, function (e) { imgFail(e); });
  }
  function imgRows(rows) {
    return (rows || []).map(function (g) {
      return { id: g.id, path: g.storage_path, mime: g.mime, size: Number(g.size_bytes) || 0, sort: Number(g.sort_order) || 0 };
    }).sort(function (a, b) { return a.sort - b.sort; });
  }
  function userErr(text) { var e = new Error(text); e.userMessage = text; return e; }
  // 刪 Storage 檔：永不丟例外，回傳 { ok }
  function removeImgFiles(paths) {
    if (!paths || !paths.length) return Promise.resolve({ ok: true });
    paths.forEach(function (p) { delete imgUrlCache[p]; });
    return Promise.resolve().then(function () { return sb.storage.from(IMG_BUCKET).remove(paths); }).then(function (r) {
      return { ok: !!r && !r.error && (r.data || []).length >= paths.length };
    }, function () { return { ok: false }; });
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
    // 設定題組的重點面向（空陣列＝清除標記）
    setDims: function (questionId, dims) {
      return wrap(sb.rpc('bank_set_dims', { p_question_id: questionId, p_dims: dims }));
    },
    // 全部題組的面向標記：{ [question_id]: [面向...] }（分頁讀完）
    loadDims: function () {
      var PAGE = 1000, map = {};
      function next(from) {
        return wrap(sb.from('question_dims').select('question_id,dims').order('question_id').range(from, from + PAGE - 1)).then(function (r) {
          var rows = r.data || [];
          rows.forEach(function (x) { map[Number(x.question_id)] = Array.isArray(x.dims) ? x.dims : []; });
          return rows.length === PAGE ? next(from + PAGE) : map;
        });
      }
      return next(0);
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
    },

    // ---- 範例圖片 ----
    // 該題組的圖片（依順序）：[{ id, path, mime, size, sort }]；功能未啟用時丟 unavailable=true 的錯誤
    listImages: function (questionId) {
      return wrapImg(sb.from('question_images').select('id,question_id,storage_path,mime,size_bytes,sort_order')
        .eq('question_id', questionId).order('sort_order')).then(function (r) { return imgRows(r.data); });
    },
    // 各題組的圖片張數：{ [question_id]: n }（分頁讀完；失敗或未啟用會丟錯，呼叫端自行忽略）
    loadImageCounts: function () {
      var PAGE = 1000, map = {};
      function next(from) {
        return wrapImg(sb.from('question_images').select('question_id').order('question_id').range(from, from + PAGE - 1)).then(function (r) {
          var rows = r.data || [];
          rows.forEach(function (x) { var k = Number(x.question_id); map[k] = (map[k] || 0) + 1; });
          return rows.length === PAGE ? next(from + PAGE) : map;
        });
      }
      return next(0);
    },
    // 上傳一張：先傳 Storage，再登記；登記失敗會把剛傳的檔刪掉。回傳 { id, path, mime, size }
    addImage: function (questionId, blob, mime, size) {
      var path = IC.buildPath(questionId, IC.newUuid(), mime);
      if (!path) return Promise.reject(userErr('圖片格式只收 jpg、png、webp'));
      if (!size || size > IC.MAX_BYTES) return Promise.reject(userErr('圖片大小必須在 2MB 以內'));
      return wrapImg(sb.storage.from(IMG_BUCKET).upload(path, blob, { contentType: mime, upsert: false })).then(function () {
        return wrapImg(sb.rpc('bank_add_question_image', { p_question_id: questionId, p_path: path, p_mime: mime, p_size: size })).then(function (r) {
          return { id: r.data, path: path, mime: mime, size: size };
        }, function (err) {
          return removeImgFiles([path]).then(function () { throw err; });
        });
      });
    },
    // 依 ids 的順序重排（必須恰好是該題全部圖片）
    reorderImages: function (questionId, ids) {
      return wrapImg(sb.rpc('bank_reorder_question_images', { p_question_id: questionId, p_image_ids: ids }));
    },
    // 刪一張：先刪資料列（取回 path），再刪 Storage 檔。回傳 { fileRemoved }；資料列刪除失敗會丟錯
    removeImage: function (imageId) {
      return wrapImg(sb.rpc('bank_remove_question_image', { p_image_id: imageId })).then(function (r) {
        var path = r.data;
        return removeImgFiles(path ? [path] : []).then(function (x) { return { fileRemoved: x.ok, path: path }; });
      });
    },
    // 清 Storage 檔（刪題組後用）：回傳 { ok }，永不丟例外
    removeImageFiles: removeImgFiles,
    // 簽名網址（快取；過期前重用）
    imageUrl: function (path) {
      var c = imgUrlCache[path];
      if (c && Date.now() - c.at < IMG_URL_REUSE_MS) return Promise.resolve(c.url);
      return wrapImg(sb.storage.from(IMG_BUCKET).createSignedUrl(path, IMG_URL_TTL)).then(function (r) {
        var u = r.data && (r.data.signedUrl || r.data.signedURL);
        if (!u) throw userErr('圖片暫時無法顯示，請稍後再試。');
        imgUrlCache[path] = { url: u, at: Date.now() };
        return u;
      });
    },
    // 只看快取（重畫時縮圖不閃）；沒有或快過期回 null
    peekImageUrl: function (path) {
      var c = imgUrlCache[path];
      return c && Date.now() - c.at < IMG_URL_REUSE_MS ? c.url : null;
    },
    forgetImageUrl: function (path) { delete imgUrlCache[path]; }
  };
})();
