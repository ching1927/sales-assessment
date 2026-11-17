/*
 * 健檢單下載管制的純函式（不連資料庫、不碰畫面）。給 checkup.html「健檢單」「下載紀錄」分頁用。
 * 瀏覽器：window.CheckupDownloadCore；Node：module.exports。
 *
 * 開放日期規則（老闆定案，台北時間，含當日）：
 *   Q1 → 當年 4/10、Q2 → 當年 7/10、Q3 → 當年 10/10；
 *   Q4 的季度健檢單、年度健檢單 → 隔年 1/10。
 *   客服部（cs_admin）與總公司主管（hq_viewer）不受限；店長沒到日期不能下載（資料庫函式也會擋）。
 * 資料庫那一份規則在 supabase/checkup_download_schema.sql（checkup_download_is_open），兩邊要一致。
 *
 * 用法：
 *   openDate(year, quarter, kind)            開放日 'YYYY-MM-DD'；kind＝'quarter'（季度）或 'year'（年度，不看 quarter）；參數不合法回 null
 *   taipeiToday(nowMs)                       台北今天 'YYYY-MM-DD'
 *   isRestricted(role)                       這個角色要不要受日期限制（只有店長受限；沒有角色也視為受限，保守）
 *   isOpen(role, year, quarter, kind, today) 這個角色今天能不能下載
 *   openLabel(year, quarter, kind)           'M/D 開放'
 *   kindLabel(kind)                          '季度' | '年度'
 *   zipName(o)                               ZIP 檔名；o: { kind, year, quarter, storeName }（storeName 空＝全部門市）
 *   groupByStore(sums)                       健檢單清單 → [{ store_code, items }]（門市順序）
 *   zipEntries(groups, nameOf, storeNameOf)  ZIP 內路徑清單 [{ path, sum }]；多門市時依門市分資料夾；同名自動加 (2)
 *   logContent(row)                          下載紀錄「內容」欄文字
 *   logTime(iso)                             下載時間 'YYYY-MM-DD HH:mm'（台北）
 */
(function (root) {
  var isNode = typeof module !== 'undefined' && module.exports;
  var CheckupCore = isNode ? require('./checkup-core.js') : root.CheckupCore;
  var TZ_MS = 8 * 3600000;
  var OPEN_MD = { 1: '04-10', 2: '07-10', 3: '10-10' };   // Q4 與年度是隔年 01-10

  function pad(n) { return (n < 10 ? '0' : '') + n; }

  function openDate(year, quarter, kind) {
    var y = Number(year), q = Number(quarter);
    if (!(y >= 2000 && y <= 2100) || Math.floor(y) !== y) return null;
    if (kind === 'year') return (y + 1) + '-01-10';
    if (kind !== 'quarter') return null;
    if (!(q >= 1 && q <= 4) || Math.floor(q) !== q) return null;
    return q === 4 ? (y + 1) + '-01-10' : y + '-' + OPEN_MD[q];
  }
  function taipeiToday(nowMs) {
    var t = new Date((typeof nowMs === 'number' ? nowMs : Date.now()) + TZ_MS);
    return t.getUTCFullYear() + '-' + pad(t.getUTCMonth() + 1) + '-' + pad(t.getUTCDate());
  }
  function isRestricted(role) { return role !== 'cs_admin' && role !== 'hq_viewer'; }
  function isOpen(role, year, quarter, kind, today) {
    if (!isRestricted(role)) return true;
    var d = openDate(year, quarter, kind);
    if (!d || typeof today !== 'string') return false;
    return today >= d;   // 'YYYY-MM-DD' 字串可直接比大小；含當日
  }
  function openLabel(year, quarter, kind) {
    var d = openDate(year, quarter, kind);
    return d ? (Number(d.slice(5, 7)) + '/' + Number(d.slice(8, 10)) + ' 開放') : '';
  }
  function kindLabel(kind) { return kind === 'year' ? '年度' : '季度'; }

  function safe(s) { return String(s == null ? '' : s).replace(/[\\\/:*?"<>|]/g, '_'); }
  function zipName(o) {
    var store = o.storeName ? safe(o.storeName) : '全部門市';
    return o.kind === 'year' ? '年度健檢單_' + store + '_' + o.year + '.zip'
      : '健檢單_' + store + '_' + o.year + 'Q' + o.quarter + '.zip';
  }

  function groupByStore(sums) {
    var by = {}, order = [];
    (sums || []).forEach(function (s) {
      if (!by[s.store_code]) { by[s.store_code] = []; order.push(s.store_code); }
      by[s.store_code].push(s);
    });
    return CheckupCore.sortStores(order.map(function (c) { return { store_code: c, items: by[c] }; }), 'store_code');
  }
  // nameOf(sum) → PDF 檔名；storeNameOf(code) → 門市名稱。只有一個門市時不分資料夾
  function zipEntries(groups, nameOf, storeNameOf) {
    var multi = (groups || []).length > 1, used = {}, out = [];
    (groups || []).forEach(function (g) {
      var folder = multi ? safe(storeNameOf(g.store_code)) + '/' : '';
      g.items.forEach(function (s) {
        var base = nameOf(s), path = folder + base, n = 1;
        while (used[path]) {
          n++;
          path = folder + base.replace(/(\.[^.]*)?$/, function (ext) { return '(' + n + ')' + (ext || ''); });
        }
        used[path] = true;
        out.push({ path: path, sum: s });
      });
    });
    return out;
  }

  function logContent(r) {
    var period = r.kind === '年度' ? r.year + ' 年度' : r.year + ' 第' + r.quarter + '季';
    if (r.method === '一鍵下載') return period + '｜全店 ' + (r.people_count == null ? 0 : r.people_count) + ' 人';
    return (r.employee_name || '') + (r.employee_id ? '（' + r.employee_id + '）' : '') + '｜' + period;
  }
  function logTime(iso) { return CheckupCore.formatScheduled(iso); }

  var api = { openDate: openDate, taipeiToday: taipeiToday, isRestricted: isRestricted, isOpen: isOpen, openLabel: openLabel, kindLabel: kindLabel,
    zipName: zipName, groupByStore: groupByStore, zipEntries: zipEntries, logContent: logContent, logTime: logTime };
  if (isNode) module.exports = api;
  else root.CheckupDownloadCore = api;
})(typeof window !== 'undefined' ? window : this);
