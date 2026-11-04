/* 健檢建議單純邏輯測試：node tests/advice-core.test.js
 * 「現在」一律傳固定值，結果可重現。 */
var assert = require('node:assert');
var A = require('../js/advice-core.js');
var Scoring = require('../js/scoring.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function ok(cond, label) { assert.ok(cond, label); passed++; }

var NOW = Date.parse('2026-11-03T10:00:00+08:00');
var DIMS = Scoring.DIMENSIONS.map(function (d) { return d.name; });
var LV = { o: '優', g: '良', w: '待加強', f: '不及格', n: '不適用' };
function lv(s) { var o = {}; DIMS.forEach(function (d, i) { o[d] = LV[s.charAt(i)]; }); return o; }
function item(id, seq, s, extra) {
  var levels = lv(s);
  return { id: id, seq: seq, category: '分類', code: 'Q' + seq, levels: levels, item_score: Scoring.scoreItem(levels).score, isExtra: !!extra };
}
// 一張健檢成績單（總分與判定用 Scoring 算，身分一律「正式」）
function chk(id, iso, year, quarter, itemsLevels, over) {
  var r = Scoring.scoreAssessment(itemsLevels.map(lv), '正式');
  var row = { id: id, kind: 'checkup', checkup_year: year, checkup_quarter: quarter, status: 'submitted', tenure: '正式',
    total_score: r.total, verdict: r.verdict, pass_line: r.passLine, hire_date_snapshot: '2025-03-01',
    created_at: iso, submitted_at: iso, voided_at: null, store_code: '中和' };
  Object.keys(over || {}).forEach(function (k) { row[k] = over[k]; });
  return row;
}
function exam(id, iso) {
  var r = Scoring.scoreAssessment([lv('ooooooo')], '正式');
  return { id: id, kind: 'exam', checkup_year: null, checkup_quarter: null, status: 'submitted', tenure: '正式', total_score: r.total, verdict: r.verdict,
    pass_line: 85, hire_date_snapshot: '2025-03-01', created_at: iso, submitted_at: iso, voided_at: null, store_code: '中和' };
}
function itemsOf(levelsList) { return levelsList.map(function (s, i) { return item('i' + i, i + 1, s); }); }

var L24 = ['ggwwgog', 'wggwwgg'];        // 2024 健檢
var L25 = ['gogwgog', 'gggwggo', 'ogggwog'];   // 2025 健檢
var L26 = ['ogogwog', 'ooggwgo', 'ogoggoo'];   // 2026 健檢
var rows = [
  chk('c24', '2024-10-08T10:00:00+08:00', 2024, 4, L24),
  chk('c25', '2025-10-14T10:00:00+08:00', 2025, 4, L25),
  chk('c26', '2026-10-20T10:00:00+08:00', 2026, 4, L26),
  exam('e1', '2026-01-10T10:00:00+08:00'),                       // 一般考核：不算健檢
  chk('cdraft', '2026-10-25T10:00:00+08:00', 2027, 1, L26, { status: 'draft', total_score: null, verdict: null, submitted_at: null }),
  chk('cvoid', '2025-05-01T10:00:00+08:00', 2025, 2, L26, { status: 'voided', voided_at: '2025-05-02T10:00:00+08:00' })
];
var itemsBy = { c24: itemsOf(L24), c25: itemsOf(L25), c26: itemsOf(L26) };
function input(over) {
  var i = { person: { name: '王小明', id: 'E001', hire: '2025-03-01' }, storeName: '中和店', assessments: rows, currentId: 'c26', itemsByAssessment: itemsBy, nowMs: NOW };
  Object.keys(over || {}).forEach(function (k) { i[k] = over[k]; });
  return i;
}

// ---- 基本常數與標籤 ----
eq(A.PASS_LINE, 85, '及格線 85');
eq(A.checkupLabel(2026, 4), '2026 Q4', '標籤');
eq(A.checkupLabel(null, null), '', '缺年度標籤為空');

// ---- classify：誰有建議單 ----
eq(A.classify(null).code, 'notfound', '查無資料');
eq(A.classify(exam('e1', '2026-01-10T10:00:00+08:00')).code, 'notcheckup', '一般考核沒有建議單');
eq(A.classify(rows[4]).code, 'notsubmitted', '草稿（未送出）沒有建議單');
eq(A.classify(rows[5]).code, 'voided', '已作廢沒有建議單');
eq(A.classify(chk('x', '2026-10-20T10:00:00+08:00', 2026, 4, L26, { status: 'voided', voided_at: null })).code, 'voided', 'status=voided 也算作廢');
eq(A.classify(rows[2]), { ok: true }, '已送出且未作廢的健檢可以有建議單');
ok(/不是健檢/.test(A.classify(rows[3]).error) && /還沒送出/.test(A.classify(rows[4]).error) && /作廢/.test(A.classify(rows[5]).error), '訊息是白話中文');

// ---- eligibleCheckups：只留已送出、未作廢的健檢，由舊到新 ----
var el = A.eligibleCheckups(rows);
eq(el.map(function (r) { return r.id; }), ['c24', 'c25', 'c26'], '排除一般考核、草稿、作廢；由舊到新');
eq(el.map(function (r) { return r.label; }), ['2024 Q4', '2025 Q4', '2026 Q4'], '年度季次標籤');
eq(el[2].date, '2026-10-20', '日期用台北日期');
eq(A.eligibleCheckups(null), [], '空輸入');
eq(A.eligibleCheckups([chk('a', '2026-01-01T00:00:00Z', 2026, 1, L26, { total_score: null })]), [], '沒有總分的排除');
eq(A.eligibleCheckups([chk('b', '壞日期', 2026, 1, L26, { created_at: '壞日期', submitted_at: null })]), [], '壞日期的排除');
// 同時間依 id
var tie = A.eligibleCheckups([chk('b2', '2026-03-01T00:00:00Z', 2026, 1, L26), chk('b1', '2026-03-01T00:00:00Z', 2026, 1, L26)]);
eq(tie.map(function (r) { return r.id; }), ['b1', 'b2'], '同時間依 id 排序');

// ---- 85 線通過與否 ----
eq(A.passInfo(85), { pass: true, passLine: 85 }, '85.0 通過');
eq(A.passInfo(84.9), { pass: false, passLine: 85 }, '84.9 未通過');
eq(A.passInfo(100).pass, true, '100 通過');
eq(A.passInfo(0).pass, false, '0 未通過');
eq(Scoring.scoreAssessment([lv('oofoooo')], '正式').total, 85, '測試資料：這組剛好 85.0');
var edge = A.buildAdvice(input({ assessments: [chk('x', '2026-10-20T10:00:00+08:00', 2026, 4, ['oofoooo'])], currentId: 'x', itemsByAssessment: { x: itemsOf(['oofoooo']) } }));
eq(edge.model.pass, true, '剛好 85.0：建議單顯示通過');
var low = A.buildAdvice(input({ assessments: [chk('x', '2026-10-20T10:00:00+08:00', 2026, 4, ['oofoooo'], { total_score: 84.9, verdict: '需複訓' })], currentId: 'x', itemsByAssessment: { x: itemsOf(['oofoooo']) } }));
eq(low.model.pass, false, '84.9：建議單顯示未通過');
eq(low.model.verdict, '需複訓', '判定用成績單上的判定');

// ---- 有上一次（非首次）----
var r26 = A.buildAdvice(input());
ok(r26.ok, '2026 健檢建議單可建立');
var m = r26.model;
eq(m.first, false, '不是首次');
eq(m.label, '2026 Q4', '本次標籤');
eq(m.prevLabel, '2025 Q4', '上一次是 2025 Q4（不是作廢的 2025 Q2、也不是一般考核）');
eq(m.prevDate, '2025-10-14', '上一次日期');
eq(m.person, { name: '王小明', id: 'E001', store: '中和店', hire: '2025-03-01' }, '考生資料');
eq(m.generated, '2026-11-03', '產生日期');
eq(m.date, '2026-10-20', '健檢日期');
eq(m.scoredCount, 3, '計分題組數');
eq(m.dims.length, 7, '七個面向');
// 面向得分率與比較完全由 Scoring 算：與直接呼叫 Scoring.scoreAssessment 一致
var sc26 = Scoring.scoreAssessment(L26.map(lv), '正式'), sc25 = Scoring.scoreAssessment(L25.map(lv), '正式');
eq(m.total, sc26.total, '總分與 Scoring 一致');
eq(m.dims.map(function (d) { return d.pct; }), DIMS.map(function (d) { return sc26.dimAverages[d]; }), '面向得分率與 Scoring 一致');
ok(m.compare && m.compare.rows.length === 7, '有比較資料');
eq(m.compare.totalDiff, Math.round((sc26.total - sc25.total) * 10) / 10, '總分差');
// 差異與進步、退步
var diffs = DIMS.map(function (d) { return Math.round((sc26.dimAverages[d] - sc25.dimAverages[d]) * 10) / 10; });
eq(m.compare.rows.map(function (r) { return r.diff; }), diffs, '各面向差異（本次 − 上一次）');
var mx = Math.max.apply(null, diffs), mn = Math.min.apply(null, diffs);
eq(m.compare.best, mx > 0 ? { names: DIMS.filter(function (d, i) { return diffs[i] === mx; }), value: mx } : null, '進步最多面向');
eq(m.compare.worst, mn < 0 ? { names: DIMS.filter(function (d, i) { return diffs[i] === mn; }), value: -mn } : null, '退步最多面向');
ok(m.compare.best && m.compare.best.value > 0, '這組資料確實有進步面向');

// ---- 退步面向、全退步、全持平的情況 ----
var dn = A.buildAdvice(input({ currentId: 'c25' }));            // 2025 比 2024：看另一組
ok(dn.ok && dn.model.prevLabel === '2024 Q4', '2025 的上一次是 2024');
var same = A.buildAdvice(input({ assessments: [chk('p', '2025-10-01T10:00:00+08:00', 2025, 4, L26), chk('q', '2026-10-01T10:00:00+08:00', 2026, 4, L26)], currentId: 'q', itemsByAssessment: { p: itemsOf(L26), q: itemsOf(L26) } }));
eq(same.model.compare.best, null, '全持平：沒有進步面向');
eq(same.model.compare.worst, null, '全持平：沒有退步面向');
eq(same.model.compare.totalDiff, 0, '全持平：總分差 0');
var worse = A.buildAdvice(input({ assessments: [chk('p', '2025-10-01T10:00:00+08:00', 2025, 4, L26), chk('q', '2026-10-01T10:00:00+08:00', 2026, 4, L24)], currentId: 'q', itemsByAssessment: { p: itemsOf(L26), q: itemsOf(L24) } }));
ok(worse.model.compare.totalDiff < 0, '退步：總分差為負');
eq(worse.model.compare.best === null || worse.model.compare.best.value > 0, true, '退步時進步面向為空或正值');
ok(worse.model.compare.worst && worse.model.compare.worst.value > 0, '退步：有退步最多面向');

// ---- 歷年走勢：3 年、2 年、1 年 ----
eq(m.trend.points.length, 3, '3 年走勢有 3 點');
eq(m.trend.curIdx, 2, '本次是第 3 點');
eq(m.trend.points.map(function (p) { return p.isCurrent; }), [false, false, true], '只有本次標記為 isCurrent');
eq(m.trend.points.map(function (p) { return p.label; }), ['2024 Q4', '2025 Q4', '2026 Q4'], '走勢點帶年度季次');
eq(m.trend.points[0].total, Scoring.scoreAssessment(L24.map(lv), '正式').total, '走勢點總分');
var t2 = A.buildAdvice(input({ currentId: 'c25' })).model.trend;
eq(t2.points.length, 3, '看 2025 的建議單，走勢仍畫「全部歷年」（含之後的 2026）');
eq(t2.curIdx, 1, '2025 的建議單本次標在第 2 點');
var two = A.buildAdvice(input({ assessments: [rows[0], rows[1]], currentId: 'c25' }));
eq(two.model.trend.points.length, 2, '2 年走勢有 2 點');
eq(two.model.trend.curIdx, 1, '2 年走勢本次在第 2 點');
// 走勢不混入一般考核
ok(m.trend.points.every(function (p) { return p.id !== 'e1'; }), '走勢不含一般考核');

// ---- 首次健檢 ----
var first = A.buildAdvice(input({ assessments: [rows[0], rows[3]], currentId: 'c24' }));
ok(first.ok, '首次健檢建議單可建立（即使有更早的一般考核）');
eq(first.model.first, true, '首次健檢 first=true');
eq(first.model.compare, null, '首次健檢沒有比較資料');
eq(first.model.prevLabel, '', '首次健檢沒有上一次標籤');
eq(first.model.prevTotal, null, '首次健檢沒有上一次總分');
eq(first.model.trend.points.length, 1, '首次健檢走勢只有 1 點');
eq(first.model.trend.curIdx, 0, '首次健檢本次在第 1 點');
eq(first.model.dims.length, 7, '首次健檢仍有七面向');

// ---- 錯誤情境 ----
eq(A.buildAdvice(input({ currentId: 'zzz' })).code, 'notfound', '查無');
eq(A.buildAdvice(input({ currentId: 'e1' })).code, 'notcheckup', '一般考核');
eq(A.buildAdvice(input({ currentId: 'cdraft' })).code, 'notsubmitted', '草稿');
eq(A.buildAdvice(input({ currentId: 'cvoid' })).code, 'voided', '作廢');
eq(A.buildAdvice(input({ itemsByAssessment: { c25: itemsOf(L25) } })).code, 'data', '本次沒有題組資料');
eq(A.buildAdvice(input({ itemsByAssessment: { c26: itemsOf(L26) } })).code, 'data', '上一次沒有題組資料');
ok(/上一次健檢/.test(A.buildAdvice(input({ itemsByAssessment: { c26: itemsOf(L26) } })).error), '上一次資料不全的訊息');
eq(A.buildAdvice(input({ assessments: [] })).code, 'notfound', '沒有任何資料');

// ---- 加考題不計入面向 ----
var withExtra = itemsOf(L26).concat([item('ix', 9, 'ffffff' + 'f', true)]);
var ex = A.buildAdvice(input({ itemsByAssessment: { c24: itemsOf(L24), c25: itemsOf(L25), c26: withExtra } }));
eq(ex.model.dims, m.dims, '加考題不影響面向得分率');
eq(ex.model.scoredCount, 3, '加考題不算計分題組');

// ---- 檔名 ----
eq(A.fileName(m), '建議單_王小明_2026-10-20.pdf', '檔名');
eq(A.fileName({ person: { name: 'a/b:c' }, date: '2026-01-02' }), '建議單_a_b_c_2026-01-02.pdf', '檔名排除非法字元');

// ---- 一頁填滿的高度計算 ----
var H = 1123 - 34 - 44;
var fit = A.fitOnePage(900, H, 6);
eq(fit.overflow, false, '有剩餘：不溢出');
eq(fit.slack, H - 900, '剩餘高度');
eq(fit.trendExtra, Math.min(120, Math.floor((H - 900) * 0.6)), '走勢圖先拿 60%（上限 120）');
ok(Math.abs(fit.trendExtra + fit.gapExtra * 6 - fit.slack) < 1e-9, '走勢加高＋區塊間距＝剩餘高度，剛好填滿');
var big = A.fitOnePage(600, H, 6);
eq(big.trendExtra, 120, '剩很多時走勢圖加高最多 120px');
ok(Math.abs(big.trendExtra + big.gapExtra * 6 - big.slack) < 1e-9, '剩很多仍然剛好填滿');
var exact = A.fitOnePage(H, H, 6);
eq(exact, { overflow: false, slack: 0, trendExtra: 0, gapExtra: 0 }, '剛好一頁：不加不減');
var over = A.fitOnePage(H + 1, H, 6);
eq(over.overflow, true, '多 1px 就是溢出');
eq(over.trendExtra + over.gapExtra, 0, '溢出不分配');
eq(A.fitOnePage(H + 0.3, H, 6).overflow, false, '不到半像素的小數誤差不算溢出');
eq(A.fitOnePage(H + 0.6, H, 6).overflow, true, '超過半像素算溢出');
eq(A.fitOnePage(900, H, 0).gapExtra, 0, '沒有可加間距的區塊時不除以零');
eq(A.fitOnePage(900, H, 6, 40).trendExtra, 40, '可指定走勢加高上限');

console.log('advice-core：' + passed + ' 項全部通過');
