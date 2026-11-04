# 第二期：每年健檢 — 資料庫腳本與函式合約（任務 1）

資料庫與網頁（任務 2 健檢頁、任務 3 考試接健檢、任務 4 建議單）共同遵守。**任務 2、3、4 只靠第三節「函式合約」開發。** 對不上就停下來回報，不要自己改約定。

> ⚠️ 兩支 SQL **尚未在真實 Supabase 執行**。開發機沒有 Supabase 連線，只在 PGlite（本機模擬的 Postgres）搭的假環境實跑過（做法與第一期相同，見第二節）。假環境的 `auth.jwt()`、Storage 是簡化版，**不能取代在真實 Supabase 跑一次**。

## 一、這份腳本做什麼

### 老闆定案的規則（一項不增減）

- 名詞叫「**健檢**」。每人每年 1 次。
- 11 家門市分四季輪流，預設季次：Q1 中和、新莊、樹林；Q2 桃園中壢、新竹、花蓮；Q3 旗艦、南台中、太平；Q4 台南、高雄（總公司不在內）。季次表全年共用一份、不分年度，客服部可隨時修改，**改了從下一次起算**。
- 健檢名單對象：在職、納入考核（`include_in_assessment`）、`period_status = '已上線'`、門市屬於該季的人。若員工有 `passed_on`，`passed_on` 必須**早於該季第一天**才入名單（Q1＝1/1、Q2＝4/1、Q3＝7/1、Q4＝10/1）；`passed_on` 為空視為長期已上線。
- 「首次健檢」＝這位員工沒有更早的、已送出且未作廢的健檢成績單。
- 考法與現有考核同一套；身分一律「正式」，及格線 85（沿用 `assess_verdict`：85 及格、95 優秀、75～84.9 需複訓）。
- 健檢沒過**只記錄**：送出時不動 `employees`（period_status、passed_on、probation_since、job_title…）、不建待開通、不開改善單、不觸發回考核期、不完成待考回報。
- 排定：客服部在名單上排定日期時間（單人單次）；沒有通知信、催辦、逾期。黃單紅單、抽查：本期不碰。

### 資料庫物件

| 物件 | 說明 |
|---|---|
| `checkup_store_quarter`（表） | 門市季次：`store_code pk`（參照 stores）、`quarter 1..4`、`updated_at`、`updated_by`；種子 11 家；RLS：客服部／主管全讀、店長讀自己門市；只能透過函式寫 |
| `assessments` 新欄位 | `kind`（`'exam'`／`'checkup'`，預設 `'exam'`，既有資料全是 exam）、`checkup_year`、`checkup_quarter`；約束：checkup 必須有年度與季次（季次 1..4）、exam 兩者必須為空、checkup 身分必須「正式」；唯一部分索引：同員工同年度最多一張**未作廢**的 checkup（含草稿） |
| `checkups`（表，排定表） | `id, employee_id, year, quarter, store_code(快照), scheduled_at, scheduled_by, note, assessment_id(可空), created_at`；`unique(employee_id, year)`；RLS 同上；`assessment_id` 參照 assessments（成績單被放棄/刪除時自動變空） |
| 狀態（由資料推得） | 沒有排定列＝**待排定**；有列且成績單未送出（沒有／草稿／已作廢）＝**已排定**；成績單已送出且未作廢＝**已完成** |
| 6 個對外函式 | `checkup_quarters_list`、`checkup_quarter_set`、`checkup_roster`、`checkup_schedule`、`checkup_unschedule`、`checkup_begin`（第三節） |
| 2 個內部函式 | `checkup_first_day`、`checkup_eligible`（網頁角色不能呼叫） |
| 被改寫的既有物件 | `assess_start`、`assess_submit`、`assess_weak_profile`、`improve_close`、`phase1_migrate_period_status`、觸發器函式 `improvement_auto_open`、`exam_req_auto_complete`、檢視 `assessment_summaries`（尾端追加 3 欄）；差異見第七節 |

### 「開始健檢」採哪個方案

採**方案一：新增 `checkup_begin(p_employee, p_year, p_quarter)`**，自己建 `kind='checkup'` 的草稿，不呼叫、也不複製 `assess_start`。理由：`assess_start` 內的身分判斷（考核期／新人 90 天／手動指定）與考核期邏輯纏在一起，加選填參數等於在既有函式裡長出健檢分支，風險比新函式高；新函式獨立，一般考核行為不受影響。唯一必須碰 `assess_start` 的地方只有兩行：「同考官同員工只能一張草稿」的唯一索引原本不分種類，改成只管 `kind='exam'`（否則考官手上有健檢草稿時開一般考核，會被誤回傳健檢草稿），`assess_start` 的 `on conflict` 條件與回傳既有草稿的查詢跟著加 `kind = 'exam'`（差異見第七節）。

## 二、執行順序與如何跑驗證

**檔案**

| 檔案 | 用途 |
|---|---|
| `checkup_schema.sql` | 要執行的那份。單一交易（begin…commit），可重複執行，不動既有資料 |
| `checkup_verify_fake.sql` | 驗證腳本：只用假資料、全程 rollback，不留任何資料；最後一張結果表 |

**順序**

0. 先到 Supabase 備份（Dashboard → Database → Backups），並先跑第五節「遷移前檢查」。前提：考題抽選器 schema、roster、assess、bank、accounts、notes_visible、backoffice、spotcheck、url_patch、weak_suggest、exam_request、**phase1** 都已執行（缺哪個，schema 開頭會用中文訊息擋下並整份回復，也會檢查 `assess_start`／`assess_submit`／`assess_weak_profile` 目前是第一期那一版）。
1. SQL Editor → New query → 貼上 `checkup_schema.sql` 整份 → Run。拿不到鎖會在 5 秒後整份回復，稍後重跑即可（避開有人正在送出成績單的時段）。
2. 執行第五節「遷移後人工檢查」。
3. 再開新的 query，貼上 `checkup_verify_fake.sql` 整份 → Run（請挑沒人抽題的時段）。**第一次跑請在客服部改季次之前**（區段 2 檢查真實季次種子）。
4. 預期：最後一張表第一列「總結」寫「**240/240 項通過**」，「通過」欄全是「通過」。有失敗時總結列會附「第一個失敗」的序號、測項與實際錯誤訊息；任何一列「失敗」就停下回報，不要自己放行。

**假環境怎麼跑（開發者用）**：PGlite 以非超級使用者角色（模擬 Supabase 的 postgres）依序載入考題抽選器 schema、roster、assess、bank、accounts、notes_visible、backoffice、spotcheck、url_patch、weak_suggest、exam_request，預塞一批像真的資料（含 12 家真實門市名稱），再執行 `phase1_schema.sql`、`checkup_schema.sql`，最後跑各 verify。

## 三、函式合約（給任務 2、3、4）

### 共通約定

- 角色字串（`app_users.role`）：`cs_admin`＝客服部、`hq_viewer`＝總公司主管、`store_manager`＝店長。沒有 `app_users` 列的登入者＝「無角色」。
- 所有函式 `security definer`、`set search_path = public, pg_temp`；`authenticated` 可執行、`anon` 與 `public` 不可（anon 呼叫會得到 `permission denied for function ...`）。角色檢查在函式內，無權限一律丟 `沒有權限`。
- 錯誤：函式以 `raise exception` 丟出中文訊息；supabase-js 回傳 `{ data: null, error }`，**訊息文字在 `error.message`**（含 `%` 的部分已被代入實際值）。前端直接顯示 `error.message` 即可（既有頁面也是這樣做）。
- 型別對照（PostgREST → JS）：`int` → number、`numeric`（分數）→ number、`uuid`／`text`／`date`（`'YYYY-MM-DD'`）→ string、`timestamptz` → ISO 字串（含時區，例如 `2026-11-10T06:00:00+00:00`）、`boolean` → boolean。
- 時間：傳 `timestamptz` 一律帶時區（例如 `new Date(...).toISOString()` 或 `'2026-11-10T14:00:00+08:00'`）；日期判斷用台北時間。
- 年度、季次由**呼叫端傳入**（資料庫不替你決定「現在是哪一季」，也不限制只能排當年當季；範圍：年度 2000～2100、季次 1～4）。前端取台北當季：`q = Math.floor(month0 / 3) + 1`（month0 為台北時間的月份 0～11）。

### 3.1 `checkup_quarters_list()`

門市季次＋該門市目前應健檢人數。

- 參數：無
- 可呼叫：`cs_admin`、`hq_viewer`、`store_manager`（店長只回自己門市 1 列）；其他 → `沒有權限`
- 回傳（多列，依 `quarter`、`store_code` 排序）：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `store_code` | text | 門市代碼（目前＝門市名稱，例如 `中和`） |
| `store_name` | text | 門市名稱 |
| `quarter` | int | 1～4 |
| `headcount` | int | 該門市「在職、納入考核、period_status＝已上線」人數（**不含** passed_on 限制，單純顯示人數） |
| `updated_at` | timestamptz | 季次最後修改時間 |
| `updated_by` | text | 最後修改人信箱；**只有客服部看得到，其他角色一律 null**（種子為 `(系統預設)`） |

- 前端：`const { data, error } = await sb.rpc('checkup_quarters_list');`
- 門市排序請沿用 `js/api.js` 的 `STORE_ORDER`（本函式回傳依季次與代碼排序，不依 STORE_ORDER）。

### 3.2 `checkup_quarter_set(p_store text, p_quarter int)`

改門市季次。**只有客服部。** 改了不影響已排定的健檢（排定列帶自己的年度、季次、門市快照），從下一次名單起算。

- 參數：`p_store`（門市代碼，前後空白會去掉）、`p_quarter`（1～4）
- 回傳：無（void，`data` 為 null）
- 錯誤訊息：`沒有權限`、`季次必須是 1 到 4`、`這間門市不在健檢季次表內（總公司或不存在的門市）：<代碼>`
- 只能改季次表內已有的門市（新開門市要先在 SQL Editor 手動新增一列，見已知限制）。
- 前端：`await sb.rpc('checkup_quarter_set', { p_store: '中和', p_quarter: 2 });`

### 3.3 `checkup_roster(p_year int, p_quarter int)`

某年某季的健檢名單（含狀態）。

- 參數：`p_year`（2000～2100）、`p_quarter`（1～4）
- 可呼叫：`cs_admin`、`hq_viewer`（全看）、`store_manager`（只看自己門市）；其他 → `沒有權限`
- 錯誤訊息：`沒有權限`、`年度不正確`、`季次必須是 1 到 4`
- 名單組成＝（A）該年該季已有排定列的人（不論之後門市改季次或人員狀態變動，排定了就留在原季；`store_code`／`store_name` 是排定當下的門市快照）＋（B）依規則在名單內、且該年還沒有排定列也沒有未作廢健檢成績單的人。同一個人同一年只會出現在一個季。
- 回傳（多列，依 `store_code`、`employee_id` 排序）：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `employee_id` | text | 員工編號 |
| `display_name` | text | 暱稱，沒有則用姓名 |
| `store_code` | text | 門市代碼 |
| `store_name` | text | 門市名稱 |
| `hire_date` | date | 到職日（可為 null） |
| `is_first` | boolean | 首次健檢（沒有更早的、已送出且未作廢的健檢成績單） |
| `status` | text | `待排定`／`已排定`／`已完成` |
| `scheduled_at` | timestamptz | 排定時間（待排定為 null） |
| `checkup_id` | uuid | 排定列 id（待排定為 null；取消排定要用） |
| `assessment_id` | uuid | 成績單 id：已完成＝該成績單；**草稿只有客服部看得到**（主管、店長一律 null）；已作廢＝null；其他 null |
| `score` | numeric | 總分（只有已完成才有） |
| `verdict` | text | 判定 優秀／及格／需複訓／不及格（只有已完成才有） |
| `assessment_status` | text | `'submitted'`（已完成）、`'draft'`（已開始未送出，**只有客服部看得到**）、null（其他）——前端用它判斷按鈕是「開始健檢」還是「繼續健檢」 |

- 備註：「已完成」也包含不及格（只記錄）；成績單被作廢後該人回到「已排定」（`assessment_id` 為 null，可再按「開始健檢」建新草稿）；人員在排定後離職／改不納入考核，仍會留在名單（因為已有排定列），客服部可取消排定。
- 前端：`const { data, error } = await sb.rpc('checkup_roster', { p_year: 2026, p_quarter: 4 });`

### 3.4 `checkup_schedule(p_employee text, p_year int, p_quarter int, p_scheduled_at timestamptz, p_note text default null)`

排定健檢（單人單次）。**只有客服部。**

- 參數：`p_employee`（員工編號）、`p_year`、`p_quarter`、`p_scheduled_at`（必填，帶時區）、`p_note`（選填，去頭尾空白，最多 500 字，空字串視為 null）
- 回傳：`uuid`（新建的 `checkups.id`）
- 檢查順序與錯誤訊息：
  1. `沒有權限`
  2. `年度不正確`／`季次必須是 1 到 4`／`請指定健檢日期與時間`／`備註最多 500 字`
  3. `找不到員工：<編號>`
  4. 該年已有排定列 → `這位人員 <年> 年已排定健檢（第 <季> 季）；要改期請先取消排定再重新排定`（同年不能排兩次，也不能改排別的季）
  5. 該年已有未作廢的健檢成績單 → `這位人員 <年> 年已有健檢成績單，不能再排定`
  6. 不在該年該季名單 → `這位人員不在 <年> 年第 <季> 季的健檢名單內（需在職、納入考核、已上線、門市屬於該季，且通過考核期的日期早於該季第一天）`
- 排定列記下：員工當下的門市（快照）、排定人信箱（`scheduled_by`；函式不回傳信箱，`checkup_roster` 也不含它）。
- 改期＝先 `checkup_unschedule` 再 `checkup_schedule`（已開始或已完成者不可）。
- 前端：`await sb.rpc('checkup_schedule', { p_employee: 'MI-0047', p_year: 2026, p_quarter: 4, p_scheduled_at: iso, p_note: note || null });`

### 3.5 `checkup_unschedule(p_checkup_id uuid)`

取消排定。**只有客服部。**

- 參數：`p_checkup_id`（取自 `checkup_roster.checkup_id`）
- 回傳：無（void）
- 錯誤訊息：`沒有權限`、`找不到這筆健檢排定`、`已完成的健檢不能取消排定`、`這場健檢已經開始（有未送出的考核草稿），請先放棄草稿再取消排定`
- 成績單已作廢或草稿已被放棄的排定可以取消。
- 前端：`await sb.rpc('checkup_unschedule', { p_checkup_id: row.checkup_id });`

### 3.6 `checkup_begin(p_employee text, p_year int, p_quarter int)`

開始健檢：建立 `kind='checkup'` 的成績單草稿並連到排定列。**只有客服部，只能對已排定的人。**

- 參數：`p_employee`、`p_year`、`p_quarter`（必須與排定列的年度、季次一致）
- 回傳：`uuid`（成績單草稿 id；已有自己的草稿則回傳**同一張**，可接續）
- 草稿內容：`kind='checkup'`、`checkup_year`、`checkup_quarter`、`tenure='正式'`、`tenure_source='自動'`、`hire_date_snapshot`＝員工到職日、`store_code`＝員工目前門市、`examiner_email`＝呼叫者、`status='draft'`
- 錯誤訊息：`沒有權限`、`年度不正確`、`季次必須是 1 到 4`、`找不到員工：<編號>`、`這位人員 <年> 年尚未排定健檢，請先排定`、`這位人員 <年> 年排定的是第 <A> 季，不是第 <B> 季`、`該員工不在考核名單（需納入考核且在職）`、`這位人員 <年> 年的健檢已完成，不能再開始`、`這場健檢已由其他客服部同仁開始，請由該同仁繼續，或請他先放棄草稿`、`這位人員 <年> 年已有進行中或已完成的健檢成績單`
- 成績單被作廢或草稿被放棄後可再呼叫，會建新草稿。
- 前端：`const { data: assessmentId, error } = await sb.rpc('checkup_begin', { p_employee: id, p_year: y, p_quarter: q });`

### 3.7 健檢草稿建好之後（任務 3 接考試）

**不要對健檢呼叫 `assess_start`。** 拿到 `checkup_begin` 回傳的 `assessmentId` 後，流程與一般考核完全相同，全部沿用既有函式：

1. 抽題：`assess_core_categories()` → `assess_draw(p_assessment_id, p_cats)`（核心 3 題組）
2. 評分暫存：`assess_save_item(...)`（四參數版）、備註附圖照舊
3. 弱項追加題（可選）：`assess_draft_weak`、`assess_add_extra`——資料庫允許；健檢是否要追加由任務 3 決定（追加題一樣不算入總分）
4. 送出：`assess_submit(p_assessment_id)` → 回傳 `total_score, verdict, pass_line(=85), weakest_dims, tenure('正式'), item_count`。**健檢送出後：不改 employees、不建待開通、不開改善單、不完成待考回報、不改抽查回考核期。** 結果頁不要顯示「已加入待開通」「仍在考核期」之類考核期文字。
5. 放棄：`assess_abandon`（排定列保留，`assessment_id` 變空，回到已排定）；作廢：`assess_void`（排定列保留，回到已排定）
6. 辨識健檢：`assessments`／`assessment_summaries` 多了 `kind`（`'exam'`／`'checkup'`）、`checkup_year`、`checkup_quarter` 三欄；`sb.from('assessments').select('...,kind,checkup_year,checkup_quarter')` 可直接讀（RLS 不變：客服部全看含草稿，主管與店長只看已送出）。
7. 既有 `assess.html` 的「我的進行中草稿」`myDrafts` 會把健檢草稿一併列出（它們是同一個考官的草稿）——前端請用 `kind` 標示「健檢」。

### 3.8 資料表與檢視（供讀取；寫入一律走函式）

- `checkups`、`checkup_store_quarter`：`authenticated` 只有 select，且受 RLS（客服部、主管全部；店長只看自己門市）；直接 insert／update／delete 一律 `permission denied`。**建議前端一律用 3.1～3.3 的函式讀**（已處理角色與草稿可見度）。
- `assessment_summaries`：尾端追加 `kind`、`checkup_year`、`checkup_quarter`（原 19 欄順序、名稱不變）。成績單列表、人員歷史、走勢、PDF 的資料來源都是它，**健檢成績單會出現在裡面**，前端需用 `kind` 標示或視需要過濾（見稽核表）。
- `analytics_dim_rates`：**欄位不變**（8 欄）。健檢成績單的題組分數**會**出現在裡面；要區分請用 `assessment_id` 對 `assessment_summaries.kind`。

## 四、稽核：哪些既有函式／檢視／觸發器讀 `assessments`

稽核方法：在假環境的資料庫中，對所有 public 函式原始碼、檢視定義、觸發器、RLS policy 搜尋 `assessments`／`assessment_items`／`assessment_summaries`，再逐一人工確認（含前端 `js/*.js` 的直接讀取）。預設原則：**會觸發動作或決定資格的地方一律排除 `kind='checkup'`；純顯示類要能看到健檢並可用 `kind` 區分。**

| # | 物件 | 讀 assessments 做什麼 | 讀到健檢成績單會怎樣 | 處理 |
|---|---|---|---|---|
| 1 | `assess_submit` | 送出：算分、判定、考核期處理（清 probation_since、轉已上線、設 passed_on、建待開通、更新 spot_probations） | 健檢身分「正式」，**不可**進考核期處理 | **已改**：兩個考核期 `if` 加 `kind = 'exam'` 守門；一般考核逐行相同（第七節 diff）。另有資料約束保證健檢身分一定是「正式」（雙保險，驗證 7B 實測） |
| 2 | 觸發器 `improvement_auto_open_trg`（函式 `improvement_auto_open`） | 送出後判定需複訓／不及格 → 自動開改善單 | 健檢沒過**不可**開單 | **已改**：條件加 `new.kind = 'exam'` |
| 3 | 觸發器 `exam_req_auto_complete_trg`（函式 `exam_req_auto_complete`） | 送出後把該員工「待處理／已排定」的待考回報標成已完成並連成績單 | 健檢送出**不可**完成店長的待考回報 | **已改**：條件加 `new.kind = 'exam'` |
| 4 | 觸發器 `improvement_auto_cancel_trg` | 成績單作廢時取消對應改善單（以 assessment_id 對應） | 健檢沒有改善單，無任何影響 | 不改 |
| 5 | `improve_close`（改善單結案，複檢成績單資格） | 檢查複檢成績單：已送出、同人、開單後送出、及格以上 | 健檢及格**不可**當複檢成績單 | **已改**：多一段 `kind <> 'exam'` → `健檢成績單不能當作複檢成績單` |
| 6 | `exam_req_candidates`、`exam_req_create`（待考回報資格） | 新人／回考核期資格只看 `employees`（period_status、probation_since）；「複檢」分支用 `exam_requests.assessment_id` 連到 assessments 判斷是否已完成 | 該連結只會由第 3 項觸發器寫入，健檢不會被連上；員工資格不讀成績單 | 不改（第 3 項已擋住唯一入口） |
| 7 | `exam_req_badge`（導覽紅點） | 讀 exam_requests、reply_activations，不讀 assessments | 無 | 不改 |
| 8 | `spot_*`（`spot_register`、`spot_candidates`、`spot_status`、`spot_cancel_probation`、`spot_mark_executed`、`spot_coach`、`spot_void_ticket`、`spot_month_yellow_ids`、`spot_quarter_red_ids`）、抽查資格 | 完全不讀 assessments；只有 `assess_submit` 會把 `spot_probations` 改「已通過」 | 抽查資格與黃紅單不受健檢影響；`spot_probations` 只在第 1 項守門內才會被改 | 不改 |
| 9 | 待開通（`reply_activations`、`activation_mark_done`） | 只由 `assess_submit` 寫入 | 健檢不會建立待開通（第 1 項守門） | 不改 |
| 10 | `assess_weak_profile`（弱項建議的取題依據：最近 3 張已送出成績單） | 取最近 3 張已送出成績單的面向得分率 | 若含健檢，健檢會左右下次考試的弱項追加題取題 | **已改（先排除）**：加 `kind = 'exam'`。**是否納入健檢＝待老闆決定（A）** |
| 11 | `assess_suggest_pool`、`assess_draw`、`assess_pick`、`assess_add_extra`（「這位考生以前考過哪些題」：`taken_before`／`repeated` 判斷） | 讀這位考生已送出或作廢成績單考過哪些題，優先避開 | 健檢考過的題也算「考過」，之後一般考核與健檢都會避開重複出題 | **不改**（維持含健檢，避免重複出題；不影響資格）。**是否要把健檢考過的題排除在「考過」之外＝待老闆決定（C）** |
| 12 | `assess_start` | 同考官同員工已有草稿就回傳那張 | 不改的話，考官手上有健檢草稿時開一般考核會回傳健檢草稿 | **已改**：草稿唯一索引與 `on conflict`／回傳查詢只管 `kind = 'exam'`（第七節 diff） |
| 13 | `assess_void`、`assess_abandon`、`assess_save_item`、`assess_add_image`、`assess_remove_image`、`assess_draft_weak` | 以成績單／題組 id 操作（草稿狀態、持有人檢查） | 健檢草稿照常可用，不分 kind；放棄草稿 → `checkups.assessment_id` 自動變空；作廢 → 回到已排定 | 不改 |
| 14 | `phase1_migrate_period_status`（遷移，平常有記號整段略過） | 遷移時判斷「已有及格以上成績單者不標考核期」 | 若老闆刻意刪記號重遷移，健檢及格會被誤當通過考核 | **已改**：條件加 `kind = 'exam'`（平常不會執行） |
| 15 | 檢視 `assessment_summaries` | 成績單列表、人員歷史、走勢、PDF 的資料來源 | 健檢成績單**會出現**（純顯示類，需要看到） | **已補**：尾端追加 `kind`、`checkup_year`、`checkup_quarter`（原 19 欄順序名稱不變）。前端要標示「健檢」（見下方前端清單） |
| 16 | 檢視 `analytics_dim_rates`（考核後台「弱項分析」七面向熱度） | 每張已送出成績單、每題組、每面向一列 | 健檢的題組分數會混進熱度表 | **不改檢視**（欄位維持 8 欄，避免破壞既有驗證）；前端可用 `assessment_id` 對 `assessment_summaries.kind` 區分。**熱度表要不要含健檢＝待老闆決定（B）** |
| 17 | 檢視 `improvement_ticket_view` | 左連 assessments 取來源成績單摘要 | 改善單的來源一定是一般考核（第 2 項），不會出現健檢 | 不改 |
| 18 | 檢視 `employees_with_tenure`、函式 `assess_candidates` | 不讀 assessments（只讀 employees） | 無 | 不改（本期沒動 employees） |
| 19 | RLS：`assessments_select`、`assessment_items_select`、`assessment_item_images_select` | 客服部全看；主管看已送出；店長看本店已送出 | 健檢同規則：主管與店長看得到已送出的健檢成績單，草稿只有客服部 | 不改（驗證 9 實測） |
| 20 | 前端 `js/assess-api.js`：`myDrafts`、`loadDraft`、`loadSummaries` | 直接 select assessments／assessment_summaries | `myDrafts` 會列出健檢草稿；`loadSummaries` 會多出健檢列 | **前端任務**：選 `kind` 欄位並標示 |
| 21 | 前端 `js/backoffice-api.js`：`loadSummaries`、`loadEmployeeAssessments`、`loadDimRates`、`loadReportItems`（歷次成績單、走勢、PDF、弱項分析） | 直接讀 assessment_summaries／assessments／analytics_dim_rates | 歷次成績單、走勢圖、PDF 會含健檢列（純顯示，正確）；與上一次比較、走勢要不要混入健檢請前端決定 | **前端任務**：選 `kind` 欄位、標示、必要時過濾 |
| 22 | 前端改善單「複檢結案」選成績單的下拉（`backoffice.html` 呼叫 `improve_close`） | 列出該考生已送出成績單供選為複檢 | 若列出健檢，選了會被函式擋下 | **前端任務**：下拉只列 `kind='exam'` |

### 待老闆決定

- **A. 弱項建議是否納入健檢成績單**（`assess_weak_profile`，也影響結果頁「下次建議考題」預告）：目前先排除。
- **B. 考核後台「弱項分析」熱度表是否含健檢**（`analytics_dim_rates`）：目前資料層不排除（健檢分數會算進熱度）；前端可用 `kind` 區分或排除。
- **C. 抽題的「考過的題」是否把健檢考過的題算進去**（`assess_pick`／`assess_draw`／`assess_add_extra`／`assess_suggest_pool`）：目前算進去（避免同一人重複考到同一題）。這三項都**不影響任何資格判定**，所以沒有停下，等老闆決定。

## 五、人工檢查查詢（在 SQL Editor 執行，每次只會顯示最後一個結果，請一段一段跑）

### 遷移前（執行 `checkup_schema.sql` 之前）

```sql
-- 1. 11 家季次門市在 stores 都找得到（代碼＝名稱）。預期：11 列（少了哪家，schema 會警告並不種入那家）
select code, name from public.stores
where code in ('中和','新莊','樹林','桃園中壢','新竹','花蓮','旗艦','南台中','太平','台南','高雄') order by code;

-- 2. 目前成績單總數與草稿數（執行後 kind='exam' 的數量要等於這個總數）
select count(*) as 成績單總數, count(*) filter (where status = 'draft') as 草稿數 from public.assessments;

-- 3. 現有「同考官同員工一張草稿」索引（執行前預期：只有 where status = 'draft'）
select indexdef from pg_indexes where schemaname = 'public' and indexname = 'assessments_one_draft_per_pair';

-- 4. 第一期已執行、assess_submit 是第一期那一版。預期：true
select p.prosrc like '%reply_activations%' and p.prosrc like '%is_extra%' as assess_submit是第一期版
from pg_proc p where p.oid = 'public.assess_submit(uuid)'::regprocedure;

-- 5. 職稱超過 20 字（本期不更新 employees，但第一期遺留的 NOT VALID 約束仍建議確認）。預期：0 列
select id, job_title from public.employees where char_length(job_title) > 20;
```

### 遷移後（執行 `checkup_schema.sql` 之後、驗證腳本之前）

```sql
-- 1. 成績單種類分布：只有 exam，且筆數等於遷移前的總數
select kind, count(*) from public.assessments group by kind;

-- 2. 門市季次（預期 Q1 3 家、Q2 3 家、Q3 3 家、Q4 2 家，與老闆指定完全一致）
select quarter, count(*) as 門市數, string_agg(store_code, '、' order by store_code) as 門市
from public.checkup_store_quarter group by quarter order by quarter;

-- 3. 草稿索引已改成只管 kind='exam'；新增的每年一張索引存在。預期：2 列
select indexname, indexdef from pg_indexes
where schemaname = 'public' and indexname in ('assessments_one_draft_per_pair', 'assessments_one_checkup_per_year') order by 1;

-- 4. 檢視欄位：原 19 欄不變，尾端多 kind、checkup_year、checkup_quarter。預期：最後 3 欄正是這三個
select string_agg(column_name, ', ' order by ordinal_position) from information_schema.columns
where table_schema = 'public' and table_name = 'assessment_summaries';

-- 5. 新函式都在、網頁角色可執行（預期 6 列，authenticated 全是 true）
select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as 登入者可執行, has_function_privilege('anon', p.oid, 'execute') as 匿名可執行
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
 ('checkup_quarters_list','checkup_quarter_set','checkup_roster','checkup_schedule','checkup_unschedule','checkup_begin') order by 1;

-- 6. 預覽「某年某季」的健檢名單人數（以 2026 年 Q4 為例；SQL Editor 沒有登入者，所以不能直接呼叫 checkup_roster，這裡用同一套規則直接查）
select e.store_code as 門市, count(*) as 人數
from public.employees e
join public.checkup_store_quarter q on q.store_code = e.store_code and q.quarter = 4
where e.status = '在職' and e.include_in_assessment and e.period_status = '已上線'
  and (e.passed_on is null or e.passed_on < make_date(2026, 10, 1))
group by e.store_code order by e.store_code;
```

### 上線後定期檢查（確認健檢沒有副作用）

```sql
-- 預期全部 0：健檢成績單沒有改善單、沒有待開通、沒有連到待考回報
select
  (select count(*) from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where a.kind = 'checkup') as 健檢改善單,
  (select count(*) from public.reply_activations r join public.assessments a on a.id = r.assessment_id where a.kind = 'checkup') as 健檢待開通,
  (select count(*) from public.exam_requests r join public.assessments a on a.id = r.assessment_id where a.kind = 'checkup') as 健檢待考回報;
```

## 六、已知限制與注意事項

1. **前端未動（本任務只做資料庫）**：`assessment_summaries` 現在包含健檢成績單，所以**資料庫上線後、任務 2～4 的前端上線前**，成績單列表、人員歷史、走勢、PDF 會出現沒有標示的健檢列，考核後台「弱項分析」也會把健檢分數算進熱度。建議資料庫腳本與前端一起上線（或先確認可接受）。
2. **季次種子驗證**：驗證腳本區段 2 檢查「真實季次種子」，客服部改過季次之後再跑會有 3 項失敗，屬預期（請在改季次之前跑）。
3. **只能改季次表內已有的門市**：`checkup_quarter_set` 不新增門市。新開門市要先在 SQL Editor 手動 `insert into public.checkup_store_quarter (store_code, quarter) values ('新門市', n);`。總公司刻意不在表內。
4. **自行補的規則（規格沒寫，請老闆確認）**：
   - 已開始（有未送出的草稿）時不能取消排定，要先放棄草稿（避免留下沒有排定的孤兒草稿）。
   - 同年已排定不能直接改期或改排別的季，要先取消排定再重新排定。
   - 成績單被作廢後排定列保留，回到「已排定」，可再開始或取消排定。
   - 排定後人員離職或改不納入考核：名單仍顯示（因為已有排定列），不能開始健檢，可取消排定；排定後變成考核期則**不擋**開始健檢（規格只要求名單與排定的資格）。
   - 備註最多 500 字、`checkup_roster` 多回一欄 `assessment_status`（前端判斷「繼續健檢」用）、`updated_by` 只給客服部。
5. **年度與季次由前端傳入**：資料庫不檢查是否為當年當季，客服部可排未來年度或過去季（2000～2100）。
6. **門市快照**：排定列的 `store_code` 是排定當下的門市；`checkup_roster` 對（A）已排定者以快照門市顯示並套用店長權限；`checkup_begin` 建的成績單 `store_code` 是開始當下員工的門市（與一般考核相同）。排定後轉調門市的人，兩處可能不同。
7. **`probation_since` 有值但已是已上線**的異常資料仍會入名單（規格只看 `period_status`）；健檢送出仍不動它（驗證 7、7B）。
8. **既有驗證腳本異動**：`phase1_verify_fake.sql` 第 459 行的檢查「assessment_summaries 欄位清單沒變（19 欄…）」改成只看前 19 欄（因為本期依規格在尾端追加欄位，原檢查會誤報）；其餘既有驗證腳本沒改，詳見下方測試結果。
9. **`spotcheck_verify_fake.sql` 既有的偶發失敗**：在假環境中，連本期腳本都不載入（只有第一期的環境）反覆跑 6 次也有 2 次出現「8 取消／8 重算」那 14 項失敗（其餘 4 次 314/314），與本期無關，疑似該腳本對時間或排序有偶發相依；載入本期腳本後重跑 6 次中有 1 次同樣出現。真實資料庫請遇到失敗時重跑一次確認。
10. 並發（兩個連線同時排定同一人、同時開始同一人的健檢）無法在單一連線的驗證腳本實測；靜態確認：`checkup_schedule` 鎖員工列、`checkup_begin` 鎖排定列與成績單列、`unique(employee_id, year)` 與 `assessments_one_checkup_per_year` 兜底。
11. 本期沒有通知信、催辦、逾期（規格指定）；`FEATURES.md`、`進度紀錄.md` 由任務 5 統一補。
12. 驗證腳本會對 `employees` 新增假列（rollback 後消失），不更新任何真實員工列，所以不會觸發職稱 20 字的 NOT VALID 約束問題；腳本開頭有 5 秒 `lock_timeout`。

## 七、與既有函式的差異（被改寫的物件，原版逐字複製，只差下列幾行）

基底都是目前生效的版本（`phase1_schema.sql`、`backoffice_schema.sql`、`exam_request_schema.sql`）；`create or replace`，簽名與回傳型別不變，權限不變；`checkup_schema.sql` 開頭會確認 `assess_start`／`assess_submit`／`assess_weak_profile` 是第一期那一版。一般考核（`kind='exam'`）的行為與改寫前相同（假環境以第一期驗證腳本實測，見測試結果）。

#### assess_start
```diff
@@ -52,13 +52,13 @@
     (v_emp.id,
      coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), '')),
      v_emp.store_code, v_me, 'draft', v_tenure, v_source, v_emp.hire_date)
-  on conflict (examiner_email, employee_id) where status = 'draft' do nothing
+  on conflict (examiner_email, employee_id) where status = 'draft' and kind = 'exam' do nothing
   returning id into v_id;
 
   if v_id is null then
     select a.id into v_id
     from public.assessments a
-    where a.employee_id = v_emp.id and a.examiner_email = v_me and a.status = 'draft';
+    where a.employee_id = v_emp.id and a.examiner_email = v_me and a.status = 'draft' and a.kind = 'exam';
   end if;
 
   return v_id;

```

#### assess_submit
```diff
@@ -81,7 +81,8 @@
    where id = v_a.id;
 
   -- 【新增】考核期通過：來源是「考核期」且總分 >= 85
-  if v_a.tenure_source = '考核期' and v_total >= 85 then
+  -- 【健檢】只有一般考核（kind = 'exam'）才處理考核期；健檢成績單只記錄，絕不改 employees、spot_probations、待開通
+  if v_a.kind = 'exam' and v_a.tenure_source = '考核期' and v_total >= 85 then
     -- 【第一期】守門：先鎖員工列；只有員工「目前仍在考核期」（probation_since 有值，或 period_status 是考核期）時
     --   才清除考核期、轉已上線、記通過日、新增待開通。員工已是已上線且 probation_since 為空
     --   （例如客服部已取消回考核期、或另一張草稿已先通過）時，只正常送出成績單，什麼都不再改。
@@ -106,7 +107,8 @@
   end if;
 
   -- 【第一期新增】考核期新人通過：身分是「新人」、總分 >= 70、員工目前是考核期 → 已上線、記通過日、新增待開通
-  if v_a.tenure = '新人' and v_total >= 70 then
+  -- 【健檢】同上：健檢成績單（身分一律正式）不進這一段
+  if v_a.kind = 'exam' and v_a.tenure = '新人' and v_total >= 70 then
     select e.period_status into v_ps from public.employees e where e.id = v_a.employee_id for update;
     if v_ps = '考核期' then
       update public.employees

```

#### assess_weak_profile
```diff
@@ -23,6 +23,7 @@
     from public.assessments a
     where a.employee_id = p_employee_id
       and a.status = 'submitted'
+      and a.kind = 'exam'   -- 【健檢】弱項建議的取題依據先排除健檢成績單（是否納入待老闆決定）
   ) r
   where r.rn <= 3;
   v_n := coalesce(cardinality(v_ids), 0);

```

#### improvement_auto_open
```diff
@@ -7,7 +7,8 @@
 begin
   if new.status = 'submitted'
      and old.status is distinct from 'submitted'
-     and new.verdict in ('需複訓', '不及格') then
+     and new.verdict in ('需複訓', '不及格')
+     and new.kind = 'exam' then   -- 【健檢】健檢沒過只記錄，不自動開改善單
     insert into public.improvement_tickets
       (assessment_id, employee_id, store_code, status, target_dims, due_date)
     values

```

#### exam_req_auto_complete
```diff
@@ -5,7 +5,8 @@
 set search_path = public, pg_temp
 as $$
 begin
-  if new.status = 'submitted' and old.status is distinct from 'submitted' then
+  if new.status = 'submitted' and old.status is distinct from 'submitted'
+     and new.kind = 'exam' then   -- 【健檢】健檢成績單送出不會把店長的待考回報標成已完成
     begin
       update public.exam_requests
          set status = '已完成',

```

#### improve_close
```diff
@@ -27,6 +27,9 @@
   if v_a.status <> 'submitted' then
     raise exception '複檢成績單必須是已送出的成績單（目前：%）', public.improvement_status_zh(v_a.status);
   end if;
+  if v_a.kind <> 'exam' then   -- 【健檢】健檢成績單不能當複檢成績單（複檢資格只看一般考核）
+    raise exception '健檢成績單不能當作複檢成績單';
+  end if;
   if v_a.employee_id <> v_t.employee_id then
     raise exception '複檢成績單必須是同一位考生的成績單';
   end if;

```

#### phase1_migrate_period_status
```diff
@@ -24,6 +24,7 @@
            and not exists (select 1 from public.assessments a
                            where a.employee_id = e.id
                              and a.status = 'submitted'
+                             and a.kind = 'exam'   -- 【健檢】健檢及格不算通過考核期
                              and a.verdict in ('及格', '優秀')))
   ) x;
 

```


另外，索引 `assessments_one_draft_per_pair` 由「`where status = 'draft'`」改成「`where status = 'draft' and kind = 'exam'`」（名稱不變）；檢視 `assessment_summaries` 在最後追加 `a.kind, a.checkup_year, a.checkup_quarter` 三欄。

## 八、測試結果（假環境）

- `checkup_verify_fake.sql`：**240/240 項通過**（預塞資料的環境；schema 連跑 2～3 次再驗結果相同；驗證前後預塞資料的逐表指紋完全相同）。涵蓋：結構與約束、授權（各角色與 anon）、季次種子（11 家、3/3/3/2、逐家對應）、季次表與改季次、名單規則（passed_on 早於季初才入名單、剛好季初不入、考核期／離職／不納入不入、下一年度輪到、首次健檢標記、三種狀態、店長只看本店）、排定／取消排定／已完成不可取消、開始健檢只限已排定與草稿規則、健檢送出（100.0 優秀、84.9 需複訓、85.0 及格、不動 employees、不建待開通、不開改善單、待考回報不被完成、抽查回考核期不動、保險 7B）、每人每年一張與作廢後可再建、一般考核回歸（考核期新人 70 線通過、不及格開改善單、回考核期 85.0 通過與 84.9 不通過，期望值與第一期驗證相同）、複檢結案排除健檢、弱項建議排除健檢、檢視欄位順序與 kind、RLS 讀取。
- 既有驗證在「全部既有 schema＋phase1＋本期 schema」的環境重跑：assess 249/249、backoffice 161/161、spotcheck 314/314、weak_suggest 177/177、bank 162/162、accounts 113/113、notes_visible 134/134、url_patch 84/84、phase1 378/378（第 459 行檢查已調整）、exam_request 388/388，**全過**。
- 本期 schema 執行前後，其餘所有 public 函式的原始碼指紋比對：**除本期新增與修改的函式外完全相同**。
- 反向測試：故意弄壞 20 種寫法（觸發器不排除健檢、待考回報誤完成、複檢可用健檢、弱項建議含健檢、名單 `<=`、排定資格 `<=`、已完成可取消、已開始可取消、送出守門拿掉、草稿索引不分 kind、開始健檢不檢查排定、每年一張索引失效、檢視沒有 kind、首次健檢判斷錯誤、店長看到別店、主管看到草稿、健檢身分約束拿掉、作廢算已完成、主管可改季次、updated_by 洩漏給非客服部），驗證腳本**全部抓得到**。
