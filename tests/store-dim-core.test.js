/* 各門市面向分析純函式測試：node tests/store-dim-core.test.js */
var assert = require('node:assert');
var D = require('../js/store-dim-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function row(code, weak, counts) { return { store_code: code, store_name: code + '店', weak_records: weak, dim_counts: counts }; }
function codes(rs) { return rs.map(function (r) { return r.store_code; }); }
function ranks(rs) { return rs.map(function (r) { return r.rank; }); }

eq(D.DIMS.length, 7, '七個面向');
eq(D.DIMS[0], '資訊正確性', '第一個面向');
eq(D.DIMS[6], '文字品質', '最後一個面向');

// ---- 排序鍵 ----
eq(D.normKey('total'), 'total', 'total');
eq(D.normKey('3'), 3, '字串數字');
eq(D.normKey(0), 0, '0 是第一個面向');
eq(D.normKey('7'), 'total', '超出範圍當合計');
eq(D.normKey('x'), 'total', '亂填當合計');
eq(D.normKey(undefined), 'total', '沒給當合計');
eq(D.keyLabel('total'), '全部面向合計', '合計名稱');
eq(D.keyLabel(2), '問題掌握', '單一面向名稱');

// ---- 格式化 ----
eq(D.formatPct(1, 4), '25%', '25%');
eq(D.formatPct(1, 3), '33%', '四捨五入');
eq(D.formatPct(0, 5), '0%', '0 次');
eq(D.formatPct(3, 0), '—', 'weak 為 0 顯示 —');
eq(D.formatAvg({ weak: 4, total: 5 }), '1.3', '平均 1.25 -> 1.3');
eq(D.formatAvg({ weak: 0, total: 0 }), '—', 'weak 為 0 平均顯示 —');
eq(D.fileBase(2026, 'Q4'), '各門市面向分析_2026_第4季', '季檔名');
eq(D.fileBase(2026, 'Y'), '各門市面向分析_2026_全年', '全年檔名');

// ---- 單一面向排序（資料 A：面向 0 的比例 = 2/4=50%、1/10=10%、3/6=50%、0/5=0%）----
var A = [row('中和', 4, [2, 0, 0, 0, 0, 0, 0]), row('新莊', 10, [1, 0, 0, 0, 0, 0, 0]), row('樹林', 6, [3, 0, 0, 0, 0, 0, 0]), row('高雄', 5, [0, 0, 0, 0, 0, 0, 0])];
var rA = D.rank(A, 0);
eq(codes(rA), ['高雄', '新莊', '中和', '樹林'], '單一面向：比例低的在前，並列依輸入順序（中和先於樹林）');
eq(ranks(rA), [1, 2, 3, 3], '並列同名次（中和、樹林都是第 3）');
eq(D.rank(A, '0').map(function (r) { return r.store_code; }), ['高雄', '新莊', '中和', '樹林'], '字串鍵 "0" 等同 0');

// ---- 並列後名次跳號 ----
var T = [row('a', 2, [1, 0, 0, 0, 0, 0, 0]), row('b', 4, [2, 0, 0, 0, 0, 0, 0]), row('c', 3, [2, 0, 0, 0, 0, 0, 0]), row('d', 10, [1, 0, 0, 0, 0, 0, 0])];
eq(codes(D.rank(T, 0)), ['d', 'a', 'b', 'c'], '1/10 最低、1/2＝2/4 並列、2/3 最高');
eq(ranks(D.rank(T, 0)), [1, 2, 2, 4], '並列後名次跳號：1、2、2、4');

// ---- 合計排序（平均每筆勾幾個面向）----
// x：合計 2÷4＝0.5；y：合計 1÷2＝0.5；z：合計 9÷3＝3（大於 100% 也照排）；w：合計 1÷10＝0.1
var B = [row('x', 4, [1, 1, 0, 0, 0, 0, 0]), row('y', 2, [1, 0, 0, 0, 0, 0, 0]), row('z', 3, [3, 3, 3, 0, 0, 0, 0]), row('w', 10, [0, 0, 0, 0, 0, 0, 1])];
var rB = D.rank(B, 'total');
eq(codes(rB), ['w', 'x', 'y', 'z'], '合計：w 最低，x、y 並列（依輸入順序），z 最高');
eq(ranks(rB), [1, 2, 2, 4], '合計並列名次');
eq(rB[3].total, 9, '合計次數');
eq(D.formatAvg(rB[3]), '3.0', '合計平均可大於 1（顯示 3.0 個，不是百分比）');
eq(D.rank(B, 'bad').map(function (r) { return r.store_code; }), ['w', 'x', 'y', 'z'], '亂填排序鍵當合計');

// ---- weak_records=0：排最後、名次 null、比例 null ----
var Z = [row('p', 0, [0, 0, 0, 0, 0, 0, 0]), row('q', 5, [5, 0, 0, 0, 0, 0, 0]), row('r', 2, [0, 0, 0, 0, 0, 0, 0])];
['total', 0].forEach(function (k) {
  var rz = D.rank(Z, k);
  eq(codes(rz), ['r', 'q', 'p'], 'weak=0 排最後（key=' + k + '）');
  eq(ranks(rz), [1, 2, null], 'weak=0 名次為 null（key=' + k + '）');
});
var rz0 = D.rank(Z, 'total')[2];
eq(rz0.rates, [null, null, null, null, null, null, null], 'weak=0 比例為 null');
eq(rz0.avg, null, 'weak=0 平均為 null');
eq(D.rank([row('p', 0, [1, 1, 1, 1, 1, 1, 1])], 0)[0].rank, null, '只有 weak=0 的門市也沒名次');
eq(D.rank([], 'total'), [], '空資料');
eq(D.rank(null, 'total'), [], 'null 資料');

// ---- 最常被勾：並列全列、全 0 為空 ----
var tp = D.rank([row('m', 5, [0, 2, 0, 2, 1, 0, 0]), row('n', 5, [0, 0, 0, 0, 0, 0, 0]), row('o', 5, [0, 0, 0, 0, 0, 0, 3])], 'total');
function byCode(rs, c) { return rs.filter(function (r) { return r.store_code === c; })[0]; }
eq(byCode(tp, 'm').tops, ['預設訊息運用', '主動引導'], '最常被勾並列全列');
eq(byCode(tp, 'n').tops, [], '全 0 沒有最常被勾');
eq(byCode(tp, 'o').tops, ['文字品質'], '只有一個最常被勾');

// ---- mine 標記 ----
var mn = D.rank(A, 0, '新莊');
eq(mn.map(function (r) { return r.mine; }), [false, true, false, false], '只有自己的門市 mine');
eq(D.rank(A, 0, null).every(function (r) { return r.mine === false; }), true, '沒有 myStore 時都不是 mine');
eq(D.rank(A, 0).every(function (r) { return r.mine === false; }), true, '沒傳 myStore 時都不是 mine');

// ---- 比例 ----
var pr = byCode(D.rank([row('k', 4, [1, 2, 0, 4, 0, 0, 0])], 'total'), 'k');
eq(pr.rates, [0.25, 0.5, 0, 1, 0, 0, 0], '各面向比例＝被勾次數÷weak');
eq(pr.total, 7, '合計次數');
eq(D.formatAvg(pr), '1.8', '平均 7÷4＝1.75 -> 1.8');
eq(pr.store_name, 'k店', '門市名稱');
eq(D.rank([{ store_code: 'c1', weak_records: 1, dim_counts: [] }], 0)[0].store_name, 'c1', '沒有名稱時用代碼');

// ---- 防呆：dim_counts 長度不是 7、缺值、非數字 ----
var bad = D.rank([
  row('s1', 4, [1, 2]),
  row('s2', 4, [1, null, 'a', undefined, -3, 2.9, 1, 99, 99]),
  { store_code: 's3', store_name: 's3', weak_records: 4 },
  { store_code: 's4', store_name: 's4', weak_records: 'abc', dim_counts: [1, 1, 1, 1, 1, 1, 1] },
  { store_code: 's5', store_name: 's5', weak_records: 4, dim_counts: 'xyz' }
], 'total');
eq(byCode(bad, 's1').counts, [1, 2, 0, 0, 0, 0, 0], '太短：缺的當 0');
eq(byCode(bad, 's2').counts, [1, 0, 0, 0, 0, 2, 1], '太長只取前 7；null／文字／負數當 0，小數無條件捨去');
eq(byCode(bad, 's3').counts, [0, 0, 0, 0, 0, 0, 0], '沒有 dim_counts 當全 0');
eq(byCode(bad, 's4').weak, 0, 'weak_records 不是數字當 0');
eq(byCode(bad, 's4').rank, null, 'weak 當 0 就沒有名次');
eq(byCode(bad, 's5').counts, [0, 0, 0, 0, 0, 0, 0], 'dim_counts 不是陣列當全 0');
eq(byCode(bad, 's1').counts.length, 7, '長度一律 7');

// ---- 摘要卡片 ----
var S = D.rank([row('lo', 10, [1, 0, 0, 0, 0, 0, 0]), row('mid', 5, [1, 1, 0, 0, 0, 0, 0]), row('hi', 2, [2, 2, 0, 0, 0, 0, 0]), row('none', 0, [0, 0, 0, 0, 0, 0, 0])], 'total');
var sm = D.summary(S, 'total');
eq(sm.best, { names: ['lo店'], value: '0.1 個' }, '合計最低：顯示 N.N 個');
eq(sm.worst, { names: ['hi店'], value: '2.0 個' }, '合計最高：顯示 N.N 個');
eq(sm.topDim, { names: ['資訊正確性'], count: 4 }, '全公司最常被勾（四次）');
var S0 = D.rank([row('lo', 10, [1, 0, 0, 0, 0, 0, 0]), row('mid', 5, [1, 1, 0, 0, 0, 0, 0]), row('hi', 2, [2, 2, 0, 0, 0, 0, 0])], 0);
var sm0 = D.summary(S0, 0);
eq(sm0.best, { names: ['lo店'], value: '10%' }, '單一面向最低：顯示百分比');
eq(sm0.worst, { names: ['hi店'], value: '100%' }, '單一面向最高：顯示百分比');
var sm1 = D.summary(D.rank([row('a', 4, [1, 0, 0, 0, 0, 0, 0]), row('b', 4, [1, 0, 0, 0, 0, 0, 0])], 0), 0);
eq(sm1.best, { names: ['a店', 'b店'], value: '25%' }, '最低並列全列');
eq(sm1.worst, null, '全部並列時沒有最高');
eq(D.summary(D.rank([row('a', 4, [1, 0, 0, 0, 0, 0, 0]), row('b', 4, [0, 0, 0, 0, 0, 0, 0])], 0), 0).best, { names: ['b店'], value: '0%' }, '0% 也算最低');
var smTie = D.summary(D.rank([row('a', 4, [3, 0, 0, 3, 0, 0, 0])], 'total'), 'total');
eq(smTie.topDim, { names: ['資訊正確性', '主動引導'], count: 3 }, '全公司最常被勾並列全列');
var smE = D.summary(D.rank([row('a', 0, [0, 0, 0, 0, 0, 0, 0])], 'total'), 'total');
eq(smE, { best: null, worst: null, topDim: null }, '全 0 或沒名次：卡片都是空');
eq(D.summary([], 'total'), { best: null, worst: null, topDim: null }, '空資料摘要');

// ---- 紅色深淺基準 ----
eq(D.maxRate(D.rank([row('a', 4, [1, 0, 0, 0, 0, 0, 0]), row('b', 2, [0, 0, 0, 0, 0, 1, 0]), row('c', 0, [0, 0, 0, 0, 0, 0, 0])], 'total')), 0.5, '全表最大單格比例');
eq(D.maxRate([]), 0, '空資料最大比例 0');

// ---- 月份期間 monthRange ----
eq(D.monthRange('2026-10', '2026-12'), { from: '2026-10-01', to: '2026-12-31', label: '2026年10月～2026年12月' }, '三個月區間');
eq(D.monthRange('2026-11', '2026-11'), { from: '2026-11-01', to: '2026-11-30', label: '2026年11月' }, '單月 30 天');
eq(D.monthRange('2024-02', '2024-02').to, '2024-02-29', '閏年 2 月 29 天');
eq(D.monthRange('2026-02', '2026-02').to, '2026-02-28', '平年 2 月 28 天');
eq(D.monthRange('1900-02', '1900-02').to, '1900-02-28', '1900 不是閏年');
eq(D.monthRange('2000-02', '2000-02').to, '2000-02-29', '2000 是閏年');
eq(D.monthRange('2025-11', '2026-02'), { from: '2025-11-01', to: '2026-02-28', label: '2025年11月～2026年2月' }, '跨年區間');
eq(D.monthRange('2026-01', '2026-01').label, '2026年1月', '月份不補 0');
eq(D.monthRange('2026-12', '2026-10'), null, '迄早於起不合法');
eq(D.monthRange('', '2026-10'), null, '起空值不合法');
eq(D.monthRange('2026-10', null), null, '迄空值不合法');
eq(D.monthRange('2026-13', '2026-13'), null, '13 月不合法');
eq(D.monthRange('2026-1', '2026-10'), null, '格式不對不合法');
eq(D.monthLabel('2026-11', '2026-11'), '2026年11月', '單月文字');
eq(D.monthFileBase('2026-10', '2026-12'), '各門市面向分析_2026-10_2026-12', '區間檔名');
eq(D.monthFileBase('2026-11', '2026-11'), '各門市面向分析_2026-11', '單月檔名');

// ---- 快速鈕（今天一律台北時間）----
eq(D.presetRange('cur', '2026-11-26'), { from: '2026-11', to: '2026-11' }, '本月');
eq(D.presetRange('prev', '2026-11-26'), { from: '2026-10', to: '2026-10' }, '上月');
eq(D.presetRange('prev', '2026-01-05'), { from: '2025-12', to: '2025-12' }, '一月的上月是去年 12 月');
eq(D.presetRange('q', '2026-11-26'), { from: '2026-10', to: '2026-11' }, '本季：本季第一個月到本月');
eq(D.presetRange('q', '2026-03-31'), { from: '2026-01', to: '2026-03' }, '三月屬第一季');
eq(D.presetRange('q', '2026-07-01'), { from: '2026-07', to: '2026-07' }, '七月是第三季第一個月');
eq(D.presetRange('y', '2026-11-26'), { from: '2026-01', to: '2026-11' }, '今年：1 月到本月');
eq(D.taipeiToday(Date.UTC(2026, 10, 25, 17, 0, 0)), '2026-11-26', '台北時間跨日（UTC 17:00＝台北隔天 01:00）');
eq(D.taipeiToday(Date.UTC(2026, 10, 25, 15, 59, 59)), '2026-11-25', '台北時間未跨日');

// ---- 全公司彙總、選擇項目 ----
var CR = D.rank([row('甲', 4, [1, 2, 0, 4, 0, 0, 0]), row('乙', 6, [3, 0, 0, 2, 0, 0, 0]), row('丙', 0, [0, 0, 0, 0, 0, 0, 0])], 'total', '甲');
var co = D.companyTotal(CR);
eq(co.store_name, '全公司', '全公司名稱');
eq(co.weak, 10, '全公司筆數加總');
eq(co.counts, [4, 2, 0, 6, 0, 0, 0], '全公司各面向次數加總');
eq(co.total, 12, '全公司合計');
eq(co.rates, [0.4, 0.2, 0, 0.6, 0, 0, 0], '全公司比例＝加總次數÷加總筆數');
eq(co.tops, ['主動引導'], '全公司最常被勾');
eq(D.pickItem(CR, '').store_name, '全公司', '空代碼＝全公司');
eq(D.pickItem(CR, '不存在').store_name, '全公司', '找不到門市＝全公司');
eq(D.pickItem(CR, '乙').store_code, '乙', '指定門市');
eq(D.pickItem(CR, '乙').counts, [3, 0, 0, 2, 0, 0, 0], '指定門市資料');
var coE = D.companyTotal(D.rank([row('甲', 0, [0, 0, 0, 0, 0, 0, 0])], 'total'));
eq(coE.weak, 0, '全公司沒資料：筆數 0');
eq(coE.rates, [null, null, null, null, null, null, null], '全公司沒資料：比例 null（分母為 0）');
eq(D.radii(coE), null, '全公司沒資料：不畫圖（半徑 null）');
eq(D.companyTotal([]).weak, 0, '空資料全公司筆數 0');
eq(D.radii(D.companyTotal([])), null, '空資料不畫圖');
eq(D.radii(null), null, 'null 不畫圖');

// ---- 星狀圖半徑＝1 − 比例 ----
eq(D.radii(co), [0.6, 0.8, 1, 0.4, 1, 1, 1], '全公司半徑＝1 − 比例');
eq(D.radii(D.pickItem(CR, '甲')), [0.75, 0.5, 1, 0, 1, 1, 1], '單店半徑：比例 100% 時半徑 0、比例 0 時半徑 1');
eq(D.radii({ weak: 2, rates: [1.5, -0.2, 0, 0, 0, 0, 0] }), [0, 1, 1, 1, 1, 1, 1], '半徑限制在 0~1');
eq(D.SHORT.length, 7, '簡稱七個');
eq(D.SHORT[0], '資訊正確', '第一個簡稱');

// ---- 最弱面向：並列全標、比例 0 不標 ----
eq(D.weakest(D.pickItem(CR, '甲')), { idx: [3], names: ['主動引導'], rate: 1 }, '單一最弱');
eq(D.weakest(D.rank([row('x', 4, [2, 0, 0, 2, 0, 1, 0])], 'total')[0]), { idx: [0, 3], names: ['資訊正確性', '主動引導'], rate: 0.5 }, '並列最弱全標');
eq(D.weakest(D.rank([row('x', 4, [0, 0, 0, 0, 0, 0, 0])], 'total')[0]), { idx: [], names: [], rate: 0 }, '比例全 0 不標');
eq(D.weakest(coE), { idx: [], names: [], rate: 0 }, '沒資料不標');
eq(D.weakest(null), { idx: [], names: [], rate: 0 }, 'null 不標');

// ---- 門市下拉選項（固定順序）----
eq(D.storeOptions([row('b', 1, []), row('a', 1, [])]).map(function (o) { return o.code; }).sort(), ['a', 'b'], '下拉含所有門市');
eq(D.storeOptions([{ store_code: 'zz', store_name: '' }])[0], { code: 'zz', name: 'zz' }, '沒名稱用代碼');
eq(D.storeOptions(null), [], '空資料沒有選項');

console.log('通過 ' + passed + ' 項');
