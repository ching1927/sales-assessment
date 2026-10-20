# 題庫管理（bank_*）說明

> ⚠️ 本資料夾的四個檔案（`bank_schema.sql`、`bank_verify_fake.sql`、`bank_retire_legacy.sql`、本說明）都「只是寫好、尚未執行」。
> 寫檔的人不能執行 SQL，所以裡面的語法與邏輯是逐條讀過、對照舊函式核對的，**還沒有在真的資料庫跑過**，請看最後一節「只能用讀的確認」。

**題庫內容含考點，只有客服部可讀寫。** 主管、店長、沒有帳號的人、未登入者都讀不到、也改不了。

## 這是什麼

客服部要用 Google 登入的網頁管理題庫，取代舊管理頁（共用密碼）。
題庫的三張資料表（`questions`、`drawn`、`category_last`）本來就收回一般權限，網頁碰不到，所以新增 5 個「先確認你是客服部」的函式，行為與舊的 `admin_*` 函式一致。

## 新增的函式（全部以 `bank_` 開頭）

| 函式 | 做什麼 | 與舊函式的對應 |
|---|---|---|
| `bank_list_questions()` | 回傳全部題組：id、分類、代號、名稱、步驟（含考點）、本輪是否已抽（drawn）。分類依第一次出現順序，再依 id 排序 | `admin_list_questions` |
| `bank_save_question(p_id, p_category, p_code, p_title, p_steps)` | `p_id` 為空＝新增，回傳新題組 id；否則編輯。驗證規則同舊函式（見下） | `admin_save_question` |
| `bank_delete_question(p_id)` | 刪除題組（已抽記錄一併清掉；找不到該題不報錯） | `admin_delete_question` |
| `bank_rename_category(p_old, p_new)` | 分類改名，回傳受影響題數；新名稱已存在＝合併 | `admin_rename_category` |
| `bank_reset(p_category)` | 洗牌（清掉本輪已抽記錄）：空值＝全部分類，否則只洗該分類 | `admin_reset` |
| `bank_assert_cs()` | 內部用的身分檢查，網頁不能直接呼叫 | — |

「各分類剩餘題數」沿用已上線的 `assess_categories()`，沒有重複實作。

### 儲存題組的驗證規則（與舊函式完全一致）

- 分類、題組名稱去除前後空白後不可空白；名稱最多 100 字；代號最多 10 字（空白代號存成空值）。
- 步驟必須是清單，1～30 個；每步必須是物件、「考官操作」（action）是非空文字、「考點」（point）是文字或空；兩者各最多 500 字。
- 只保留 action、point 兩個欄位並去空白，缺的考點補空字串。
- 編輯時若**改了分類**，這題會從「已抽記錄」移除（避免記錄錯亂），行為同舊函式。
- 白話錯誤訊息與舊函式相同，例如「分類不可空白」、「題組名稱太長（最多 100 字）」、「代號太長（最多 10 字）」、「至少要有 1 個步驟」、「步驟太多（最多 30 個）」、「找不到題目：」、「新分類名稱不可空白」；不是客服部一律「沒有權限」。

### 改名與洗牌的細節（照舊）

- 改名：舊分類的「最近一題」記錄會刪掉；新舊名稱相同則不動；舊分類不存在回傳 0。已抽記錄跟著題目走。
- 洗牌：全部＝清空 `drawn` 與 `category_last`；單一分類＝只清該分類的已抽記錄與該分類的「最近一題」記錄。

## 權限與安全

- 全部 `security definer`、固定 `search_path`；不是客服部（含未登入、沒帳號、總公司主管、店長）一律丟「沒有權限」。
- 收回 `public`、`anon` 的 execute，只授權 `authenticated`（登入者）。`bank_assert_cs` 連 `authenticated` 都不開放。
- **不開放網頁直接讀寫** `questions`、`drawn`、`category_last`：這三張表維持「開 RLS、沒有 policy、沒有任何直接權限」，本檔完全沒有動它們。
- 會寫入的四個函式（儲存、刪除、改名、洗牌）先取與舊 `draw_questions`、`assess_draw` 同一把 advisory lock（`pg_advisory_xact_lock(hashtext('exam_draw_questions'))`），所以抽題與管理操作不會同時進行（彼此會排隊，通常不到一瞬間）。列表是純讀取，不取鎖（與舊 `admin_list_questions` 一致）。

## 怎麼執行（等老闆同意後才做）

前提：`roster_schema.sql`、`assess_schema.sql`、考題抽選器的 `schema.sql` 都已執行過（`bank_schema.sql` 開頭有檢查，缺少會停下並提示）。

1. Supabase 專案 → SQL Editor → New query → 貼上 `bank_schema.sql` 整份 → Run。可重複執行，不會動到題庫資料。
2. 再開一個 New query → 貼上 `bank_verify_fake.sql` 整份 → Run（全程 rollback，不留任何資料）。
3. 看結果表（見下節）。全部「通過」才算成功。

## 驗證腳本的結果表怎麼看

- 最後一個結果是一張表：「序號／測項／預期／實際／通過」。第一列「總結」顯示 `N/M 項通過`。
- 「通過」欄全部是「通過」＝驗證成功；有「失敗」就看那一列的「預期」與「實際」。
- 若畫面出現兩張一樣的表，看最後一張（第一張是備援）。
- 測項分區：1 權限（主管／店長／無帳號／沒登入／anon 全被拒，且被拒後資料沒被動到）、2 列表（欄位、排序、drawn 旗標）、3 儲存（新增／編輯／改分類，及各欄位驗證）、4 刪除、5 改名與合併、6 洗牌（單一與全部）、7 抽題（`assess_draw`）與洗牌的互動、8 直接讀寫三張表被拒與函式設定、9 停用舊抽選器（含還原）、10 既有資料表與函式沒被改動。
- 假資料一律 `ZZ` 開頭、假信箱 `vr-xxx@2motor.tw`，全部在交易內建立、最後 rollback。為了測「全部洗牌」，腳本會先把真實的已抽記錄備份到暫存表，洗完立刻還原，並在區段 10 比對筆數；整份腳本都在交易內，rollback 後真實題庫與已抽記錄不會改變；備份與還原只是讓筆數比對更乾淨。第一次執行請選在沒人抽題的時段。
- 假題庫會用掉幾個流水號（id 不會因 rollback 倒退），無害。

## 停用舊抽選器（`bank_retire_legacy.sql`，單獨一份、可還原）

⚠️ **尚未執行，待老闆確認新題庫管理頁好用之後才執行。**

### 為什麼要停

舊抽選器與舊管理頁用「共用密碼」，不看登入身分，是繞過「只有客服部」規則的漏洞（階段 2 已記錄，退役前要處理）。

### 實證：新系統沒有呼叫舊的密碼函式

以下是讀檔得到的結果：

- `assess_schema.sql` 的所有 `assess_*` 函式（`assess_categories`、`assess_candidates`、`assess_start`、`assess_draw`、`assess_save_item`、`assess_submit`、`assess_void`、`assess_abandon`、`assess_add_image`、`assess_remove_image` 與計算小工具）都沒有呼叫 `_pw_ok`、`_assert_pw`、`list_categories`、`draw_questions`、`admin_*`；身分檢查走 `assess_assert_cs()`，只直接讀寫那三張題庫表。
- 新的 `bank_*` 函式只走 `bank_assert_cs()`，同樣沒有呼叫任何舊函式。
- 整個「業務考核系統」資料夾搜尋舊函式名稱：只出現在 `roster_schema.sql`、`assess_schema.sql`、`backoffice_schema.sql` 的說明註解，與 `assess_verify_fake.sql` 的驗證；前端頁面與 js 沒有任何呼叫。
- **沒有發現任何呼叫，所以不需要停下回報。** 但這是讀檔結論，資料庫實際狀態以兩道自動檢查為準：`bank_retire_legacy.sql` 開頭有一段防護，會在資料庫掃描所有 public 函式、policy、檢視，只要發現有東西引用舊函式就丟錯停下、什麼都不改；`bank_verify_fake.sql` 區段 9 也有同樣的實證測項。**若這兩處任何一處報告有引用，請停下回報，不要自行處理。**

### 停用步驟（之後老闆同意才做）

1. 先跑 `bank_verify_fake.sql` 確認全部通過，並請客服部試用新題庫管理頁確認好用。
2. Supabase SQL Editor → New query → 貼上 `bank_retire_legacy.sql` 整份 → Run。它只做一件事：對 8 個舊函式（`list_categories(text)`、`draw_questions(text, text[])`、`admin_login(text)`、`admin_list_questions(text)`、`admin_save_question(text, bigint, text, text, text, jsonb)`、`admin_delete_question(text, bigint)`、`admin_rename_category(text, text, text)`、`admin_reset(text, text)`）收回 `anon` 的 execute。
3. 結果：舊抽選器與舊管理頁完全無法運作。**不刪除任何函式、不動 `app_secret`（密碼雜湊）、不動題庫資料。**
4. 提醒：`assess_verify_fake.sql` 的「draw_questions 仍開放 anon 執行」那一列，停用後會顯示「失敗」，這是預期（那是停用前的驗證），其他列不受影響。

### 還原方法（只有要恢復舊抽選器時才執行）

`bank_retire_legacy.sql` 檔案下半段有 8 行 `grant execute … to anon`，**整段包在 `/* … */` 註解裡，平常不會執行**。要恢復時，把那 8 行單獨複製出來，貼到 SQL Editor 執行即可（內容與舊 `schema.sql` 最後一段授權相同）。還原後舊抽選器與舊管理頁恢復運作（共用密碼仍有效，因為密碼雜湊沒動過）。
`bank_verify_fake.sql` 的區段 9 會在交易內演練「停用 → 驗證 anon 被拒、assess_* 與 bank_* 仍可用 → 還原 → 驗證 anon 恢復」，最後一起 rollback。

## 已知限制

- 驗證腳本與 `bank_retire_legacy.sql` 都有各自的一份 revoke／grant 語句（腳本不能 include 別的檔案），兩邊若要修改必須同步。
- 「抽題與管理操作不會同時發生」靠同一把鎖；驗證腳本只能讀函式內容確認四個寫入函式都取了同一把鎖，**真正的同時操作（兩個連線同時按）腳本測不到**。
- 防護掃描（`bank_retire_legacy.sql` 開頭與驗證區段 9）只掃 public schema 的函式內容、public 與 storage 的 policy、public 的檢視；未掃觸發器、欄位預設值與其他 schema。以現況（已讀檔實證沒有引用）足夠；日後若新增相關物件，須重新檢查。
- 驗證區段 9 還原後不實際呼叫舊函式（它們密碼錯誤時會 sleep 0.5 秒），只用 `has_function_privilege` 確認 anon 權限恢復。
- 區段 10 的真實 drawn／category_last 筆數比對，若腳本執行期間剛好有人抽題，可能誤報；**第一次執行請選在沒人抽題的時段**，誤報時在沒人抽題時重跑即可。
- 分類名稱沒有長度上限（與舊函式一致，沒有另外加規則）。
- 刪除題組時，已存在成績單裡的題組快照不受影響（成績單機密表的題號沒有外鍵）。
- `bank_reset` 洗牌全部時會清掉所有分類的「已抽記錄」與「最近一題」記錄；新一輪第一題避開上一題的保護因此也跟著清掉（與舊函式一致）。
- 網頁（題庫管理頁）本身不在這四個檔案範圍內，仍需另外製作。

## 只能用讀的確認（寫檔的人不能執行 SQL）

- 所有 SQL 都沒有在真的資料庫執行過；語法（含 `with ordinality` 別名、`aclexplode`、預備陳述式輸出）與邏輯是逐條讀過，必須靠第一次在 Supabase 跑 `bank_verify_fake.sql` 才算確認。
- 驗證腳本預期值（例如 `pg_get_function_result` 的字串 `TABLE(id bigint, …)`、各錯誤訊息文字、`ZZ` 假分類不與真實分類撞名）是依舊函式與 Postgres 行為推論，第一次跑若有「失敗」列，先看是預期字串差異還是真的行為不同。
- 「新系統沒有呼叫舊密碼函式」目前是讀檔結論；資料庫端以 `bank_retire_legacy.sql` 開頭防護與驗證區段 9 的實證測項確認。
- `grant`／`revoke` 對 Supabase 預設權限（`alter default privileges` 會自動授權給 anon）的實際效果，要靠區段 8、9 的 `has_function_privilege` 與 `set local role anon` 測項實跑才算確認。
- 還原後舊函式的「恢復」只以 `has_function_privilege` 判斷，沒有實際呼叫。
