/* 抽查登記改版純函式測試：node tests/spotdims-core.test.js
 * 全部用假資料。重點：判定顯示改名（資料庫值不變）、面向正規化、登記前檢查沿用既有規則、截圖路徑格式。 */
var assert = require('node:assert');
var Scoring = require('../js/scoring.js');
var S = require('../js/spotdims-core.js');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}

// ---- 判定改名：只改顯示，資料庫值不變 ----
eq(S.verdictLabel('適當'), '優良回覆', '適當 → 優良回覆');
eq(S.verdictLabel('不適當'), '待加強回覆', '不適當 → 待加強回覆');
eq(S.verdictLabel('其他'), '其他', '不認得的原樣回傳');
eq(S.verdictLabel(null), '', 'null 回空字串');
eq(S.VERDICTS.map(function (v) { return v.value; }), ['適當', '不適當'], '送資料庫的值仍是 適當／不適當');
eq(S.VERDICTS.map(function (v) { return v.label; }), ['優良回覆', '待加強回覆'], '畫面用字');

// ---- 七面向名稱與評分模組一致 ----
eq(S.DIMS, Scoring.DIMENSIONS.map(function (d) { return d.name; }), '七面向名稱與 scoring.js 相同');
eq(S.DIMS.length, 7, '七個面向');

// ---- 面向正規化 ----
eq(S.normalizeDims([]), [], '空陣列');
eq(S.normalizeDims(null), [], 'null');
eq(S.normalizeDims(['文字品質', '資訊正確性']), ['資訊正確性', '文字品質'], '依七面向順序');
eq(S.normalizeDims(['問題掌握', '問題掌握', '亂寫']), ['問題掌握'], '去重與去不認得');
eq(S.normalizeDims(S.DIMS), S.DIMS, '七個全勾');

// ---- 截圖路徑 ----
var RID = '11111111-2222-4333-8444-555555555555', FID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
eq(S.shotPath(RID, FID, 'image/jpeg'), 'spot/' + RID + '/' + FID + '.jpg', 'jpeg 路徑');
eq(S.shotPath(RID, FID, 'image/png'), 'spot/' + RID + '/' + FID + '.png', 'png 路徑');
eq(S.shotPath(RID, FID, 'image/webp'), 'spot/' + RID + '/' + FID + '.webp', 'webp 路徑');
eq(S.shotPath(RID, FID, 'image/gif'), '', '不收 gif');
eq(/^spot\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/.test(S.shotPath(RID, FID, 'image/jpeg')), true, '路徑符合資料庫 policy 的格式');

// ---- 舊制分數 ----
eq(S.legacyScore({ total_score: 64 }), 64, '舊紀錄有分數');
eq(S.legacyScore({ total_score: '77.5' }), 77.5, '字串分數');
eq(S.legacyScore({ total_score: null }), null, '新紀錄 null');
eq(S.legacyScore({}), null, '沒有欄位');
eq(S.legacyScore(null), null, 'null 列');

// ---- 登記前檢查（既有規則照舊）----
var OK = { emp: 'MI-1', day: '2026-11-11', url: 'https://chat.line.biz/x', verdict: '適當', reason: '', dims: [], note: '', shotCount: 0 };
function with_(o) { var r = {}; Object.keys(OK).forEach(function (k) { r[k] = OK[k]; }); Object.keys(o).forEach(function (k) { r[k] = o[k]; }); return r; }
eq(S.validateReg(OK), '', '最小合法登記（優良回覆、沒勾、沒圖）');
eq(S.validateReg(with_({ dims: ['問題掌握', '風險意識'], note: '一句話', shotCount: 3 })), '', '優良回覆也可以勾面向、附圖、寫說明');
eq(S.validateReg(with_({ emp: '' })), '請選擇被抽查人員。', '沒選人');
eq(S.validateReg(with_({ day: '' })), '請選擇抽查日期。', '沒選日期');
eq(S.validateReg(with_({ url: '' })), '請填寫訊息抽檢的 LINE 聊天室網址。', '網址必填');
eq(S.validateReg(with_({ url: '   ' })), '請填寫訊息抽檢的 LINE 聊天室網址。', '網址全空白');
eq(S.validateReg(with_({ url: 'ftp://x' })), '網址必須以 http:// 或 https:// 開頭，後面要接完整網址。', '網址開頭');
eq(S.validateReg(with_({ url: 'https://a b' })), '網址不可含空白。', '網址含空白');
eq(S.validateReg(with_({ url: 'https://a/' + new Array(600).join('x') })), '網址不可超過 500 字。', '網址太長');
eq(S.validateReg(with_({ url: '  https://chat.line.biz/x  ' })), '', '網址頭尾空白會去掉');
eq(S.validateReg(with_({ verdict: '不適當', reason: '' })), '判定待加強回覆時，原因必填。', '待加強回覆必填原因');
eq(S.validateReg(with_({ verdict: '不適當', reason: '　 ' })), '判定待加強回覆時，原因必填。', '原因只有空白（含全形）');
eq(S.validateReg(with_({ verdict: '不適當', reason: '沒確認需求就報價' })), '', '待加強回覆有原因');
eq(S.validateReg(with_({ verdict: '' })), '請選擇判定。', '沒有判定');
eq(S.validateReg(with_({ dims: ['亂寫'] })), '可改善面向有不認得或重複的項目，請重新勾選。', '不認得的面向');
eq(S.validateReg(with_({ dims: ['問題掌握', '問題掌握'] })), '可改善面向有不認得或重複的項目，請重新勾選。', '重複面向');
eq(S.validateReg(with_({ note: new Array(502).join('字') })), '說明最多 500 字。', '說明太長');
eq(S.validateReg(with_({ note: new Array(501).join('字') })), '', '說明剛好 500 字');
eq(S.validateReg(with_({ shotCount: 11 })), '截圖最多 10 張。', '截圖太多');
eq(S.validateReg(with_({ shotCount: 10 })), '', '截圖剛好 10 張');

// ---- 登記結果文字 ----
eq(S.resultLines('甲', '2026-11-11', '適當', { dims_count: 2, shots_count: 1 }),
  ['已登記：甲，2026-11-11，判定「優良回覆」；可改善面向 2 項、截圖 1 張。'], '優良回覆不開單');
eq(S.resultLines('甲', '2026-11-11', '不適當', { dims_count: 0, shots_count: 0, yellow_id: 'y' }),
  ['已登記：甲，2026-11-11，判定「待加強回覆」；可改善面向 0 項、截圖 0 張。', '已開立一張黃單。'], '待加強回覆開黃單');
var full = S.resultLines('甲', 'd', '不適當', { yellow_id: 'y', red_id: 'r', probation_id: 'p' });
eq(full.length, 2, '紅單與回考核期已停用：就算舊版資料庫回傳 red_id、probation_id，也只顯示登記與黃單兩行');
eq(/紅單|考核期/.test(full.join('')), false, '結果文字不再出現紅單與回考核期');
eq(S.resultLines('甲', 'd', '適當', [{ dims_count: 1 }])[0].indexOf('可改善面向 1 項') > 0, true, '陣列回傳取第一筆');
eq(S.resultLines('甲', 'd', '適當', null).length, 1, 'null 回傳不報錯');
// 畫面文字不再出現舊用字
eq(/適當/.test(S.resultLines('甲', 'd', '不適當', {})[0].replace(/優良回覆|待加強回覆/g, '')), false, '結果文字不含舊稱「適當」');

console.log('通過 ' + passed + ' 項');
