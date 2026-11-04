/*
 * 建議單資料層（只給 advice.html 用）：只讀。全部查詢走 js/backoffice-api.js（BackofficeApi）的既有函式，
 * 權限一律由資料庫 RLS 把關（客服部、總公司主管、該店店長；前端不做假權限，讀不到就丟白話訊息）。
 * 依賴：BackofficeApi（backoffice-api.js）、AdviceCore（advice-core.js）。
 * 不查機密表（assessment_item_secrets）：建議單不需要題名，loadReportItems 的 withTitle 一律傳 false。
 * 不把成績單內容、session 寫進 console 或瀏覽器儲存。
 */
(function (root) {
  var Api = root.BackofficeApi, Core = root.AdviceCore;
  var NOT_FOUND = '找不到這張成績單，可能不存在，或你沒有權限查看。';

  function userErr(msg) { var e = new Error(msg); e.userMessage = msg; return e; }
  function empName(e) { return ((e.nickname || '').trim() || (e.full_name || '').trim()); }

  // 讀出某張健檢成績單的建議單內容 -> Promise<{ model, row }>；任何不能產生建議單的情況都丟帶 userMessage 的錯誤
  function load(assessmentId) {
    if (!assessmentId) return Promise.reject(userErr('網址缺少成績單編號，請從健檢名單或考核後台的「建議單」連結進來。'));
    return Api.loadAssessmentById(assessmentId).then(function (row) {
      var c = Core.classify(row);
      if (!c.ok) throw userErr(c.error);
      return Promise.all([Api.loadEmployeeAssessments(row.employee_id, 'checkup'), Api.loadEmployee(row.employee_id), Api.loadStores()]).then(function (r) {
        var rows = r[0], emp = r[1], stores = r[2] || [];
        var list = Core.eligibleCheckups(rows), idx = -1;
        list.forEach(function (x, i) { if (x.id === assessmentId) idx = i; });
        if (idx < 0) throw userErr(NOT_FOUND);
        var ids = [assessmentId].concat(idx > 0 ? [list[idx - 1].id] : []);
        var storeName = '';
        stores.forEach(function (s) { if (s.code === row.store_code) storeName = s.name; });
        return Api.loadReportItems(ids, false).then(function (itemsBy) {
          var res = Core.buildAdvice({
            person: { name: emp ? (empName(emp) || emp.id) : row.employee_id, id: row.employee_id, hire: emp ? emp.hire_date : '' },
            storeName: storeName || row.store_code || '',
            assessments: rows, currentId: assessmentId, itemsByAssessment: itemsBy, nowMs: Date.now()
          });
          if (!res.ok) throw userErr(res.error);
          return { model: res.model, row: row };
        });
      });
    });
  }

  root.AdviceApi = { load: load, explain: function (e) { return (e && e.userMessage) || Api.explain(e); } };
})(window);
