/* 待填天數純函式測試：node tests/todo-days-core.test.js（「現在」一律傳固定值） */
var assert = require('node:assert');
var T = require('../js/todo-days-core.js');
function eq(a, e, label) { assert.deepStrictEqual(a, e, label + '：預期 ' + JSON.stringify(e) + '，實際 ' + JSON.stringify(a)); }

var NOW = Date.parse('2026-11-25T10:00:00+08:00');
eq(T.daysSince('2026-11-25T00:05:00+08:00', NOW), 0, '當天');
eq(T.daysSince('2026-11-21', NOW), 4, '日期字串（UTC 午夜＝台北 08:00，同日）');
eq(T.daysSince('2026-11-24T23:59:00+08:00', NOW), 1, '前一天深夜');
eq(T.daysSince('2026-11-24T16:30:00Z', NOW), 0, 'UTC 16:30＝台北隔天 00:30，算當天');
eq(T.daysSince('壞掉', NOW), null, '無法解析');
eq(T.daysSince(null, NOW), null, 'null');
eq(T.daysSince('', NOW), null, '空字串');
eq(typeof T.daysSince('2026-11-20', undefined), 'number', '不傳 nowMs 用現在');

eq(T.level(0), 'gray', '0'); eq(T.level(3), 'gray', '3'); eq(T.level(4), 'warn', '4');
eq(T.level(7), 'warn', '7'); eq(T.level(8), 'red', '8'); eq(T.level(null), 'gray', 'null');

eq(T.chipHtml(2), '<span class="tag gray">已開單 2 天</span>', 'chip gray');
eq(T.chipHtml(5), '<span class="tag warn">已開單 5 天</span>', 'chip warn');
eq(T.chipHtml(9), '<span class="tag red">已開單 9 天</span>', 'chip red');
eq(T.chipHtml(null), '', 'chip null');
assert.ok(!/計時|倒數/.test(T.chipHtml(9)), '不得出現計時/倒數');
console.log('todo-days-core 全部通過');
