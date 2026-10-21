/*
 * 考核資料層（進行考核頁與成績單頁共用）：登入檢查、評分函式、成績單讀取、備註附圖的 Storage 存取。
 * 資料表、函式名稱與參數名稱以 supabase/assess_schema.sql 為準。
 * 不把 session／token／簽名網址寫進 console。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);
  var PAGE = 1000;
  var BUCKET = 'assess-notes';
  var URL_TTL = 300;          // 簽名網址有效秒數
  var URL_REUSE_MS = 240000;  // 快取只用 240 秒，避免拿到快過期的網址
  var STORE_ORDER = ['總公司', '中和', '新莊', '樹林', '桃園中壢', '新竹', '旗艦', '南台中', '太平', '台南', '高雄', '花蓮'];
  function storeRank(code) {
    var i = STORE_ORDER.indexOf(code);
    return i < 0 ? STORE_ORDER.length : i;
  }

  var NO_PERM = '你沒有這個操作的權限，或登入已過期，請重新登入後再試。';

  // 把錯誤分類：network 網路、perm 權限／登入、storage／db 各自的重複、size、mime、app（資料庫函式自己丟的白話訊息）、other
  function classify(err) {
    var code = err && err.code ? String(err.code) : '';
    var raw = err && err.message ? String(err.message) : '';
    var msg = raw.toLowerCase();
    var status = err && (err.status || err.statusCode) ? String(err.status || err.statusCode) : '';
    if (code === '42501' || code === 'PGRST301' || msg.indexOf('row-level security') >= 0 || msg.indexOf('permission denied') >= 0 ||
        msg.indexOf('jwt') >= 0 || raw.indexOf('沒有權限') === 0 || status === '401' || status === '403') return 'perm';
    if (msg.indexOf('failed to fetch') >= 0 || msg.indexOf('networkerror') >= 0 || msg.indexOf('network request failed') >= 0 ||
        msg.indexOf('network error') >= 0 || msg.indexOf('load failed') >= 0) return 'network';
    if (status === '413' || msg.indexOf('exceeded the maximum') >= 0 || msg.indexOf('payload too large') >= 0) return 'size';
    if (msg.indexOf('mime type') >= 0 || (msg.indexOf('not supported') >= 0 && msg.indexOf('image') >= 0)) return 'mime';
    if (code === '23505') return 'dbdup';                       // 資料庫唯一鍵重複
    if (status === '409' || msg.indexOf('already exists') >= 0 || msg.indexOf('duplicate') >= 0) return 'filedup';  // Storage 檔案重複
    if (code === 'P0001' && /[一-鿿]/.test(raw)) return 'app';
    return 'other';
  }

  // 把資料庫／網路／Storage 錯誤換成白話繁體中文（不顯示原始錯誤碼）
  function explain(err) {
    if (err && err.userMessage) return err.userMessage;
    switch (classify(err)) {
      case 'perm': return NO_PERM;
      case 'network': return '網路連線失敗，請檢查網路後再試一次。';
      case 'size': return '圖片檔案太大（單張須在 2MB 內），請換一張較小的圖片。';
      case 'mime': return '圖片格式不支援（只收 png、jpeg、webp）。';
      case 'dbdup': return '資料重複（已經有相同的紀錄），請重新整理頁面後再試。';
      case 'filedup': return '圖片檔案已存在，請重新操作一次。';
      case 'app': return String(err.message);
      default: return '系統發生問題，請稍後再試；若持續發生請聯絡客服部。';
    }
  }

  function fail(error) {
    var e = new Error(explain(error)); e.userMessage = e.message; e.kind = classify(error); throw e;
  }
  function wrap(p) {
    return p.then(function (r) { if (r.error) fail(r.error); return r; }, function (e) { fail(e); });
  }
  function userError(text) { var e = new Error(text); e.userMessage = text; e.kind = 'app'; return e; }

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

  // ---- 簽名網址（快取，過期自動重取）----
  var urlCache = {};
  function signedUrl(path) {
    var c = urlCache[path];
    if (c && Date.now() - c.at < URL_REUSE_MS) return Promise.resolve(c.url);
    return wrap(sb.storage.from(BUCKET).createSignedUrl(path, URL_TTL)).then(function (r) {
      var u = r.data && (r.data.signedUrl || r.data.signedURL);
      if (!u) throw userError('圖片暫時無法顯示，請稍後再試。');
      urlCache[path] = { url: u, at: Date.now() };
      return u;
    });
  }
  function forgetUrl(path) { delete urlCache[path]; }
  // 只看快取（重畫畫面時避免縮圖閃一下）；沒有或快過期回 null
  function peekUrl(path) {
    var c = urlCache[path];
    return c && Date.now() - c.at < URL_REUSE_MS ? c.url : null;
  }

  // 把一批題組的圖片列依 item_id 分組
  function groupImages(rows) {
    var map = {};
    (rows || []).forEach(function (g) {
      (map[g.item_id] = map[g.item_id] || []).push({ id: g.id, path: g.storage_path, mime: g.mime, size: g.size_bytes });
    });
    return map;
  }
  function loadImages(itemIds) {
    if (!itemIds.length) return Promise.resolve({});
    return wrap(sb.from('assessment_item_images').select('id,item_id,storage_path,mime,size_bytes,created_at')
      .in('item_id', itemIds).order('created_at')).then(function (r) { return groupImages(r.data); });
  }

  window.AssessApi = {
    explain: explain,
    userError: userError,

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
        return (r.data || []).sort(function (a, b) {
          return storeRank(a.code) - storeRank(b.code) || (a.code < b.code ? -1 : a.code > b.code ? 1 : 0);
        });
      });
    },

    // ---- 進行考核（只有客服部；全部走資料庫函式）----
    candidates: function () {
      return wrap(sb.rpc('assess_candidates')).then(function (r) { return r.data || []; });
    },
    categories: function () {
      return wrap(sb.rpc('assess_categories')).then(function (r) { return r.data || []; });
    },
    // 有到職日就不要傳 override（傳 null）
    start: function (employeeId, tenureOverride) {
      return wrap(sb.rpc('assess_start', { p_employee_id: employeeId, p_tenure_override: tenureOverride || null }))
        .then(function (r) { return r.data; });
    },
    draw: function (assessmentId, cats) {
      return wrap(sb.rpc('assess_draw', { p_assessment_id: assessmentId, p_cats: cats })).then(function (r) { return r.data || []; });
    },
    saveItem: function (itemId, levels, note) {
      return wrap(sb.rpc('assess_save_item', { p_item_id: itemId, p_levels: levels, p_note: note || '' }));
    },
    submit: function (assessmentId) {
      return wrap(sb.rpc('assess_submit', { p_assessment_id: assessmentId })).then(function (r) {
        var d = r.data;
        return Array.isArray(d) ? d[0] : d;
      });
    },
    // 回傳該草稿所有圖片的 storage path 陣列
    abandon: function (assessmentId) {
      return wrap(sb.rpc('assess_abandon', { p_assessment_id: assessmentId })).then(function (r) { return r.data || []; });
    },
    voidReport: function (assessmentId, reason) {
      return wrap(sb.rpc('assess_void', { p_assessment_id: assessmentId, p_reason: reason }));
    },
    addImage: function (itemId, path, mime, size) {
      return wrap(sb.rpc('assess_add_image', { p_item_id: itemId, p_path: path, p_mime: mime, p_size: size })).then(function (r) { return r.data; });
    },
    removeImage: function (imageId) {
      return wrap(sb.rpc('assess_remove_image', { p_image_id: imageId })).then(function (r) { return r.data; });
    },

    // 我的進行中草稿
    myDrafts: function (email) {
      return wrap(sb.from('assessments')
        .select('id,employee_id,employee_label,store_code,tenure,tenure_source,created_at')
        .eq('status', 'draft').eq('examiner_email', email.toLowerCase()).order('created_at', { ascending: false }))
        .then(function (r) { return r.data || []; });
    },
    // 載入一張草稿：考核本身＋題組（備註在 assessment_items.note；機密表只取名稱、步驟）＋圖片
    loadDraft: function (assessmentId) {
      return wrap(sb.from('assessments')
        .select('id,employee_id,employee_label,store_code,examiner_email,status,tenure,tenure_source,created_at')
        .eq('id', assessmentId).maybeSingle()).then(function (r) {
        var a = r.data;
        if (!a || a.status !== 'draft') throw userError('找不到這張草稿，可能已被放棄或已送出。');
        return window.AssessApi.loadItemsFull(assessmentId).then(function (items) { return { a: a, items: items }; });
      });
    },
    // 客服部用：題組（含 levels、分數）＋機密（題組名稱、步驟）＋備註＋圖片
    loadItemsFull: function (assessmentId) {
      return wrap(sb.from('assessment_items')
        .select('id,seq,category,code,levels,item_score,dim_points,na_dims,weakest_dims,note')
        .eq('assessment_id', assessmentId).order('seq')).then(function (r) {
        var items = r.data || [];
        var ids = items.map(function (i) { return i.id; });
        if (!ids.length) return [];
        return Promise.all([
          wrap(sb.from('assessment_item_secrets').select('item_id,title,steps').in('item_id', ids)),
          loadImages(ids)
        ]).then(function (res) {
          var sec = {};
          (res[0].data || []).forEach(function (s) { sec[s.item_id] = s; });
          return items.map(function (i) {
            var s = sec[i.id] || {};
            return {
              id: i.id, seq: i.seq, category: i.category, code: i.code, levels: i.levels || {},
              item_score: i.item_score, dim_points: i.dim_points, na_dims: i.na_dims, weakest_dims: i.weakest_dims,
              title: s.title || '', steps: Array.isArray(s.steps) ? s.steps : [], note: i.note || '',
              imgs: res[1][i.id] || []
            };
          });
        });
      });
    },
    // 送出後只讀題組分數（不含機密）
    loadItemScores: function (assessmentId) {
      return wrap(sb.from('assessment_items')
        .select('id,seq,category,code,levels,item_score,dim_points,na_dims,weakest_dims')
        .eq('assessment_id', assessmentId).order('seq')).then(function (r) { return r.data || []; });
    },

    // ---- 成績單 ----
    // 列表：RLS 已依角色過濾，這裡分頁讀完
    loadSummaries: function () {
      return pageAll(function (from, to) {
        return sb.from('assessment_summaries')
          .select('id,employee_id,employee_label,store_code,store_name,created_at,submitted_at,examiner_email,tenure,tenure_source,total_score,verdict,pass_line,weakest_dims,status,voided_at,void_reason,item_count')
          .order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },
    // 總公司主管與店長用：只讀 assessment_items（精簡欄位，含考官備註）與圖片；絕不查機密表
    loadItemsLimited: function (assessmentId) {
      return wrap(sb.from('assessment_items')
        .select('id,seq,category,code,item_score,dim_points,note')
        .eq('assessment_id', assessmentId).order('seq')).then(function (r) {
        var items = r.data || [];
        return loadImages(items.map(function (i) { return i.id; })).then(function (imgs) {
          return items.map(function (i) {
            return { id: i.id, seq: i.seq, category: i.category, code: i.code, item_score: i.item_score, dim_points: i.dim_points, note: i.note || '', imgs: imgs[i.id] || [] };
          });
        });
      });
    },

    // ---- Storage（bucket assess-notes）----
    uploadImage: function (path, blob, mime) {
      return wrap(sb.storage.from(BUCKET).upload(path, blob, { contentType: mime, upsert: false }));
    },
    // 刪檔：永不拋例外，回傳 { ok, removed }。檔案本來就不存在視為成功。
    removeFiles: function (paths) {
      if (!paths || !paths.length) return Promise.resolve({ ok: true, removed: 0 });
      var store = sb.storage.from(BUCKET);
      paths.forEach(forgetUrl);
      return store.remove(paths).then(function (r) {
        if (r.error) return { ok: false, removed: 0 };
        var gone = {};
        (r.data || []).forEach(function (o) { if (o && o.name) gone[o.name] = true; });
        var left = paths.filter(function (p) { return !gone[p]; });
        if (!left.length) return { ok: true, removed: paths.length };
        // 沒被回報刪掉的：可能本來就不存在（成功），也可能被擋下（失敗）；列出資料夾確認
        return Promise.all(left.map(function (p) {
          var i = p.lastIndexOf('/'), dir = p.slice(0, i), name = p.slice(i + 1);
          return store.list(dir, { search: name, limit: 10 }).then(function (lr) {
            if (lr.error) return false;   // 查不到結果，保守當作沒刪掉
            return !(lr.data || []).some(function (o) { return o.name === name; });   // 已不存在 → 成功
          }, function () { return false; });
        })).then(function (oks) {
          var bad = oks.filter(function (x) { return !x; }).length;
          return { ok: bad === 0, removed: paths.length - bad };
        });
      }, function () { return { ok: false, removed: 0 }; });
    },
    signedUrl: signedUrl,
    peekUrl: peekUrl,
    forgetUrl: forgetUrl
  };
})();
