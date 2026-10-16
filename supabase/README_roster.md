# 人員名冊資料庫說明

狀態：**檔案已寫好，尚未在 Supabase 執行**（待老闆同意）。

## 檔案

| 檔案 | 用途 |
|---|---|
| `roster_schema.sql` | 建三張表、一個檢視、權限規則（可重複執行） |
| `roster_seed_fake.sql` | 測試用假資料（假門市、假人員、example.invalid 假信箱） |

執行順序：先 schema、再 seed（只在測試時跑 seed；真名冊之後另外匯入，不進公開倉庫）。
與考題抽選器共用同一個 Supabase 專案，但名稱不衝突，也不會動到它的任何東西。

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
