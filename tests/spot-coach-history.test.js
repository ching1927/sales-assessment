/* 異常回覆輔導紀錄編輯版本的畫面純函式測試：node tests/spot-coach-history.test.js
 * 函式寫在 spotcheck.html 的 coach-versions-core 區段（esc 一併擷取其定義），這裡擷取後執行；
 * 另外對整份頁面的內嵌 script 做語法檢查，並確認 API 層與頁面接線存在。 */
var assert = require('node:assert');
var fs = require('fs');
var path = require('path');

var passed = 0;
function eq(actual, expected, label) {
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function ok(cond, label) { assert.ok(cond, label); passed++; }

var html = fs.readFileSync(path.join(__dirname, '..', 'spotcheck.html'), 'utf8');
var m = html.match(/\/\/ ==== coach-versions-core begin[^\n]*\n([\s\S]*?)\/\/ ==== coach-versions-core end ====/);
ok(!!m, '找得到 coach-versions-core 區段');
var esc = html.match(/function esc\(s\) \{[\s\S]*?\n  \}\n/)[0];
var F = new Function(esc + m[1] + '\nreturn { fmtTaipei: fmtTaipei, coachEditInfo: coachEditInfo, editorText: editorText, versionHead: versionHead, versionsHtml: versionsHtml };')();

// ---- 時間（台北）----
eq(F.fmtTaipei('2026-11-16T10:40:00Z'), '2026-11-16 18:40', '台北時間 +8');
eq(F.fmtTaipei('2026-11-16T17:00:00Z'), '2026-11-17 01:00', '跨日');
eq(F.fmtTaipei(null), '—', '空值');
eq(F.fmtTaipei('不是時間'), '—', '無法解析');

// ---- 清單資訊 ----
eq(F.coachEditInfo(null), null, '沒有統計');
eq(F.coachEditInfo({ version_count: 0 }), null, '0 版');
eq(F.coachEditInfo({ version_count: 3, last_edited_at: '2026-11-16T10:40:00Z' }),
  { lastText: '最後編輯：2026-11-16 18:40（共編輯 2 次）', btnText: '編輯紀錄（3 筆）', count: 3 }, '3 版＝共編輯 2 次、3 筆');
eq(F.coachEditInfo({ version_count: 1, last_edited_at: '2026-11-16T10:40:00Z' }).lastText, '', '1 版＝不顯示最後編輯');

// ---- 編輯人 ----
eq(F.editorText({ editor_label: '中和-阿甲', edited_by: 'a@2motor.tw' }), '中和-阿甲', '優先用「門市-暱稱」');
eq(F.editorText({ editor_label: '  ', edited_by: 'abc@2motor.tw' }), 'abc', '沒有顯示名退信箱前綴');
eq(F.editorText({ editor_label: null, edited_by: null }), '—', '都沒有');

// ---- 版本標頭 ----
eq(F.versionHead({ version_no: 3, is_current: true, edited_at: '2026-11-16T10:40:00Z', editor_label: '總公司-小客服' }), '第 3 版（目前）｜2026-11-16 18:40｜總公司-小客服', '目前版');
eq(F.versionHead({ version_no: 2, is_current: false, edited_at: '2026-11-13T01:10:00Z', editor_label: '中和-阿甲' }), '第 2 版｜2026-11-13 09:10｜中和-阿甲', '中間版');
eq(F.versionHead({ version_no: 1, is_current: false, edited_at: '2026-11-12T12:05:00Z', editor_label: '中和-阿甲' }), '第 1 版（首次回填）｜2026-11-12 20:05｜中和-阿甲', '首次回填');
eq(F.versionHead({ version_no: 1, is_current: true, edited_at: '2026-11-12T12:05:00Z', editor_label: 'x' }), '第 1 版（目前、首次回填）｜2026-11-12 20:05｜x', '只有一版');

// ---- 版本清單 HTML ----
var h = F.versionsHtml([
  { version_no: 2, is_current: true, coached_on: '2026-11-12', coach_note: '新<b>備註</b>', edited_at: '2026-11-16T10:40:00Z', editor_label: '中和-阿甲' },
  { version_no: 1, is_current: false, coached_on: '2026-11-11', coach_note: '舊備註', edited_at: '2026-11-12T12:05:00Z', editor_label: '中和-阿甲' }
]);
ok(h.indexOf('class="ver cur"') >= 0 && h.indexOf('class="ver"') >= 0, '目前版有 cur 樣式');
ok(h.indexOf('<b>') < 0 && h.indexOf('&lt;b&gt;備註&lt;/b&gt;') >= 0, '備註內容已跳脫');
ok(h.indexOf('輔導日期 2026-11-11') >= 0, '每版都帶輔導日期');
ok(h.indexOf('第 2 版') < h.indexOf('第 1 版'), '新到舊順序照傳入順序');
ok(F.versionsHtml([]).indexOf('沒有編輯紀錄') >= 0, '空清單提示');

// ---- 頁面內嵌 script 語法、接線 ----
var scripts = html.match(/<script>[\s\S]*?<\/script>/g) || [];
scripts.forEach(function (s) { new Function(s.replace(/^<script>|<\/script>$/g, '')); });
ok(scripts.length >= 1, '內嵌 script 語法正確');
ok(html.indexOf('data-hist=') >= 0 && html.indexOf('showCoachHistory') >= 0, '清單有編輯紀錄按鈕與對話框');
var api = fs.readFileSync(path.join(__dirname, '..', 'js', 'spotcheck-api.js'), 'utf8');
ok(api.indexOf("'spot_coach_versions'") >= 0 && api.indexOf("'spot_coach_version_stats'") >= 0, 'API 層呼叫兩個新函式');
ok(api.indexOf("sb.rpc('spot_coach', { p_ticket_id: ticketId, p_coached_on: coachedOn, p_note: note })") >= 0, '原 coach 呼叫不變');

console.log('spot-coach-history 通過 ' + passed + ' 項');
