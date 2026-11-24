# 題組範例圖片（資料庫與 Storage）

檔案：`question_images_schema.sql`（只新增、不改既有資料表／函式；可重複執行）。驗證：`question_images_verify_fake.sql`（假資料、全程 rollback，PGlite 152/152）。

## 內容
- 私有 Storage bucket `question-samples`（不公開、單檔 2MB、只收 jpeg／png／webp），路徑 `{question_id}/{uuid}.jpg|png|webp`。
- 資料表 `question_images`（RLS：只有客服部可讀；無直接寫入）。
- 函式 `bank_add_question_image`（每題最多 8 張、驗路徑前綴與副檔名）、`bank_remove_question_image`（回傳 path 由前端刪檔）、`bank_reorder_question_images`。
- storage policy `question_samples_select／insert／delete`，全限客服部；沒有 update policy（要換圖請刪掉重傳）。
- 圖片只有客服部看得到；主管、店長、未開通帳號、anon 一律被擋。

## 套用順序
前提：roster、assess、bank 已執行。與雙考官互不相依，**上線時先貼本檔、再貼 dual_examiner_schema.sql**（見 `README_dual_examiner.md` 的上線順序，先備份）。
1. SQL Editor 貼整份 `question_images_schema.sql` → Run（重跑不報錯）。
2. Storage 頁確認出現 `question-samples` bucket，且為 Private。
3. 貼 `question_images_verify_fake.sql`，最後一張表「通過」欄全為「通過」。
4. 才推網站（題庫管理頁 `questions.html` 才會顯示範例圖片區；schema 沒套用時頁面顯示「範例圖片功能尚未啟用」）。

## 驗證補充
- verify 的 Storage 只驗 policy 內容與各角色 select／insert／update 結果；delete 不實際刪檔（Supabase 的 storage.protect_delete 會擋直接 delete），實際刪檔請在網頁上傳一張再刪除手動確認。
- 網頁：`node tests/question-images-api.test.js`。
- 刪題組時 `question_images` 資料列 cascade 刪除，Storage 檔案不會自動刪（前端刪題前可先逐張刪圖）。

## 回滾
本檔只新增：不需要時可 `drop table public.question_images;`、drop 三個 bank_*_question_image(s) 函式、三個 `question_samples_*` policy，並於 Storage 清空後刪 bucket。舊功能不受影響。
