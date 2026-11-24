# 雙考官輪流考核（資料庫）

單一檔案：`dual_examiner_schema.sql`（分三段，每段各自一個交易，可重複執行、不刪任何資料）。驗證腳本：`dual_examiner_verify_fake.sql`（假資料、全程 rollback）。

> 公開倉庫規矩：真實考官信箱**不放在倉庫**。考官名單由老闆本機檔「雙考官名單_種子.sql」寫入（本機 `C:\Users\user\Downloads\`，不 commit）。schema 只建表與函式。

## 規則摘要
- 考官名單內恰好 2 位啟用中、且在 app_users 都是客服部（cs_admin）才能開考；名單為空會顯示「尚未設定考官名單」。
- 開考時資料庫用 random() 抽籤：考官1 考基礎 3 題、考官2 考進階 2＋綜合 1，鎖定不可重抽。
- 各自交卷，兩位都交卷才完成並產生一張成績單。不支援弱項追加題。健檢與舊單人流程不變。

## 上線順序（老闆自己貼進 Supabase SQL Editor；先確認網址列是 uphowx… 專案）
1. **備份**：貼本機檔 `雙考官_上線前備份.sql`（內容同下方「備份」；可重複執行），結尾檢查列全部「通過」。
2. `question_images_schema.sql`（題組範例圖片，見 `README_question_images.md`）。
3. `dual_examiner_schema.sql`（整份貼上執行，結尾驗證查詢全部「通過」）。
4. **本機種子名單**：貼本機檔 `雙考官名單_種子.sql`（UNA、PENNY；可重複執行），結尾檢查三列全部「通過」。前提：兩位都已在 app_users 且為 cs_admin。
5. 可選：貼 `dual_examiner_verify_fake.sql`（全程 rollback；它會在交易內暫時換成假考官名單）。看最後一張結果表「通過」欄全是「通過」。
6. **以上都通過才推網站**（網站先上線會呼叫不存在的函式）。

前提（需已執行過）：roster → assess → bank → accounts → notes_visible → backoffice → spotcheck → url_patch → weak_suggest → exam_request → phase1 → checkup → roster_line／coached_reminder → grade3 → fullreport → spotdims → noredticket。
⚠️ 本檔之後不要重跑 assess_schema／weak_suggest_schema（會把 assess_draw／assess_pick 蓋回沒有雙考官守衛的版本）；萬一重跑過，再貼一次 dual_examiner_schema.sql 即可。

## 備份（內容與本機檔相同，可重複執行）
備份表 `bak_dual_assessments`、`bak_dual_assessment_items`、`bak_dual_assessment_item_images`（三張表複本）與 `bak_dual_funcs`（將被改寫函式的 `pg_get_functiondef`），全部啟用 RLS 且不開 policy（網頁角色讀不到）。

```sql
begin;
drop table if exists public.bak_dual_assessments;
create table public.bak_dual_assessments as select * from public.assessments;
alter table public.bak_dual_assessments enable row level security;
drop table if exists public.bak_dual_assessment_items;
create table public.bak_dual_assessment_items as select * from public.assessment_items;
alter table public.bak_dual_assessment_items enable row level security;
drop table if exists public.bak_dual_assessment_item_images;
create table public.bak_dual_assessment_item_images as select * from public.assessment_item_images;
alter table public.bak_dual_assessment_item_images enable row level security;
drop table if exists public.bak_dual_funcs;
create table public.bak_dual_funcs as
  select p.oid::regprocedure::text as func, pg_get_functiondef(p.oid) as def
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('assess_abandon','assess_add_extra','assess_add_image','assess_draft_weak','assess_draw',
                      'assess_finalize','assess_i_own_item','assess_owns_item','assess_pick','assess_remove_image',
                      'assess_save_dim_notes','assess_save_item','assess_start','assess_submit',
                      'assess_submit_part','assess_unsubmit_part',
                      'bank_add_question_image','bank_remove_question_image','bank_reorder_question_images');
alter table public.bak_dual_funcs enable row level security;
commit;
```

## 種子名單怎麼套
本機檔 `雙考官名單_種子.sql` 是 `insert into assess_examiner_pool … on conflict (email) do update`，附 3 列檢查（啟用中恰好 2 位、兩位都在名單、兩位都是客服部）。換考官：在 SQL Editor 改名單（`update … set active = false`／新增一列），維持「恰好 2 位啟用且為客服部」。

## 驗證
- 資料庫：`dual_examiner_verify_fake.sql`（PGlite 448/448；含「名單為空」「名單設定錯誤」各情境）。
- 網頁：`node tests/assess-dual-core.test.js`。
- 上線後手動：UNA 與 PENNY 各登入，對測試考生（如 MI-9998）開考，確認題組分工與對方唯讀；測完刪除測試考核。

## 回滾
1. 還原函式：`select func, def from public.bak_dual_funcs;`，把需要還原的 `def` 逐一貼上執行（至少 assess_draw、assess_pick、assess_start、assess_submit、assess_save_item、assess_save_dim_notes、assess_add_image、assess_remove_image、assess_abandon、assess_draft_weak、assess_add_extra）。
2. storage policy `assess_notes_insert`／`assess_notes_delete`：重貼 `assess_schema.sql` 內該兩個 policy 段落。
3. 新表與新欄位（assess_examiner_pool、assessment_examiners、assessments.is_dual 等）留著不影響舊流程，不必刪；有雙考官草稿則先放棄它們。
4. 資料真的壞了才用 `bak_dual_assessments` 等備份表比對還原。確認穩定後 drop 備份表。
