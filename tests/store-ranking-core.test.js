/* 門市黃單排名純函式測試：node tests/store-ranking-core.test.js
 * 「現在」一律傳固定值，結果可重現。 */
var assert = require('node:assert');
var R = require('../js/store-ranking-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

// ---- 期間日期（日曆季、全年；含頭尾）----
eq(R.periodRange(2026, 'Q1'), { start: '2026-01-01', end: '2026-03-31' }, 'Q1');
eq(R.periodRange(2026, 'Q2'), { start: '2026-04-01', end: '2026-06-30' }, 'Q2');
eq(R.periodRange(2026, 'Q3'), { start: '2026-07-01', end: '2026-09-30' }, 'Q3');
eq(R.periodRange(2026, 'Q4'), { start: '2026-10-01', end: '2026-12-31' }, 'Q4');
eq(R.periodRange(2026, 'Y'), { start: '2026-01-01', end: '2026-12-31' }, '全年');
eq(R.periodRange('2027', 'Q4'), { start: '2027-10-01', end: '2027-12-31' }, '年度可以是字串');
eq(R.periodRange(2026, 'Q5'), null, '不合法的期間');
eq(R.periodRange(2026, ''), null, '空期間');
eq(R.periodRange('abc', 'Q1'), null, '不合法的年度');
eq(R.periodLabel(2026, 'Q4'), '2026 年 第4季', '季標題');
eq(R.periodLabel(2026, 'Y'), '2026 年 全年', '全年標題');
eq(R.fileBase(2026, 'Q4'), '門市黃單排名_2026_第4季', '季檔名');
eq(R.fileBase(2026, 'Y'), '門市黃單排名_2026_全年', '全年檔名');

// ---- 預設期間與年度選單（台北時間）----
eq(R.defaultPeriod(Date.parse('2026-11-16T10:00:00+08:00')), { year: 2026, period: 'Q4' }, '11 月是第 4 季');
eq(R.defaultPeriod(Date.parse('2026-03-31T15:59:00Z')), { year: 2026, period: 'Q1' }, 'UTC 3/31 15:59＝台北 3/31 23:59 是第 1 季');
eq(R.defaultPeriod(Date.parse('2026-03-31T16:00:00Z')), { year: 2026, period: 'Q2' }, 'UTC 3/31 16:00＝台北 4/1 是第 2 季');
eq(R.defaultPeriod(Date.parse('2025-12-31T16:00:00Z')), { year: 2026, period: 'Q1' }, '台北跨年');
eq(R.yearOptions(Date.parse('2026-11-16T10:00:00+08:00')), [2026], '2026 年只有 2026');
eq(R.yearOptions(Date.parse('2028-02-01T10:00:00+08:00')), [2028, 2027, 2026], '2026 起到今年，新到舊');
eq(R.yearOptions(Date.parse('2025-06-01T10:00:00+08:00')), [2026], '早於 2026 仍至少有 2026');

// ---- 排名資料 ----
function row(code, tickets, headcount) { return { store_code: code, store_name: code, tickets: tickets, headcount: headcount }; }
var ROWS = [row('高雄', 6, 12), row('中和', 2, 10), row('新莊', 3, 6), row('樹林', 4, 8), row('台南', 12, 15), row('花蓮', 1, 7)];
function codes(rs) { return rs.map(function (r) { return r.store_code; }); }
function ranks(rs) { return rs.map(function (r) { return r.rank; }); }

var A = R.rank(ROWS, 'avg');
// 平均每人：中和 0.20、花蓮 0.14、新莊 0.50、樹林 0.50、高雄 0.50、台南 0.80
eq(codes(A), ['花蓮', '中和', '新莊', '樹林', '高雄', '台南'], '平均每人：少的在前，同值依門市固定順序（新莊、樹林、高雄）');
eq(ranks(A), [1, 2, 3, 3, 3, 6], '同值並列（3、3、3 之後跳到 6）');
eq(R.formatAvg(A[0]), '0.14', '平均每人小數 2 位');
eq(R.formatAvg(A[5]), '0.80', '平均每人 0.80');
var T = R.rank(ROWS, 'tot');
eq(codes(T), ['花蓮', '中和', '新莊', '樹林', '高雄', '台南'], '總張數：少的在前');
eq(ranks(T), [1, 2, 3, 4, 5, 6], '總張數名次');
eq(R.rank(ROWS).map(function (r) { return r.rank; }), ranks(A), '沒給排序方式預設依平均每人');
eq(R.rank(ROWS, 'xx').map(function (r) { return r.rank; }), ranks(A), '不認得的排序方式也依平均每人');

// 並列：用交叉相乘判斷，不被小數誤差影響（1/3 與 2/6）
var TIE = R.rank([row('中和', 1, 3), row('新莊', 2, 6), row('樹林', 1, 7)], 'avg');
eq(ranks(TIE), [1, 2, 2], '1/3 與 2/6 必須並列');
eq(codes(TIE), ['樹林', '中和', '新莊'], '1/7 最少，其後 1/3＝2/6 並列依門市順序');

// 人數為 0：沒有平均、沒有名次、排最後；總張數排序下仍有名次
var Z = R.rank([row('中和', 3, 0), row('新莊', 2, 4), row('樹林', 0, 5)], 'avg');
eq(codes(Z), ['樹林', '新莊', '中和'], '人數為 0 的排最後');
eq(ranks(Z), [1, 2, null], '人數為 0 沒有名次');
eq(R.formatAvg(Z[2]), '—', '人數為 0 顯示 —');
eq(Z[2].avg, null, '人數為 0 的 avg 為 null');
eq(Z[2].barPct, 0, '沒有平均就沒有橫條');
var ZT = R.rank([row('中和', 3, 0), row('新莊', 2, 4)], 'tot');
eq(ranks(ZT), [1, 2], '總張數排序不看人數');

// 全 0 張：全部並列第 1、橫條都是最小值
var ZERO = R.rank([row('中和', 0, 4), row('新莊', 0, 6)], 'avg');
eq(ranks(ZERO), [1, 1], '全 0 全並列第 1');
eq(ZERO.map(function (r) { return r.barPct; }), [4, 4], '全 0 的橫條固定 4%');

// 橫條
eq(A.map(function (r) { return r.barPct; }), [17.9, 25, 62.5, 62.5, 62.5, 100], '橫條：最大值 100%，其餘依比例');
eq(R.rank([row('中和', 0, 4), row('新莊', 8, 4)], 'avg').map(function (r) { return r.barPct; }), [4, 100], '0 張橫條至少 4%');

// 自己的門市標記
var M = R.rank(ROWS, 'avg', '樹林');
eq(M.filter(function (r) { return r.mine; }).map(function (r) { return r.store_code; }), ['樹林'], '只標自己的門市');
eq(R.rank(ROWS, 'avg').some(function (r) { return r.mine; }), false, '沒給自己的門市就不標');
eq(R.rank(ROWS, 'avg', '不存在').some(function (r) { return r.mine; }), false, '自己的門市不在名單內就不標');

// 欄位來源：字串數字也能處理；沒有名稱用代碼；null 列表
var S = R.rank([{ store_code: '中和', store_name: null, tickets: '3', headcount: '6' }], 'avg');
eq([S[0].store_name, S[0].tickets, S[0].headcount, S[0].avg], ['中和', 3, 6, 0.5], '字串數字、缺名稱');
eq(R.rank(null, 'avg'), [], 'null 列表');
eq(R.rank([], 'avg'), [], '空列表');
// 不改動傳入的資料
var src = [row('高雄', 6, 12), row('中和', 2, 10)], copy = JSON.stringify(src);
R.rank(src, 'avg');
eq(JSON.stringify(src), copy, '不改動傳入的列');

// ---- 摘要 ----
var SM = R.summary(A, 'avg');
eq(SM.best, { names: ['花蓮'], value: '每人 0.14 張' }, '黃單最少：花蓮');
eq(SM.worst, { names: ['台南'], value: '每人 0.80 張' }, '黃單最多：台南');
eq(SM.total, 28, '全公司黃單總張數');
var SMT = R.summary(T, 'tot');
eq(SMT.best, { names: ['花蓮'], value: '1 張' }, '總張數：最少');
eq(SMT.worst, { names: ['台南'], value: '12 張' }, '總張數：最多');
// 並列：把並列的門市都列出
var TS = R.summary(R.rank([row('中和', 1, 5), row('新莊', 1, 5), row('樹林', 3, 5), row('高雄', 3, 5)], 'avg'), 'avg');
eq(TS.best.names, ['中和', '新莊'], '並列第一都列出');
eq(TS.worst.names, ['樹林', '高雄'], '並列最後都列出');
// 全部並列：不顯示「最多」，避免和「最少」是同一批
eq(R.summary(R.rank([row('中和', 1, 5), row('新莊', 1, 5)], 'avg'), 'avg').worst, null, '全部並列時沒有「最多」');
// 只有一家：沒有「最多」
eq(R.summary(R.rank([row('中和', 1, 5)], 'avg'), 'avg').worst, null, '只有一家時沒有「最多」');
// 沒有任何名次
eq(R.summary(R.rank([row('中和', 2, 0)], 'avg'), 'avg'), { best: null, worst: null, total: 2 }, '全都沒有人數');
eq(R.summary([], 'avg'), { best: null, worst: null, total: 0 }, '空');

console.log('通過 ' + passed + ' 項');
