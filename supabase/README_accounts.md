# 帳號管理護欄與操作紀錄（accounts）

> ⚠️ 兩份 SQL 都**尚未執行**，等老闆同意後才在 Supabase 執行。

客服部（cs_admin）會在網頁上管理「誰能登入、是什麼角色」（資料表 `app_users`）。
這一包在資料庫層加上「護欄」和「操作紀錄」：網頁就算寫錯、或被人亂用，資料庫自己也會擋。
**不會改動任何既有資料表、函式、policy**，只在 `app_users` 上多掛觸發器，並新增一張紀錄表與一個檢視（另在檔尾有一個獨立小節替職稱欄加長度限制，見第八節）。

## 一、檔案

| 檔案 | 用途 |
|---|---|
| `accounts_schema.sql` | 正式內容：護欄、操作紀錄表、帳號清單檢視 |
| `accounts_verify_fake.sql` | 驗證腳本：用假資料逐項測試，跑完自動復原（rollback） |

執行順序：先確定 `roster_schema.sql` 已上線 → 再跑 `accounts_schema.sql` → 再跑 `accounts_verify_fake.sql`。

## 二、護欄與紀錄是什麼

| 編號 | 規則 | 被擋時的訊息 |
|---|---|---|
| 1 | 至少保留一位客服部（刪除或降級後客服部會變 0 位就擋） | 至少要保留一位客服部 |
| 2 | 客服部不能移除自己、不能把自己降級、不能把自己的信箱改掉 | 不能移除或降級自己的客服部身分 |
| 3 | 信箱必須符合 `^[^@\s]+@2motor\.tw$`（以 `@2motor.tw` 結尾、不含空白與第二個 @；新增或修改信箱時檢查） | 只收公司信箱（@2motor.tw） |
| 4 | 每次新增／修改／移除自動寫一筆「操作紀錄」 | （不會擋，只是記錄） |

- 「一次降級全部客服部」這種整批操作也擋得住（整個語句改完才判斷人數）。
- 兩人同時互相移除對方，資料庫會讓他們排隊，後面的人會被擋。
- 護欄 2 檢查的是「操作人的信箱」＝「被異動那一列的信箱」，所以客服部**改自己的其他欄位**（例如對應員工）是允許的。
- 說明：客服部帳號的「門市」欄依資料表規定必須為空，所以「改自己的門市」不適用於客服部。

### 操作紀錄表 `app_users_audit`

| 欄位 | 內容 |
|---|---|
| id | 流水號 |
| at | 時間 |
| by_email | 操作人信箱；不是透過網頁登入操作（例如在 SQL Editor 直接下指令）記為 `(SQL Editor)` |
| action | insert／update／delete |
| email | 被異動的帳號（信箱被改時記「改後的新信箱」，舊信箱在 old_row 裡） |
| old_row／new_row | 異動前、異動後的整列內容（新增時 old_row 為空、移除時 new_row 為空） |

紀錄**只增不改**：任何人（包含客服部、含網頁）都不能新增、修改、刪除紀錄，只有資料庫觸發器能寫入。

### 兩個給前端用的東西

- **帳號清單**：`accounts_list`（檢視）。`app_users` 左接 `employees`，帶出員編、暱稱、姓名。沿用現有權限：客服部看全部，其他角色只看到自己那一列。
- **操作紀錄**：**不另做檢視**，前端客服部頁面直接讀 `app_users_audit` 即可（權限已限制只有客服部讀得到，多包一層檢視沒有好處，所以選較簡單的做法）。範例：

```sql
select * from app_users_audit order by id desc limit 100;
```

## 三、各角色能做什麼

| 角色 | 帳號資料 `app_users` | 操作紀錄 `app_users_audit` | 帳號清單 `accounts_list` |
|---|---|---|---|
| 客服部 | 可新增、修改、移除（受護欄限制） | 只能讀 | 看全部 |
| 總公司主管 | 只能讀自己那一列，不能寫 | 看不到（讀出來 0 筆）、不能寫 | 只看到自己 |
| 店長 | 同上 | 同上 | 只看到自己 |
| 有登入但沒有帳號 | 什麼都看不到、不能寫 | 看不到、不能寫 | 0 列 |
| 未登入（anon） | 完全沒有權限 | 完全沒有權限 | 完全沒有權限 |

## 四、重要例外：SQL Editor 直接操作時，護欄 1、2 不啟動

判斷方式：看這次操作有沒有「登入者的信箱」。透過網頁（Supabase API）呼叫一定有；
在 Supabase 的 SQL Editor 直接下指令（postgres 角色）沒有。沒有登入者時：

- 護欄 1（至少保留一位客服部）、護欄 2（不能移除自己）**不啟動**。
- 護欄 3（信箱網域）與操作紀錄**照常生效**（紀錄的 by_email 記為 `(SQL Editor)`）。

**為什麼要這樣**：萬一客服部被全部刪光（或剩下的人不能登入），網頁上已經沒有人有權限修復，
這時只能靠 SQL Editor 人工補回。如果護欄在這裡也啟動，就會把修復的路擋死。
SQL Editor 只有擁有 Supabase 專案權限的人進得去，風險可接受；而且做了什麼都會留紀錄。
（用 service_role 金鑰從後端呼叫也同樣沒有登入者信箱，視同 SQL Editor；請妥善保管該金鑰。）

### 緊急修復：把客服部補回來

在 SQL Editor 貼上並 Run（把信箱換成要補回的公司信箱；若該信箱已存在但角色不對，用第二段）：

```sql
-- 信箱還不在 app_users：新增為客服部
insert into public.app_users (email, role)
values ('某人@2motor.tw', 'cs_admin');

-- 信箱已在 app_users：把角色改回客服部（客服部的門市欄必須為空）
update public.app_users
set role = 'cs_admin', store_code = null
where email = '某人@2motor.tw';
```

補回後會自動留一筆操作紀錄（操作人 `(SQL Editor)`）。

## 五、怎麼執行

1. 打開 Supabase 專案 → **SQL Editor** → **New query**。
2. 打開 `accounts_schema.sql`，整份複製貼上 → **Run**。看到 Success 即可。可重複執行，重跑不會報錯、不會刪資料。
3. 另開一個 New query，貼上 `accounts_verify_fake.sql` 整份 → **Run**。

**跑驗證腳本的安全做法**

- **選在沒人在管理帳號的時段執行。** 腳本一開始會 `lock table public.app_users in share row exclusive mode`（擋寫入、不擋讀取，登入查角色不受影響），並設 `lock_timeout = 5s`（5 秒拿不到鎖就報錯停下，rollback 後無影響）。跑的幾秒內，若有人正好在新增／修改／刪除帳號，那一次寫入會短暫等待。
- **執行前後各跑一次 `select count(*) from public.app_users;`，兩次結果應該相同（目前為 19 筆）。** 不同就立刻回報，不要再做任何操作。

```sql
select count(*) from public.app_users;   -- 執行驗證腳本前
-- …跑 accounts_verify_fake.sql…
select count(*) from public.app_users;   -- 執行後：兩次應相同（目前 19）
```

### 驗證腳本會做什麼、結果怎麼看

- 整份包在 `begin; … rollback;` 裡：跑完**自動復原，不留任何資料**。
- 為了讓「客服部人數」可以精準測試，腳本會在交易內先把 `app_users` 清空，再放入假帳號。
  這個清空只存在於這次交易內，rollback 後**真實帳號原封不動**。
- 假信箱一律用 `vr-xxx@2motor.tw`（`vr` 是 verify 的縮寫，明顯是測試用）。
  不能用 `example.invalid`：它不是 `@2motor.tw` 結尾，會被護欄 3 擋掉。
- 結果表最後一張：欄位「序號／測項／預期／實際／通過」。
  - 第一列「總結」顯示「N/M 項通過」。
  - 「通過」欄**全部是「通過」**才算驗證成功；有「失敗」就把那列的「預期」與「實際」回報給我。
  - 畫面若出現兩張一樣的表（rollback 前的備援＋最後一張），看最後一張即可。
- 另有 `MI-9801`～`MI-9803` 的假員工與 `ZZ-A1`／`ZZ-A2` 假門市，一樣只存在於交易內。
- 涵蓋：客服部新增／修改／移除與紀錄內容、最後一位客服部被擋、移除或降級自己（含改自己信箱）被擋、
  信箱格式（空白、兩個 @）、無異動 UPDATE 不寫紀錄、service_role／擁有者對操作紀錄的 update／delete／truncate 被擋、職稱 20 字限制、信箱網域、
  店長／主管／無帳號／anon 都看不到也寫不了紀錄、沒有登入者時的緊急修復、既有結構（欄位、policy、函式）沒被改動。

## 六、已知限制與注意事項

1. **信箱規則**：本檔生效後，信箱必須符合 `^[^@\s]+@2motor\.tw$`（不能空、不能有空白、不能有第二個 @、網域固定 `2motor.tw`），否則一律寫不進 `app_users`。前端請用同一條規則先擋。
   - 因此原本用 `example.invalid` 假信箱的 `roster_seed_fake.sql` 與 `assess_verify_fake.sql` 會被擋。**這兩份已經只改假信箱字串**（其餘邏輯與預期值沒動），統一改成 `vr-` 開頭、`@2motor.tw` 結尾的明顯測試信箱（例如 `cs1@example.invalid` → `vr-cs1@2motor.tw`；同一人在檔內所有出現處一致，包含模擬登入的 JWT 信箱）。
   - `README_roster.md` 內的手動測試範例仍寫舊的 `example.invalid` 信箱，若要照著做，請自行換成 `roster_seed_fake.sql` 內的新信箱（`vr-cs.test1@2motor.tw`、`vr-hq.test1@2motor.tw`、`vr-mgr.a@2motor.tw`、`vr-mgr.b@2motor.tw`）。
2. **護欄 2 已涵蓋「把自己的信箱改掉」**：客服部不能對自己那一列改信箱（等於移除自己），訊息同樣是「不能移除或降級自己的客服部身分」。改「另一位」客服部的信箱則允許。
3. 護欄擋的是資料庫層；網頁前端仍應自己顯示友善訊息（把上表的訊息直接顯示即可）。
4. 紀錄的 `by_email` 取自登入 JWT 內的信箱（已轉小寫），不是可由前端自填的欄位，無法偽造。
5. **操作紀錄「只增不改」的真實程度**：
   - 第一層：`app_users_audit` 對 anon、authenticated、service_role 的 insert／update／delete／truncate 權限全部收回（只留 select 給 authenticated，再由 RLS 限定客服部）。
   - 第二層：資料表上有 BEFORE UPDATE、BEFORE DELETE、BEFORE TRUNCATE 觸發器，一律報錯「操作紀錄只增不改」，連資料庫擁有者（postgres）直接下指令也會被擋。
   - 寫入由 `app_users` 上的 AFTER 觸發器代寫（security definer），不經過上述擋門，不受影響。
   - **限制**：資料庫擁有者（Supabase 專案管理者）仍可先 `alter table … disable trigger` 停用這些觸發器再改，或直接刪除觸發器；這是擁有者權限，無法也不需要在資料庫內完全避免，靠「只有少數人能進 Supabase 後台」來控管。
6. 修改 `app_users` 但內容完全沒變（例如把角色設成原本的角色），**不會**寫操作紀錄，避免灌水。
7. **在 Supabase Table Editor（網頁表格編輯器）操作也是 postgres 角色、沒有登入者**：會被記成 `(SQL Editor)`，且護欄 1、2 **不啟動**。要用護欄保護，請透過系統網頁（有登入者）操作，不要在 Table Editor 直接改 `app_users`。
8. **建議到 Supabase 後台 Authentication 檢查登入方式**：確認「Email／密碼註冊」已關閉，或至少要求信箱驗證，避免有人用別人（尤其客服部）的信箱自行註冊來冒用身分。本系統只開 Google 登入，其餘方式建議全部關閉。
9. 這一包只在寫檔階段：兩份 SQL 都沒有實際執行過，語法與邏輯靠人工逐行核對；請以第一次實際跑出的驗證結果表為準。

## 七、只能用「讀」的確認（上線後，不會改任何資料）

在 SQL Editor 貼上執行即可：

```sql
-- 1. app_users 的 4 個觸發器都掛上了（應有 accounts_audit_trg、accounts_audit_upd_trg、accounts_email_domain_trg、accounts_guard_trg）
select tgname from pg_trigger
where tgrelid = 'public.app_users'::regclass and not tgisinternal order by tgname;

-- 2. 操作紀錄表與帳號清單檢視存在
select to_regclass('public.app_users_audit') as audit_table,
       to_regclass('public.accounts_list')   as list_view;

-- 3. 操作紀錄表的 policy（應只有 accounts_audit_select_cs）
select policyname, cmd from pg_policies
where schemaname = 'public' and tablename = 'app_users_audit';

-- 4. 目前客服部人數（至少 1）
select count(*) from public.app_users where role = 'cs_admin';

-- 5. 最近的操作紀錄
select at, by_email, action, email from public.app_users_audit order by id desc limit 20;
```

## 八、名冊小補強：職稱最多 20 字

`accounts_schema.sql` 檔尾有獨立小節，替 `employees.job_title` 加上「最多 20 字」的限制（`accounts_employees_job_title_len`），可重複執行。
因為不確定既有資料有沒有超過 20 字，這個限制是用 `NOT VALID` 加上：**只檢查之後新增或修改的資料**，不會讓整份 schema 因舊資料而失敗。

先用讀的查詢檢查有沒有超過 20 字的既有資料（應為 0 列）：

```sql
select id, job_title, char_length(job_title) as len
from public.employees
where char_length(job_title) > 20;
```

確認 0 列之後，才啟用「連既有資料也一併驗證」（若有超過的資料，這行會報錯而不改任何東西，先去修正那幾筆再執行）：

```sql
alter table public.employees validate constraint accounts_employees_job_title_len;
```

確認限制已存在（讀）：

```sql
select conname, convalidated from pg_constraint
where conname = 'accounts_employees_job_title_len';   -- convalidated：false＝尚未驗證既有資料，true＝已驗證
```
