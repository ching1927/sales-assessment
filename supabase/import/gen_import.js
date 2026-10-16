// 名冊匯入產生器：讀名單 PDF → 產生 import_roster.local.sql
// 用法：node gen_import.js "<名單 PDF 路徑>"（需 pdftotext 在 PATH，或用環境變數 PDFTOTEXT 指定完整路徑）
// 本腳本不含任何真實個資；終端機只印數量彙總。
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const pdfPath = process.argv[2];
if (!pdfPath) fail('請提供名單 PDF 路徑');

const HQ = '總公司';
const ASSESS_TITLES = new Set(['業務', '收車業務', '業務/助理']);
const ROLE_BY_REMARK = { '只看不改': 'hq_viewer', '後台建立修改、維護': 'cs_admin', '部分權限': 'store_manager' };
const REMARKS = ['無權限', ...Object.keys(ROLE_BY_REMARK)];
const ID_RE = /^(MI|PT)-[0-9]{4}$/;

function fail(msg) { console.error('錯誤：' + msg); process.exit(1); }

// 1. PDF → 文字（輸出到系統暫存資料夾）
const tmpTxt = path.join(os.tmpdir(), 'roster_gen_' + process.pid + '.txt');
execFileSync(process.env.PDFTOTEXT || 'pdftotext', ['-raw', '-enc', 'UTF-8', pdfPath, tmpTxt]);
const lines = fs.readFileSync(tmpTxt, 'utf8').split(/\r?\n/).map(s => s.trim()).filter(Boolean);
fs.unlinkSync(tmpTxt);

// 2. 解析
const stores = [];
const employees = [];
const appUsers = [];
let ptCounter = 0;

lines.forEach((line, i) => {
  if (line.startsWith('門市 職級 員工編號')) return; // 換頁重複表頭
  let rest = line;
  let email = null;
  const m = rest.match(/\s(\S+@\S+)$/);
  if (m) { email = m[1].toLowerCase(); rest = rest.slice(0, m.index).trim(); }
  const remark = REMARKS.find(r => rest.endsWith(' ' + r));
  if (!remark) fail(`第 ${i + 1} 行找不到備註欄`);
  rest = rest.slice(0, rest.length - remark.length).trim();
  const parts = rest.split(/\s+/);
  if (parts.length < 4) fail(`第 ${i + 1} 行欄位不足`);
  const store = parts[0];
  let title = parts[1];
  let id = parts[2];
  const nameField = parts.slice(3).join(' ');
  let nickname = null, fullName = null;
  const slash = nameField.indexOf('/');
  if (slash >= 0) { nickname = nameField.slice(0, slash).trim() || null; fullName = nameField.slice(slash + 1).trim() || null; }
  else { nickname = nameField.trim(); }

  let assess = ASSESS_TITLES.has(title);
  if (id === 'PT') { // 工讀：編號補成 PT-0001 起，職級改工讀，不納入考核
    ptCounter++;
    id = 'PT-' + String(ptCounter).padStart(4, '0');
    title = '工讀';
    assess = false;
  }
  if (!ID_RE.test(id)) fail(`第 ${i + 1} 行員工編號格式不符`);
  if (!stores.includes(store)) stores.push(store);
  employees.push({ id, nickname, fullName, store, title, assess });

  if (email) {
    const role = ROLE_BY_REMARK[remark];
    if (!role) fail(`第 ${i + 1} 行有信箱但備註不是可辨識的角色`);
    appUsers.push({ email, role, store: role === 'store_manager' ? store : null, employeeId: id });
  }
});

// 3. 自我檢查
const count = (arr, f) => arr.filter(f).length;
const roleCount = r => count(appUsers, u => u.role === r);
const checks = [
  ['門市數(含總公司)', stores.length, 12],
  ['員工數', employees.length, 60],
  ['app_users 數', appUsers.length, 19],
  ['cs_admin', roleCount('cs_admin'), 3],
  ['hq_viewer', roleCount('hq_viewer'), 5],
  ['store_manager', roleCount('store_manager'), 11],
];
let bad = false;
for (const [name, actual, expected] of checks) {
  if (actual !== expected) { bad = true; console.error(`不符：${name} 實際 ${actual}，預期 ${expected}`); }
}
if (new Set(employees.map(e => e.id)).size !== employees.length) { bad = true; console.error('不符：員工編號有重複'); }
if (new Set(appUsers.map(u => u.email)).size !== appUsers.length) { bad = true; console.error('不符：信箱有重複'); }
for (const s of stores.filter(s => s !== HQ)) {
  const n = count(employees, e => e.store === s && e.title === '店長');
  if (n !== 1) { bad = true; console.error(`不符：有門市店長數不是 1（實際 ${n}）`); }
}
if (!stores.includes(HQ)) { bad = true; console.error('不符：找不到總公司'); }
if (employees.some(e => !ID_RE.test(e.id))) { bad = true; console.error('不符：有編號格式錯誤'); }
if (bad) fail('自我檢查未通過，未產生 SQL');

// 4. 產生 SQL
const q = v => v === null || v === undefined ? 'null' : "'" + String(v).replace(/'/g, "''") + "'";
const out = [];
out.push(`-- ============================================================
-- 業務考核系統：人員名冊匯入（由 gen_import.js 自動產生，請勿手改）
--
-- ⚠️ 本檔含真實個資（姓名、信箱、員工編號）：只放本機，不得上傳、不得進任何倉庫。
--
-- 執行方式：Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
-- 前提：必須先執行過 roster_schema.sql。
-- 可重複執行：重跑會以員工編號／信箱／門市代碼更新既有資料（到職日與在職狀態重跑時不會被覆蓋）。
-- 整份包在一個 transaction，任何一步失敗會全部回復。
-- ============================================================

begin;

-- 門市（含總公司）
insert into public.stores (code, name) values`);
out.push(stores.map(s => `  (${q(s)}, ${q(s)})`).join(',\n'));
out.push(`on conflict (code) do update set name = excluded.name;

-- 人員名冊
insert into public.employees (id, nickname, full_name, store_code, job_title, hire_date, status, include_in_assessment) values`);
out.push(employees.map(e => `  (${q(e.id)}, ${q(e.nickname)}, ${q(e.fullName)}, ${q(e.store)}, ${q(e.title)}, null, '在職', ${e.assess})`).join(',\n'));
out.push(`on conflict (id) do update set
  nickname = excluded.nickname,
  full_name = excluded.full_name,
  store_code = excluded.store_code,
  job_title = excluded.job_title,
  include_in_assessment = excluded.include_in_assessment;

-- 登入帳號對應
insert into public.app_users (email, role, store_code, employee_id) values`);
out.push(appUsers.map(u => `  (${q(u.email)}, ${q(u.role)}, ${q(u.store)}, ${q(u.employeeId)})`).join(',\n'));
out.push(`on conflict (email) do update set
  role = excluded.role,
  store_code = excluded.store_code,
  employee_id = excluded.employee_id;

commit;
`);
fs.writeFileSync(path.join(__dirname, 'import_roster.local.sql'), out.join('\n'), 'utf8');

// 5. 只印數量彙總
console.log('自我檢查通過，已產生 import_roster.local.sql');
console.log(`門市 ${stores.length}（含總公司）、員工 ${employees.length}（納入考核 ${count(employees, e => e.assess)}）、app_users ${appUsers.length}（cs_admin ${roleCount('cs_admin')}、hq_viewer ${roleCount('hq_viewer')}、store_manager ${roleCount('store_manager')}）`);
