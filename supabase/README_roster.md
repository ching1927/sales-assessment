# 人員名冊資料庫說明

狀態：**檔案已寫好，尚未在 Supabase 執行**（待老闆同意）。

## 檔案

| 檔案 | 用途 |
|---|---|
| `roster_schema.sql` | 建三張表、一個檢視、權限規則（可重複執行） |
| `roster_seed_fake.sql` | 測試用假資料（假門市、假人員、example.invalid 假信箱） |

執行順序：先 schema、再 seed（只在測試時跑 seed；真名冊之後另外匯入，不進公開倉庫）。
與考題抽選器共用同一個 Supabase 專案，但名稱不衝突，也不會動到它的任何東西。

## LINE 權限與新類別（技師、公務機）

檔案：`roster_line_schema.sql`（結構）、`roster_line_verify_fake.sql`（假資料驗證）、`import/gen_line_import.js`（產生匯入檔）、`import/import_line.local.sql`（匯入檔，含真實姓名，只放本機）。

新增內容：職稱「技師」「公務機」（不納入考核、免健檢，各名單都靠 `include_in_assessment` 自動排除）、員編放寬為 MI／PT／OF（公務機 OF-0001 起）、新表 `line_accounts`（12 個官方 LINE）與 `line_access`（誰有哪個 LINE 的回覆權限）、函式 `roster_set_line_access`。權限：客服部讀增改刪；總公司主管只讀全部；店長只讀自己門市人員；其他人與未登入沒有權限。

### 老闆照這個順序在 Supabase SQL Editor 執行（每一步貼上 → Run → 看到 Success 再做下一步）

1. **備份**：貼上並執行下面三行（把員工名冊整份複製成 bak_line_employees，原表不動）：

```sql
drop table if exists public.bak_line_employees;
create table public.bak_line_employees as select * from public.employees;
alter table public.bak_line_employees enable row level security;
```

   再執行 `select count(*) from public.bak_line_employees;`，數字應等於名冊人數。
2. 執行 `roster_line_schema.sql`（整份貼上）。可重複執行。
3. 執行 `import/import_line.local.sql`（本機產生；整份貼上）。整份是一個交易，名冊缺人會全部回復並列出缺的員編。可重複執行。
4. **驗證查詢**（貼上執行，看結果）：

```sql
select count(*) as line_accounts_n from public.line_accounts;                        -- 預期 12
select count(*) as line_access_n from public.line_access;                            -- 預期 237（以匯入檔彙總為準）
select job_title, count(*) from public.employees
 where job_title in ('技師','公務機') group by 1;                                    -- 預期 技師 6、公務機 6
-- 另外：匯入檔指定改離職的 4 位（員編見本機匯入檔），到「人員名冊」頁把狀態篩選改成「含離職」確認是離職。
-- employees 沒有離職日欄位，所以不會有日期。
```

5. 另可執行 `roster_line_verify_fake.sql`（假資料、結尾自動復原），最後一個結果表第一列應為「61/61 項通過」。
6. 一切確認後，備份表可刪除：`drop table public.bak_line_employees;`

產生匯入檔（工程師做）：`node supabase/import/gen_line_import.js [xlsx 路徑]`。依賴 exceljs（不在專案內，路徑見腳本開頭）與本機規則檔 `supabase/import/line_rules.local.json`（員編清單，含個資，不進倉庫）。

匯入規則摘要：名冊已有的人只寫 LINE 權限、職稱門市納入考核維持名冊現況；總公司老闆與行銷不新增、不寫權限；新增一般人員 1 位、技師 6 位、公務機 6 台；4 位改離職（只改狀態，employees 沒有離職日欄位）；兩位未在名單內的人員不做任何標記。

## 三張表是做什麼的

| 表 | 白話 |
|---|---|
| `stores` 門市 | 11 間門市＋總公司的清單（代號、名稱） |
| `employees` 人員 | 名冊本體，員工編號是唯一識別（MI-xxxx；工讀為 PT-xxxx，每人須有各自唯一的號碼）。記暱稱、姓名（至少一個）、門市、職級、到職日（可空）、在職／離職、是否納入考核 |
| `app_users` 登入帳號 | 「哪個 Google 信箱 = 什麼角色」。店長必須指定門市，其他角色不可填門市。信箱一律小寫 |

另有檢視 `employees_with_tenure`：在 employees 後面多一欄 `tenure_group`，到職日起 90 天內（含第 90 天）顯示「新人」，之後「正式」，沒填到職日顯示「未填到職日」。檢視用 `security_invoker`，所以不會繞過權限。

## 權限規則一覽

| 身分 | stores | employees／檢視 | app_users |
|---|---|---|---|
| 客服部 cs_admin | 讀、增、改、刪 | 讀、增、改、刪 | 讀、增、改、刪（全部） |
| 總公司主管 hq_viewer | 只讀全部 | 只讀全部 | 只讀自己那一列 |
| 店長 store_manager | 只讀自己門市 | 只讀自己門市 | 只讀自己那一列 |
| 有 Google 登入但沒有 app_users 對應 | 看不到 | 看不到 | 看不到 |
| 未登入（anon） | 無權限（報錯） | 無權限（報錯） | 無權限（報錯） |

判斷依據：登入者 JWT 的 email（轉小寫）對 `app_users.email`。

## 權限驗證清單（第二波驗收照這份做）

前提：已執行 schema 與 seed。在 Supabase SQL Editor 一次貼一段執行。
每段都用 `begin ... rollback`，測完不留痕跡；`set local role` 模擬網頁端身分，`set_config` 模擬登入信箱。

通用寫法（把信箱換掉即可）：

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"role":"authenticated","email":"cs.test1@example.invalid"}', true);
-- 這裡放要測的查詢
rollback;
```

### 1. 客服部（cs.test1@example.invalid）

```sql
select count(*) from public.employees;                 -- 預期 15
select count(*) from public.stores;                    -- 預期 3
select count(*) from public.app_users;                 -- 預期 4
select id, tenure_group from public.employees_with_tenure
 where id in ('MI-9005','MI-9006','MI-9007','MI-9011'); -- 預期：新人、新人、正式、未填到職日
update public.employees set nickname = '測試改名' where id = 'MI-9005';  -- 預期成功 1 列
insert into public.employees (id, nickname, store_code, job_title)
 values ('MI-9999', '測試新增', 'TEST-A', '業務');       -- 預期成功
delete from public.employees where id = 'MI-9999';      -- 預期成功 1 列
```

不該發生：任何一句被擋。

### 2. 總公司主管（hq.test1@example.invalid）

```sql
select count(*) from public.employees;                 -- 預期 15
select count(*) from public.stores;                    -- 預期 3
select email from public.app_users;                    -- 預期只有 hq.test1@example.invalid 一列
insert into public.employees (id, nickname, store_code, job_title)
 values ('MI-9998', '不該成功', 'TEST-A', '業務');       -- 預期報錯 row-level security
update public.employees set nickname = 'x' where id = 'MI-9005';  -- 預期 0 列被改（不報錯）
delete from public.employees where id = 'MI-9005';      -- 預期 0 列被刪（不報錯）
```

不該發生：新增成功、改到或刪到任何一列、看到別人的 app_users。

### 3. 店長甲店（mgr.a@example.invalid）

```sql
select count(*) from public.employees;                 -- 預期 5（只有 TEST-A）
select distinct store_code from public.employees;      -- 預期只有 TEST-A
select count(*) from public.employees where store_code = 'TEST-B';  -- 預期 0
select code from public.stores;                        -- 預期只有 TEST-A
select count(*) from public.employees_with_tenure;     -- 預期 5（檢視也被 RLS 限制）
select email from public.app_users;                    -- 預期只有 mgr.a@example.invalid
update public.employees set nickname = 'x' where id = 'MI-9005';  -- 預期 0 列被改
insert into public.employees (id, nickname, store_code, job_title)
 values ('MI-9997', '不該成功', 'TEST-A', '業務');       -- 預期報錯 row-level security
```

換成 `mgr.b@example.invalid` 再做一次：預期 employees 7 筆，只有 TEST-B。

不該發生：看到其他門市的人、檢視繞過限制、能改能刪。

### 4. 沒有帳號的人（有 Google 登入，但不在 app_users）

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claims',
  '{"role":"authenticated","email":"nobody@example.invalid"}', true);
select count(*) from public.employees;                 -- 預期 0
select count(*) from public.stores;                    -- 預期 0
select count(*) from public.app_users;                 -- 預期 0
select count(*) from public.employees_with_tenure;     -- 預期 0
insert into public.employees (id, nickname, store_code, job_title)
 values ('MI-9996', '不該成功', 'TEST-A', '業務');       -- 預期報錯 row-level security
rollback;
```

另測大小寫：信箱寫成 `"CS.Test1@Example.Invalid"`，預期仍被視為客服部（看到 15 筆）。

### 5. 未登入（anon）

```sql
begin;
set local role anon;
select count(*) from public.employees;                 -- 預期報錯 permission denied
select count(*) from public.stores;                    -- 預期報錯 permission denied
select count(*) from public.app_users;                 -- 預期報錯 permission denied
select count(*) from public.employees_with_tenure;     -- 預期報錯 permission denied
rollback;
```

不該發生：回傳任何資料列（連 0 以外的數字都不行）。

### 6. 約束檢查（用客服部身分或直接以管理者身分）

```sql
-- 預期都報錯（check 約束）：
insert into public.employees (id, store_code, job_title) values ('MI-9990', 'TEST-A', '業務');          -- 暱稱與姓名都空
insert into public.employees (id, nickname, store_code, job_title) values ('XX-1', 'a', 'TEST-A', '業務'); -- 編號格式不對
insert into public.app_users (email, role) values ('x@example.invalid', 'store_manager');                -- 店長沒填門市
insert into public.app_users (email, role, store_code) values ('y@example.invalid', 'cs_admin', 'TEST-A'); -- 非店長卻填門市
insert into public.app_users (email, role) values ('Z@Example.Invalid', 'cs_admin');                      -- 信箱含大寫
```
