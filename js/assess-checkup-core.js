/*
 * 考試接健檢的純函式（不連資料庫、不碰畫面）。規則見 supabase/README_checkup.md 第 3.6、3.7 節。
 * 瀏覽器：window.AssessCheckupCore；Node：module.exports。
 *
 * 網址合約（由健檢名單 checkup.html 連過來，不可更改）：
 *   assess.html?mode=checkup&emp=<員工編號>&year=<年>&quarter=<季>
 *
 * 用法：
 *   AssessCheckupCore.PASS_LINE                    健檢及格線 85
 *   AssessCheckupCore.parseParams(search)          網址參數 -> { isCheckup, ok, emp, year, quarter, error }
 *                                                  mode 不是 checkup 時 isCheckup=false（一般考核，其餘欄位不用看）
 *   AssessCheckupCore.titleOf(year, quarter)       '健檢（2026 年 第 4 季）'
 *   AssessCheckupCore.checkupUrl(emp, y, q)        回到這場健檢的網址（含 encodeURIComponent）
 *   AssessCheckupCore.adviceUrl(assessmentId)      'advice.html?assessment=<id>'
 *   AssessCheckupCore.LIST_URL                     'checkup.html'
 *   AssessCheckupCore.passed(total, passLine)      總分是否達及格線（passLine 缺值用 85）
 */
(function (root) {
  var PASS_LINE = 85;
  var LIST_URL = 'checkup.html';
  var EMP_RE = /^[A-Za-z0-9_.\-]{1,40}$/;

  function parseParams(search) {
    var p;
    try { p = new URLSearchParams(String(search == null ? '' : search)); } catch (e) { p = new URLSearchParams(''); }
    if (p.get('mode') !== 'checkup') return { isCheckup: false, ok: false, emp: '', year: 0, quarter: 0, error: '' };
    var emp = String(p.get('emp') == null ? '' : p.get('emp')).trim();
    var ys = String(p.get('year') == null ? '' : p.get('year')).trim();
    var qs = String(p.get('quarter') == null ? '' : p.get('quarter')).trim();
    var out = { isCheckup: true, ok: false, emp: emp, year: 0, quarter: 0, error: '' };
    if (!emp || !ys || !qs) { out.error = '健檢網址缺少員工編號、年度或季次，請從健檢名單重新進入。'; return out; }
    if (!EMP_RE.test(emp)) { out.error = '健檢網址的員工編號格式不正確，請從健檢名單重新進入。'; return out; }
    if (!/^\d{4}$/.test(ys) || +ys < 2000 || +ys > 2100) { out.error = '健檢網址的年度不正確，請從健檢名單重新進入。'; return out; }
    if (!/^[1-4]$/.test(qs)) { out.error = '健檢網址的季次必須是 1 到 4，請從健檢名單重新進入。'; return out; }
    out.ok = true; out.year = +ys; out.quarter = +qs;
    return out;
  }

  function titleOf(year, quarter) { return '健檢（' + year + ' 年 第 ' + quarter + ' 季）'; }

  function checkupUrl(emp, year, quarter) {
    return 'assess.html?mode=checkup&emp=' + encodeURIComponent(emp) + '&year=' + encodeURIComponent(year) + '&quarter=' + encodeURIComponent(quarter);
  }

  function adviceUrl(assessmentId) { return 'advice.html?assessment=' + encodeURIComponent(assessmentId); }

  function passed(total, passLine) {
    var line = Number(passLine);
    if (!isFinite(line) || passLine == null || passLine === '') line = PASS_LINE;
    return Number(total) >= line;
  }

  var api = {
    PASS_LINE: PASS_LINE, LIST_URL: LIST_URL,
    parseParams: parseParams, titleOf: titleOf, checkupUrl: checkupUrl, adviceUrl: adviceUrl, passed: passed
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.AssessCheckupCore = api;
})(typeof window !== 'undefined' ? window : this);
