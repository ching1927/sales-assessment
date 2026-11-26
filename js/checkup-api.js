/*
 * 每年健檢資料層（只給 checkup.html 用）：登入檢查與五個資料庫函式。
 * 函式、參數、欄位以 supabase/README_checkup.md 第三節為準。
 * 寫入一律走 sb.rpc；權限由資料庫把關。資料庫函式丟的繁中訊息（P0001）直接顯示。
 * 不把 session／token 寫進 console 或網址列。
 */
(function () {
  var cfg = window.APP_CONFIG;
  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY);

  var PAGE = 1000;
  var BUCKET = 'assess-notes', URL_TTL = 3600;     // 抽查截圖放私有 bucket，路徑 spot/{抽查id}/{uuid}.jpg

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

  // 下載管制的資料庫函式；還沒部署時（42883／PGRST202）回固定繁中提示
  function dlRpc(name, args) {
    return sb.rpc(name, args).then(function (r) {
      if (r.error) {
        var c = String(r.error.code || ''), m = String(r.error.message || '').toLowerCase();
        if (c === '42883' || c === 'PGRST202' || m.indexOf('could not find the function') >= 0) {
          var e = new Error('下載管制功能尚未啟用，請聯絡客服部。'); e.userMessage = e.message; e.notDeployed = true; throw e;
        }
        fail(r.error);
      }
      return r.data;
    }, function (e) { fail(e); });
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
    // 各門市異常回覆預警榜（只有彙總：門市、異常回覆張數、人數；三種角色都看得到全部門市）。start、end：YYYY-MM-DD，含頭尾。
    // 資料庫函式還沒部署時（42883／PGRST202）回傳固定的繁中提示，不顯示英文錯誤
    yellowRanking: function (start, end) {
      return sb.rpc('checkup_yellow_ranking', { p_from: start, p_to: end }).then(function (r) {
        if (r.error) {
          var c = String(r.error.code || ''), m = String(r.error.message || '').toLowerCase();
          if (c === '42883' || c === 'PGRST202' || m.indexOf('could not find the function') >= 0 || m.indexOf('does not exist') >= 0) {
            var e = new Error('異常回覆預警榜功能尚未啟用，請聯絡客服部。'); e.userMessage = e.message; e.notDeployed = true; throw e;
          }
          fail(r.error);
        }
        return r.data || [];
      }, function (e) { fail(e); });
    },
    // 各門市面向分析（只有彙總：門市、有勾面向的待加強回覆筆數、七面向被勾次數）。start、end：YYYY-MM-DD，含頭尾。
    // 資料庫函式還沒部署時回傳固定的繁中提示（notDeployed），不顯示英文錯誤
    storeDims: function (start, end) {
      return sb.rpc('checkup_store_dims', { p_from: start, p_to: end }).then(function (r) {
        if (r.error) {
          var c = String(r.error.code || ''), m = String(r.error.message || '').toLowerCase();
          if (c === '42883' || c === 'PGRST202' || m.indexOf('could not find the function') >= 0 || m.indexOf('does not exist') >= 0) {
            var e = new Error('各門市面向分析暫時讀不到，請稍後再試'); e.userMessage = e.message; e.notDeployed = true; throw e;
          }
          fail(r.error);
        }
        return r.data || [];
      }, function (e) { fail(e); });
    },

    // ---- 健檢單下載管制與下載紀錄（supabase/checkup_download_schema.sql）----
    // 記一筆下載；店長日期沒到或不是自己門市資料庫會丟中文訊息。成功才可以產生檔案。
    // o: { store, method:'一鍵下載'|'單人下載', kind:'季度'|'年度', year, quarter, employeeId, employeeName, peopleCount }
    logDownload: function (o) {
      return dlRpc('checkup_log_download', {
        p_store: o.store, p_method: o.method, p_kind: o.kind, p_year: o.year, p_quarter: o.quarter,
        p_employee_id: o.employeeId || null, p_employee_name: o.employeeName || null,
        p_people_count: o.peopleCount == null ? null : o.peopleCount
      });
    },
    // 各店彙總（只有客服部）；method：null 或 '一鍵下載'／'單人下載'
    downloadSummary: function (method) { return dlRpc('checkup_download_summary', { p_method: method || null }).then(function (d) { return d || []; }); },
    // 明細（只有客服部），新到舊，最多 500 筆
    downloadList: function (store, method) {
      return dlRpc('checkup_download_list', { p_store: store || null, p_method: method || null, p_limit: 500 }).then(function (d) { return d || []; });
    },

    // ---- 健檢單（每季抽查彙整）：直接讀 spot_inspections，RLS 已依角色過濾（店長只有自己門市）----
    // 讀 [start, end]（YYYY-MM-DD，含頭尾）內的抽查紀錄；分頁讀完，排序固定
    sheetInspections: function (start, end) {
      var all = [];
      function next(from) {
        return wrap(sb.from('spot_inspections')
          .select('id,employee_id,employee_label,store_code,checked_on,verdict,improve_dims,improve_note,shot_paths,total_score,created_at')
          .gte('checked_on', start).lte('checked_on', end)
          .order('checked_on').order('created_at').order('id').range(from, from + PAGE - 1)).then(function (r) {
          var rows = r.data || [];
          all = all.concat(rows);
          return rows.length === PAGE ? next(from + PAGE) : all;
        });
      }
      return next(0);
    },
    // 截圖簽名網址（私有 bucket assess-notes；storage 的 RLS 決定誰讀得到：店長只有自己門市）
    signedUrl: function (path) {
      return wrap(sb.storage.from(BUCKET).createSignedUrl(path, URL_TTL)).then(function (r) {
        var u = r.data && (r.data.signedUrl || r.data.signedURL);
        if (!u) { var e = new Error('圖片暫時無法顯示，請稍後再試。'); e.userMessage = e.message; throw e; }
        return u;
      });
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
