# 待考回報 — 規則與資料庫介面約定

這份是「資料庫」與「網頁」兩邊共同遵守的約定。改任何一邊之前先對照這份；對不上就停下來回報，不要自己改約定。樣品見 `樣品/待考回報樣品.html`（老闆已確認方向與畫面）。

## 一、規則（老闆 2026-11-03～04 定案）

1. **誰回報**：店長只能替「自己門市」的人回報；客服部也可代為回報；總公司主管只能看。
2. **三種情況（kind）**：
   - `新人`：新人準備好了要考核。對象＝在職、納入考核、`employees_with_tenure.tenure_group = '新人'`、`probation_since is null`。
   - `回考核期`：回考核期的人準備好再考。對象＝在職、納入考核、`probation_since is not null`。
   - `複檢`：改善單複檢考核。對象＝該人有一張狀態為「已輔導」的改善單（`improvement_tickets`，以 backoffice_schema.sql 的實際狀態值為準），且該改善單還沒有未結案的複檢回報；人員必須在職且納入考核；已有狀態為 `已完成` 的複檢回報、且其連結的成績單目前仍是 `submitted` 的改善單不再列出、也不可再報（成績單被作廢者可重報）；回報時要指定改善單 id。
3. **回報內容**：人員、希望考核日期（1～3 個，不可重複、不可早於今天〔台北時間〕）、備註（≤500 字，可空）；**新人必須勾選「已看完線上回覆實戰全攻略影片」**（`video_done` 必須為 true；另兩種情況不適用，存 null）。
4. **防重複**：同一人同一種情況有「未結案」（待處理或已排定）的回報時不能再報；複檢以改善單為單位判斷。**每日上限**：同一回報人（`requested_by`）當天（台北日期）已建立 20 筆（含已取消）就拒絕，訊息「今天回報次數已達上限（20 筆），請明天再試或聯絡客服部」。
5. **狀態**：`待處理` → `已排定`（客服部填考核日期時間，可重新排定）→ `已完成`（該人員有成績單「送出」時，由資料庫自動標記並連結成績單）；`已取消`（店長可在「待處理」時撤回；客服部可在待處理或已排定時退回，原因必填）。
6. **考核是線上進行**：提示語用「請同仁準時上線」。
7. **通知**：
   - 系統內：客服部看到「待處理」數量紅點與清單；店長看到自己門市「有客服部回覆（已排定／退回）但尚未看過」的數量與內容。
   - 信件：新回報 → 寄給「所有客服部帳號」（`app_users` 角色為 cs_admin 的信箱）；排定或退回 → 寄給當初回報的人（requested_by）。信件只放摘要（門市、人員、情況、希望日期／排定時間、備註前 80 字）與登入連結。
   - 寄信失敗不影響回報本身；信件一律先寫進寄信佇列 `mail_outbox`，再由 pg_net 呼叫公司 Google Apps Script 寄出，狀態可查。
8. **看得到誰**：客服部全部；總公司主管全部（唯讀）；店長只看自己門市。

## 二、資料表（public schema；全部開 RLS；直接寫入一律收回，只能透過函式寫）

- `exam_requests`：id uuid pk；kind（`新人`/`回考核期`/`複檢`）；employee_id；employee_label；store_code；requested_by（信箱）；requested_role（`店長`/`客服部`）；desired_dates date[]（1～3 個）；video_done boolean null；note text；improvement_ticket_id uuid null（複檢才有）；status（`待處理`/`已排定`/`已完成`/`已取消`）；scheduled_at timestamptz null；reply_note text null；handled_by（信箱）null；cancel_by（`店長`/`客服部`）null；cancel_reason text null；assessment_id uuid null；mgr_seen boolean not null default true（客服部排定／退回時設 false，店長標記已看後設 true；自動完成時也設 false）；created_at；updated_at。
  - 唯一部分索引：未結案（待處理、已排定）時，`(employee_id, kind)` 唯一；複檢另以 `improvement_ticket_id` 唯一。
- `mail_outbox`：id uuid pk；to_emails text[]；subject text；body_html text；kind text；request_id uuid null；status（`queued`/`sent`/`failed`/`skipped`）；net_request_id bigint null；last_error text null；created_at；updated_at。只有客服部能 select。
- `app_settings`：key text pk；value text。**全部權限收回，沒有任何 policy**，只有 security definer 函式讀取（含 `mail_relay_url`、`mail_relay_token`、`site_url`，後兩者由老闆之後自己在 SQL Editor 填；`site_url` 預設 `https://ching1927.github.io/sales-assessment/`）。

SELECT 權限（RLS）：`exam_requests` 客服部、總公司主管全部、店長自己門市；`mail_outbox` 只有客服部。

## 三、函式（`security definer`、`set search_path`、全部 `revoke … from public, anon` 再 `grant execute … to authenticated`；函式內自己驗角色；錯誤訊息繁中 `raise exception`）

| 函式 | 誰能呼叫 | 說明 |
|---|---|---|
| `exam_req_candidates(p_kind text)` → table(employee_id, label, store_code, ticket_id uuid, ticket_note text) | 客服部、店長 | 依第一節第 2 點列出可回報的人（店長只列自己門市；已有未結案回報者不列；複檢每張可複檢的改善單一列，帶 ticket_id） |
| `exam_req_create(p_kind text, p_employee_id text, p_dates date[], p_video boolean, p_note text, p_ticket_id uuid default null)` → uuid | 客服部、店長（店長限自己門市） | 驗證資格、日期、影片、重複；寫入並排信（寄所有客服部）。回傳新回報 id |
| `exam_req_withdraw(p_id uuid)` | 店長（自己門市、待處理）、客服部 | 撤回，`cancel_by` 記角色；回報人自己撤回（含客服部撤回自己建立的）原因「回報人撤回」；客服部撤回別人建立的回報原因「客服部撤回」且 `mgr_seen=false`（店長撤回不動 `mgr_seen`） |
| `exam_req_schedule(p_id uuid, p_at timestamptz, p_note text)` | 客服部 | 待處理或已排定 → 已排定；`p_at` 不可早於「現在往前 1 小時」；寫 handled_by、mgr_seen=false；排信給回報人 |
| `exam_req_return(p_id uuid, p_reason text)` | 客服部 | 待處理或已排定 → 已取消（原因必填）；mgr_seen=false；排信給回報人 |
| `exam_req_mark_seen()` | 店長 | 把自己門市所有 `mgr_seen=false` 的回報設為已看 |
| `exam_req_badge()` → int | 客服部／店長／主管 | 客服部＝待處理數；店長＝自己門市 `mgr_seen=false` 數；主管＝0 |
| `mail_outbox_sync()` | 客服部 | 依 `net._http_response` 更新佇列狀態（status_code 200～399＝sent〔寄信腳本已收到請求；若回應內容含 `"ok":false` 則為 failed，`last_error` 記內容前 200 字〕；400 以上、逾時或有錯誤訊息＝failed）；無 pg_net 時什麼都不做 |

觸發器：`assessments` 狀態轉為 `submitted` 時，把該員工的未結案回報（待處理、已排定）改為 `已完成`，記 assessment_id、`mgr_seen=false`（不改既有 assess_submit；觸發器內任何錯誤都吞掉並發出警告，絕不讓成績單送出失敗，漏標由客服部手動處理）。寄信：`mail_outbox` insert 後的 AFTER 觸發器呼叫 `net.http_post`（`pg_net` 擴充存在、且 `app_settings` 已填 `mail_relay_url` 與 `mail_relay_token` 才寄；否則狀態記 `skipped`；任何錯誤都吞掉並記 `last_error`、狀態 `failed`，**絕不讓主交易失敗**）。寄信 body（JSON）：`{ "token": …, "to": [信箱…], "subject": …, "html": … }`，所有使用者文字進信件前一律 HTML escape；收件人只會是 `app_users` 內的 @2motor.tw 信箱。

## 四、網頁

- 新頁 `requests.html`（導覽名稱「待考回報」，位置在「考核後台」之後、「抽查」之前），`js/requests-api.js`。
- 店長：回報表單（照樣品：情況、人員〔依情況載入〕、希望日期最多 3 個、新人才顯示影片勾選〔紅字整句〕、備註）、我的回報清單、客服部回覆通知（開頁時顯示未看的並呼叫 `exam_req_mark_seen`）、待處理可撤回。
- 客服部：待考回報清單（門市、狀態篩選；排定日期時間、退回〔原因必填〕、已排定者「開始考核」連到 `assess.html`）、寄信紀錄（讀 `mail_outbox`，按「更新寄信狀態」呼叫 `mail_outbox_sync`）；客服部也能代為回報。
- 主管：唯讀。
- 導覽列「待考回報」分頁顯示紅點數字（`exam_req_badge()`），每個頁面都要有；`assess.html` 選考生時，已有待處理／已排定回報的人排前面並標記「已回報待考」。

---

## 五、資料庫實作說明與執行步驟（資料庫工程師補充，規格正文第一至四節未改動）

> ⚠️ 兩支 SQL **尚未在 Supabase 執行**。開發機沒有 Supabase 連線，只在 PGlite（npm 的 `@electric-sql/pglite`，本機模擬的 Postgres）搭的假環境裡實際跑過：先依序執行既有的 roster／assess／bank／accounts／notes_visible／backoffice／spotcheck／url_patch／weak_suggest（含 accounts 的信箱網域、護欄、稽核觸發器），再執行本功能的 schema（連跑兩次確認可重複執行），再跑驗證腳本。pg_net 在假環境用自己寫的假 `net` schema 代替（`net.http_post` 回傳遞增編號、`net._http_response` 表）。

> 驗證腳本不會往 `app_users` 寫入非 @2motor.tw 的信箱（真實資料庫的 `accounts_email_domain_check` 會擋）；收件人過濾改用字面值直接呼叫內部函式 `exam_req_enqueue` 測。假資料建立若失敗，總結列的「實際」欄會寫出第一個失敗的錯誤訊息。

### 檔案

| 檔案 | 用途 |
|---|---|
| `exam_request_schema.sql` | 要執行的那份。單一交易（begin…commit），可重複執行，不動既有資料、不改任何既有函式 |
| `exam_request_verify_fake.sql` | 驗證腳本：只用假資料、全程 rollback，不留任何資料 |

### 前置

1. 先到 Supabase 備份（Dashboard → Database → Backups）。
2. 前提：`roster_schema.sql`、`assess_schema.sql`、`spotcheck_schema.sql`、`backoffice_schema.sql` 已執行（缺任何一個，schema 開頭會用中文錯誤訊息擋下並整份回復）。驗證腳本另外需要 `url_patch.sql` 已執行（`assess_save_item` 四參數版）。
3. 啟用 pg_net：Dashboard → Database → Extensions → 搜尋 `pg_net` → 打開。**沒啟用也能執行 schema**（腳本不會 create extension，會用 notice 提示），只是信件會一律記為 `skipped`；之後再啟用就能寄，不必重跑。

### 執行順序

1. SQL Editor → New query → 貼上 `exam_request_schema.sql` 整份 → Run。拿不到鎖會在 5 秒後整份回復，稍後重跑即可。成功時 Messages 會顯示 pg_net 是否已啟用的提示。
2. 再開新的 query，貼上 `exam_request_verify_fake.sql` 整份 → Run。
3. 預期結果：最後一張表第一列「總結」寫「N/N 項通過」（目前 N＝386），「通過」欄全是「通過」。任何一列「失敗」就停下回報，不要自己放行（總結列會列出未通過的序號）。
4. 填寄信設定（見下）。**驗證腳本不需要先填設定**（它在交易內清掉設定、結束後 rollback，老闆填的值原樣保留）。

### 之後老闆要在 SQL Editor 填的兩行（寄信網址與密碼）

Apps Script 部署好之後（見 `設定步驟E_寄信.md`），在 SQL Editor 執行下面這段，把兩個佔位字換成自己的值（保留前後單引號）。這兩個值只存在 `app_settings`，網頁與任何角色都讀不到；不要貼在對話裡。

```sql
insert into public.app_settings (key, value) values
  ('mail_relay_url',   '這裡換成 Apps Script 網頁應用程式網址'),
  ('mail_relay_token', '這裡換成 RELAY_TOKEN 那串長亂碼')
on conflict (key) do update set value = excluded.value;
```

`site_url` 已預填 `https://ching1927.github.io/sales-assessment/`；網址若有變，同樣用 `insert … on conflict (key) do update` 改 `site_url` 那一列即可（結尾有無斜線都可，信件連結會補成 `…/requests.html`）。

### 新增物件清單

- 資料表：`exam_requests`、`mail_outbox`、`app_settings`（三張都開 RLS；`authenticated` 只對前兩張有 select，沒有任何直接寫入；`app_settings` 完全不給權限也沒有 policy；`anon` 全無）。
- 索引：`exam_requests_status_idx`、`exam_requests_store_idx`、`exam_requests_employee_idx`、`exam_requests_open_emp_kind_uq`（唯一部分索引）、`exam_requests_open_ticket_uq`（唯一部分索引）、`mail_outbox_status_idx`、`mail_outbox_request_idx`。
- 資料完整性約束（`exam_requests`）：新人必須 `video_done = true`、非新人必須 null；只有複檢可帶改善單；希望日期 1～3 個；備註 ≤ 500 字。
- RLS policy：`exam_requests_select`（客服部、主管全看，店長只看自己門市）、`mail_outbox_select`（只有客服部）。
- 對外函式（`authenticated` 可呼叫）：`exam_req_candidates`、`exam_req_create`、`exam_req_withdraw`、`exam_req_schedule`、`exam_req_return`、`exam_req_mark_seen`、`exam_req_badge`、`mail_outbox_sync`。
- 內部函式（任何網頁角色都不能呼叫）：`exam_req_status_open`、`exam_req_label`、`exam_req_esc`（HTML escape）、`exam_req_setting`、`exam_req_link`、`exam_req_net_ready`／`exam_req_net_post`／`exam_req_net_result`（pg_net 的三個小包裝，讓驗證腳本能在交易內換成假的）、`exam_req_mail_content`、`exam_req_enqueue`、`exam_req_notify`，以及兩個觸發器函式 `mail_outbox_dispatch`、`exam_req_auto_complete`。
- 觸發器：`exam_requests_touch_trg`、`mail_outbox_touch_trg`（更新時間）、`mail_outbox_dispatch_trg`（寄信）、`exam_req_auto_complete_trg`（掛在 `assessments`，新增；沒改 `assess_submit`）。
- 緊急停用：`drop trigger if exists exam_req_auto_complete_trg on public.assessments;`（停止自動完成，不影響成績單）；`drop trigger if exists mail_outbox_dispatch_trg on public.mail_outbox;`（停止寄信，新信會停在 queued）。

### 與規格的差異／實作時的解讀（沒有改規格正文；以下請老闆或規格作者確認）

1. **唯一部分索引的範圍**：規格寫「未結案時 `(employee_id, kind)` 唯一；複檢另以 `improvement_ticket_id` 唯一」，同時第 4 點寫「複檢以改善單為單位判斷」。若複檢也套 `(employee_id, kind)` 唯一，同一人有兩張已輔導改善單時就只能報一張，與「以改善單為單位」矛盾。所以實作成：`(employee_id, kind)` 唯一**只套用新人與回考核期**，複檢只靠 `improvement_ticket_id` 唯一。
2. **mail_outbox_sync 的判斷**（依 2026-11-04 補充調整，規格第三節已同步更新）：`status_code` 200～399 記 `sent`（意思是「寄信腳本已收到請求」，Apps Script 常回 302 轉址；但回應內容含 `"ok":false`〔容忍空白、不分大小寫〕時記 `failed`，`last_error` 記內容前 200 字）；400 以上記 `failed`（`last_error` 記「HTTP 狀態碼：回應前 200 字」）；逾時（`timed_out`）或 `error_msg` 不為空記 `failed`（原因寫進 `last_error`，錯誤優先於狀態碼）；還沒有回應的維持 `queued`。規格正文原寫「200 系列＝sent」，此處以補充為準。
3. **信件裡的「備註」**：規格只寫「備註前 80 字」。實作：新回報信取回報人的備註；排定信取客服部排定時填的備註；退回信取退回原因（退回原因對回報人是必要資訊，所以用它代替備註列）。
4. **複檢的資格**（審查後規格已補述）：除「已輔導改善單、沒有未結案複檢回報」外，人員必須在職且納入考核（錯誤訊息沿用「已離職」「未納入考核」）；已有 `已完成` 複檢回報且其成績單仍是已送出的改善單不再列出、不可再報，成績單作廢後可重報；店長範圍用「人員目前所屬門市」。
5. **ticket_note 的內容**：`exam_req_candidates` 複檢列的 `ticket_note` 放改善單的「輔導備註」（`coach_note`）；規格沒指定內容。
6. 小細節：`exam_req_mark_seen()` 回傳 void；`mail_outbox_sync()` 回傳 int（這次更新的筆數，網頁可忽略）；`exam_req_badge()` 對未開通帳號丟「沒有權限」；日期照傳入順序存、不排序；非新人傳入的 `p_video`、非複檢傳入的 `p_ticket_id` 一律忽略（存 null）；撤回不記 `handled_by`（客服部撤回別人的回報時才把 `mgr_seen` 設 false，見規格第三節）；`employee_id` 外鍵設 `on delete cascade`（刪除名冊人員時一併刪其回報，避免卡住既有的名冊刪除），`store_code` 不設外鍵（是快照）。
7. 內部多了 `exam_req_net_*` 三個包裝函式（實作細節，行為與直接呼叫 pg_net 相同），目的是讓驗證腳本能在交易內以假實作測全部寄信分支。

沒有其他差異。

### 已知限制

- **`sent` 只代表「寄信腳本已收到請求」，不保證信箱實際收到**。Apps Script 回 302 轉址時 pg_net 不一定跟著轉，腳本端若 token 錯誤也可能一樣回轉址，所以狀態是 `sent` 但沒收到信是有可能的。**上線前老闆要用 Apps Script 的 `testSend` 測試寄信，再用客服部「代為回報」送一封真實回報，各驗一次，確認信箱真的收到**（`設定步驟E_寄信.md` 步驟 4、7）。
- 狀態不會自動更新：要在「寄信紀錄」按「更新寄信狀態」（`mail_outbox_sync`）才會依 pg_net 回應改 `sent`／`failed`。pg_net 只保留近期的回應（約數小時，依 pg_net 設定），太久沒按、回應被清掉的信會一直停在 `queued`。
- pg_net 是在「交易提交之後」才真正送出請求；寄信失敗、逾時、或腳本回錯誤，都只會讓那封信標 `failed`，不會影響回報本身。
- 同一次回報若有多位客服部，只寄一封（收件人是全部客服部信箱，Apps Script 一次最多 30 位）。
- 自動完成的觸發器會吞掉例外並發出警告（`raise warning`），絕不讓 `assess_submit` 失敗；萬一漏標，由客服部手動把該回報退回或撤回；緊急時用上面的 drop trigger 停用。
- 自動完成只看 `employee_id`：一張成績單送出，會把該員工**所有**未結案回報（不分情況）一併完成（老闆決定維持現狀）。
- 回報的 `store_code` 是回報當下人員所屬門市的快照，人員之後轉店不改；店長以快照門市看到（老闆決定維持現狀）。
- `exam_req_mark_seen` 一次把自己門市所有未看的回覆標為已看，不分條目（老闆決定維持現狀）。
- 每日上限 20 筆是「同一回報人、台北日期」計算，含已取消；客服部代報也算在客服部本人名下。
- 並發保護（兩個連線同時回報同一人）無法在單一連線的驗證腳本實測：以唯一部分索引的直接重複寫入被拒、`exam_req_create` 內含 `for update` 鎖定做靜態確認。
- 驗證腳本在交易內暫時取代三個 `exam_req_net_*` 函式與刪除寄信設定，整段 rollback 後自動還原；第 1 區用「真實」pg_net 驗證 queued（rollback 後不會真的送出）。我沒有在真實 Supabase 跑過，真實 pg_net 的簽名（`net.http_post` 具名參數 `url`／`body`／`headers`／`timeout_milliseconds`）、`net._http_response` 欄位、以及 postgres 角色對 `net` 的權限，是依 pg_net 文件寫的，未實測；若驗證腳本第 1 區出現「failed」並附權限類錯誤訊息，就是這裡要調整。
