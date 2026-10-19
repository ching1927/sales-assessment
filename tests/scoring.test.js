/* 評分計算測試：node tests/scoring.test.js
 * V1~V6 為固定測資（資料庫端會用同一組數字驗證，數字不可改）；V7 為邊界與五入測資。 */
var assert = require('node:assert');
var Scoring = require('../js/scoring.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

// 依面向順序傳入七個等級，組成題組物件
function mk(arr) {
  var o = {};
  Scoring.DIMENSIONS.forEach(function (d, i) { o[d.name] = arr[i]; });
  return o;
}
function pts(r) { return Scoring.DIMENSIONS.map(function (d) { return r.dimPoints[d.name]; }); }
var ALL = Scoring.DIMENSIONS.map(function (d) { return d.name; });

// ---- 基本常數 ----
eq(Scoring.DIMENSIONS.reduce(function (s, d) { return s + d.weight; }, 0), 100, '配分合計');
eq(ALL, ['資訊正確性', '預設訊息運用', '問題掌握', '主動引導', '風險意識', '語氣與禮貌', '文字品質'], '面向順序');
eq(Scoring.LEVELS, { '優': 100, '良': 70, '待加強': 40, '不及格': 0 }, '等級');

// ---- V1 ----
var V1 = mk(['良', '優', '良', '待加強', '優', '良', '優']);
var r1 = Scoring.scoreItem(V1);
eq(r1.ok, true, 'V1 ok');
eq(r1.score, 77.5, 'V1 題組分數');
eq(pts(r1), [14, 15, 10.5, 6, 15, 7, 10], 'V1 面向得分');
eq(r1.applicableWeight, 100, 'V1 適用配分');
eq(r1.naDims, [], 'V1 不適用');
eq(r1.weakest, ['主動引導'], 'V1 題組最弱');
var a1 = Scoring.scoreAssessment([V1], '新人');
eq(a1.total, 77.5, 'V1 單題組總分');
eq(a1.verdict, '及格', 'V1 新人判定');
eq(a1.passLine, 70, 'V1 新人合格線');
var a1f = Scoring.scoreAssessment([V1], '正式');
// 正式員工 77.5 分落在 75–84.9，判定為「需複訓」
eq(a1f.verdict, '需複訓', 'V1 正式判定（77.5 落在 75–84）');
eq(a1f.passLine, 85, 'V1 正式合格線');
eq(a1.weakest, ['主動引導'], 'V1 整場最弱');

// ---- V2：風險意識、文字品質不適用 ----
var V2 = mk(['良', '優', '良', '待加強', '不適用', '良', '不適用']);
var r2 = Scoring.scoreItem(V2);
eq(r2.ok, true, 'V2 ok');
eq(r2.applicableWeight, 75, 'V2 適用配分合計');
eq(r2.score, 70.0, 'V2 題組分數');
eq(r2.naDims, ['風險意識', '文字品質'], 'V2 不適用面向');
eq(pts(r2), [14, 15, 10.5, 6, null, 7, null], 'V2 面向得分（不適用為 null）');
eq(r2.weakest, ['主動引導'], 'V2 題組最弱');
eq(Scoring.scoreAssessment([V2], '新人').verdict, '及格', 'V2 新人');
eq(Scoring.scoreAssessment([V2], '正式').verdict, '不及格', 'V2 正式');
eq(Scoring.scoreAssessment([V2], '新人').weakest, ['主動引導'], 'V2 整場最弱');

// ---- V3：七項全優 ----
var V3 = mk(['優', '優', '優', '優', '優', '優', '優']);
var a3 = Scoring.scoreAssessment([V3], '新人');
eq(Scoring.scoreItem(V3).score, 100.0, 'V3 題組分數');
eq(a3.total, 100.0, 'V3 總分');
eq(a3.verdict, '優秀', 'V3 新人');
eq(Scoring.scoreAssessment([V3], '正式').verdict, '優秀', 'V3 正式');
eq(Scoring.scoreItem(V3).weakest, ALL, 'V3 題組最弱（七個並列）');
eq(a3.weakest, ALL, 'V3 整場最弱（七個並列）');

// ---- V4：七項全不及格 ----
var V4 = mk(['不及格', '不及格', '不及格', '不及格', '不及格', '不及格', '不及格']);
var a4 = Scoring.scoreAssessment([V4], '新人');
eq(Scoring.scoreItem(V4).score, 0.0, 'V4 題組分數');
eq(a4.total, 0.0, 'V4 總分');
eq(a4.verdict, '不及格', 'V4 新人');
eq(Scoring.scoreAssessment([V4], '正式').verdict, '不及格', 'V4 正式');
eq(a4.weakest, ALL, 'V4 整場最弱（七個並列）');
eq(Scoring.scoreItem(V4).weakest, ALL, 'V4 題組最弱（七個並列）');

// ---- V5：V1(77.5) 與 V3(100.0) 兩個題組 ----
// 十分位 775 + 1000 = 1775，n=2 → floor((3550+2)/4)=888 → 88.8（88.75 五入）
var a5 = Scoring.scoreAssessment([V1, V3], '新人');
eq(a5.ok, true, 'V5 ok');
eq(a5.itemScores.map(function (x) { return x.score; }), [77.5, 100], 'V5 各題組分數');
eq(a5.total, 88.8, 'V5 總分');
eq(a5.verdict, '優秀', 'V5 新人');
eq(Scoring.scoreAssessment([V1, V3], '正式').verdict, '及格', 'V5 正式');
eq(a5.weakest, ['主動引導'], 'V5 整場最弱');
eq(a5.dimAverages['主動引導'], 70, 'V5 主動引導等級平均 (40+100)/2');
eq(a5.dimAverages['資訊正確性'], 85, 'V5 資訊正確性等級平均 (70+100)/2');

// 整場最弱：不適用的面向只在適用題組內平均；全部不適用者排除
var NA2 = mk(['優', '優', '優', '優', '良', '不適用', '不適用']);
var aNA = Scoring.scoreAssessment([NA2, NA2], '新人');
eq(aNA.dimAverages['語氣與禮貌'], null, '全題組不適用的面向平均為 null');
eq(aNA.weakest, ['風險意識'], '全題組不適用的面向不參與最弱');
// 三題組、平均 70 與 (100+100+40)/3=80 比較：交叉相乘需正確
var T1 = mk(['優', '優', '優', '優', '優', '優', '優']);
var T2 = mk(['優', '優', '優', '良', '優', '優', '優']);
var T3 = mk(['優', '優', '優', '待加強', '優', '優', '優']);
eq(Scoring.scoreAssessment([T1, T2, T3], '新人').weakest, ['主動引導'], '三題組最弱（平均 70）');
eq(Scoring.scoreAssessment([T1, T2, T3], '新人').dimAverages['主動引導'], 70, '三題組等級平均 (100+70+40)/3');

// ---- V6：不合法輸入 ----
var bad;
bad = Scoring.scoreItem(mk(['不適用', '不適用', '不適用', '優', '優', '優', '優']));
eq(bad.ok, false, 'V6 不適用 3 個');
assert.ok(typeof bad.error === 'string' && bad.error.length > 0); passed++;
var missing = mk(['優', '優', '優', '優', '優', '優', '優']); delete missing['問題掌握'];
eq(Scoring.scoreItem(missing).ok, false, 'V6 缺一個面向');
eq(Scoring.scoreItem(mk(['優', '優', '普通', '優', '優', '優', '優'])).ok, false, 'V6 未知等級');
eq(Scoring.scoreItem(mk(['優', '優', undefined, '優', '優', '優', '優'])).ok, false, 'V6 面向值為空');
eq(Scoring.scoreItem(null).ok, false, 'V6 題組為 null');
eq(Scoring.scoreAssessment([V1], '實習').ok, false, 'V6 身分實習');
eq(Scoring.scoreAssessment([V1]).ok, false, 'V6 沒給身分');
eq(Scoring.scoreAssessment([], '新人').ok, false, 'V6 題組數 0');
eq(Scoring.scoreAssessment(null, '新人').ok, false, 'V6 題組不是陣列');
var bad2 = Scoring.scoreAssessment([V1, mk(['優', '優', '優', '優', '優', '優', '普通'])], '新人');
eq(bad2.ok, false, 'V6 整場中有不合法題組');
eq(Scoring.verdictFor(80, '實習').ok, false, 'V6 verdictFor 身分錯誤');
eq(Scoring.scoreItem(mk(['優', '優', '優', '優', '優', '不適用', '不適用'])).ok, true, '不適用剛好 2 個仍合法');

// ---- V7：邊界與五入 ----
// 以下「題組分數」皆由 scoreItem 算出，推導以十分位整數表示（例：700 ＝ 70.0）。
function v(t, tenure) { return Scoring.verdictFor(t, tenure).verdict; }

// V7-1 新人 70.0：七項全良＝S 7000、W 100 → 十分位 floor((140000+100)/200)=700 → 70.0
var G70 = mk(['良', '良', '良', '良', '良', '良', '良']);
eq(Scoring.scoreItem(G70).score, 70.0, 'V7-1 題組 70.0');
eq(Scoring.scoreAssessment([G70], '新人').verdict, '及格', 'V7-1 新人 70.0 剛好及格');
eq(Scoring.scoreAssessment([G70], '正式').verdict, '不及格', 'V7-1 正式 70.0 不及格');

// V7-2 新人 69.9：四題組十分位 700、700、700、695 → 和 2795，n=4
//   floor((2×2795+4)/8)=floor(5594/8)=699（平均 698.75 五入 699）→ 69.9 → 需複訓
//   G695（良、優、優、優、良、不及格、不及格）的題組分數為 69.5，下面先驗證這個數字
var G695 = mk(['良', '優', '優', '優', '良', '不及格', '不及格']);
eq(Scoring.scoreItem(G695).score, 69.5, 'V7-2 題組 69.5');
var a72 = Scoring.scoreAssessment([G70, G70, G70, G695], '新人');
eq(a72.total, 69.9, 'V7-2 總分 69.9');
eq(a72.verdict, '需複訓', 'V7-2 新人 69.9 需複訓');

// V7-3 新人／正式 84.9：四題組十分位 850、850、855、840 → 和 3395，n=4
//   floor((2×3395+4)/8)=floor(6794/8)=849（平均 848.75 五入 849）→ 84.9
var G850 = mk(['優', '優', '優', '優', '待加強', '優', '待加強']); // S 8500 → 85.0
var G855 = mk(['優', '優', '優', '優', '良', '優', '不及格']);     // S 8550 → 85.5
var G840 = mk(['優', '優', '優', '優', '優', '待加強', '不及格']); // S 8400 → 84.0
eq([Scoring.scoreItem(G850).score, Scoring.scoreItem(G855).score, Scoring.scoreItem(G840).score], [85.0, 85.5, 84.0], 'V7-3 題組分數');
var a73 = Scoring.scoreAssessment([G850, G850, G855, G840], '新人');
eq(a73.total, 84.9, 'V7-3 總分 84.9');
eq(a73.verdict, '及格', 'V7-3 新人 84.9 及格（未達優秀 85）');
eq(Scoring.scoreAssessment([G850, G850, G855, G840], '正式').verdict, '需複訓', 'V7-3 正式 84.9 需複訓（未達及格 85）');

// V7-4 85.0：單題組 850 → 85.0；新人剛好優秀、正式剛好及格
eq(Scoring.scoreAssessment([G850], '新人').total, 85.0, 'V7-4 總分 85.0');
eq(Scoring.scoreAssessment([G850], '新人').verdict, '優秀', 'V7-4 新人 85.0 優秀');
eq(Scoring.scoreAssessment([G850], '正式').verdict, '及格', 'V7-4 正式 85.0 及格');

// V7-5 正式 94.9：四題組十分位 1000、955、940、900 → 和 3795，n=4
//   floor((2×3795+4)/8)=floor(7594/8)=949（平均 948.75 五入 949）→ 94.9 → 正式及格；新人優秀
var G1000 = V3;
var G955 = mk(['優', '優', '優', '優', '良', '優', '優']);
var G940 = mk(['優', '優', '優', '優', '優', '優', '待加強']);
var G900 = mk(['優', '優', '優', '優', '優', '優', '不及格']);
var a75 = Scoring.scoreAssessment([G1000, G955, G940, G900], '正式');
eq(a75.total, 94.9, 'V7-5 總分 94.9');
eq(a75.verdict, '及格', 'V7-5 正式 94.9 及格');
eq(Scoring.scoreAssessment([G1000, G955, G940, G900], '新人').verdict, '優秀', 'V7-5 新人 94.9 優秀');

// V7-6 正式 95.0：兩題組 1000、900 → 和 1900，n=2 → floor((3800+2)/4)=950 → 95.0 → 正式優秀
var a76 = Scoring.scoreAssessment([G1000, G900], '正式');
eq(a76.total, 95.0, 'V7-6 總分 95.0');
eq(a76.verdict, '優秀', 'V7-6 正式 95.0 優秀');

// V7-7 正式 75.0 / 74.9
//   75.0：單題組 750（優,優,優,優,待加強,待加強,不及格：S 7500）→ 正式需複訓（≥75）
//   74.9：四題組 750、750、750、745 → 和 2995，n=4 → floor((5990+4)/8)=floor(5994/8)=749（748.75 五入 749）→ 正式不及格
var G750 = mk(['優', '優', '優', '優', '待加強', '待加強', '不及格']);
var G745 = mk(['優', '優', '優', '良', '待加強', '待加強', '待加強']);
eq([Scoring.scoreItem(G750).score, Scoring.scoreItem(G745).score], [75.0, 74.5], 'V7-7 題組分數');
eq(Scoring.scoreAssessment([G750], '正式').verdict, '需複訓', 'V7-7 正式 75.0 需複訓');
var a77 = Scoring.scoreAssessment([G750, G750, G750, G745], '正式');
eq(a77.total, 74.9, 'V7-7 總分 74.9');
eq(a77.verdict, '不及格', 'V7-7 正式 74.9 不及格');
eq(Scoring.scoreAssessment([G750, G750, G750, G745], '新人').verdict, '及格', 'V7-7 新人 74.9 及格');

// V7-8 題組層級的 .x5 五入（整數運算）
//   優,優,優,優,待加強,不適用,不適用：S 7100、W 80 → 71×10/80… 20×7100+80=142080，÷160=888 → 88.8（88.75 五入）
//   優,優,優,優,不及格,不適用,不適用：S 6500、W 80 → (130000+80)/160=812 → 81.3（81.25 五入）
var T88 = mk(['優', '優', '優', '優', '待加強', '不適用', '不適用']);
var T81 = mk(['優', '優', '優', '優', '不及格', '不適用', '不適用']);
eq(Scoring.scoreItem(T88).score, 88.8, 'V7-8 題組 88.75 → 88.8');
eq(Scoring.scoreItem(T81).score, 81.3, 'V7-8 題組 81.25 → 81.3');

// V7-9 總分 .x5 五入（浮點容易出錯的情形）：四題組十分位 705、705、700、700
//   和 2810，n=4 → floor((5620+4)/8)=703（平均 702.5 剛好 .5 → 五入 703）→ 70.3
var G705 = mk(['優', '優', '優', '良', '待加強', '待加強', '不及格']);
eq(Scoring.scoreItem(G705).score, 70.5, 'V7-9 題組 70.5');
eq(Scoring.scoreAssessment([G705, G705, G70, G70], '新人').total, 70.3, 'V7-9 總分 70.25 → 70.3');
// 八個題組全是 88.8（10 位 888）與 V5 同型：兩個 88.8 的平均仍為 88.8
eq(Scoring.scoreAssessment([T88, T88], '新人').total, 88.8, 'V7-9 兩個 88.8 平均 88.8');

// V7-10 verdictFor 直接帶入邊界值
eq(['新人', '正式'].map(function (t) { return [69.9, 70, 84.9, 85].map(function (s) { return v(s, t); }); }),
  [['需複訓', '及格', '及格', '優秀'], ['不及格', '不及格', '需複訓', '及格']], 'V7-10 邊界判定表');
eq([59.9, 60, 74.9, 75, 94.9, 95].map(function (s) { return v(s, '新人'); }),
  ['不及格', '需複訓', '及格', '及格', '優秀', '優秀'], 'V7-10 新人 59.9/60');
eq([74.9, 75, 94.9, 95].map(function (s) { return v(s, '正式'); }), ['不及格', '需複訓', '及格', '優秀'], 'V7-10 正式 74.9/75/94.9/95');
eq(Scoring.verdictFor(70, '新人').passLine, 70, 'V7-10 新人合格線');
eq(Scoring.verdictFor(70, '正式').passLine, 85, 'V7-10 正式合格線');

console.log('通過 ' + passed + ' 項');
