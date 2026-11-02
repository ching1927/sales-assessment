# 弱項建議題組 — 規則與資料庫介面約定

這份是「資料庫」與「網頁」兩邊共同遵守的約定。改任何一邊之前先對照這份；對不上就停下來回報，不要自己改約定。樣品見 `樣品/弱項建議題組樣品.html`（老闆已確認方向）。

## 一、規則（老闆 2026-11-02 定案）

1. 考核後看到考生的弱項，下次考核直接建議題組，不必走抽選器；考核結束的成績頁預告「下次建議考題」。
2. **可勾選的面向只有 5 個**：資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識。「語氣與禮貌」「文字品質」每個題組都要注意，**不勾選、不拿來挑題**；它們偏低（最近 3 次平均得分率低於 70%）時，只在畫面提醒考官留意。
3. **題組面向標記**：客服部在題庫管理替題組勾選 1～3 個面向（可以不勾＝未標記，未標記的題組不會被當成弱項題）。
4. **弱項怎麼算**：取該考生最近 3 張「已送出、未作廢」的成績單；各面向得分率＝所有題組該面向的等級百分比平均（優 100／良 70／待加強 40／不及格 0；不適用與未評不計入）；在上述 5 個面向中取得分率最低的 **2 個**（不足 2 個有資料就取有的）。完全沒有成績單＝沒有弱項（新人第一次考）。
5. **建議題數**：預設 3，可選 2～4。**弱項題 = 題數 − 1（至少 1）**，輪流分給 2 個弱項面向；其餘照原本輪替規則隨機，避免考生猜到範圍。
6. **選弱項題的條件**：題組標記包含該弱項面向、且「該考生沒考過」（以該考生已送出或作廢考核的題組為準，草稿不算）。符合的題組不夠時，用隨機題補，並提示客服部「題庫標記不足」。隨機題優先挑「該考生沒考過、本輪還沒被抽過」的。
7. 沒有弱項（第一次考）或找不到建議題組時，退回原本的抽選器隨機抽。
8. 客服部可對每一題「換一題」，或整份改用抽選器。

## 二、資料庫物件（`security definer`、`set search_path`、`revoke … from public, anon` 再 `grant execute … to authenticated`；函式內驗角色；錯誤訊息繁中）

- 新表 `question_dims`：`question_id`（對應題庫 questions 的 id，型別照 questions.id，主鍵，`on delete cascade`）、`dims text[] not null`（只能是上述 5 個面向、不重複、1～3 個）、`updated_at`、`updated_by`。開 RLS，**只有客服部能 select**，直接寫入一律收回，只能經函式。
- `bank_set_dims(p_question_id <questions.id 型別>, p_dims text[])`：客服部；題組須存在；`p_dims` 空陣列＝刪除標記；超過 3 個、含非法面向、重複都拒絕。
- `assess_weak_profile(p_employee_id text)` → jsonb：客服部；
  `{ "n": 取到的成績單張數(0~3), "rates": [{"dim": 面向, "pct": 數字或null}（七個面向，固定順序）], "weak": [{"dim","pct"}（5 個面向中最低的至多 2 個，由低到高）], "always_low": [{"dim","pct"}（語氣與禮貌、文字品質中平均 < 70 者）] }`。員工須存在。
- `assess_suggest_pool(p_employee_id text)` → table(`question_id`, `category text`, `title text`, `dims text[]`（未標記為空陣列）, `taken_before boolean`（該考生考過）, `drawn_this_round boolean`（目前在抽選器 drawn 內））：客服部；回傳整個題庫（供網頁依規則挑選與換題；題組名稱屬機密，所以只有客服部能呼叫）。
- `assess_pick(p_assessment_id uuid, p_question_ids <questions.id 型別>[])` → **與 `assess_draw` 完全相同的回傳欄位**（`item_id, category, code, title, steps, repeated, new_round`，以 `assess_draw` 最後生效版本為準）：客服部；只能對自己的草稿考核；題組須存在、不重複、不可已在這份考核內；總題組數不可超過現行上限；寫入方式與 `assess_draw` 相同（同一把鎖、items 與 secrets、`was_drawn_before`、`drawn` 與 `category_last` 的更新、`repeated` 判斷），讓抽選器的輪替公平性不被破壞。
- 既有函式（`assess_draw`、`bank_*`、`assess_start`、`assess_submit` 等）**不得改動行為**。

## 三、網頁

- `js/suggest.js`：選題純函式（可在 Node 測試），輸入 profile 與 pool、題數，輸出建議清單與「題庫不足」旗標；換題函式。
- `questions.html`：題組表單與列表可勾選／顯示重點面向（5 個，最多 3 個，說明語氣與文字品質每題都評）。
- `assess.html`：選考生並按「準備考核」後，先顯示「弱項與建議題組」面板（有弱項才顯示；沒有就照原流程）；可「用這些題組開始考核」（`assess_start` → `assess_pick`，直接進入評分）或「改用抽選器隨機抽」（原流程）。送出後的結果頁顯示「下次建議考題」預告。
- `js/assess-api.js`、`js/questions-api.js` 加對應封裝。

---

## 四、資料庫實作說明與執行步驟（資料庫工程師補充，規格正文第一至三節未改動）

> 兩支 SQL **尚未在 Supabase 執行**。開發機沒有 Postgres，但已用 PGlite（真正的 PostgreSQL 搬到 WASM 跑）搭一個假的 Supabase 環境實跑過：`roster → assess → bank` 最小環境與「再加 accounts、notes_visible、backoffice、spotcheck、url_patch」完整環境，兩種都是 **177/177 項通過**；`weak_suggest_schema.sql` 連跑兩次也不報錯。另外做了 6 組「故意改壞」測試（改成取 5 張、不開新一輪、不算作廢、草稿也算、不取鎖、`<= 70`），驗證腳本都抓得出來。這不能取代在真實 Supabase 跑一次（假環境的 `auth.jwt()`、Storage 是自己寫的簡化版）。

### 檔案

| 檔案 | 用途 |
|---|---|
| `weak_suggest_schema.sql` | 要執行的那份。單一交易（begin…commit），可重複執行，不動既有資料 |
| `weak_suggest_verify_fake.sql` | 驗證腳本：只用假資料、全程 rollback，不留任何資料 |

### 執行順序

0. 先到 Supabase 備份（Dashboard → Database → Backups）。前提：`roster_schema.sql`、`assess_schema.sql`、`bank_schema.sql` 已執行（`spotcheck_schema.sql`、`url_patch.sql`、`backoffice_schema.sql` 等有沒有執行都不影響）。
1. SQL Editor → New query → 貼上 `weak_suggest_schema.sql` 整份 → Run。拿不到鎖會在 5 秒後整份回復，稍後重跑即可。
2. 再開新的 query，貼上 `weak_suggest_verify_fake.sql` 整份 → Run（請挑沒人抽題的時段）。
3. 預期結果：最後一張表第一列「總結」寫「**N/N 項通過**」（目前是 177/177）、「通過」欄全是「通過」。任何一列「失敗」就停下回報，不要自己放行（總結列會列出未通過的序號）。

### 新增的物件（全部都是新增，沒有改動任何既有物件）

- 資料表 `question_dims`：`question_id bigint` 主鍵、外鍵指向 `questions(id)` `on delete cascade`；`dims text[] not null`；`updated_at`；`updated_by`（記設定者信箱）。約束 `question_dims_dims_valid`：只能是 5 個面向、不重複、1～3 個（資料表層再擋一次）。開 RLS、policy `question_dims_select`（只有客服部）；`authenticated` 只有 select，`anon` 什麼權限都沒有，直接寫入全收回。
- 函式（全部 `security definer`、`set search_path = public, pg_temp`、`revoke … from public, anon` 再 `grant execute … to authenticated`；內部驗客服部，其餘角色一律「沒有權限」）：
  - `bank_set_dims(p_question_id bigint, p_dims text[])` → void
  - `assess_weak_profile(p_employee_id text)` → jsonb（`n`、`rates`、`weak`、`always_low`）
  - `assess_suggest_pool(p_employee_id text)` → table(`question_id bigint, category text, title text, dims text[], taken_before boolean, drawn_this_round boolean`)
  - `assess_pick(p_assessment_id uuid, p_question_ids bigint[])` → 欄位與 `assess_draw` 完全相同（`item_id, category, code, title, steps, repeated, new_round`；驗證腳本有逐字比對）

### 實作細節（規格有寫、這裡補足做法）

- **`assess_pick` 逐行對照 `assess_draw`（`assess_schema.sql` 版本；`assess_draw` 在其他檔案沒有被重新定義過）**：鎖該張考核 `for update` → 只限草稿、只限建立者本人 → 取同一把 `pg_advisory_xact_lock(hashtext('exam_draw_questions'))` → 每題前「分類已全部在 drawn 內就清掉該分類 drawn、`new_round = true`」→ `repeated`＝該考生以前有已送出或已作廢的考核考過（草稿不算）→ `was_drawn_before`＝寫入 drawn 前（開新一輪則是清完之後）是否已在 drawn → drawn `on conflict` 更新時間、`category_last` `on conflict` 更新題號 → `seq` 接在目前最大值後 → 寫 `assessment_items` 與 `assessment_item_secrets`。唯一差別是題組由呼叫者指定、不再用 `order by … random()` 挑。驗證腳本對同一題、同樣起始狀態各跑一次 `assess_draw` 與 `assess_pick`（三種情境：全新、已在 drawn 會開新一輪、考生考過），比對寫入後的題組、機密、drawn、category_last、回傳旗標，完全一致。
- **`assess_weak_profile` 的得分率與考核後台 `dimRates` 同一個算法**：取該員工最近 3 張「已送出」的成績單，把所有題組中該面向的等級百分比取平均（不是先算每張再平均）；`assess_level_pct` 回 null 的（不適用、未評）不計入。已用「3 題優＋1 題不及格＝75（不是 50）」驗證。
- **執行時不讀 `analytics_dim_rates` 檢視**（直接 join 底層資料表），所以不依賴 `backoffice_schema.sql` 有沒有執行。
- `bank_set_dims` 與 `assess_pick` 都取與 `assess_draw`、`bank_*` 寫入函式相同的那把鎖，抽題、選題、改題庫不會同時發生。

### 與規格的差異

**沒有差異**（簽名、回傳欄位、資料表欄位、權限都照規格）。下面是規格沒明寫、我採用的解讀，**請老闆（或網頁那邊）確認**；每一項都是單一處可改：

1. **「總題組數不可超過現行上限」怎麼落地**：`assess_draw` 其實沒有「幾題」的數字上限，唯一的限制是資料表 `unique(assessment_id, category)`＝「一場每個分類最多一個題組」。所以 `assess_pick` 的上限就是同一條：一次選的題組彼此分類不可重複（`一場考核每個分類只能抽一個題組，分類不可重複`），也不可與這場已有題組的分類重複（`這場考核已抽過其中的分類，每個分類最多一個題組`，文字與 `assess_draw` 相同，網頁現有的 `/已抽過|最多一個題組/` 判斷照樣適用）。另外選到這場已經有的題組會被拒（`這個題組已在這場考核內，不可重複選取`）。**網頁選題時要注意：同一分類只能選一題**，弱項題與隨機題若落在同一分類，要換題。
2. **`bank_set_dims` 回傳 void**（規格沒寫回傳型別）。`p_dims` 為 null 也被拒（錯誤訊息提示改傳空陣列）；存入時一律依固定順序（資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識）排列。
3. **`assess_suggest_pool` 也檢查員工存在**（規格只在 `assess_weak_profile` 寫了「員工須存在」；這裡同樣回「找不到員工」，因為 `taken_before` 是針對某位考生算的）。回傳欄位照規格，沒有 `code`。
4. **`assess_weak_profile` 的數字**：判斷（是否 < 70、取最低 2 個）用未四捨五入的平均；輸出的 `pct` 四捨五入到小數 1 位（例如 69.23 輸出 69.2）。平均值是「10 的倍數 ÷ 題組數」，題組數不到 200 時四捨五入不可能讓 < 70 的值變成 70，所以不會出現「顯示 70 卻被標偏低」。5 個面向中得分率並列時依固定順序取先者；`always_low` 依固定順序（語氣與禮貌、文字品質）。
5. 同一時刻送出的成績單（`submitted_at` 完全相同）依 `created_at`、`id` 由新到舊決定取哪 3 張，結果固定。
6. **「邊界 69.9／70」做不出 69.9**：平均值是 10 的倍數除以題組數，要剛好 69.9 需要 100 題以上。驗證腳本改用「13 題＝69.23（< 70，進 always_low）」與「兩題平均剛好 70（不進）」當邊界。

### 已知限制

- **並發沒有實測**：只靜態確認 `assess_pick` 與 `assess_draw` 取同一把 advisory lock（驗證腳本有比對函式原始碼）。真正的並發需要另開兩個連線手動實證。
- `assess_abandon`（既有）放棄草稿時「不還原 `category_last`、只把 `was_drawn_before = false` 的題從 drawn 移除」的既有限制，對 `assess_pick` 選出來的題組同樣適用（因為寫入方式一致）。
- 題組改分類（`bank_save_question`，既有）不會清掉面向標記（標記跟著題號走）；刪題組才會連帶刪除標記。
- 面向名稱在資料表約束與三個函式中各寫了一份（5 個），日後若面向改名，這幾處要一起改。
- `assess_weak_profile` 只看「已送出」且「未作廢」的成績單；成績單裡面向全是「不適用」的題組不影響平均。
