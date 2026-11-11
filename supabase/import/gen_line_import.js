// 官方 LINE 權限匯入產生器：讀名單 xlsx → 產生 import_line.local.sql
// 用法：node gen_line_import.js [xlsx 路徑]
//   預設 xlsx：C:\Users\user\Downloads\官方LINE權限名單.xlsx（第一個分頁「總表-各官方LINE權限」）
//   規則檔：同資料夾的 line_rules.local.json（含員編，檔名有 .local. 所以不進 git），格式：
//     { "newEmployeeIds": ["MI-xxxx"],   // 名冊還沒有、要新增的一般人員（技師與公務機由職稱自動判斷，不用列）
//       "leaveIds": ["MI-xxxx", ...] }   // 要改成「離職」的人
// 依賴：exceljs（套件不在本專案內）。預設從下面這個絕對路徑載入，也可用環境變數 EXCELJS 指定 exceljs 資料夾：
//   C:\Users\user\AppData\Local\Temp\claude\C--Users-user-Downloads-AI----------1-\7a8872d7-8799-44f5-9e70-a88e18482c83\scratchpad\node_modules\exceljs
// 本腳本不含任何個資（沒有姓名、員編、信箱）；終端機只印數量彙總。
'use strict';
const fs = require('fs');
const path = require('path');

const XLSX_PATH = process.argv[2] || 'C:\\Users\\user\\Downloads\\官方LINE權限名單.xlsx';
const SHEET = '總表-各官方LINE權限';
const EXCELJS_PATH = process.env.EXCELJS ||
  'C:\\Users\\user\\AppData\\Local\\Temp\\claude\\C--Users-user-Downloads-AI----------1-\\7a8872d7-8799-44f5-9e70-a88e18482c83\\scratchpad\\node_modules\\exceljs';
const RULES_PATH = path.join(__dirname, 'line_rules.local.json');

const HQ = '總公司';
const HQ_SKIP_TITLES = new Set(['老闆', '行銷']);            // 總公司這兩種人：不新增進名冊、不寫權限
const ASSESS_TITLES = new Set(['業務', '收車業務', '業務/助理']);
const EXEMPT_TITLES = new Set(['技師', '公務機']);
const LINE_NAMES = ['總', '同行', '中和', '新莊', '樹林', '桃園', '新竹', '旗艦', '南台中', '台南', '高雄', '花蓮'];
const FIRST_LINE_COL = 5;                                      // xlsx 第 5 欄起是 12 個 LINE 欄
const STORE_FIX = { '桃園': '桃園中壢' };                       // xlsx 門市名去掉「門市」後，與資料庫門市代碼不同的對照
const ID_RE = /^(MI|PT|OF)-[0-9]{4}$/;

function fail(msg) { console.error('錯誤：' + msg); process.exit(1); }

let ExcelJS;
try { ExcelJS = require(EXCELJS_PATH); } catch (e) { fail('載入不到 exceljs（' + EXCELJS_PATH + '）；請設定環境變數 EXCELJS 指向 exceljs 資料夾'); }

if (!fs.existsSync(RULES_PATH)) fail('找不到規則檔 line_rules.local.json（格式見本檔開頭說明）');
const rules = JSON.parse(fs.readFileSync(RULES_PATH, 'utf8'));
const newIds = new Set(rules.newEmployeeIds || []);
const leaveIds = rules.leaveIds || [];
for (const id of [...newIds, ...leaveIds]) if (!ID_RE.test(id)) fail('規則檔裡有員編格式不符');

// 取儲存格文字：一般字串、rich text、超連結、公式結果都處理
function cellText(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') {
    if (Array.isArray(v.richText)) return v.richText.map(r => r.text).join('');
    if (v.text !== undefined) return cellText(v.text);
    if (v.result !== undefined) return cellText(v.result);
    return '';
  }
  return String(v);
}
const clean = s => cellText(s).replace(/\s+/g, ' ').trim();

(async () => {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.readFile(XLSX_PATH);
  const ws = wb.getWorksheet(SHEET) || wb.worksheets[0];
  if (!ws) fail('找不到分頁');

  // 表頭檢查：第 5～16 欄必須是 12 個 LINE（欄名去掉「LINE」後與預期一致）
  const head = ws.getRow(1).values;
  const lineCols = LINE_NAMES.map((n, i) => {
    const h = clean(head[FIRST_LINE_COL + i]).replace(/LINE/gi, '').trim();
    if (h !== n) fail(`表頭第 ${FIRST_LINE_COL + i} 欄與預期的 LINE 名稱不符`);
    return FIRST_LINE_COL + i;
  });

  // 解析每一列
  const people = [];        // 要處理的人（已排除總公司老闆與行銷）
  let skipped = 0, ofCounter = 0, ptCounter = 0;
  ws.eachRow((row, n) => {
    if (n === 1) return;
    const v = row.values;
    const rawStore = clean(v[1]);
    if (!rawStore) return;
    let store = rawStore.replace(/門市$/, '');
    store = STORE_FIX[store] || store;
    let id = clean(v[2]);
    let title = clean(v[3]);
    const nameField = clean(v[4]);
    const codes = LINE_NAMES.filter((name, i) => v[lineCols[i]] === true);
    for (let i = 0; i < 12; i++) {
      const x = v[lineCols[i]];
      if (x !== true && x !== false) fail(`第 ${n} 列的 LINE 欄不是 true／false`);
    }

    if (store === HQ && HQ_SKIP_TITLES.has(title)) { skipped++; return; }

    let isNew = false, include = ASSESS_TITLES.has(title);
    let nickname = null, fullName = null;
    const slash = nameField.indexOf('/');
    if (slash >= 0) { nickname = nameField.slice(0, slash).trim() || null; fullName = nameField.slice(slash + 1).trim() || null; }
    else { nickname = nameField || null; }

    if (id === 'x' && title === 'x') {            // 公務機：員編 OF-0001 起，依 xlsx 由上到下
      ofCounter++;
      id = 'OF-' + String(ofCounter).padStart(4, '0');
      title = '公務機'; include = false; isNew = true;
      nickname = nickname || '公務機';
    } else if (id === 'PT') {                      // 工讀：對應名冊既有 PT-0001（維持工讀、不納入考核），只寫權限
      ptCounter++;
      id = 'PT-' + String(ptCounter).padStart(4, '0');
    } else if (title === '技師') {
      isNew = true; include = false;
    } else if (newIds.has(id)) {
      isNew = true;
    }
    if (!ID_RE.test(id)) fail(`第 ${n} 列員工編號格式不符`);
    if (!nickname && !fullName) fail(`第 ${n} 列沒有姓名／暱稱`);
    // 新增者、且姓名是單一名字：放暱稱（上面 nickname 已處理）；有「暱稱/全名」則照拆
    people.push({ id, nickname, fullName, store, title, include, isNew, codes });
  });

  // 自我檢查
  const count = (f) => people.filter(f).length;
  const checks = [
    ['略過（總公司老闆與行銷）', skipped, 2],
    ['公務機', count(p => p.title === '公務機'), 6],
    ['技師', count(p => p.title === '技師'), 6],
    ['規則檔指定新增的一般人員', count(p => p.isNew && !EXEMPT_TITLES.has(p.title)), 1],
    ['新增總計', count(p => p.isNew), 13],
    ['離職更新', leaveIds.length, 4],
  ];
  let bad = false;
  for (const [name, actual, expected] of checks) {
    if (actual !== expected) { bad = true; console.error(`不符：${name} 實際 ${actual}，預期 ${expected}`); }
  }
  if (new Set(people.map(p => p.id)).size !== people.length) { bad = true; console.error('不符：員工編號有重複'); }
  if (people.some(p => EXEMPT_TITLES.has(p.title) && p.include)) { bad = true; console.error('不符：技師／公務機不該納入考核'); }
  for (const id of newIds) if (!people.some(p => p.id === id && p.isNew)) { bad = true; console.error('不符：規則檔的新增員編在 xlsx 找不到'); }
  for (const id of leaveIds) if (people.some(p => p.id === id && p.codes.length > 0)) { bad = true; console.error('不符：要改離職的人在 xlsx 裡還有 LINE 權限'); }
  if (bad) fail('自我檢查未通過，未產生 SQL');

  // 產生 SQL
  const q = v => v === null || v === undefined ? 'null' : "'" + String(v).replace(/'/g, "''") + "'";
  const out = [];
  out.push(`-- ============================================================
-- 業務考核系統：官方 LINE 權限匯入（由 gen_line_import.js 自動產生，請勿手改）
--
-- ⚠️ 本檔含個資（姓名、員工編號）：只放本機，不得上傳、不得進任何倉庫（檔名含 .local.，已被 .gitignore 擋掉）。
--
-- 執行方式：Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
-- 前提：必須先完成備份，並已執行 roster_line_schema.sql（順序見 README_roster.md「LINE 權限與新類別」）。
-- 做的事：
--   1. 新增名冊還沒有的人（一般業務、技師、公務機）；名冊已有的人一律不改任何欄位（on conflict do nothing）
--   2. 指定的幾位改為「離職」（只改狀態；employees 沒有離職日欄位，不填任何日期）
--   3. 檢查：xlsx 裡每個人都必須已在名冊，否則整份回復並列出缺的員編
--   4. 寫入官方 LINE 權限：每個人先刪掉舊的、再依 xlsx 重新寫入（可重複執行）
-- 不動的人：總公司老闆與行銷（不新增、不寫權限）、名冊裡不在 xlsx 的人。
-- 整份包在一個 transaction，任何一步失敗會全部回復。
-- ============================================================

begin;

-- 1. 新增名冊還沒有的人（已存在就跳過，不會覆蓋任何欄位；新增者回覆狀態用資料庫預設「已上線」）
insert into public.employees (id, nickname, full_name, store_code, job_title, hire_date, status, include_in_assessment) values`);
  out.push(people.filter(p => p.isNew).map(p =>
    `  (${q(p.id)}, ${q(p.nickname)}, ${q(p.fullName)}, ${q(p.store)}, ${q(p.title)}, null, '在職', ${p.include})`).join(',\n'));
  out.push(`on conflict (id) do nothing;

-- 2. 改為離職（只改狀態）
update public.employees set status = '離職'
where id in (${leaveIds.map(q).join(', ')}) and status <> '離職';

-- 3. 檢查 xlsx 的每個人都在名冊（缺人就中止並回復）
do $$
declare
  v_missing text;
begin
  select string_agg(x, '、' order by x) into v_missing
  from unnest(array[${people.map(p => q(p.id)).join(', ')}]) as x
  where not exists (select 1 from public.employees e where e.id = x);
  if v_missing is not null then
    raise exception '這些員編不在名冊，已全部回復、什麼都沒改：%', v_missing;
  end if;
end
$$;

-- 4. 官方 LINE 權限：先刪掉這些人原有的，再依 xlsx 寫入
delete from public.line_access
where employee_id in (${people.map(p => q(p.id)).join(', ')});

insert into public.line_access (employee_id, line_code) values`);
  const pairs = [];
  for (const p of people) for (const c of p.codes) pairs.push(`  (${q(p.id)}, ${q(c)})`);
  out.push(pairs.join(',\n'));
  out.push(`on conflict (employee_id, line_code) do nothing;

commit;
`);
  fs.writeFileSync(path.join(__dirname, 'import_line.local.sql'), out.join('\n'), 'utf8');

  // 只印數量彙總
  console.log('自我檢查通過，已產生 import_line.local.sql');
  console.log(`略過 ${skipped}；處理 ${people.length} 人（新增 ${count(p => p.isNew)}：公務機 ${count(p => p.title === '公務機')}、技師 ${count(p => p.title === '技師')}、一般 ${count(p => p.isNew && !EXEMPT_TITLES.has(p.title))}）；改離職 ${leaveIds.length}；權限共 ${pairs.length} 筆；其中 12 個全有 ${count(p => p.codes.length === 12)} 人，沒有任何權限 ${count(p => p.codes.length === 0)} 人`);
})().catch(e => fail(e.message));
