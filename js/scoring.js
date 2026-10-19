/*
 * 評分計算（純計算，不連資料庫、不碰畫面）。
 * 瀏覽器：window.Scoring；Node：module.exports。
 *
 * 用法：
 *   Scoring.DIMENSIONS                       // [{name, weight}] 七面向，順序固定，配分合計 100
 *   Scoring.LEVELS                           // {優:100, 良:70, 待加強:40, 不及格:0}（百分比整數）；另有字串「不適用」
 *   Scoring.scoreItem({資訊正確性:'良', ...}) // 算一個題組
 *     -> { ok, error?, score, dimPoints:{面向:得分|null}, applicableWeight, naDims:[], weakest:[] }
 *   Scoring.scoreAssessment([題組等級, ...], '新人'|'正式') // 算整場考核
 *     -> { ok, error?, itemScores:[...], total, verdict, passLine, weakest:[], dimAverages:{面向:等級平均|null} }
 *   Scoring.verdictFor(total, '新人'|'正式')  // -> { ok, verdict, passLine } 或 { ok:false, error }
 *
 * 不合法輸入一律回 { ok:false, error:'白話中文訊息' }，不拋例外。
 * 所有四捨五入（五入 half up）一律用整數運算，避免浮點誤差：
 *   題組分數十分位 = floor((20×S + W) ÷ (2×W))，S＝Σ(配分×等級%)、W＝適用配分合計
 *   總分十分位     = floor((2×Σ題組十分位 + n) ÷ (2×n))
 */
(function (root) {
  var DIMENSIONS = [
    { name: '資訊正確性', weight: 20 },
    { name: '預設訊息運用', weight: 15 },
    { name: '問題掌握', weight: 15 },
    { name: '主動引導', weight: 15 },
    { name: '風險意識', weight: 15 },
    { name: '語氣與禮貌', weight: 10 },
    { name: '文字品質', weight: 10 }
  ];
  var LEVELS = { '優': 100, '良': 70, '待加強': 40, '不及格': 0 };
  var NA = '不適用';
  var MAX_NA = 2;

  // 判定門檻（以十分位整數表示，避免浮點）：[優秀, 及格, 需複訓]
  var RULES = {
    '新人': { passLine: 70, cuts: [850, 700, 600] },
    '正式': { passLine: 85, cuts: [950, 850, 750] }
  };

  function has(obj, key) { return Object.prototype.hasOwnProperty.call(obj, key); }
  function fail(msg) { return { ok: false, error: msg }; }

  // 整數除法（皆為非負整數）
  function idiv(a, b) { return Math.floor(a / b); }

  // 回傳等級百分比；NA 回 null；未知回 undefined
  function levelPct(lv) {
    if (lv === NA) return null;
    return (typeof lv === 'string' && has(LEVELS, lv)) ? LEVELS[lv] : undefined;
  }

  // 從 [{name, pct, ...}] 找出等級%最低者（並列全列），回傳名稱陣列（維持面向順序）
  function lowestNames(rows) {
    var min = null;
    rows.forEach(function (r) { if (min === null || r.pct < min) min = r.pct; });
    return rows.filter(function (r) { return r.pct === min; }).map(function (r) { return r.name; });
  }

  function scoreItem(levels) {
    if (!levels || typeof levels !== 'object') return fail('題組的評分資料不完整，請七個面向都評分。');
    var S = 0, W = 0, naDims = [], dimPoints = {}, rows = [];
    for (var i = 0; i < DIMENSIONS.length; i++) {
      var d = DIMENSIONS[i];
      if (!has(levels, d.name) || levels[d.name] === null || levels[d.name] === undefined || levels[d.name] === '') {
        return fail('「' + d.name + '」還沒有評分，七個面向都要選一個等級。');
      }
      var pct = levelPct(levels[d.name]);
      if (pct === undefined) return fail('「' + d.name + '」的等級「' + String(levels[d.name]) + '」不正確，只能選優、良、待加強、不及格或不適用。');
      if (pct === null) {
        naDims.push(d.name);
        dimPoints[d.name] = null;
      } else {
        S += d.weight * pct;
        W += d.weight;
        dimPoints[d.name] = (d.weight * pct) / 100;
        rows.push({ name: d.name, pct: pct });
      }
    }
    if (naDims.length > MAX_NA) return fail('一個題組最多只能有 ' + MAX_NA + ' 個面向標「不適用」，請重新評分或重抽題組。');
    // 最多 2 個不適用，W 至少 80，不會是 0
    var tenth = idiv(20 * S + W, 2 * W);
    return {
      ok: true,
      score: tenth / 10,
      tenth: tenth,
      dimPoints: dimPoints,
      applicableWeight: W,
      naDims: naDims,
      weakest: lowestNames(rows)
    };
  }

  function verdictFor(total, tenure) {
    if (!has(RULES, tenure)) return fail('身分只能是「新人」或「正式」。');
    if (typeof total !== 'number' || !isFinite(total)) return fail('總分不是有效的數字。');
    var r = RULES[tenure];
    var t = Math.round(total * 10); // 總分本身已是 1 位小數，轉成整數十分位比較
    var verdict = t >= r.cuts[0] ? '優秀' : t >= r.cuts[1] ? '及格' : t >= r.cuts[2] ? '需複訓' : '不及格';
    return { ok: true, verdict: verdict, passLine: r.passLine };
  }

  function scoreAssessment(itemsLevels, tenure) {
    if (!has(RULES, tenure)) return fail('身分只能是「新人」或「正式」。');
    if (!Array.isArray(itemsLevels) || itemsLevels.length === 0) return fail('至少要有一個題組的評分才能結算。');
    var itemScores = [], sumTenth = 0;
    var sums = {}, counts = {};
    DIMENSIONS.forEach(function (d) { sums[d.name] = 0; counts[d.name] = 0; });
    for (var i = 0; i < itemsLevels.length; i++) {
      var r = scoreItem(itemsLevels[i]);
      if (!r.ok) return fail('第 ' + (i + 1) + ' 個題組：' + r.error);
      itemScores.push(r);
      sumTenth += r.tenth;
      DIMENSIONS.forEach(function (d) {
        var p = levelPct(itemsLevels[i][d.name]);
        if (p !== null) { sums[d.name] += p; counts[d.name] += 1; }
      });
    }
    var n = itemScores.length;
    var totalTenth = idiv(2 * sumTenth + n, 2 * n);
    var total = totalTenth / 10;
    var v = verdictFor(total, tenure);

    // 每個面向的等級平均；最弱＝平均最低（交叉相乘比較 sum/count，不用浮點）
    var dimAverages = {}, best = null, weakest = [];
    DIMENSIONS.forEach(function (d) {
      var c = counts[d.name];
      dimAverages[d.name] = c === 0 ? null : sums[d.name] / c;
      if (c === 0) return;
      if (best === null || sums[d.name] * best.c < best.s * c) { best = { s: sums[d.name], c: c }; }
    });
    DIMENSIONS.forEach(function (d) {
      var c = counts[d.name];
      if (c !== 0 && sums[d.name] * best.c === best.s * c) weakest.push(d.name);
    });

    return {
      ok: true,
      itemScores: itemScores,
      total: total,
      verdict: v.verdict,
      passLine: v.passLine,
      weakest: weakest,
      dimAverages: dimAverages
    };
  }

  var api = {
    DIMENSIONS: DIMENSIONS,
    LEVELS: LEVELS,
    NOT_APPLICABLE: NA,
    scoreItem: scoreItem,
    scoreAssessment: scoreAssessment,
    verdictFor: verdictFor
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.Scoring = api;
})(typeof window !== 'undefined' ? window : null);
