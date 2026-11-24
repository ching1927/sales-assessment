/*
 * 考核資料層（進行考核頁與成績單頁共用）：登入檢查、評分函式、成績單讀取、備註附圖的 Storage 存取。
 * 資料表、函式名稱與參數名稱以 supabase/assess_schema.sql 為準。
 * 不把 session／token／簽名網址寫進 console。
 */
(function () {
  var cfg = window.APP_CONFIG;
  // 同一頁若同時載入 backoffice-api.js 與本檔（考核後台的「近期考核」），共用同一個 client，避免兩個 GoTrueClient；只載入本檔的頁面行為不變
  var sb = window.__sbSharedClient || (window.__sbSharedClient = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY));
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

  // ---- 雙考官（資料庫尚未執行 dual_examiner_schema.sql 時，單人流程照常運作）----
  var DUAL_OFF = '雙考官功能尚未啟用';
  var dualOffSeen = false;
  var DUAL_COL_RE = /is_dual|slot1_name|slot2_name|examiner_slot/;
  // 查詢多帶雙考官欄位：build(extraCols) 回傳查詢；欄位不存在（資料庫還沒升級）就退回不帶的版本
  function withDualCols(build, extraCols) {
    return build(extraCols).then(function (r) {
      if (r && r.error && (r.error.code === '42703' || DUAL_COL_RE.test(String(r.error.message || '')))) return build('');
      return r;
    });
  }
  function isNotEnabled(err) {
    var code = err && err.code ? String(err.code) : '';
    var msg = err && err.message ? String(err.message) : '';
    return code === 'PGRST202' || code === '42883' || code === 'PGRST205' || /Could not find the (function|table)|does not exist/i.test(msg);
  }
  // 呼叫雙考官資料庫函式：函式不存在回「雙考官功能尚未啟用」，其餘沿用既有錯誤處理
  function dualRpc(name, args) {
    return sb.rpc(name, args).then(function (r) {
      if (r.error) { if (isNotEnabled(r.error)) throw userError(DUAL_OFF); fail(r.error); }
      return r;
    }, function (e) { fail(e); });
  }

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
  var SAMPLE_BUCKET = 'question-samples';   // 題組範例圖片（supabase/question_images_schema.sql）
  // 預設 bucket（assess-notes）的快取鍵維持原本的 path；其他 bucket 前面加 bucket 名，避免不同 bucket 同路徑互撞
  function ckey(path, bucket) { return bucket && bucket !== BUCKET ? bucket + '|' + path : path; }
  function signedUrl(path, bucket) {
    var k = ckey(path, bucket), c = urlCache[k];
    if (c && Date.now() - c.at < URL_REUSE_MS) return Promise.resolve(c.url);
    return wrap(sb.storage.from(bucket || BUCKET).createSignedUrl(path, URL_TTL)).then(function (r) {
      var u = r.data && (r.data.signedUrl || r.data.signedURL);
      if (!u) throw userError('圖片暫時無法顯示，請稍後再試。');
      urlCache[k] = { url: u, at: Date.now() };
      return u;
    });
  }
  function forgetUrl(path, bucket) { delete urlCache[ckey(path, bucket)]; }
  // 只看快取（重畫畫面時避免縮圖閃一下）；沒有或快過期回 null
  function peekUrl(path, bucket) {
    var c = urlCache[ckey(path, bucket)];
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

  // assess_draw、assess_pick、assess_add_extra 的回傳格式一致：每列 { item_id, category, code, title, steps, repeated, new_round }
  function drawRows(p) { return wrap(p).then(function (r) { return r.data || []; }); }

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
    // 已有未結案回報（待處理、已排定）的人：選考生清單用來標記「已回報待考」；失敗由呼叫端略過，不擋考核
    openRequests: function () {
      return pageAll(function (from, to) {
        return sb.from('exam_requests').select('employee_id,kind,status,scheduled_at')
          .in('status', ['待處理', '已排定']).order('created_at', { ascending: false }).order('id').range(from, to);
      });
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
      return drawRows(sb.rpc('assess_draw', { p_assessment_id: assessmentId, p_cats: cats }));
    },
    // ---- 第一期：固定 3 題組與弱項追加題（規格：supabase/README_phase1.md）----
    // 核心分類清單（text[]，預設 基礎、進階、綜合）；網頁用它當 assess_draw 的分類一次抽齊
    coreCategories: function () {
      return wrap(sb.rpc('assess_core_categories')).then(function (r) {
        return (Array.isArray(r.data) ? r.data : []).filter(function (c) { return typeof c === 'string' && c.trim(); });
      });
    },
    // 這一場核心題組的弱項（jsonb 物件 { rates, weak:[{dim,pct}], always_low:[{dim,pct}] }；格式與 assess_weak_profile 的 weak 相容，可直接給 Suggest.weakOf／pick）
    draftWeak: function (assessmentId) {
      return wrap(sb.rpc('assess_draft_weak', { p_assessment_id: assessmentId })).then(function (r) {
        var d = Array.isArray(r.data) ? r.data[0] : r.data;
        d = d || {};
        return { rates: d.rates || [], weak: d.weak || [], always_low: d.always_low || [] };
      });
    },
    // 追加弱項題（一次最多 4 題）；回傳格式與 draw 一致
    addExtra: function (assessmentId, questionIds) {
      return drawRows(sb.rpc('assess_add_extra', { p_assessment_id: assessmentId, p_question_ids: questionIds }));
    },
    // 這場考核已用的題組 id（追加題要避開；客服部才讀得到機密表）
    questionIdsOf: function (itemIds) {
      if (!itemIds || !itemIds.length) return Promise.resolve([]);
      return wrap(sb.from('assessment_item_secrets').select('item_id,question_id').in('item_id', itemIds))
        .then(function (r) { return (r.data || []).map(function (s) { return s.question_id; }); });
    },
    // 追加開始時間（assessments.extra_started_at，ISO 字串或 null）
    extraStartedAt: function (assessmentId) {
      return wrap(sb.from('assessments').select('extra_started_at').eq('id', assessmentId).maybeSingle())
        .then(function (r) { return (r.data && r.data.extra_started_at) || null; });
    },
    // 送出後：這張成績單有沒有新增「待開通」（reply_activations），沒有回 null
    activationOf: function (assessmentId) {
      return wrap(sb.from('reply_activations').select('id,status,passed_on').eq('assessment_id', assessmentId).maybeSingle())
        .then(function (r) { return r.data || null; });
    },
    // 送出後：考生目前的 period_status（考核期／已上線）
    periodStatus: function (employeeId) {
      return wrap(sb.from('employees_with_tenure').select('period_status').eq('id', employeeId).maybeSingle())
        .then(function (r) { return (r.data && r.data.period_status) || null; });
    },
    // ---- 弱項建議題組（規格：supabase/README_weak_suggest.md）----
    // 弱項摘要（jsonb 物件）
    weakProfile: function (employeeId) {
      return wrap(sb.rpc('assess_weak_profile', { p_employee_id: employeeId })).then(function (r) {
        var d = Array.isArray(r.data) ? r.data[0] : r.data;
        return d || { n: 0, rates: [], weak: [], always_low: [] };
      });
    },
    // 整個題庫（含面向標記、該考生考過與否、是否在抽選器 drawn 內）；題組名稱機密，只有客服部能呼叫
    suggestPool: function (employeeId) {
      return wrap(sb.rpc('assess_suggest_pool', { p_employee_id: employeeId })).then(function (r) { return r.data || []; });
    },
    // 指定題組開考，回傳格式與 draw 一致
    pick: function (assessmentId, questionIds) {
      return drawRows(sb.rpc('assess_pick', { p_assessment_id: assessmentId, p_question_ids: questionIds }));
    },
    // dimNotes（三級制面向備註 { 面向: 文字 }）：不是 undefined 才多呼叫一次 assess_save_dim_notes（需先執行 supabase/grade3_schema.sql）；
    // 資料庫只留「該面向目前是尚可／待加強」的備註，所以一定在存完等級之後才存備註
    saveItem: function (itemId, levels, note, noteUrl, dimNotes) {
      return wrap(sb.rpc('assess_save_item', { p_item_id: itemId, p_levels: levels, p_note: note || '', p_note_url: noteUrl || null })).then(function (r) {
        if (dimNotes === undefined) return r;
        return wrap(sb.rpc('assess_save_dim_notes', { p_item_id: itemId, p_dim_notes: dimNotes || {} }));
      });
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
    // 帶 is_dual：頁面用它把「我開的雙考官草稿」從單人草稿清單濾掉（改由 myDraftsDual 顯示）
    myDrafts: function (email) {
      return wrap(withDualCols(function (x) {
        return sb.from('assessments')
          .select('id,employee_id,employee_label,store_code,tenure,tenure_source,created_at,kind,checkup_year,checkup_quarter' + (x ? ',' + x : ''))
          .eq('status', 'draft').eq('examiner_email', email.toLowerCase()).order('created_at', { ascending: false });
      }, 'is_dual'))
        .then(function (r) { return r.data || []; });
    },
    // 載入一張草稿：考核本身＋題組（備註在 assessment_items.note；機密表只取名稱、步驟）＋圖片
    loadDraft: function (assessmentId) {
      return wrap(withDualCols(function (x) {
        return sb.from('assessments')
          .select('id,employee_id,employee_label,store_code,examiner_email,status,tenure,tenure_source,created_at,extra_started_at' + (x ? ',' + x : ''))
          .eq('id', assessmentId).maybeSingle();
      }, 'is_dual,slot1_name,slot2_name')).then(function (r) {
        var a = r.data;
        if (!a || a.status !== 'draft') throw userError('找不到這張草稿，可能已被放棄或已送出。');
        return window.AssessApi.loadItemsFull(assessmentId).then(function (items) { return { a: a, items: items }; });
      });
    },
    // 客服部用：題組（含 levels、分數）＋機密（題組名稱、步驟）＋備註＋圖片
    loadItemsFull: function (assessmentId) {
      return wrap(withDualCols(function (x) {
        return sb.from('assessment_items')
          .select('id,seq,category,code,levels,item_score,dim_points,na_dims,weakest_dims,note,note_url,is_extra' + (x ? ',' + x : ''))
          .eq('assessment_id', assessmentId).order('seq');
      }, 'examiner_slot')).then(function (r) {
        var items = r.data || [];
        var ids = items.map(function (i) { return i.id; });
        if (!ids.length) return [];
        return Promise.all([
          wrap(sb.from('assessment_item_secrets').select('item_id,title,steps,dim_notes').in('item_id', ids)),
          loadImages(ids)
        ]).then(function (res) {
          var sec = {};
          (res[0].data || []).forEach(function (s) { sec[s.item_id] = s; });
          return items.map(function (i) {
            var s = sec[i.id] || {};
            return {
              id: i.id, seq: i.seq, category: i.category, code: i.code, levels: i.levels || {}, isExtra: !!i.is_extra, examinerSlot: i.examiner_slot == null ? null : i.examiner_slot,
              item_score: i.item_score, dim_points: i.dim_points, na_dims: i.na_dims, weakest_dims: i.weakest_dims,
              title: s.title || '', steps: Array.isArray(s.steps) ? s.steps : [], dimNotes: s.dim_notes && typeof s.dim_notes === 'object' ? s.dim_notes : {}, note: i.note || '', note_url: i.note_url || '',
              imgs: res[1][i.id] || []
            };
          });
        });
      });
    },
    // 送出後只讀題組分數（不含機密）
    loadItemScores: function (assessmentId) {
      return wrap(withDualCols(function (x) {
        return sb.from('assessment_items')
          .select('id,seq,category,code,levels,item_score,dim_points,na_dims,weakest_dims,is_extra' + (x ? ',' + x : ''))
          .eq('assessment_id', assessmentId).order('seq');
      }, 'examiner_slot')).then(function (r) {
        return (r.data || []).map(function (i) { i.isExtra = !!i.is_extra; return i; });
      });
    },

    // ---- 成績單 ----
    // 列表：RLS 已依角色過濾，這裡分頁讀完
    // withExaminer 只有客服部傳 true：店長與主管不要求考官信箱欄位（網路回應也不帶）
    loadSummaries: function (withExaminer) {
      return pageAll(function (from, to) {
        return sb.from('assessment_summaries')
          .select('id,employee_id,employee_label,store_code,store_name,created_at,submitted_at,' + (withExaminer ? 'examiner_email,' : '') + 'tenure,tenure_source,total_score,verdict,pass_line,weakest_dims,status,voided_at,void_reason,item_count,kind,checkup_year,checkup_quarter')
          .order('created_at', { ascending: false }).order('id').range(from, to);
      });
    },
    // 總公司主管與店長用：只讀 assessment_items（精簡欄位，含考官備註）與圖片；絕不查機密表
    loadItemsLimited: function (assessmentId) {
      return wrap(sb.from('assessment_items')
        .select('id,seq,category,code,levels,item_score,dim_points,note,note_url,is_extra')
        .eq('assessment_id', assessmentId).order('seq')).then(function (r) {
        var items = r.data || [];
        return loadImages(items.map(function (i) { return i.id; })).then(function (imgs) {
          return items.map(function (i) {
            return { id: i.id, seq: i.seq, category: i.category, code: i.code, levels: i.levels, isExtra: !!i.is_extra, item_score: i.item_score, dim_points: i.dim_points, note: i.note || '', note_url: i.note_url || '', imgs: imgs[i.id] || [] };
          });
        });
      });
    },

    // 總公司主管與店長用（成績單完整版）：在 loadItemsLimited 之上多帶「題目名稱」與「面向備註」。
    // 這兩項存在機密表，前端不直接查表，只呼叫資料庫函式 fullreport_items（資料庫依角色與門市把關，不回傳考官信箱、步驟、考點；需先執行 supabase/fullreport_schema.sql）。
    loadItemsFullReport: function (assessmentId) {
      return Promise.all([
        window.AssessApi.loadItemsLimited(assessmentId),
        wrap(sb.rpc('fullreport_items', { p_assessment_ids: [assessmentId] }))
      ]).then(function (res) {
        var by = {};
        (res[1].data || []).forEach(function (x) { by[x.item_id] = x; });
        return res[0].map(function (it) {
          var x = by[it.id] || {};
          it.title = x.title || '';
          it.dimNotes = x.dim_notes && typeof x.dim_notes === 'object' ? x.dim_notes : {};
          return it;
        });
      });
    },

    // ---- 第二期：健檢（規格：supabase/README_checkup.md 第 3.6、3.7 節）----
    // 開始（或接續）健檢：只有客服部、只能對已排定的人；回傳成績單草稿 id（已有自己的草稿會回同一張）。
    // 之後的抽題、評分、送出一律沿用上面的 draw／saveItem／submit，不呼叫 assess_start。
    checkupBegin: function (employeeId, year, quarter) {
      return wrap(sb.rpc('checkup_begin', { p_employee: employeeId, p_year: year, p_quarter: quarter })).then(function (r) { return r.data; });
    },

    // ---- 雙考官輪流考核（規格：supabase/dual_examiner_schema.sql；資料庫沒升級時回「雙考官功能尚未啟用」）----
    // 我是不是考官名單內的人（只有名單內的人才看得到「開始雙考官考核」）；讀不到一律當不是，不擋單人流程
    isExaminer: function (email) {
      return sb.from('assess_examiner_pool').select('email,active').eq('email', String(email || '').toLowerCase()).maybeSingle()
        .then(function (r) { return !r.error && !!(r.data && r.data.active); }, function () { return false; });
    },
    // 開考＋抽籤＋抽題一次完成；已有雙考官草稿會回既有那張（existing=true）。回傳 { assessment_id, existing, my_slot, slots, items }
    startDual: function (employeeId, tenureOverride) {
      return dualRpc('assess_start_dual', { p_employee_id: employeeId, p_tenure_override: tenureOverride || null }).then(function (r) {
        var d = Array.isArray(r.data) ? r.data[0] : r.data;
        if (!d || !d.assessment_id) throw userError('開考後沒有收到考核編號，請重新整理頁面確認草稿清單。');
        return d;
      });
    },
    // 我是考官之一的雙考官草稿（含別人開、輪到我考的）；不含信箱。資料庫沒升級時回空陣列
    myDraftsDual: function () {
      dualOffSeen = false;
      return dualRpc('assess_my_drafts', {}).then(function (r) { return Array.isArray(r.data) ? r.data : []; },
        function (e) { if (e && e.userMessage === DUAL_OFF) { dualOffSeen = true; return []; } throw e; });
    },
    // 最近一次讀雙考官草稿時，資料庫函式是否不存在（雙考官功能尚未啟用）
    dualOff: function () { return dualOffSeen; },
    // 這張雙考官考核的兩位考官：{ my_slot, slots:[{ slot, name, scope, submittedAt, lastSavedAt }] }；信箱只用來認出自己，不回傳
    loadExaminers: function (assessmentId, email) {
      return wrap(sb.from('assessment_examiners').select('slot,email,display_name,scope,submitted_at,last_saved_at')
        .eq('assessment_id', assessmentId).order('slot')).then(function (r) {
        var me = String(email || '').toLowerCase(), my = null;
        var slots = (r.data || []).map(function (x) {
          if (String(x.email || '').toLowerCase() === me) my = x.slot;
          return { slot: x.slot, name: x.display_name, scope: x.scope, submittedAt: x.submitted_at || null, lastSavedAt: x.last_saved_at || null };
        });
        return { my_slot: my, slots: slots };
      });
    },
    // 送出我的題組：回傳 { done, waiting_for_slot }；兩位都送出（done）才產生成績單
    submitPart: function (assessmentId) {
      return dualRpc('assess_submit_part', { p_assessment_id: assessmentId }).then(function (r) { return Array.isArray(r.data) ? r.data[0] : r.data; });
    },
    // 撤回我的送出（整張完成前才可以）
    unsubmitPart: function (assessmentId) {
      return dualRpc('assess_unsubmit_part', { p_assessment_id: assessmentId }).then(function (r) { return r.data; });
    },
    // 題組範例圖片（客服部才讀得到）：{ [item_id]: [{ id, path, mime, size }] }，依 sort_order。
    // 經 assessment_item_secrets 取 item→question_id，再讀 question_images。資料表或機密表讀不到（例如尚未貼 question_images_schema.sql）一律靜默回 {}，不影響評分
    sampleImages: function (itemIds) {
      var DCore = window.AssessDualCore;
      if (!itemIds || !itemIds.length || !DCore) return Promise.resolve({});
      return Promise.resolve(sb.from('assessment_item_secrets').select('item_id,question_id').in('item_id', itemIds)).then(function (r1) {
        if (!r1 || r1.error) return {};
        var seen = {}, qids = [];
        (r1.data || []).forEach(function (s) { if (s.question_id != null && !seen[s.question_id]) { seen[s.question_id] = 1; qids.push(s.question_id); } });
        if (!qids.length) return {};
        return Promise.resolve(sb.from('question_images').select('id,question_id,storage_path,mime,size_bytes,sort_order')
          .in('question_id', qids).order('sort_order')).then(function (r2) {
          return DCore.groupSamples(r1.data, r2 && !r2.error ? (r2.data || []) : []);
        });
      }).then(function (m) { return m; }, function () { return {}; });
    },
    SAMPLE_BUCKET: SAMPLE_BUCKET,
    // 雙考官兩位都送出後，讀成績單摘要（總分、判定、及格線、最弱面向）
    loadSummaryOf: function (assessmentId) {
      return wrap(sb.from('assessment_summaries').select('id,employee_id,tenure,total_score,verdict,pass_line,weakest_dims,item_count')
        .eq('id', assessmentId).maybeSingle()).then(function (r) { return r.data || null; });
    },

    // ---- Storage（bucket assess-notes）----
    uploadImage: function (path, blob, mime) {
      return wrap(sb.storage.from(BUCKET).upload(path, blob, { contentType: mime, upsert: false }));
    },
    // 刪檔：永不拋例外，回傳 { ok, removed }。檔案本來就不存在視為成功。
    removeFiles: function (paths) {
      if (!paths || !paths.length) return Promise.resolve({ ok: true, removed: 0 });
      var store = sb.storage.from(BUCKET);
      paths.forEach(function (p) { forgetUrl(p); });
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
