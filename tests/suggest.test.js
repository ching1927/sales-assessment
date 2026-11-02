/* 弱項建議題組選題測試：node tests/suggest.test.js
 * 亂數一律傳固定函式（永遠選第一個或最後一個），結果可重現。 */
var assert = require('node:assert');
var Suggest = require('../js/suggest.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
var first = function () { return 0; };
var last = function () { return 0.999999; };

var D = Suggest.TAG_DIMS;
function q(id, dims, o) {
  o = o || {};
  return { question_id: id, category: o.cat || '分類' + id, title: '題組' + id, dims: dims, taken_before: !!o.taken, drawn_this_round: !!o.drawn };
}
function prof(dims) { return { n: 3, rates: [], weak: dims.map(function (d, i) { return { dim: d, pct: 40 + i * 10 }; }), always_low: [] }; }
function ids(r) { return r.items.map(function (x) { return x.question_id; }); }
function kinds(r) { return r.items.map(function (x) { return x.kind; }); }
function uniq(a) { return a.filter(function (x, i) { return a.indexOf(x) === i; }).length === a.length; }

// ---- 常數 ----
eq(D, ['資訊正確性', '預設訊息運用', '問題掌握', '主動引導', '風險意識'], '5 個可勾選面向');
eq(Suggest.ALWAYS_DIMS, ['語氣與禮貌', '文字品質'], '每題都評的面向');

// ---- 無弱項 ----
var POOL = [
  q(1, ['主動引導']), q(2, ['主動引導', '風險意識']), q(3, ['風險意識']), q(4, ['問題掌握']),
  q(5, ['主動引導']), q(6, []), q(7, ['風險意識']), q(8, [])
];
eq(Suggest.pick({ n: 0, rates: [], weak: [], always_low: [] }, POOL, 3, first), { items: [], short: false, fewCats: false, empty: true }, '無弱項：empty');
eq(Suggest.pick(null, POOL, 3, first).empty, true, 'profile 為 null 視為無弱項');
eq(Suggest.pick(prof(['主動引導']), POOL, 0, first).empty, true, '題數 0 視為 empty');

// ---- 語氣與文字不進 weak ----
eq(Suggest.pick(prof(['語氣與禮貌', '文字品質']), POOL, 3, first).empty, true, '只有語氣與文字 -> 沒有弱項');
var mixed = Suggest.pick(prof(['語氣與禮貌', '主動引導']), POOL, 3, first);
eq(mixed.items.filter(function (x) { return x.kind === 'weak'; }).every(function (x) { return x.dim === '主動引導'; }), true, '語氣不被當弱項面向');
eq(mixed.items.some(function (x) { return x.dim === '語氣與禮貌' || x.dim === '文字品質'; }), false, '結果不含語氣／文字面向');

// ---- 1 個弱項 ----
var r1 = Suggest.pick(prof(['主動引導']), POOL, 3, first);
eq(kinds(r1), ['weak', 'weak', 'rand'], '1 個弱項、3 題：弱項 2、隨機 1');
eq(r1.items[0].dim, '主動引導', '1 個弱項：面向');
eq(r1.short, false, '1 個弱項：不足旗標為否');
eq(uniq(ids(r1)), true, '同一題不重複');

// ---- 2 個弱項，輪流分配 ----
var r2 = Suggest.pick(prof(['風險意識', '主動引導']), POOL, 4, first);
eq(kinds(r2), ['weak', 'weak', 'weak', 'rand'], '2 個弱項、4 題：弱項 3、隨機 1');
eq(r2.items.slice(0, 3).map(function (x) { return x.dim; }), ['風險意識', '主動引導', '風險意識'], '弱項題輪流分配');
eq(uniq(ids(r2)), true, '2 個弱項：不重複');

// ---- 題數 2／3／4 ----
eq(kinds(Suggest.pick(prof(['風險意識', '主動引導']), POOL, 2, first)), ['weak', 'rand'], '題數 2：弱項 1、隨機 1');
eq(kinds(Suggest.pick(prof(['風險意識', '主動引導']), POOL, 3, first)), ['weak', 'weak', 'rand'], '題數 3：弱項 2、隨機 1');
eq(Suggest.pick(prof(['風險意識', '主動引導']), POOL, 4, first).items.length, 4, '題數 4：共 4 題');

// ---- 標記不足，用隨機補 ----
var thin = [q(1, ['主動引導']), q(2, []), q(3, []), q(4, ['問題掌握'])];
var rs = Suggest.pick(prof(['主動引導', '風險意識']), thin, 3, first);
eq(rs.short, true, '標記不足：short 為 true');
eq(rs.items.length, 3, '標記不足：仍湊滿 3 題');
eq(kinds(rs), ['weak', 'rand', 'rand'], '標記不足：弱項 1、其餘隨機');
eq(Suggest.pick(prof(['風險意識']), [q(1, []), q(2, []), q(3, [])], 3, first).items.every(function (x) { return x.kind === 'rand'; }), true, '完全沒有標記：全部隨機');
eq(Suggest.pick(prof(['主動引導']), [q(1, ['主動引導']), q(2, []), q(3, [])], 3, first).short, true, '標記 1 題但需要 2 題：short');
eq(Suggest.pick(prof(['主動引導']), POOL, 3, first).short, false, '標記足夠：short 為 false');

// ---- 一個弱項沒題，改從另一個弱項補 ----
var only = [q(1, ['風險意識']), q(2, ['風險意識']), q(3, ['風險意識']), q(4, [])];
var rf = Suggest.pick(prof(['主動引導', '風險意識']), only, 4, first);
eq(rf.items.slice(0, 3).map(function (x) { return x.dim; }), ['風險意識', '風險意識', '風險意識'], '一個弱項沒題，由另一弱項補足');
eq(rf.short, false, '補足後不算不足');

// ---- 考過的不選 ----
var taken = [q(1, ['主動引導'], { taken: true }), q(2, ['主動引導'], { taken: true }), q(3, ['主動引導']), q(4, [], { taken: true }), q(5, []), q(6, [])];
var rt = Suggest.pick(prof(['主動引導']), taken, 3, first);
eq(ids(rt).indexOf(1) < 0 && ids(rt).indexOf(2) < 0 && ids(rt).indexOf(4) < 0, true, '考過的題不會被選');
eq(rt.items[0].question_id, 3, '弱項題只選沒考過的');
eq(rt.items.every(function (x) { return x.repeated === false; }), true, '有沒考過的題可選時不重複');

// ---- drawn 優先順序 ----
var dpool = [q(1, ['主動引導']), q(2, [], { drawn: true }), q(3, [], { drawn: true }), q(4, []), q(5, [], { taken: true })];
eq(ids(Suggest.pick(prof(['主動引導']), dpool, 2, first)), [1, 4], '隨機題優先選本輪沒被抽過的');
var dpool2 = [q(1, ['主動引導']), q(2, [], { drawn: true }), q(3, [], { drawn: true }), q(5, [], { taken: true })];
var rd2 = Suggest.pick(prof(['主動引導']), dpool2, 2, first);
eq(ids(rd2), [1, 2], '沒有「未抽過」的就退而求其次選本輪已抽過但沒考過的');
eq(rd2.items[1].repeated, false, '已抽過但沒考過不算 repeated');

// ---- 全部考過才 repeated ----
var all = [q(1, ['主動引導'], { taken: true }), q(2, [], { taken: true }), q(3, [], { taken: true })];
var ra = Suggest.pick(prof(['主動引導']), all, 2, first);
eq(ra.items.length, 2, '全部考過：仍給題');
eq(ra.items.every(function (x) { return x.repeated === true && x.kind === 'rand'; }), true, '全部考過：repeated 為 true，且都是隨機題');
eq(ra.short, true, '全部考過：弱項題湊不滿');
eq(Suggest.pick(prof(['主動引導']), [q(1, [], { taken: true }), q(2, [], { taken: true })], 5, first).items.length, 2, '題庫比題數少：只給得出的題數');

// ---- 亂數函式 ----
eq(Suggest.pick(prof(['主動引導']), POOL, 3, last).items[0].question_id, 5, '亂數取最後一個候選');
eq(uniq(ids(Suggest.pick(prof(['風險意識', '主動引導']), POOL, 4))), true, '預設亂數也不重複');

// ---- swap ----
var cur = Suggest.pick(prof(['風險意識', '主動引導']), POOL, 3, first).items;
var s1 = Suggest.swap(prof(['風險意識', '主動引導']), POOL, cur, 0, first);
eq(s1.kind, 'weak', 'swap：弱項題換成弱項題');
eq(s1.dim, cur[0].dim, 'swap：面向不變');
eq(cur.map(function (x) { return x.question_id; }).indexOf(s1.question_id) < 0, true, 'swap：不與現有題重複（含自己）');
var s2 = Suggest.swap(prof(['風險意識', '主動引導']), POOL, cur, 2, first);
eq(s2.kind, 'rand', 'swap：隨機題換成隨機題');
eq(cur.map(function (x) { return x.question_id; }).indexOf(s2.question_id) < 0, true, 'swap：隨機題不重複');
var curW = [{ question_id: 1, category: '基礎', title: '題組1', dims: ['主動引導'], kind: 'weak', dim: '主動引導', repeated: false }];
var sw = Suggest.swap(prof(['主動引導']), [q(1, ['主動引導']), q(2, []), q(3, ['風險意識'])], curW, 0, first);
eq(sw.kind, 'rand', 'swap：同面向沒題，退而選隨機');
eq(sw.question_id, 2, 'swap：退隨機選到另一題');
eq(Suggest.swap(prof(['主動引導']), [q(1, ['主動引導']), q(2, ['主動引導'], { taken: true }), q(3, [], { taken: true }), q(4, [])], curW, 0, first).question_id, 4, 'swap：不選考過的題');
var sr = Suggest.swap(prof(['主動引導']), [q(1, ['主動引導']), q(2, [], { taken: true })], curW, 0, first);
eq(sr.question_id === 2 && sr.repeated === true, true, 'swap：只剩考過的題才 repeated');
eq(Suggest.swap(prof(['主動引導']), [q(1, ['主動引導'])], curW, 0, first), null, 'swap：沒有可換的回 null');
eq(Suggest.swap(prof(['主動引導']), POOL, cur, 9, first), null, 'swap：index 超出範圍回 null');
var curTwo = [
  { question_id: 1, category: '基礎', title: '題組1', dims: ['主動引導'], kind: 'weak', dim: '主動引導', repeated: false },
  { question_id: 5, category: '基礎', title: '題組5', dims: ['主動引導'], kind: 'weak', dim: '主動引導', repeated: false }
];
eq(Suggest.swap(prof(['主動引導']), [q(1, ['主動引導']), q(5, ['主動引導']), q(2, ['主動引導'])], curTwo, 0, first).question_id, 2, 'swap：避開其他題與自己');
var sd = Suggest.swap(prof(['主動引導']), [q(1, [], { drawn: true }), q(2, [], { drawn: true }), q(3, [])], [{ question_id: 9, category: 'x', title: 'x', dims: [], kind: 'rand', dim: null, repeated: false }], 0, first);
eq(sd.question_id, 3, 'swap：隨機題同樣優先選本輪沒被抽過的');

// ---- 同一分類最多一題 ----
function cats(r) { return r.items.map(function (x) { return x.category; }); }
var CP = [
  q(1, ['主動引導'], { cat: 'A' }), q(2, ['主動引導'], { cat: 'A' }), q(3, ['風險意識'], { cat: 'B' }), q(4, ['風險意識'], { cat: 'B' }),
  q(5, [], { cat: 'C' }), q(6, [], { cat: 'C' }), q(7, [], { cat: 'D' })
];
var rc = Suggest.pick(prof(['主動引導', '風險意識']), CP, 4, first);
eq(uniq(cats(rc)), true, 'pick：同分類不重複');
eq(rc.items.length, 4, 'pick：分類夠時湊滿 4 題');
eq(uniq(cats(Suggest.pick(prof(['主動引導', '風險意識']), CP, 4, last))), true, 'pick：亂數取最後也不同分類');
// 分類不足：只有 2 個分類，要 4 題
var two = [q(1, ['主動引導'], { cat: 'A' }), q(2, ['主動引導'], { cat: 'A' }), q(3, [], { cat: 'B' }), q(4, [], { cat: 'B' }), q(5, [], { cat: 'B' })];
var rt2 = Suggest.pick(prof(['主動引導']), two, 4, first);
eq(rt2.items.length, 2, '分類不足：題數減少為分類數');
eq(uniq(cats(rt2)), true, '分類不足：仍不同分類');
eq(rt2.fewCats, true, '分類不足：fewCats 為 true');
eq(Suggest.pick(prof(['主動引導']), POOL, 3, first).fewCats, false, '分類夠：fewCats 為 false');
// 弱項與隨機同分類：弱項優先
var tie = [q(1, [], { cat: 'A' }), q(2, ['主動引導'], { cat: 'A' })];
var rtie = Suggest.pick(prof(['主動引導']), tie, 2, first);
eq(rtie.items.length, 1, '弱項與隨機同分類：只留一題');
eq(rtie.items[0].question_id === 2 && rtie.items[0].kind === 'weak', true, '弱項與隨機同分類：弱項優先');
// 弱項題第二題與第一題同分類 → 改挑其他分類的弱項題
var wsame = [q(1, ['主動引導'], { cat: 'A' }), q(2, ['主動引導'], { cat: 'A' }), q(3, ['主動引導'], { cat: 'B' }), q(4, [], { cat: 'C' })];
var rw = Suggest.pick(prof(['主動引導']), wsame, 3, first);
eq(rw.items.filter(function (x) { return x.kind === 'weak'; }).map(function (x) { return x.category; }), ['A', 'B'], '弱項題彼此也不同分類');
// 弱項題湊不滿因分類衝突 → short
eq(Suggest.pick(prof(['主動引導']), [q(1, ['主動引導'], { cat: 'A' }), q(2, ['主動引導'], { cat: 'A' }), q(3, [], { cat: 'B' })], 3, first).short, true, '弱項因分類衝突湊不滿：short');
// swap 不造成同分類重複
var curC = Suggest.pick(prof(['主動引導', '風險意識']), CP, 3, first).items; // A、B、隨機
var swc = Suggest.swap(prof(['主動引導', '風險意識']), CP, curC, 0, first);
eq(swc === null || curC.slice(1).every(function (x) { return x.category !== swc.category; }), true, 'swap：不與其他題同分類');
var curA = [
  { question_id: 1, category: 'A', title: 't', dims: ['主動引導'], kind: 'weak', dim: '主動引導', repeated: false },
  { question_id: 3, category: 'B', title: 't', dims: [], kind: 'rand', dim: null, repeated: false }
];
var swA = Suggest.swap(prof(['主動引導']), [q(1, ['主動引導'], { cat: 'A' }), q(2, ['主動引導'], { cat: 'A' }), q(4, ['主動引導'], { cat: 'B' }), q(3, [], { cat: 'B' })], curA, 0, first);
eq(swA.question_id, 2, 'swap：可與被換掉那題同分類，但不與其他題同分類');
eq(Suggest.swap(prof(['主動引導']), [q(1, ['主動引導'], { cat: 'A' }), q(4, ['主動引導'], { cat: 'B' }), q(3, [], { cat: 'B' })], curA, 0, first), null, 'swap：只剩與其他題同分類的題 -> null');
var swR = Suggest.swap(prof(['主動引導']), [q(1, [], { cat: 'A' }), q(2, [], { cat: 'A' }), q(3, [], { cat: 'B' })], [curA[1], { question_id: 1, category: 'A', title: 't', dims: [], kind: 'rand', dim: null, repeated: false }], 1, first);
eq(swR.question_id, 2, 'swap：隨機題換入同分類的另一題');

// ---- 弱項必須低於 85% ----
function profP(arr, low) { return { n: 3, rates: [], weak: arr.map(function (x) { return { dim: x[0], pct: x[1] }; }), always_low: low || [] }; }
eq(Suggest.WEAK_BELOW, 85, 'WEAK_BELOW 為 85');
eq(Suggest.weakOf(profP([['風險意識', 60], ['主動引導', 80]])).map(function (w) { return w.dim; }), ['風險意識', '主動引導'], '兩個都 < 85：都保留');
eq(Suggest.weakOf(profP([['風險意識', 60], ['主動引導', 90]])), [{ dim: '風險意識', pct: 60 }], '只有一個 < 85：只留一個');
eq(Suggest.weakOf(profP([['風險意識', 85]])), [], '剛好 85 不算弱項');
eq(Suggest.weakOf(profP([['風險意識', 84.9]])).length, 1, '84.9 算弱項');
eq(Suggest.weakOf(profP([['風險意識', 90], ['主動引導', 100]])), [], '全部 >= 85：沒有弱項');
eq(Suggest.weakOf(profP([['風險意識', null], ['主動引導', 70]])).map(function (w) { return w.dim; }), ['主動引導'], 'pct 為 null 的忽略');
eq(Suggest.weakOf(profP([['主動引導', 80], ['風險意識', 60]])).map(function (w) { return w.dim; }), ['風險意識', '主動引導'], '由低到高');
eq(Suggest.weakOf(profP([['語氣與禮貌', 10], ['文字品質', 20]])), [], '語氣與文字不算弱項');
var pe = Suggest.pick(profP([['風險意識', 85], ['主動引導', 95]]), POOL, 3, first);
eq(pe, { items: [], short: false, fewCats: false, empty: true }, '全部 >= 85 -> empty');
eq(Suggest.pick(profP([['風險意識', null]]), POOL, 3, first).empty, true, '只有 null -> empty');
var p1 = Suggest.pick(profP([['風險意識', 50], ['主動引導', 88]]), POOL, 3, first);
eq(p1.empty, false, '只有一個 < 85：不是 empty');
eq(p1.items.filter(function (x) { return x.kind === 'weak'; }).every(function (x) { return x.dim === '風險意識'; }), true, '只有一個 < 85：弱項題只針對該面向');
eq(kinds(p1), ['weak', 'weak', 'rand'], '只有一個 < 85：弱項題數照既有邏輯');
eq(Suggest.pick(profP([['風險意識', 85]]), POOL, 3, first).empty, true, '85 邊界：pick 視為沒有弱項');
eq(Suggest.swap(profP([['風險意識', 50]]), POOL, p1.items, 0, first).dim, '風險意識', 'swap 不受影響');
// always_low 不受影響：不論弱項是否保留，profile.always_low 原樣
var lowP = profP([['風險意識', 90]], [{ dim: '語氣與禮貌', pct: 55 }]);
eq(lowP.always_low, [{ dim: '語氣與禮貌', pct: 55 }], 'always_low 保持原樣');
eq(Suggest.pick(profP([['風險意識', 50]], [{ dim: '文字品質', pct: 60 }]), POOL, 3, first).empty, false, 'always_low 不影響弱項判斷');

console.log('通過 ' + passed + ' 項');
