/*
 * 名冊「官方 LINE 回覆權限」與「技師／公務機」類別的純函式（不連資料庫、不碰畫面）。
 * 瀏覽器：window.LineCore；Node：module.exports。
 *
 * 用法：
 *   LineCore.EXEMPT_TITLES                 免考核、免健檢的兩種類別 ['技師', '公務機']
 *   LineCore.isExempt(title)               是否為技師／公務機
 *   LineCore.defaultPeriod(title)          新增人員時「回覆狀態」預設：技師／公務機＝已上線，其他＝考核期
 *   LineCore.assessText(p)                 「納入考核」欄文字：是／否／否（免健檢）
 *   LineCore.titleClass(title)             職稱標籤樣式：技師 tech、公務機 dev、其他 ''
 *   LineCore.groupAccess(rows)             line_access 列 -> { 員編: [line_code, ...] }
 *   LineCore.lineSummary(codes, accounts)  某人的 LINE 權限摘要 -> { kind: 'none'|'some'|'all', items: [{code,name}] }
 *                                          items 依 accounts 的 sort_order 排序；全部帳號都有＝all；只認得 accounts 內的代碼
 *   LineCore.matchCategory(title, cat)     類別篩選：空字串＝全部；選「業務」時「業務/助理」也算
 *   LineCore.matchRow(p, f, codes)         名冊一列是否符合篩選 f = { store, q, category, line, status }
 *   LineCore.categoryOptions()             類別下拉選項（全部類別之外的 7 個）
 */
(function (root) {
  var EXEMPT_TITLES = ['技師', '公務機'];
  var CATEGORIES = ['技師', '公務機', '店長', '業務', '收車業務', '助理', '工讀'];

  function isExempt(title) { return EXEMPT_TITLES.indexOf(title) >= 0; }

  function defaultPeriod(title) { return isExempt(title) ? '已上線' : '考核期'; }

  function assessText(p) {
    if (p && p.include_in_assessment) return '是';
    return p && isExempt(p.job_title) ? '否（免健檢）' : '否';
  }

  function titleClass(title) {
    return title === '技師' ? 'tech' : title === '公務機' ? 'dev' : '';
  }

  function groupAccess(rows) {
    var m = {};
    (rows || []).forEach(function (r) {
      (m[r.employee_id] = m[r.employee_id] || []).push(r.line_code);
    });
    return m;
  }

  function lineSummary(codes, accounts) {
    var have = {};
    (codes || []).forEach(function (c) { have[c] = true; });
    var list = (accounts || []).slice().sort(function (a, b) { return a.sort_order - b.sort_order; });
    var items = list.filter(function (a) { return have[a.code]; })
      .map(function (a) { return { code: a.code, name: a.name }; });
    var kind = items.length === 0 ? 'none' : (items.length === list.length ? 'all' : 'some');
    return { kind: kind, items: items };
  }

  function matchCategory(title, cat) {
    if (!cat) return true;
    if (cat === '業務') return title === '業務' || title === '業務/助理';
    return title === cat;
  }

  function matchRow(p, f, codes) {
    f = f || {};
    if (f.store && p.store_code !== f.store) return false;
    if (f.status && p.status !== f.status) return false;
    if (!matchCategory(p.job_title, f.category)) return false;
    if (f.line && (codes || []).indexOf(f.line) < 0) return false;
    var q = String(f.q || '').trim().toLowerCase();
    if (q) {
      var hay = (p.id + ' ' + (p.nickname || '') + ' ' + (p.full_name || '')).toLowerCase();
      if (hay.indexOf(q) < 0) return false;
    }
    return true;
  }

  function categoryOptions() { return CATEGORIES.slice(); }

  var api = {
    EXEMPT_TITLES: EXEMPT_TITLES, isExempt: isExempt, defaultPeriod: defaultPeriod, assessText: assessText,
    titleClass: titleClass, groupAccess: groupAccess, lineSummary: lineSummary,
    matchCategory: matchCategory, matchRow: matchRow, categoryOptions: categoryOptions
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.LineCore = api;
})(typeof window !== 'undefined' ? window : this);
