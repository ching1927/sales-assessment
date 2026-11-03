# 第一期：考核期、固定 3 題組、弱項追加題、待開通 — 規則與資料庫介面約定

資料庫與網頁兩邊共同遵守。對不上就停下來回報，不要自己改約定。樣品：`樣品/第一期流程樣品.html`（老闆已確認）。

## 一、規則（老闆 2026-11-05 定案）

1. **考核期**：新進同仁在「考核期」不能回覆顧客。新人考核合格線一律 **70 分**（初考、補考相同），通過就轉為「已上線」，並進入「待開通回覆權限」清單。不管到職多久，沒通過就一直是考核期。
2. **新人標籤**：到職 3 個月（90 天）內顯示「新人」，**只是辨認用**，與能不能回覆無關。標籤顯示規則：考核期者顯示「考核期」；到職 90 天內另顯示「新人」；其他顯示「已上線」。
3. **回考核期**（現有 `probation_since` 機制，之後由客服部手動拉回，第一期不改它的觸發方式）：回考核期者同樣是考核期，補考合格線仍是 **85**（正式員工標準，沿用現有 `tenure_source = '考核期'` 的行為）；通過 85 分除了清除 `probation_since`，也要進入「待開通回覆權限」清單。**（老闆 2026-11-03 追加）** `period_status` 是「是否考核期」的單一事實：抽查拉回考核期（`spot_register` 觸發回考核期）時，同步設 `period_status = '考核期'`；客服部取消回考核期（`spot_cancel_probation`，誤判復原）時，同步把 `period_status` 設回 `已上線`；已通過的回考核期不可取消的既有規則不變。**（審查建議，老闆 2026-11-03 追加）** 考核期的人（`period_status = '考核期'`）不能回覆顧客、不抽查：`spot_candidates` 名單排除、`spot_register` 拒絕（訊息沿用「該員工目前在考核期，不能抽查」）。
4. **固定 3 題組**：一場考核固定考基礎、進階、綜合各 1 題（共 3 個「核心題組」）。分類清單存 `app_settings` 的 `exam_core_categories`（逗號分隔，預設 `基礎,進階,綜合`），日後新增分類只改設定。
5. **弱項追加題**：核心題組評完後，用「這一場」核心題組的成績找弱項（5 個可標記面向：資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識，得分率最低的至多 2 個，且得分率必須 < 85%；語氣與禮貌、文字品質不拿來挑題），針對弱項從題庫隨機再出題（沿用「弱項建議題組」的標記與選題邏輯，**允許與核心題組同分類**）。追加題**不算入總分、判定、弱項最弱面向、七面向分析與改善單**，只記在成績單上當輔導參考。沒有弱項（全部 ≥ 85%）就不追加。追加題只記「追加開始時間」，不做倒數。
6. **待開通清單**：考核通過（新人 ≥ 70；回考核期 ≥ 85）時自動新增一筆「待開通」；客服部去 LINE 官方帳號開通後，按「已開通」留紀錄（日期、人）。
7. **待考回報**：資格改成：`新人` 回報＝在職、納入考核、`period_status = '考核期'` 且 `probation_since is null`（不再用到職 90 天判斷）；`回考核期` 回報＝在職、納入考核、`probation_since is not null`；`複檢` 不變。

## 二、資料庫物件（`security definer`、`set search_path`、`revoke … from public, anon` 再 `grant execute … to authenticated`；函式內驗角色；錯誤訊息繁中）

- `employees.period_status text not null default '已上線'`（check：`考核期`/`已上線`）、`employees.passed_on date null`。**既有資料遷移**：目前 `employees_with_tenure.tenure_group = '新人'`（到職 90 天內）、在職、納入考核、且「沒有任何已送出未作廢、判定為及格或優秀的成績單」者 → `考核期`；其餘 → `已上線`；`probation_since is not null` 者一律 `考核期`。遷移要寫在腳本內並可重複執行（重跑不得把已上線的人改回考核期）。`employees_with_tenure` 要重建以帶出新欄位（drop 後重建並重做權限，內容與最新版相同再加新欄位）。
- `assessment_items.is_extra boolean not null default false`；`assessments.extra_started_at timestamptz null`。`assessment_items` 原本「同一場每個分類最多一個題組」的唯一限制，改成**只對 `is_extra = false` 生效**（部分唯一索引）。
- 新表 `reply_activations`：id uuid pk、employee_id、employee_label、store_code、assessment_id uuid、passed_on date、status（`待開通`/`已開通`）、done_on date null、done_by（信箱）null、created_at。RLS：客服部、總公司主管全部 select；店長自己門市；直接寫入全收回。
- `assess_core_categories()` → text[]：客服部；讀 `app_settings.exam_core_categories`（解析、去空白、去重；沒設定回預設三類）。
- `assess_start`（修改，保留全部既有行為）：員工 `period_status = '考核期'` 且 `probation_since is null` → `tenure = '新人'`（合格線 70），`tenure_source` 維持 `'自動'`；`probation_since is not null` 維持既有（正式、`考核期`、85）；`period_status = '已上線'` 者維持既有判斷。
- `assess_draw`（不改）；網頁用核心分類清單當 `p_cats` 一次抽 3 題。
- `assess_draft_weak(p_assessment_id uuid)` → jsonb：客服部、自己的草稿；只用 `is_extra = false` 的題組、必須每題都已評完；回傳 `{ "rates": [{dim,pct}（七個面向）], "weak": [{dim,pct}（5 面向中 < 85 的最低至多 2 個）], "always_low": [{dim,pct}（語氣與禮貌、文字品質 < 70）] }`。
- `assess_add_extra(p_assessment_id uuid, p_question_ids bigint[])` → 回傳欄位與 `assess_draw` 相同（以 `assess_pick` 為範本，同一把鎖）：客服部、自己的草稿；核心題組（`is_extra=false`）必須已有且全部評完；題組不存在、重複、已在這場考核內都拒絕；一次最多 4 題、整場追加題最多 4 題；寫入 `is_extra = true`，**不受每分類一題限制**，第一次呼叫時寫 `assessments.extra_started_at`；同樣更新 drawn／category_last 並判斷 repeated。
- `assess_submit`（修改，保留全部既有行為）：總分、題組分數平均、判定、`weakest_dims` **只用 `is_extra = false` 的題組**；追加題一樣要求評完才能送出；送出後依規則 1、3 處理考核期：新人（`tenure = '新人'`）總分 ≥ 70 且員工 `period_status = '考核期'` → 設 `已上線`、`passed_on`、新增 `reply_activations`；回考核期者（`tenure_source = '考核期'`）總分 ≥ 85 → 既有清除 `probation_since` 行為不變，另設 `已上線`、`passed_on`、新增待開通。**同一張成績單不可重複新增待開通**。
- 所有以 `assessment_items` 計算「面向平均得分率、弱項分析、改善單判定」的檢視與函式（backoffice_schema.sql 的 analytics 檢視、`assessment_summaries`、`assess_weak_profile`、`improvement_*`、成績單相關函式等）都必須排除 `is_extra = true`（`item_count` 也只算核心題組）。要逐一盤點並在 README 列出清單。
- `activation_mark_done(p_id uuid)`：客服部；`待開通` → `已開通`，記 done_on（台北日期）與 done_by；已開通者拒絕。
- `exam_req_candidates` 與 `exam_req_create`（修改，保留既有行為）：新人資格依規則 7。
- `exam_req_badge()`（修改）：客服部＝待處理回報數 ＋ 待開通數；其餘角色不變。
- `spot_register`（修改，老闆追加）：觸發回考核期時，除了設 `probation_since`，也設 `period_status = '考核期'`，其餘行為不變。
- `spot_cancel_probation`（修改，老闆追加）：取消時，除了清除 `probation_since`，也把該員 `period_status` 設回 `已上線`，其餘行為不變。
- `spot_candidates`（修改，老闆追加）：名單多一個條件 `period_status <> '考核期'`，其餘條件不變。
- `spot_register` 的資格檢查（老闆追加）：「目前在考核期」改成 `probation_since is not null` **或** `period_status = '考核期'`，訊息不變。
- `assess_submit` 回考核期通過分支的守門（老闆追加）：先鎖員工列，**只有員工目前 `probation_since is not null` 或 `period_status = '考核期'`** 時才清 `probation_since`、轉已上線、設 `passed_on`、新增待開通；員工已是已上線且 `probation_since` 為空（例如已取消回考核期、或另一張草稿已先通過）時，只正常送出成績單。`spot_probations` 的既有更新維持原樣。新人分支原本就有同樣守門（`period_status = '考核期'` 才轉）。
- 觸發器與其他既有函式不得改變行為。

## 三、網頁

- `assess.html`：選考生並按「準備考核」後，**自動用 `assess_core_categories()` 一次抽 3 題**，進入評分（不再讓客服部選分類、不再顯示「弱項與建議題組」面板；若核心分類在題庫裡缺題導致抽不出來，顯示明確錯誤並可退回舊的選分類流程）；核心 3 題評完按「分析弱項」→ 呼叫 `assess_draft_weak`；有弱項就顯示弱項與建議追加題（用 `js/suggest.js` 選題，新增選項允許同分類）、客服部可換題、按「追加弱項題」呼叫 `assess_add_extra` 後繼續評分（追加題標示「追加題・不算總分」，並顯示追加開始時間）；沒有弱項或客服部選「不追加」就直接送出。結果頁：總分與判定只看核心題組，追加題另列，通過者顯示「已加入待開通」；未通過顯示可再約補考。
- `reports.html` 成績單詳情：追加題區塊獨立顯示（「弱項追加題・不算入總分」）；雷達圖只用核心題組。
- `requests.html`（客服部）：新增「待開通回覆權限」區塊（清單、已開通按鈕、狀態篩選）；導覽紅點含待開通數（`exam_req_badge`）。
- `roster.html`：標籤顯示規則依第一節第 2 點（考核期、新人、已上線）；名冊與其他處原有「新人／正式」顯示若與此衝突，以此為準，但不得破壞既有篩選。「考核期」標籤只看 `period_status`（資料庫已讓它與 `probation_since` 同步，不必再 OR 判斷）；**網頁新增人員時要明確帶 `period_status = '考核期'`**（資料庫預設是已上線）。
- 「待考回報」的三項前置條件**尚未確認，第一期不做**，維持現有影片勾選。

---

## 四、資料庫實作說明與執行步驟（資料庫工程師補充，規格正文第一至三節未改動）

> ⚠️ 兩支 SQL **尚未在 Supabase 執行**。開發機沒有 Supabase 連線，只在 PGlite（npm 的 `@electric-sql/pglite`，本機模擬的 Postgres）搭的假環境實跑過：用**非超級使用者**角色（模擬 Supabase 的 postgres）依序載入考題抽選器 schema、roster、assess、bank、accounts、notes_visible、backoffice、spotcheck、url_patch、weak_suggest、exam_request（含假的 pg_net），先預塞一批像真的資料（3 間門市、15 位員工含新人／已過關新人／舊人／離職／考核期中／未填到職日、5 個帳號、已送出與作廢與草稿成績單、改善單、舊待考回報、題庫與抽選器狀態），再執行本期 schema，再跑驗證腳本；驗證完 rollback 後預塞資料經逐表指紋比對**原樣保留**。假環境的 `auth.jwt()`、Storage 是自己寫的簡化版，**不能取代在真實 Supabase 跑一次**。

### 檔案

| 檔案 | 用途 |
|---|---|
| `phase1_schema.sql` | 要執行的那份。單一交易（begin…commit），可重複執行，不動既有資料 |
| `phase1_verify_fake.sql` | 驗證腳本：只用假資料、全程 rollback，不留任何資料 |

### 執行順序

0. 先到 Supabase 備份（Dashboard → Database → Backups），並先跑下面「遷移前老闆要先跑的檢查查詢」確認結果符合預期。前提：考題抽選器 schema、`roster`、`assess`、`bank`、`accounts`、`notes_visible`、`backoffice`、`spotcheck`、`url_patch`、`weak_suggest`、`exam_request` 都已執行（缺哪個，schema 開頭會用中文訊息擋下並整份回復；也會檢查 `assess_start`／`assess_submit` 目前是 spotcheck 那一版）。
1. SQL Editor → New query → 貼上 `phase1_schema.sql` 整份 → Run。拿不到鎖會在 5 秒後整份回復，稍後重跑即可。**若報「這些人員的職稱超過 20 字…」**：先到名冊把該員職稱縮短到 20 字內再重跑（原因見「已知限制」第 6 點）。
2. 執行下面「遷移後人工檢查」的 SQL，確認被標成考核期的人數與名單合理。
3. 再開新的 query，貼上 `phase1_verify_fake.sql` 整份 → Run（請挑沒人抽題的時段）。
4. 預期結果：最後一張表第一列「總結」寫「**N/N 項通過**」（目前 N＝378），「通過」欄全是「通過」。有失敗時總結列會附「第一個失敗」的序號、測項與實際錯誤訊息；任何一列「失敗」就停下回報，不要自己放行。

### 新增與修改的物件清單

**新增**
- 欄位：`employees.period_status`（text not null default `'已上線'`，check 只收考核期／已上線，約束名 `employees_period_status_check`）、`employees.passed_on`（date）、`assessment_items.is_extra`（boolean not null default false）、`assessments.extra_started_at`（timestamptz）。
- 資料表 `reply_activations`（欄位照規格；`assessment_id` 可空、外鍵 `on delete set null`；`employee_id` 外鍵 `on update cascade on delete cascade`；check `reply_activations_status_fields`：待開通不可有開通資料、已開通必須有日期與人）。索引：`reply_activations_status_idx`、`reply_activations_store_idx`、`reply_activations_one_per_assessment`（同一張成績單最多一筆，唯一部分索引）。RLS policy `reply_activations_select`（客服部、總公司主管全部；店長本店；其他沒有）；`authenticated` 只有 select，`anon` 全無，直接寫入全收回。
- 唯一部分索引 `assessment_items_one_core_per_category`（`(assessment_id, category) where not is_extra`），取代原本的 `unique (assessment_id, category)` 約束（用查出來的名稱 drop，不寫死）。
- `app_settings` 新增兩列：`exam_core_categories`（`基礎,進階,綜合`，已有就不動）、`phase1_migrated_on`（遷移完成記號，值為遷移當天台北日期）。
- 函式：`assess_core_categories()`、`assess_draft_weak(uuid)`、`assess_add_extra(uuid, bigint[])`、`activation_mark_done(uuid)`（授權 `authenticated`，函式內驗客服部）；內部 `phase1_migrate_period_status()`（任何網頁角色都不能呼叫）。全部 `security definer`、固定 `search_path = public, pg_temp`、`revoke … from public, anon` 再 `grant execute … to authenticated`。

**修改（簽名與回傳型別都不變）**
- `assess_start`：以 spotcheck 版為基礎，只多一段 `elsif period_status = '考核期'`（probation_since 為空）→ 新人／自動，不管到職日、不用手動指定。
- `assess_submit`：以 spotcheck 版為基礎；總分、判定、`weakest_dims`、`item_count` 只用核心題組，追加題一樣要評完才能送出且照常寫入各自的 item_score；送出後依規則 1、3 轉已上線、記 `passed_on`、新增待開通（`on conflict do nothing`＋唯一索引保證同一張成績單一筆）。**回考核期通過分支有守門（審查建議）**：先鎖員工列，只有員工目前 `probation_since` 有值或 `period_status = '考核期'` 才清除、轉已上線、設 `passed_on`、新增待開通；否則（已取消回考核期，或另一張草稿已先通過）只正常送出成績單、不再新增待開通、不改 `passed_on`。新人分支原本就有同樣守門，兩個分支規則一致。`spot_probations` 改已通過的既有更新照舊（不受守門影響）。
- `assess_weak_profile`、`exam_req_candidates`、`exam_req_create`、`exam_req_badge`：以各自最後生效版本為基礎，只改規格要求的部分。
- **`spot_register`**（以 `url_patch.sql` 版為基礎）：只改一行——觸發回考核期時 `update employees set probation_since = v_today` 改成同時 `period_status = '考核期'`。其餘（資格檢查、黃單／紅單／回考核期規則、回傳）逐字不變。
- **`spot_register` 資格檢查**（同一個函式，審查建議）：「該員工目前在考核期，不能抽查」的條件由 `probation_since is not null` 改成 `probation_since is not null or period_status = '考核期'`（到職超過 90 天但仍是考核期、未填到職日的考核期人員都被擋）；其餘條件與訊息不動。
- **`spot_candidates`**（以 `spotcheck_schema.sql` 版為基礎，審查建議）：名單條件多一行 `and e.period_status <> '考核期'`，其餘不動。（`spot_status` 沒有改。）
- **`spot_cancel_probation`**（以 `spotcheck_schema.sql` 版為基礎）：只改一行——取消清除 `probation_since` 時同時把 `period_status` 設回 `已上線`。「已通過不可取消」「已取消不可重複取消」「原因必填」「有別筆進行中就不清除」等既有規則不變。
- 檢視：`employees_with_tenure`（drop 後重建，內容與 spotcheck 版相同，新欄位由 `e.*` 帶出，重做權限）、`assessment_summaries`（`item_count` 只算核心）、`analytics_dim_rates`（排除追加題）。

**逐一盤點：哪些讀 `assessment_items`、有沒有排除 `is_extra`**

| 物件 | 用途 | 處理 |
|---|---|---|
| `assess_submit` | 總分、判定、最弱面向、題組數 | 已排除（追加題只算自己的分數） |
| `assessment_summaries`（檢視） | 成績單列表的 `item_count` | 已排除 |
| `analytics_dim_rates`（檢視） | 考核後台七面向分析資料來源 | 已排除 |
| `assess_weak_profile` | 考生最近 3 張的弱項 | 已排除 |
| `assess_draft_weak`（新） | 本場弱項 | 只用核心題組 |
| `improvement_auto_open`（觸發器）、`improve_*`、`improvement_ticket_view` | 改善單 | 不讀題組表；開單用成績單的 `weakest_dims` 與 `verdict`，兩者已只看核心，所以自動符合 |
| `assess_suggest_pool`、`assess_draw`、`assess_pick`、`assess_add_extra` 的「考過／repeated」判斷 | 這位考生以前考過哪些題 | **刻意不排除**：追加題也是真的考過的題，仍應避免重複（這不是計分，不在規格排除範圍；若老闆要排除請告知） |
| `assess_abandon` | 放棄草稿時還原 drawn | **刻意不排除**：追加題也要一併刪除並還原題池（已驗證） |
| `assess_save_item`、`assess_add_image`、`assess_remove_image` | 單一題組暫存／圖片 | 以題組 id 操作，追加題照樣可用 |
| `spot_*`、`exam_req_*`、`bank_*`、`accounts_*` | — | 不讀題組表 |
| 網頁端（`js/assess-api.js`、`reports.html`）直接 `select` `assessment_items` 的地方 | 草稿載入、成績單詳情、雷達圖 | **資料庫已提供 `is_extra` 欄位；網頁要把它加進 select 並自己分開顯示／排除**（不在本次範圍，提醒網頁工程師） |

### 與規格的差異／實作時的解讀（沒有改規格正文；以下請老闆或規格作者確認）

1. **遷移只做一次（用記號）**：規格要求「重跑不得把已上線的人改回考核期」。實作成：遷移完成後在 `app_settings` 寫 `phase1_migrated_on`，之後重跑看到記號就整段略過。好處是連客服部之後手動調整的結果也不會被重跑覆蓋。為此多了一個內部函式 `phase1_migrate_period_status()` 與這一列設定（規格沒列，屬實作細節）。**若要刻意重新遷移，需先刪掉那一列設定**。
2. **`employees_with_tenure` 的「再加新欄位」**：規格「內容與最新版相同再加新欄位」，我解讀為 `period_status`、`passed_on` 兩個新欄位（由 `e.*` 自動帶出），沒有再多加計算欄位（標籤文字由網頁依規則組合）。
3. **`exam_req_create` 新人資格的錯誤訊息**改為「這位人員不是新人（考核期者才能以「新人」回報，已上線者不行）」。仍含「不是新人」三字，所以舊訊息比對仍成立；其餘訊息不變。
4. **`assess_core_categories` 同時接受半形「,」與全形「，」**（規格只寫逗號分隔）；沒設定、空字串、只有逗號與空白都回預設三類。
5. **`reply_activations` 的外鍵與可空性規格沒寫**：`assessment_id` 設可空＋`on delete set null`（成績單日後被刪也保留紀錄）；`employee_id` 設 `on delete cascade`（與 `exam_requests` 一致）。
6. **「同一張成績單不可重複」只以成績單為單位**（規格原文）：同一個人若先後通過兩次（例如回考核期又通過）可各有一筆，即使前一筆還沒按已開通。
7. 追加題錯誤訊息（規格未指定）：核心未評完＝「核心題組尚未評完，不能追加弱項題（第 N 題組：…）」；沒有核心題組＝「這場考核還沒有核心題組，不能追加弱項題」；一次超過 4 題＝「一次最多追加 4 題（目前 N 題）」；整場超過＝「整場追加題最多 4 題（已追加 N 題，這次要再追加 M 題）」；題組重複／已在場內／不存在沿用 `assess_pick` 的文字。
8. **規格正文已依老闆 2026-11-03 決定更新**（老闆授權）：第一節規則 3 補上 `period_status` 單一事實、取消時還原、考核期的人不抽查；第二節新增 `spot_register`（同步設定與資格）、`spot_cancel_probation`、`spot_candidates` 的修改說明與 `assess_submit` 守門；第三節 `roster.html` 補「標籤只看 `period_status`」與「新增人員要明確帶考核期」。
9. 其餘沒有差異。

### 已知限制與注意事項

1. **新增人員的資料庫預設是「已上線」**（規格指定）。網頁（`roster.html` 新增人員）**會明確帶 `period_status = '考核期'`**（老闆已確認）；若哪天有別的入口（SQL Editor 直接新增、匯入腳本）沒帶，新人就不會進考核期。上線後建議定期查：`select id, hire_date from public.employees where status = '在職' and include_in_assessment and period_status = '已上線' and passed_on is null and hire_date >= (now() at time zone 'Asia/Taipei')::date - 90;`（列出的人要不是遷移前就已上線，就是漏帶考核期）。
2. **取消回考核期把人設回「已上線」的前提**：被抽查拉回考核期的都是「已上線的正式業務」。若異常資料中有人是「考核期新人」又同時有 `probation_since`（例如遷移時新人也有 `probation_since`），客服部取消他的回考核期，會一併把他設成已上線。這種人在實務上不該存在，若有請先人工確認。
3. **舊驗證腳本 `exam_request_verify_fake.sql` 已依新人規則更新**（老闆決定）：假新人建立時就是考核期；原本「全優送出後同一人可再回報新人」改成「通過後轉已上線，不可再以新人回報」；新增「已上線的新人標籤者（到職 10 天）不能報新人」；開頭多一個前置檢查（要先執行 `phase1_schema.sql`）。在新環境重跑 **388/388 全過**。`README_exam_request.md` 裡寫的「N＝386」已過期，現在是 388（那份文件不在本次修改範圍，沒改）。
4. **驗證腳本會暫時動到約束與遷移記號**（整段在交易內、最後 rollback，沒有任何殘留）：區段 2 會暫時拿掉遷移完成記號重跑遷移、暫時 drop 再加回 `accounts_employees_job_title_len` 約束（為了測職稱超過 20 字的保護），其餘都是直接寫入假資料。因為這些動作會對 `employees` 取鎖，**請在沒人使用系統的時段執行**；腳本開頭有 5 秒 `lock_timeout`，拿不到鎖會整段停下（不會卡住別人，rollback 後無影響）。
5. 轉為已上線／待開通不會倒回：作廢成績單（`assess_void`）後員工仍是已上線、待開通仍在（規格「作廢不倒回」）。
6. **`accounts_employees_job_title_len`（職稱最多 20 字）是 NOT VALID 約束**：只要更新到那一列就會被檢查。若真實資料有人職稱超過 20 字，遷移會用中文訊息停下並列出編號；日後該員通過考核時 `assess_submit` 更新其員工列也會被同一約束擋下（`spotcheck` 的清除考核期本來就有同樣風險）。上線前建議先查：`select id, job_title from public.employees where char_length(job_title) > 20;`
7. 並發（兩個連線同時送出同一張成績單、同時追加題）無法在單一連線的驗證腳本實測；只做了靜態確認：`assess_submit` 先鎖成績單再鎖員工列、`assess_add_extra` 先鎖成績單並取與抽題同一把 advisory lock、待開通有唯一索引。
8. 驗證腳本的「開通日期用台北日期」只在台北日期與 UTC 日期不同的時段（約台北 00:00～08:00）才有鑑別力。
9. 資料庫不強制「有弱項才能追加」：弱項是否存在由 `assess_draft_weak` 與網頁判斷，`assess_add_extra` 只管核心評完、題數上限、不重複。

### 遷移前老闆要先跑的檢查查詢（在 SQL Editor 執行，**執行 `phase1_schema.sql` 之前**）

遷移與日後的 `assess_submit` 會「更新員工那一列」，而資料庫對「被更新的列」會重新檢查所有約束，包括 `accounts_employees_job_title_len`（職稱最多 20 字，當初用 NOT VALID 加上，只檢查之後新增或修改的列）。所以先確認沒有現存資料會被擋：

```sql
-- A. 職稱超過 20 字的人。預期：0 列（有列就先到人員名冊縮短職稱，否則遷移會用中文訊息停下並列出編號）
select id, job_title, char_length(job_title) as 字數 from public.employees where char_length(job_title) > 20;

-- B. 資料庫裡所有「還沒驗證過」（NOT VALID）的約束。預期：只有 accounts_employees_job_title_len 這一列
--    （若有別的列，把它的名稱貼給資料庫工程師確認是否會擋住更新員工）
select conrelid::regclass as 資料表, conname as 約束名稱, pg_get_constraintdef(oid) as 內容
from pg_constraint where not convalidated order by 1, 2;

-- C. 暱稱與姓名都是空白的人（employees_name_present 約束要求至少一個有內容）。預期：0 列
select id from public.employees where nullif(btrim(nickname), '') is null and nullif(btrim(full_name), '') is null;

-- D. 預覽「遷移會把誰標成考核期」（與 schema 內規則相同；跑完 schema 後第 2 項檢查應與此名單一致）
select e.id, coalesce(nullif(e.nickname,''), e.full_name) as 名稱, e.store_code as 門市, e.hire_date as 到職日, e.probation_since as 回考核期起始日
from public.employees_with_tenure e
where e.probation_since is not null
   or (e.status = '在職' and e.include_in_assessment and e.tenure_group = '新人'
       and not exists (select 1 from public.assessments a where a.employee_id = e.id and a.status = 'submitted' and a.verdict in ('及格','優秀')))
order by e.store_code, e.id;
```

預期結果：A 與 C 都是 0 列；B 只有 `accounts_employees_job_title_len`（若已經執行過 `validate constraint` 則 0 列）；D 的名單就是目前「到職 90 天內且還沒通過考核的在職納入考核人員」加上所有「回考核期中」的人，請確認合理再執行 schema。

### 遷移後老闆應該人工檢查的事（在 SQL Editor 執行）

```sql
-- 1. 各狀態人數
select period_status, count(*) from public.employees group by 1 order by 1;

-- 2. 被標成「考核期」的人員名單（確認都是該在考核期的人）
select e.id, coalesce(nullif(e.nickname,''), e.full_name) as 名稱, e.store_code as 門市, e.status as 在職狀態,
       e.include_in_assessment as 納入考核, e.hire_date as 到職日, e.probation_since as 回考核期起始日
from public.employees e
where e.period_status = '考核期'
order by e.store_code, e.id;

-- 3. 到職 90 天內、卻被標成「已上線」的人（應該都是「已有及格以上成績單」、離職或不納入考核者）
select e.id, coalesce(nullif(e.nickname,''), e.full_name) as 名稱, e.status, e.include_in_assessment,
       (select count(*) from public.assessments a where a.employee_id = e.id and a.status = 'submitted' and a.verdict in ('及格','優秀')) as 及格以上張數
from public.employees_with_tenure e
where e.tenure_group = '新人' and e.period_status = '已上線'
order by e.id;

-- 4. 遷移記號（有值＝遷移已完成）與核心分類設定
select * from public.app_settings where key in ('phase1_migrated_on', 'exam_core_categories');

-- 5. 職稱超過 20 字的人（會影響遷移與日後通過考核時的更新）
select id, job_title from public.employees where char_length(job_title) > 20;
```

### 測試結果摘要（假環境）

- `phase1_verify_fake.sql`：**378/378 項通過**（有預塞資料與完全空資料庫兩種都是；schema 連跑 2～3 次再驗也是 332/332；驗證完預塞資料逐表指紋與驗證前完全相同）。
- 本期 schema 執行前後，其餘所有 public 函式的原始碼指紋比對：**除本期新增與修改的函式外完全相同**。
- 既有驗證腳本在「全部既有 schema＋本期 schema」的新環境重跑：assess 249/249、backoffice 161/161、spotcheck 314/314（**不需修改**，其假資料沒有考核期的人被抽查）、weak_suggest 177/177、bank 162/162、accounts 113/113、notes_visible 134/134、url_patch 84/84 **全過**；**更新後的 `exam_request_verify_fake.sql` 388/388 全過**（見已知限制第 3 點）。
- 反向測試：故意弄壞 25 種寫法（追加題算進總分、新人合格線 69、弱項改成 ≤85、analytics／summaries／weak_profile 不排除追加題、單次上限 5、extra_started_at 每次覆蓋、遷移不看記號、紅點不加待開通、候選仍用 90 天規則、唯一索引改成全面唯一、已開通可重複標記、assess_start 沒有考核期新人分支、回考核期通過不新增待開通或不改狀態、draft_weak 不檢查評完、追加題未評完可送出、追加不檢查核心、遷移把作廢及格當及格、`spot_register` 拉回時不設 `period_status`、`spot_cancel_probation` 取消時不還原、`assess_submit` 回考核期通過分支拿掉守門、`spot_register` 資格不排除考核期、`spot_candidates` 不排除考核期），驗證腳本**全部抓得到**。
- 審查建議新增驗證（區段 13C，共 24 項斷言）：(a) 草稿存在期間取消回考核期後 ≥85 送出——成績單正常送出、不新增待開通、`passed_on` 不變；(b) 兩張回考核期草稿先後 ≥85 送出——只有一筆待開通、連到第一張；新人兩張草稿先後通過也只一筆；抽查資格——考核期的人（到職超過 90 天、未填到職日）不在 `spot_candidates`、`spot_register` 被拒且不留紀錄，已上線者（含未填到職日）行為不變，有 `probation_since` 者仍被拒，店長仍無權限。
- 新增驗證（區段 13B，共 22 項斷言）：拉回考核期後 `period_status`＝考核期且 `assess_start` 仍是正式／考核期、考核 85.0 通過後恢復已上線＋待開通＋spot_probations 已通過；取消後已上線、標籤與候選名單正確、`assess_start` 走原正式判斷；已通過不可取消且員工狀態不變；權限不變。
