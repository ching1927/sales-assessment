/*
 * 健檢建議單的純邏輯（不連資料庫、不碰畫面、不連網）。規格見 FEATURES.md「健檢建議單」。
 * 瀏覽器：window.AdviceCore；Node：module.exports。依賴 scoring.js（Scoring）、report-pdf-core.js（ReportPdfCore，沿用成績單 PDF 的面向得分率、比較、走勢）。
 *
 * 用法：
 *   AdviceCore.PASS_LINE                              及格線（取 Scoring 的「正式」合格線，85）
 *   AdviceCore.checkupLabel(year, quarter)            -> '2026 Q4'（缺年度回 ''）
 *   AdviceCore.classify(row)                          單張成績單能不能有建議單 -> { ok:true } 或 { ok:false, code, error }
 *                                                      code：notfound／notcheckup／voided／notsubmitted
 *   AdviceCore.eligibleCheckups(rows)                 該員工全部考核列 -> 只留「kind='checkup'、已送出、未作廢」，由舊到新（同時間依 id）
 *                                                      -> [{ id, ts, date, total, verdict, year, quarter, label }]
 *   AdviceCore.passInfo(total)                        -> { pass, passLine }（85 分以上通過；以十分位整數比較）
 *   AdviceCore.buildAdvice(input)                     把資料整理成建議單內容 -> { ok, model } 或 { ok:false, code, error }
 *   AdviceCore.fileName(model)                        '建議單_姓名_健檢日期.pdf'
 *   AdviceCore.fitOnePage(usedH, contentH, gaps, max) 一頁填滿的高度分配（先給走勢圖，其餘平均加在區塊之間）
 *
 * 「上一次健檢」＝同一員工在本次之前、已送出且未作廢的健檢（一般考核不算）。第一年沒有上一次：compare 為 null、first 為 true。
 * 面向得分率與比較：交給 ReportPdfCore.dimRates／compare（再交給 Scoring）；加考題（is_extra）依規則不計入。
 */
(function (root) {
  var isNode = typeof module !== 'undefined' && module.exports;
  var Scoring = isNode ? require('./scoring.js') : root.Scoring;
  var Core = isNode ? require('./report-pdf-core.js') : root.ReportPdfCore;
  var PASS_LINE = Scoring.verdictFor(100, '正式').passLine;

  function cmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
  function tenth(x) { return Math.round(Number(x) * 10); }
  function fail(code, error) { return { ok: false, code: code, error: error }; }

  function checkupLabel(year, quarter) {
    if (year == null || year === '') return '';
    return year + (quarter == null || quarter === '' ? '' : ' Q' + quarter);
  }

  // 單張成績單能不能有建議單（只有已送出且未作廢的健檢才有）
  function classify(row) {
    if (!row) return fail('notfound', '找不到這張成績單，可能不存在，或你沒有權限查看。');
    if (row.kind !== 'checkup') return fail('notcheckup', '這不是健檢成績單，只有健檢成績單才有建議單。');
    if (row.status === 'voided' || row.voided_at) return fail('voided', '這張健檢成績單已作廢，沒有建議單。');
    if (row.status !== 'submitted') return fail('notsubmitted', '這張健檢成績單還沒送出，送出後才有建議單。');
    return { ok: true };
  }

  function eligibleCheckups(rows) {
    var out = [];
    (rows || []).forEach(function (r) {
      if (!r || r.kind !== 'checkup' || r.status !== 'submitted' || r.voided_at) return;
      if (r.total_score == null) return;
      var iso = r.submitted_at || r.created_at, ts = Date.parse(iso);
      if (isNaN(ts)) return;
      out.push({
        id: r.id, ts: ts, date: Core.taipeiDate(iso), total: Number(r.total_score), verdict: r.verdict || '',
        year: r.checkup_year, quarter: r.checkup_quarter, label: checkupLabel(r.checkup_year, r.checkup_quarter)
      });
    });
    out.sort(function (a, b) { return a.ts - b.ts || cmp(a.id, b.id); });
    return out;
  }

  function passInfo(total) {
    return { pass: tenth(total) >= PASS_LINE * 10, passLine: PASS_LINE };
  }

  // input: { person:{name,id,hire}, storeName, assessments:[該員工全部考核列], currentId, itemsByAssessment:{ id:[題組] }, nowMs }
  function buildAdvice(input) {
    var rows = input.assessments || [];
    var raw = rows.filter(function (a) { return a.id === input.currentId; })[0];
    var c = classify(raw);
    if (!c.ok) return c;
    var list = eligibleCheckups(rows), idx = -1;
    list.forEach(function (r, i) { if (r.id === input.currentId) idx = i; });
    if (idx < 0) return fail('notfound', '找不到這張健檢成績單的有效資料，可能缺少總分或送出時間。');
    var cur = list[idx], prev = idx > 0 ? list[idx - 1] : null;
    var by = input.itemsByAssessment || {};
    var rates = Core.dimRates(by[cur.id] || []);
    if (!rates.ok) return fail('data', rates.error);
    var prevRates = null;
    if (prev) {
      prevRates = Core.dimRates(by[prev.id] || []);
      if (!prevRates.ok) return fail('data', '上一次健檢的資料不完整，無法比較：' + prevRates.error);
    }
    var items = by[cur.id] || [];
    var scored = items.filter(function (it) { return !it.isExtra; }).length;
    var verdict = cur.verdict || (Scoring.verdictFor(cur.total, '正式').verdict);
    var p = passInfo(cur.total);
    var person = input.person || {};
    var model = {
      generated: Core.taipeiToday(input.nowMs),
      person: {
        name: person.name || '', id: person.id || '', store: input.storeName || '',
        hire: raw.hire_date_snapshot || person.hire || ''
      },
      date: cur.date, year: cur.year, quarter: cur.quarter, label: cur.label,
      first: !prev,
      total: cur.total, verdict: verdict, passLine: p.passLine, pass: p.pass,
      scoredCount: scored,
      dims: rates.rows,
      prevLabel: prev ? prev.label : '', prevDate: prev ? prev.date : '', prevTotal: prev ? prev.total : null,
      compare: Core.compare(rates.rows, prevRates && prevRates.rows, cur.total, prev ? prev.total : 0),
      trend: Core.trendSeries(list, cur.id)
    };
    // 走勢點補上年度季次標籤（x 軸用）
    model.trend.points = model.trend.points.map(function (pt, i) {
      return { id: pt.id, date: pt.date, total: pt.total, verdict: pt.verdict, isCurrent: pt.isCurrent, label: list[i].label, year: list[i].year, quarter: list[i].quarter };
    });
    return { ok: true, model: model };
  }

  function fileName(m) { return ('建議單_' + m.person.name + '_' + m.date + '.pdf').replace(/[\\\/:*?"<>|]/g, '_'); }

  /*
   * 一頁填滿：usedH＝目前所有區塊高度合計，contentH＝一頁可用高度，gapCount＝可加間距的區塊數。
   * 回傳 { overflow, slack, trendExtra, gapExtra }：
   *   超出一頁（slack < 0）→ overflow:true，不分配。
   *   否則剩餘高度 60%（最多 maxTrend，預設 120px）先給走勢圖，其餘平均加在每個區塊的下方間距。
   */
  function fitOnePage(usedH, contentH, gapCount, maxTrend) {
    var slack = contentH - usedH;
    if (slack < 0 && slack > -0.5) slack = 0;   // 瀏覽器小數高度的誤差（不到半個像素）不算溢出
    if (slack < 0) return { overflow: true, slack: slack, trendExtra: 0, gapExtra: 0 };
    var cap = maxTrend == null ? 120 : maxTrend;
    var trendExtra = Math.min(cap, Math.floor(slack * 0.6));
    var rest = slack - trendExtra;
    return { overflow: false, slack: slack, trendExtra: trendExtra, gapExtra: gapCount > 0 ? rest / gapCount : 0 };
  }

  var api = {
    PASS_LINE: PASS_LINE, DIMS: Core.DIMS,
    checkupLabel: checkupLabel, classify: classify, eligibleCheckups: eligibleCheckups, passInfo: passInfo,
    buildAdvice: buildAdvice, fileName: fileName, fitOnePage: fitOnePage
  };
  if (isNode) module.exports = api;
  else root.AdviceCore = api;
})(typeof window !== 'undefined' ? window : this);
