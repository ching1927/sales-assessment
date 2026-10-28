# 抽查系統（階段 4）— 規則與資料庫介面約定

這份是「資料庫」與「網頁」兩邊共同遵守的約定。改任何一邊之前先對照這份；對不上就停下來回報，不要自己改約定。

## 一、規則（老闆 2026-10-22 定案）

1. **抽查對象**：正式業務（通過新人考核列入正式的，加上系統上線前就已入職的正式業務）。
   - 條件：在職、納入考核＝是、不是新人（到職日起 90 天內算新人；沒填到職日者視為正式）、目前不在「考核期」。
2. **一次抽查**（客服部登記）：日期、被抽查人員、抽到的訊息文字、七面向等級（沿用考核同一套 優／良／待加強／不及格／不適用，分數用資料庫現有的 `assess_score_item` 計算）、判定「適當／不適當」、原因（判定不適當時必填）。
3. **黃單（觀察單）**：判定不適當就自動開一張，種類 `黃`。
4. **紅單（改善紅單）**：同一人在同一個「日曆月」（台北時間）內，**紅單之後**累積 5 張有效黃單，自動開一張紅單，種類 `紅`；之後黃單重新從 0 算（只算最近一張有效紅單之後的黃單）。
5. **回考核期**：同一人在同一個「日曆季」（1–3、4–6、7–9、10–12 月，台北時間）內，只計算「該員工最近一筆回考核期紀錄（任何狀態，含已通過、已取消）建立之後」才開出的有效紅單，滿 2 張（沒有回考核期紀錄時，計本季全部有效紅單；回考核期發生後紅單重新從 0 算，與黃單「紅單之後重算」同一邏輯），自動建立一筆「回考核期」紀錄（狀態 `待執行`），同時 `employees.probation_since` 設為當天；系統標示「建議移除官方 LINE 回覆權限」。實際關閉權限由客服部手動做，回系統按「已執行」留紀錄（狀態 `已執行`）。
6. **考核期怎麼算過**：在考核期的人，之後進行考核（`assess_start`）一律用「正式員工」標準（身分 `正式`，`tenure_source` 記 `考核期`），**總分 ≥ 85（判定及格或優秀）才算通過**，通過時資料庫自動清除 `probation_since`、把回考核期紀錄改 `已通過`。沒過就維持考核期。考核期內不再被抽查。
7. **作廢**：客服部可作廢任何一張單（要寫原因、不刪除）。次數永遠由「有效單」即時計算，作廢後自動少算；**作廢不會倒回去取消已開出的紅單或回考核期**（那要靠客服部自己作廢紅單、取消回考核期）。
8. **輔導回填**：客服部與該門市店長可對單據回填輔導日期＋備註（備註必填，不限字數）；總公司主管唯讀。
9. **看得到誰**：客服部全部；總公司主管全部（唯讀）；店長只看自己門市的人員與單據（唯讀＋輔導回填）。

## 二、資料表（public schema，全部開 RLS，直接寫入一律收回，只能透過下面的函式寫）

- `spot_inspections`：id uuid pk、employee_id、employee_label、store_code、checked_on date、message text、levels jsonb、total_score numeric、dim_points jsonb、weakest_dims text[]、verdict text（`適當`/`不適當`）、reason text、examiner_email、created_at。
- `spot_tickets`：id uuid pk、kind（`黃`/`紅`）、employee_id、employee_label、store_code、inspection_id uuid null（黃單才有）、source_ticket_ids uuid[] null（紅單：湊成它的黃單）、reason text、issued_on date、status（`有效`/`作廢`）、void_reason、voided_by、voided_at、coached_on date null、coach_note text null、coached_by、coached_at、created_at。
- `spot_probations`：id uuid pk、employee_id、employee_label、store_code、red_ticket_ids uuid[]、triggered_on date、status（`待執行`/`已執行`/`已通過`/`已取消`）、executed_on date null、executed_by、passed_assessment_id uuid null、cancel_reason、created_at、updated_at。
- `employees.probation_since date null`（新增欄位）。

SELECT 權限（RLS）：客服部、總公司主管看全部；店長只看 `store_code` 等於自己門市。`spot_inspections` 的訊息與七面向等級同樣依此規則。

## 三、函式（`security definer`、`set search_path`、全部 `revoke … from public, anon` 再 `grant execute … to authenticated`；函式內自己驗角色）

| 函式 | 誰能呼叫 | 說明 |
|---|---|---|
| `spot_candidates()` → table(id, nickname, full_name, store_code, job_title, hire_date) | 客服部 | 符合「抽查對象」條件的人 |
| `spot_register(p_employee_id text, p_checked_on date, p_message text, p_levels jsonb, p_verdict text, p_reason text)` → jsonb | 客服部 | 驗證人員資格、等級（七面向缺一不可，不適用最多 2 個）、不適當必填原因；寫入抽查；不適當就開黃單並套用第 4、5 條規則。回傳 `{inspection_id, total_score, weakest_dims, yellow_id, red_id, probation_id}`（沒有就是 null） |
| `spot_void_ticket(p_ticket_id uuid, p_reason text)` | 客服部 | 作廢（原因必填）；已作廢不可再作廢 |
| `spot_coach(p_ticket_id uuid, p_coached_on date, p_note text)` | 客服部、該門市店長 | 回填輔導（日期、備註必填）；作廢的單不能回填 |
| `spot_mark_executed(p_probation_id uuid)` | 客服部 | `待執行` → `已執行`，記日期與人 |
| `spot_cancel_probation(p_probation_id uuid, p_reason text)` | 客服部 | 誤判時取消：狀態 `已取消`、清除 `probation_since`（原因必填；已通過者不可取消） |
| `spot_status()` → table(employee_id, employee_label, store_code, yellow_month int, red_quarter int, probation_id uuid, probation_status text) | 全部已開通角色（依角色過濾門市） | 每位「正式或考核期」人員當月（紅單之後）有效黃單數、當季有效紅單數、回考核期狀態；`yellow_month` 以呼叫當下的台北日曆月計 |

錯誤訊息一律繁體中文、`raise exception`，網頁直接顯示。

## 四、與既有功能的串接（會修改既有函式，必須保留原有全部行為）

- `assess_start`：若該員工 `probation_since is not null` → 身分 `正式`、`tenure_source = '考核期'`（`assessments.tenure_source` 的 check 要加入 `考核期`）。
- `assess_submit`：若這張成績單 `tenure_source = '考核期'` 且 `total_score >= 85` → 清除 `employees.probation_since`、對應的 `spot_probations` 改 `已通過` 並記 `passed_assessment_id`。
- 作廢成績單（`assess_void`）不倒回已通過的考核期，維持現狀即可。
- 名冊（`employees_with_tenure` 檢視）要帶出 `probation_since`，網頁名冊在考核期的人旁顯示「考核期」標籤。

## 五、網頁

- 新頁 `spotcheck.html`（導覽名稱「抽查」，位置在「考核後台」之後）、`js/spotcheck-api.js`。
- 客服部：看人員抽查狀態、登記抽查、看單據與回考核期、作廢、回填輔導、標記已執行、取消回考核期。
- 總公司主管：唯讀。店長：只看自己門市，可回填輔導。

---

## 六、資料庫實作說明與執行步驟（資料庫工程師補充，規格正文第一至五節未改動）

> ⚠️ 兩支 SQL **尚未執行**，也沒有在真實 Postgres 上跑過（開發機沒有 Postgres），只做過逐行人工核對。待老闆同意後才在 Supabase 執行。

### 檔案

| 檔案 | 用途 |
|---|---|
| `spotcheck_schema.sql` | 要執行的那份。單一交易（begin…commit），可重複執行，不刪既有資料 |
| `spotcheck_verify_fake.sql` | 驗證腳本：只用假資料、全程 rollback，不留任何資料 |

### 執行順序

0. 先到 Supabase 備份（Dashboard → Database → Backups）。前提：`roster_schema.sql`、`assess_schema.sql` 已執行（`notes_visible_schema.sql`、`backoffice_schema.sql` 有沒有執行都不影響）。
1. SQL Editor → New query → 貼上 `spotcheck_schema.sql` 整份 → Run。拿不到鎖會在 5 秒後整份回復，稍後重跑即可。
2. 再開新的 query，貼上 `spotcheck_verify_fake.sql` 整份 → Run。
3. 預期結果：最後一張表第一列「總結」寫「N/N 項通過」、「通過」欄全是「通過」。任何一列「失敗」就停下回報，不要自己放行（總結列會列出未通過的序號）。

### 新增與被改寫的物件

- 欄位：`employees.probation_since`；約束 `assessments_tenure_source_check` 重建（多收「考核期」；先檢查既有資料、再「查出」現有約束名稱才 drop，只動管 `tenure_source` 這一欄的 check）。
- 資料表：`spot_inspections`、`spot_tickets`、`spot_probations`（全開 RLS；`authenticated` 只有 select，沒有任何直接寫入；`anon` 完全沒有）。另加資料完整性約束：黃單必須有抽查連結、紅單必須有來源黃單陣列；作廢欄位、輔導欄位、回考核期各狀態的欄位要齊。
- 索引：`spot_inspections_employee_idx`、`spot_inspections_store_idx`、`spot_tickets_employee_idx`、`spot_tickets_store_idx`、`spot_tickets_inspection_idx`、`spot_probations_employee_idx`、`spot_probations_store_idx`。
- 觸發器：`spot_probations_touch_trg`（更新 `updated_at`，沿用 `roster_touch_updated_at`）。
- RLS policy：`spot_inspections_select`、`spot_tickets_select`、`spot_probations_select`（客服部、主管全看；店長只看自己門市；未開通帳號 0 筆）。
- 對外函式（七個，簽名與規格一致）：`spot_candidates`、`spot_register`、`spot_void_ticket`、`spot_coach`、`spot_mark_executed`、`spot_cancel_probation`、`spot_status`。
- 內部小工具（網頁角色不能直接呼叫）：`spot_month_yellow_ids`、`spot_quarter_red_ids`（月內「最近一張有效紅單之後」的有效黃單、季內有效紅單，供 `spot_register` 與 `spot_status` 共用同一套算法）。
- 被改寫的既有物件：`assess_start`（只新增「考核期」分支）、`assess_submit`（只在更新成績單之後新增「考核期通過」段落）、檢視 `employees_with_tenure`（帶出 `probation_since`；因 `create or replace view` 不能把新欄位插在中間，所以 drop 後重建，內容與 `roster_schema.sql` 相同，權限重做）。`assessment_summaries` 不需修改（本來就明列 `tenure_source`，新值自然帶出）。`assess_void` 不改。

### 實作細節（規格有寫、這裡補足做法）

- **月／季一律台北時間**：今天＝`now() at time zone 'Asia/Taipei'`；月、季邊界用 `date_trunc('month'|'quarter', 今天::timestamp)`；月與季以單據的 `issued_on`（開單日）判斷。
- **「紅單之後」**以單據的 `created_at` 判斷，`created_at` 預設用 `clock_timestamp()`（實際寫入時刻），所以同一個交易內先後寫入的黃單與紅單也分得出先後。
- **紅單／回考核期與黃單同一交易**：都在 `spot_register` 內完成，任何一步失敗整筆回復（包含抽查紀錄）。
- **並發保護**：`spot_register`、`spot_void_ticket`、`spot_mark_executed`、`spot_cancel_probation` 都先對該員工的 `employees` 列做 `for update`，再讀次數與寫入；同一個人同時登記會排隊，不會重複開紅單或重複開回考核期。`assess_submit` 清除考核期時也會鎖同一列，與抽查登記一樣排隊。鎖順序統一為「員工列 → 單據／紀錄列」，避免死結。驗證腳本只能做靜態確認（函式含 `for update`），**真正的並發需另開兩個連線手動實證**。
- 作廢、取消都不刪除資料；作廢不倒回紅單與回考核期，作廢成績單（`assess_void`）也不倒回已通過的考核期。

### 與規格的差異

**沒有差異**（七個函式簽名、回傳欄位、資料表欄位、權限、串接行為都照規格）。下面是規格沒明寫、我採用的解讀，**請老闆確認**；每一項都是單一處可改：

1. **月、季看哪個日期**：規格說「日曆月（台北時間）內」。實作以「開單日 `issued_on`＝登記當天的台北日期」計，不是登記人填的 `p_checked_on`。所以事後補登上個月的抽查，仍算「登記當月」的黃單。`p_checked_on` 只驗證不為空，**不限制過去或未來**（規格沒說）。
2. **抽到的訊息文字不是必填**：規格的必填只列「不適當要原因」與七面向，所以 `p_message` 可空，原樣保存。
3. **紅單用「>= 5」**：每次登記只會多一張黃單，正常情況剛好 5；但若客服部作廢了某張紅單，紅單之前的黃單會重新算回來，下一張黃單就會再開紅單。紅單的來源黃單＝當時所有計入的有效黃單。
4. **回考核期的紅單從 0 重算（老闆 2026-10-27 決定，已寫進規格第一節第 5 點）**：本日曆季、且在「該員工最近一筆回考核期紀錄（任何狀態，含已通過、已取消）建立之後」才開出的有效紅單 >= 2 張，才開回考核期；沒有回考核期紀錄時照舊計本季全部有效紅單。邊界用 `created_at` 比較（`created_at` 預設 `clock_timestamp()`，同一交易內的先後也分得出）。所以回考核期（通過或取消後）同季再開 1 張紅單不會立刻再開回考核期，再開第 2 張才會；`red_ticket_ids` 只含回考核期之後的那些紅單。`spot_status` 的 `red_quarter` 用同一個口徑（目前還在累計中的紅單數）。作廢紅單仍不倒回已開的回考核期。
5. **`spot_status` 的範圍**：在職、納入考核、而且是正式（含未填到職日）或 `probation_since` 有值的人；新人不列。`probation_id`／`probation_status` 只顯示「進行中」（待執行／已執行）的那筆，已通過、已取消的不顯示（人已回到正式或取消）。名稱是名冊「現在」的暱稱／姓名。
6. **`spot_coach` 沒有日期檢查**（規格只說日期、備註必填）。可重填修改；店長對找不到或別間門市的單只回「找不到這張單據或沒有權限」。
7. **考核通過判斷用 `total_score >= 85`**（考核期一律正式標準，等同判定及格或優秀）。

### 已知限制

- **考核期前就開始的草稿**：若某人在被開回考核期「之前」已有一張草稿（來源是「自動」或「手動指定」），之後送出即使 >= 85 也**不會**清除考核期（規格只認 `tenure_source = '考核期'`）。**操作提醒（老闆決定維持現狀、不改程式）**：客服部要先放棄該草稿、再重新開始考核，送出才會依考核期標準（正式、85 分）判定並解除考核期。
- 客服部本來就能直接改 `employees`（既有 RLS），手動改 `probation_since` 不會同步回考核期紀錄；請走 `spot_cancel_probation`。
- 本檔未在真實 Postgres 執行過，語法與邏輯只做過人工核對；執行驗證腳本時才會得到實證。上線後建議用網頁真實流程各走一次：登記不適當到第 5 張（開紅單）、考核期的人考核（通過與沒過）。

---

## 七、網址欄位修補（url_patch.sql）

> ⚠️ 尚未執行，也沒有在真實 Postgres 上跑過，只做過逐行人工核對。待老闆同意後才在 Supabase 執行。

老闆追加兩項（2026-10-28 決定）：

1. 抽查登記的「抽到的訊息」改為「訊息抽檢-LINE聊天室網址」，**必填**。
2. 考核備註新增「備註網址」，**非必填**。

### 檔案

| 檔案 | 用途 |
|---|---|
| `url_patch.sql` | 要執行的修補：單一交易、可重複執行，只含這兩項（欄位＋約束＋兩個函式）。可直接在「已執行舊版 spotcheck_schema.sql」的資料庫上跑 |
| `url_patch_verify_fake.sql` | 驗證 `note_url` 與 `assess_save_item` 新行為（假資料、全程 rollback） |
| `spotcheck_schema.sql` | 其中的 `spot_register` 已同步成新版，所以**全新安裝**的 `spot_register` 也是新版；但 `note_url` 欄位與四參數 `assess_save_item` 只在 `url_patch.sql`，全新安裝後仍要再跑一次 `url_patch.sql` |
| `spotcheck_verify_fake.sql` | 所有 `spot_register` 呼叫改傳合法網址（`https://line.me/R/ti/p/test-1`），並新增網址驗證斷言 |

### 執行順序

0. 先備份。前提：`spotcheck_schema.sql`、`notes_visible_schema.sql` 已執行。
1. `url_patch.sql`（貼上整份 → Run）。
2. `url_patch_verify_fake.sql`（預期：總結列「N/N 項通過」、「通過」欄全是「通過」）。
3. `spotcheck_verify_fake.sql`（同上；前置檢查會確認 `assess_save_item` 已是四參數版本，沒跑 `url_patch.sql` 會直接報錯停下）。

### 規則

- **`spot_register`**：參數名稱 `p_message` 與欄位 `spot_inspections.message` 都不改（欄位現在存網址）。去頭尾空白（含全形空白、tab、換行）後必填，必須符合 `^https?://[^[:space:]]+$`（不分大小寫），長度 <= 500；存去空白後的值。失敗訊息：「請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）」。**這項驗證排在所有其他驗證之後**（找不到員工、資格、日期、判定、原因、七面向等級的錯誤優先），所以既有錯誤的優先順序與訊息不變。
- **`assessment_items.note_url`**（text，可空）：check ＝ null 或（長度 <= 500 且符合同一個格式，不分大小寫）；既有資料不受影響。
- **`assess_save_item(p_item_id, p_levels, p_note, p_note_url default null)`**：以最後生效的版本（`notes_visible_schema.sql`）為基礎，其餘行為逐行保留（客服部檢查、題組歸屬、只限草稿、只限建立者本人、`assess_check_levels`、備註 `nullif(btrim(p_note), '')`）。`p_note_url` 去頭尾空白後，空字串或全空白視為 null；格式錯誤丟「備註網址格式不正確（需 http 或 https 開頭，不可含空白，最長 500 字）」，排在所有既有檢查之後。先 `drop function if exists` 舊的三參數版本再建新版（避免重載歧義），並重做 revoke／grant。
- **可見性**：`note_url` 與備註同表，沿用 `assessment_items` 既有 RLS（客服部全看；主管看已送出；店長看自己門市已送出；草稿與作廢只有客服部），不需改 RLS。已送出或作廢後 `assess_save_item` 一律被拒（「只有草稿可以暫存評分」），網址同樣不可改。

### 與規格的差異／需要知道的事

- 規格正文第一至五節**未改動**（規格第二節資料表欄位 `spot_inspections.message` 的內容意義改為網址，欄位名稱與型別不變）。
- **整份取代**：`assess_save_item` 每次呼叫會整份取代評分、備註與備註網址（與備註一樣：沒傳＝清除）。**舊的三參數呼叫（例如尚未更新的前端 `js/assess-api.js`，它只傳 `p_item_id／p_levels／p_note`）仍可運作，但每次存檔都會把 `note_url` 清成 null**；前端存檔時必須一併傳 `p_note_url`。
- **舊驗證腳本受影響**：`notes_visible_verify_fake.sql` 區段 4 以三參數簽名 `'public.assess_save_item(uuid, jsonb, text)'::regprocedure` 查函式（並確認只有一個版本）；`url_patch.sql` 執行後該簽名已不存在，那一段會失敗，需另行更新（本次依指示未動該檔）。其餘舊腳本中的三參數「呼叫」寫法照舊可用（`url_patch_verify_fake.sql` 區段 5 用同樣寫法驗證）。
- 網址驗證用的 `[[:space:]]` 是否涵蓋全形空白取決於資料庫的 locale；函式對「頭尾」的全形空白用 `btrim` 另外處理（去除），但網址「中間」夾全形空白不一定會被擋。
