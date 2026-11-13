# 功能點名冊（現有功能的唯一事實清單）

格式：功能名｜入口｜一行驗證方式。新功能完成要在同一個 commit 補一行。

## 階段 1 樣品（假資料，不連資料庫）

- 樣品登入頁｜`樣品/index.html`｜按「使用公司 Google 帳號登入」，出現三個假帳號，點選後跳到名冊頁
- 名冊頁（客服部）｜`樣品/roster.html`｜看全部門市；可新增、編輯、切換「納入考核」開關
- 名冊頁（總公司主管）｜`樣品/roster.html`｜切換身分為總公司主管：看全部門市，畫面上沒有任何編輯、新增、開關
- 名冊頁（店長）｜`樣品/roster.html`｜切換身分為店長：只看自己門市（可換門市示範），唯讀
- 新人／正式自動判斷｜`樣品/roster.html`｜MI-9011（第 90 天）顯示新人、MI-9010（第 91 天）顯示正式
- 未填到職日｜`樣品/roster.html`｜MI-9015、MI-9016 顯示「未填到職日」，新增人員時到職日可留空
- 門市篩選與搜尋｜`樣品/roster.html`｜客服部、主管可篩門市；搜尋框可用編號或姓名找人
- 手機版面｜`樣品/roster.html`｜寬度 375px 時控制項直向排列，表格可橫向捲動

## 階段 1 正式版（已寫好，尚未對真資料庫實測；要先完成 設定步驟A到D.md）

- 正式登入頁｜`index.html`｜按 Google 登入；非公司帳號或帳號未開通會顯示提示
- 公司網域與開通檢查｜`roster.html`｜非 @2motor.tw 登出並回登入頁；app_users 查不到者只顯示「帳號尚未開通」
- 正式名冊頁｜`roster.html`｜讀 employees_with_tenure；客服部可新增、編輯、切換納入考核；主管與店長唯讀
- 新增人員門市必選｜`roster.html`｜按「新增人員」，門市預設為「請選擇門市」；沒選就送出會提示「請選擇門市」
- 定時保持專案運作｜`.github/workflows/keepalive.yml`｜每 3 天呼叫一次資料庫函式 roster_keepalive()，失敗（例如專案被暫停）時 GitHub 寄通知；需先在資料庫執行 `supabase/roster_schema.sql` 最後一段
- 門市排序｜`js/api.js`｜門市選單與名冊列表依「總公司、中和、新莊、樹林、桃園中壢、新竹、旗艦、南台中、太平、台南、高雄、花蓮」排列；同門市內店長排最前，其餘依員工編號；不在清單內的門市排最後
- 名冊資料存取｜`js/api.js`、`js/config.js`｜只含網址與公開金鑰；寫入被權限擋下時顯示白話訊息
- 匯入檔產生器｜`supabase/import/gen_import.js`｜執行後產生本機匯入 SQL（含個資，不進倉庫），終端機只印數量彙總
- 設定步驟｜`設定步驟A到D.md`｜Supabase 建表與匯入、GitHub Pages、Google 憑證、Supabase 登入設定

## 階段 2 評分

### 三級制評分與新人面向備註（網頁與資料庫腳本已寫好；尚未在真實 Supabase 執行，順序見 supabase/README_assess.md 文末）

- 三級制評分（優良 100、尚可 70、待加強 40、不適用）｜`assess.html`、`js/scoring.js`、`js/grade3-core.js`、`app.css`｜新人考核頁每面向四顆按鈕（優良綠、尚可橘、待加強紅、不適用灰）；驗證：`node tests/scoring.test.js`、`node tests/grade3-core.test.js` 全過（含新舊等級換算相同、舊單 優／良／不及格 結果與改制前一致）
- 新人考核面向備註必填｜`assess.html`、`js/assess-api.js`、`supabase/grade3_schema.sql`｜新人選尚可／待加強，該面向下方跳紅字必填備註（無字數下限，空白不算）；未填按「分析弱項」或送出會被擋並標紅面向；資料庫送出時也擋；正式、回考核期、健檢備註選填；驗證：`supabase/grade3_verify_fake.sql`（結尾復原）第一列「100/100 項通過」
- 舊單相容（不換算、不修改）｜`supabase/grade3_schema.sql`（assess_level_pct 新舊都認得）、`js/recent-reports.js`、`js/report-pdf.js`｜舊單的優／良／不及格原樣顯示並借用綠／橘／紅；資料庫新資料只准新等級（觸發器擋舊字串）；驗證：grade3_verify_fake.sql 區段 1、5
- 成績單面向備註（客服部視角）｜`backoffice.html` 近期考核詳情、成績單 PDF（`js/report-pdf.js`、`js/report-pdf-core.js`）｜非優良面向下方顯示「考官備註：…」；舊單沒有就不顯示；店長／主管精簡版不顯示也不查此欄（備註存機密表）；驗證：`node tests/report-pdf-core.test.js`
- 成績單完整版（店長自己門市、總公司主管）｜`backoffice.html` 近期考核詳情與歷次成績單 PDF、`js/recent-reports.js`、`js/assess-api.js`（loadItemsFullReport）、`js/backoffice-api.js`（loadReportItems 第三參數）、`js/report-pdf*.js`、`supabase/fullreport_schema.sql`｜在精簡版上多顯示題目名稱、題組備註、面向備註（舊單照常）；考官信箱、步驟、考點仍只有客服部；題目名稱與面向備註走資料庫函式 fullreport_items（店長限自己門市、主管全部已送出、其他人與 anon 一律擋；機密表不開放）；店長與主管的列表查詢不再要求考官信箱欄位；驗證：`supabase/fullreport_verify_fake.sql`（結尾復原）第一列「46/46 項通過」、`node tests/fullreport-api.test.js`、`node tests/report-pdf-core.test.js`

### 正式版（已執行 SQL、已審查；客服部流程已用測試考生實測通過，店長與主管的真實登入尚未測）

- 進行考核（只有客服部）｜`assess.html`｜選考生（可依門市下拉篩選，只列有人的門市並顯示人數，選擇記在 sessionStorage；每位考生那列按「準備考核・去抽題」直接開始，到職日空白則就地展開「新人／正式」兩鍵）→ 自動抽固定核心題組（失敗可改自選分類）→ 七面向評分並自動暫存 → 核心評完分析弱項、可追加弱項題（弱項分析失敗可重試或略過直接送出）→ 結算（以資料庫計算為準，與預覽不一致會警告）→ 送出；可接續草稿、放棄考核
- 考官備註文字對主管與店長可見｜`supabase/notes_visible_schema.sql`、`supabase/notes_visible_verify_fake.sql`（驗證，結尾自動復原）、`supabase/README_notes_visible.md`、`assess.html`、`backoffice.html`（近期考核分頁）、`js/recent-reports.js`、`js/assess-api.js`｜備註改存 assessment_items.note（舊 secrets.note 停用並清空）；客服部、主管、同門市店長讀得到（主管與店長限已送出未作廢）；備註框與附圖區提醒考官不要貼腳本或考點
- 備註附圖（正式版）｜`assess.html`、`js/assess-api.js`｜貼上、拖曳、選檔；上傳到私有 bucket assess-notes；每題組最多 5 張；顯示用簽名網址
- 成績單（所有已開通角色）｜考核後台「近期考核」分頁（`backoffice.html#recent`、`js/recent-reports.js`；舊網址 `reports.html` 已改為轉址頁）｜客服部看完整內容並可作廢；主管看已送出的精簡版；店長只看自己門市已送出的精簡版；精簡版含考官備註文字與備註附圖，不含題組名稱、步驟、考點、考官信箱（備註存在 assessment_items.note；需先在 Supabase 執行 notes_visible_schema.sql）
- 導覽統一（現含 `backoffice.html`、`accounts.html`，導覽已加入「考核後台」）｜`roster.html`、`assess.html`、`backoffice.html`｜頁首黑底導覽列（貳輪嶼 LOGO、圖示分頁、目前頁黃底、頭像、登出圖示；窄螢幕分頁自成一行、信箱隱藏只留角色標籤）；分頁順序：人員名冊、進行考核（客服部）、成績單&考核後台（原「成績單」與「考核後台」合併）、題庫管理（客服部）、帳號管理（客服部）；名冊頁標題為「貳輪嶼官方LINE訊息回覆人員名冊」

### 抽查系統（網頁已寫好，尚未連真實資料庫；需先執行 supabase/spotcheck_schema.sql，規格見 supabase/README_spotcheck.md）

- 抽查頁｜`spotcheck.html`、`js/spotcheck-api.js`｜所有已開通角色可進；開頁見「人員抽查狀態」表（本月黃單張數與狀態；紅單欄、回考核期欄已停用拿掉；可用門市下拉選單篩選；店長只有自己門市，不顯示下拉）與單據清單（只列黃單，已無種類篩選；可依門市、人員、狀態篩選；選門市後人員下拉只列該門市；店長不顯示門市下拉）；寫入全走 RPC（spot_register_dims／spot_void_ticket／spot_coach；原 spot_mark_executed／spot_cancel_probation 資料庫保留、頁面不再呼叫）
- 登記抽查（只有客服部）｜`spotcheck.html`｜「登記一次抽查」區塊在「人員抽查狀態」之前（警示列仍最上面；主管與店長沒有登記區塊，直接看狀態表）；選人員、日期、判定、七面向等級、原因（不適當必填）；「訊息抽檢-LINE聊天室網址」為必填單行網址（去空白、http／https 開頭、無空白、500 字內，否則顯示繁中提示不送出），以 p_message 傳送；登記後顯示開了黃單（紅單／回考核期已停用）；單據清單有「聊天室」欄（黃單用 inspection_id 對應 spot_inspections.message，http／https 開頭才顯示可點的「開啟 LINE 聊天室」連結，否則純文字；紅單顯示「—」；三種角色都看得到）
- 備註網址（非必填）｜`assess.html`、`backoffice.html`（近期考核分頁）、`js/recent-reports.js`、`js/assess-api.js`｜考官備註下方多一個網址欄，隨題組自動暫存（assess_save_item 第四參數 p_note_url，空字串傳 null），草稿重開會帶回；格式不合（非 http／https、含空白、超過 500 字）顯示提示、該題組不暫存、無法送出；成績單詳情（客服部與主管／店長版）有網址時在備註旁顯示「備註網址」連結，只有 http／https 才成連結（javascript: 等不會）
- 【已停用 2026-11】回考核期警示列｜`spotcheck.html`｜原：待執行時客服部見「標記已執行」與「取消回考核期」。現：警示列、已執行／取消回考核期按鈕與對話框全部拿掉；資料庫函式與資料表保留（見 `supabase/noredticket_schema.sql`）
- 單據作廢與輔導回填｜`spotcheck.html`｜客服部可作廢（原因必填）；客服部與該門市店長可回填輔導（日期＋備註必填）；總公司主管無任何操作按鈕
- 導覽「抽查」｜`roster.html`、`assess.html`、`backoffice.html`、`questions.html`、`accounts.html`、`spotcheck.html`｜所有已開通角色看得到，在「考核後台」之後（第二期起：此導覽分頁改為「健檢」，抽查頁改由健檢頁內的連結進入；第三期整併）
- 考核期標籤｜`roster.html`、`backoffice.html`（近期考核分頁）、`js/recent-reports.js`、`assess.html`｜（回考核期已停用：新成績單不會再產生 tenure_source「考核期」，此標籤只為舊成績單相容而保留顯示）成績單與進行考核的「考核時身分」在 tenure_source 為「考核期」時顯示「考核期」標籤（名冊的標籤已改為第一期規則，見「第一期」一節）

### 題庫管理（正式版；bank_schema.sql 已在 Supabase 執行，162 項驗證通過；老闆用測試分類實測通過）

- 題庫管理頁（只有客服部）｜`questions.html`、`js/questions-api.js`｜取代舊管理頁，Google 登入；讀寫呼叫 bank_list_questions／bank_save_question／bank_delete_question／bank_rename_category／bank_reset 與 assess_categories；功能對應舊管理頁（分類下拉、統計、題組列表、新增編輯與步驟編輯器、草稿保留、刪除與洗牌二次確認、分類改名與合併）；題庫內容不寫入 console 或瀏覽器儲存；載入失敗時停用表單與洗牌
- 導覽「題庫管理」｜`roster.html`、`assess.html`、`accounts.html`、`backoffice.html`｜只有客服部看得到，在「帳號管理」之前

### 題庫管理（樣品與設計稿）

- 題庫管理樣品（假資料）｜`樣品/questions.html`｜完整對應舊管理頁：分類下拉（含「全部分類」與特殊名稱）、統計小卡、收合列表與步驟展開、新增與編輯題組（步驟編輯器 1～30、上下移）、草稿保留、刪除二次確認（4 秒還原）、分類改名與合併、洗牌（單一與全部，二次確認）；底部註明題庫內容含考點只有客服部可見
- 題庫管理設計稿｜`supabase/bank_schema.sql`、`bank_verify_fake.sql`、`README_bank.md`｜bank_list_questions／bank_save_question／bank_delete_question／bank_rename_category／bank_reset，只有客服部能呼叫，行為與舊 admin_* 函式一致，與抽題共用 advisory lock（寫入函式）；驗證腳本結尾自動復原
- 停用舊抽選器腳本（單獨、可還原、尚未執行）｜`supabase/bank_retire_legacy.sql`｜收回 anon 對 8 個舊函式的 execute，不刪函式與資料；開頭防護：有其他物件引用舊函式就中止；還原段在註解內

### 考核後台（正式版；SQL 已在 Supabase 執行，161 項驗證通過；網頁尚未用真實登入實測）

- 考核後台頁｜`backoffice.html`、`js/backoffice-api.js`｜所有已開通角色可進；三個分頁「人員歷史」「弱項分析」「改善單」，網址 #history、#insights、#tickets；資料皆讀資料庫（不查機密表）；改善單動作呼叫 improve_update_plan／improve_close／improve_cancel（客服部）、improve_mark_coached（店長自己門市或客服部）；主管只讀；已取消單只有客服部看得到；主管與店長視角的改善單紀錄不顯示他人信箱（頁首仍顯示自己的信箱）
- 弱項分析雷達圖｜`backoffice.html`（#insights）、`js/radar.js`、`js/recent-reports-core.js`（radarRows、canCompare）｜七面向長條圖改雷達圖，最弱面向橘色；選單一門市時加灰色虛線＝全公司平均（資料只涵蓋一家門市如店長則不畫），圖旁數值表按得分率高到低、顯示全公司與 ▲▼差異；保留範圍／期間篩選與門市×面向熱度表；驗證：`node tests/recent-reports-core.test.js` 通過，開後台弱項分析切換範圍有虛線、手機 375 不橫向捲動
- 歷次成績單下載 PDF｜`backoffice.html`、`js/report-pdf.js`、`js/report-pdf-core.js`、`js/backoffice-api.js`、`tests/report-pdf-core.test.js`｜考核後台打開考生 →「歷次成績單」每列最右「下載 PDF」，產生 A4 兩頁（題組多自動三頁）成績單，檔名 成績單_姓名_日期.pdf；版面同 `樣品/成績單PDF樣品.html`（總分判定、雷達圖與面向得分率、與上一次比較、每題得分、全部歷次走勢）；加考題標「加考」不計入；客服部 PDF 顯示題名，主管與店長只顯示題組編號與分類（前端完全不查 assessment_item_secrets，資料庫也只放行客服部）；html2canvas 1.4.1／jsPDF 2.5.1 第一次按下載才動態載入；驗證：`node tests/report-pdf-core.test.js` 印出「通過 175 項」且結束碼 0
- 導覽「成績單&考核後台」（原「考核後台」，已與「成績單」合併）｜`roster.html`、`assess.html`、`accounts.html`、`backoffice.html`｜所有已開通角色看得到；順序：人員名冊、進行考核（客服部）、成績單&考核後台、題庫管理（客服部）、帳號管理（客服部）
- 自動開單與自動取消｜資料庫觸發器（backoffice_schema.sql）｜成績單送出且判定需複訓或不及格時自動開單（期限 14 天）；成績單作廢時 open／coached 的單自動取消；**上線後要用真實流程送一張不及格成績單驗證**

### 考核後台（樣品與設計稿，已被正式版取代）

- 考核後台樣品（假資料）｜`樣品/backoffice.html`｜三個分頁「人員歷史」（列表、走勢圖、七面向平均、歷次成績單）、「弱項分析」（全公司或單一門市、最近 3 次或全部、門市×面向熱度表）、「改善單」（狀態與門市篩選；客服部編輯面向與期限、結案需複檢成績單、取消；店長回填已輔導，備註必填不限字數；主管只讀）；右上角可切換身分示範
- 改善單與分析設計稿｜`supabase/backoffice_schema.sql`、`supabase/backoffice_verify_fake.sql`、`supabase/README_backoffice.md`｜成績單送出且判定需複訓或不及格時自動開單（預設 14 天）；成績單作廢時 open／coached 的單自動取消；improve_update_plan／improve_mark_coached／improve_close／improve_cancel；improvement_ticket_view、analytics_dim_rates；驗證腳本含真實 assess_submit／assess_void 流程，結尾自動復原

### 帳號管理（正式版；SQL 已在 Supabase 執行並通過 113 項驗證；網頁尚未用真實登入實測）

- 帳號管理頁（只有客服部）｜`accounts.html`、`js/accounts-api.js`｜列出帳號（信箱、角色、門市、對應員工），新增、編輯、移除（二次確認）；護欄由資料庫把關，訊息直接顯示；底部操作紀錄（新到舊、每次 50 筆、載入更多、只增不改）
- 導覽「帳號管理」｜`roster.html`、`assess.html`、`backoffice.html`｜導覽分頁，只有客服部看得到
- 職級「其他（自行輸入）」｜`roster.html`｜新增／編輯人員可自訂職級（必填、最長 20 字）；輸入框失焦或送出時，若恰好等於標準八種職稱（含技師、公務機）就改用標準職級並套用納入考核預設；編輯時職級不在六種內自動選「其他」
- 編輯帳號的保護｜`accounts.html`｜原門市不在清單、或找不到對應員編時，保留原值並提示，不會悄悄改掉

### 帳號管理（樣品，已被正式版取代）

- 帳號管理樣品（假資料）｜`樣品/accounts.html`｜客服部新增、編輯、移除帳號；護欄：不能移除或降級自己、至少留一位客服部、信箱只收 @2motor.tw、店長須選門市；操作紀錄只增不改；有「只剩一位客服部」示範開關
- 職級「其他（自行輸入）」樣品｜`樣品/roster.html`｜新增／編輯人員時可自行輸入職級（必填、最長 20 字）；輸入標準職稱會自動改用標準職級
- 護欄與操作紀錄（已在 Supabase 執行，113 項驗證通過，由正式版採用）｜`supabase/accounts_schema.sql`、`supabase/accounts_verify_fake.sql`、`supabase/README_accounts.md`｜最後一位客服部不能被刪除或降級、不能移除或降級自己（含改自己信箱）、信箱網域檢查、操作紀錄表 app_users_audit 只增不改；在 SQL Editor 操作時護欄 1、2 不啟動（緊急修復用）；驗證腳本結尾自動復原

### 樣品與設計稿

- 進行考核樣品（假資料）｜`樣品/assess.html`｜登入後依序選考生（到職日空白須手動選新人／正式）→ 抽題 → 七面向評分（不適用每題組最多 2 個）→ 結算 → 送出；兩題組 77.5 與 100.0 平均顯示 88.8；評分時隨時可看目前題組的步驟與考點（桌機左側常駐面板、手機右下角「看腳本」浮動鈕開面板，開關不影響評分進度）；暫存提示不顯示時間
- 成績單樣品（假資料；樣品當時的規則，備註文字尚不給主管與店長，正式版已改為可看）｜`樣品/reports.html`｜客服部看到題組名稱、步驟、考點、備註並可作廢；主管與店長只看到已送出未作廢的精簡版（含備註附圖）
- 考官備註附圖（樣品）｜`樣品/assess.html`｜評分時在備註區 Ctrl+V 貼圖、拖曳或選檔（手機可拍照）；每題組最多 5 張、只收 png／jpeg／webp、自動縮到最長邊 1600px；可移除、點開放大；提醒文字說明主管與該門市店長也看得到圖片
- 備註附圖儲存設計（尚未執行）｜`supabase/assess_schema.sql`｜私有 bucket assess-notes（每張 2MB 內）；客服部可上傳刪除（僅草稿）；主管看已送出的圖、店長看自己門市已送出的圖
- 樣品名冊頁導覽｜`樣品/roster.html`｜右上角多了「進行考核」與「成績單」連結

- 評分計算模組｜`js/scoring.js`｜`node tests/scoring.test.js` 印出「通過 N 項」且結束碼 0；範例（良優良待加強優良優）題組分數 77.5
- 考核資料庫設計稿｜`supabase/assess_schema.sql`、`supabase/assess_verify_fake.sql`｜**尚未在 Supabase 執行**；在 SQL Editor 先執行 schema，再執行 verify（交易內執行並復原），結果表全部通過；說明見 `supabase/README_assess.md`

## 弱項建議題組（網頁已寫好，尚未連真實資料庫；需先執行 supabase/weak_suggest_schema.sql，規格見 supabase/README_weak_suggest.md）

- 題組標記重點面向｜`questions.html`、`js/questions-api.js`｜新增／編輯題組表單勾選 1～3 個面向（只有 5 個：資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識；語氣與禮貌、文字品質不用勾）；儲存題組後呼叫 bank_set_dims（失敗只提示、題組已存）；列表每題組顯示面向標籤或「未標記」，統計多一格「已標記／總題組數」
- 弱項與建議題組面板（已由「弱項追加題」取代，面板已從考核流程拿掉；下次建議考題預告保留）｜`assess.html`、`js/suggest.js`、`js/assess-api.js`｜原本選考生後依歷史成績建議題組；第一期改成固定 3 題組＋評完後的弱項追加題（見「第一期」一節），`js/suggest.js` 選題函式與 `weakProfile`／`suggestPool`／`pick` 封裝仍保留給追加題與結果頁預告使用
- 下次建議考題預告｜`assess.html`｜送出成功的結果頁多一區「下次建議考題」（最新弱項 3 題，僅預覽）；沒有弱項或載入失敗就不顯示
- 選題函式測試｜`js/suggest.js`、`tests/suggest.test.js`｜`node tests/suggest.test.js` 印出「通過 97 項」且結束碼 0（涵蓋無弱項、1／2 個弱項、題數 2／3／4、標記不足補隨機、考過不選、drawn 優先、全部考過才 repeated、swap、預設同分類最多一題、語氣與文字不進弱項；新增 `opts.allowSameCategory` 允許同分類的追加題選題與換題）

## 待考回報（網頁已寫好，尚未連真實資料庫；需先執行 supabase/exam_request_schema.sql 並設定寄信，規格見 supabase/README_exam_request.md）

- 待考回報頁｜`requests.html`、`js/requests-api.js`｜所有已開通角色可進；店長看到回報表單（情況、人員依情況載入、希望日期 1～3 個不早於今天、新人才顯示影片勾選整句紅字、備註 500 字）、「我的回報」清單、開頁時顯示未看過的客服部回覆（已排定／退回）並呼叫 exam_req_mark_seen、待處理可撤回；客服部看到待考回報清單（門市與狀態篩選、排定日期時間、重新排定、退回原因必填、已排定者「開始考核」連到 assess.html）、寄信紀錄（「更新寄信狀態」）、信件預覽，並可代為回報（表單多一個門市選擇）；總公司主管唯讀（沒有表單與任何按鈕）；寫入全走 RPC（exam_req_create／withdraw／schedule／return／mark_seen、mail_outbox_sync），不直接寫資料表
- 待考回報前端驗證與純函式｜`js/requests-core.js`、`tests/requests-core.test.js`｜`node tests/requests-core.test.js` 印出「通過 94 項」且結束碼 0（日期 1～3 個／不重複／不早於台北今天、新人影片規則、備註 500 字、台北時間 datetime-local 與 ISO 互轉、排定時間不早於現在往前 1 小時、已回報標記與排序）
- 導覽「待考回報」｜`roster.html`、`assess.html`、`backoffice.html`、`questions.html`、`accounts.html`、`spotcheck.html`、`requests.html`｜所有已開通角色看得到，在「考核後台」之後、「抽查」之前
- 導覽紅點｜`js/appbar.js`、`app.css`｜登入後呼叫 exam_req_badge()，大於 0 時在「待考回報」分頁文字旁顯示紅色數字（超過 99 顯示 99+）；只從 localStorage 讀目前 session 的 access_token（sb-專案代號-auth-token），建不存 session、不換 token、不監聽登入的 client 以 Authorization 標頭呼叫，絕不 refresh、不寫 storage；讀不到 token、JSON 壞掉、token 過期或任何失敗都安靜忽略；登入頁不載入；requests.html 做完動作會呼叫 window.AppBadge.refresh() 重抓
- 選考生標記「已回報待考」｜`assess.html`、`js/assess-api.js`｜進行考核步驟 1 的清單，已有待處理／已排定回報的人排最前面並顯示黃底「已回報待考」（已排定者附排定時間）；讀取 exam_requests 失敗就照原樣，不擋考核
- 已輔導後自動跳轉待考回報並預填（尚未連真實資料庫；需先執行 supabase/coached_reminder_schema.sql，說明見 supabase/README_exam_request.md 第六節）｜`backoffice.html`、`requests.html`、`js/coached-core.js`、`js/backoffice-api.js`、`js/requests-api.js`｜店長在考核後台改善單第一次按「回填已輔導」儲存成功，直接跳到 `requests.html?from_ticket=單號`，人員與情況（需複訓→複檢；不及格且在考核期→回考核期；其他留空）【2026-11 更新：回考核期已停用，不再預填，只剩需複訓→複檢】已預填並顯示「由改善單帶入」；非本店單號、亂寫參數、已約考的單一律忽略；編輯既有輔導紀錄不跳轉。驗證：`node tests/coached-core.test.js` 印出「通過 75 項」；資料庫驗證 `coached_reminder_verify_fake.sql` 第一列「77/77 項通過」
- 尚未約考三處提醒｜`backoffice.html`（改善單黃色「尚未約考」標籤＋店長與客服部的「前往預約」按鈕）、`requests.html`（店長頂部黃色提醒條「○○ 已輔導完成，記得預約考核」＋「一鍵帶入」）、`js/appbar.js`（待考回報紅點＝`exam_req_badge()`＋`coached_pending_count()`，店長才會加；客服部、主管不變）｜驗證：假環境走一輪，沒送出時標籤、黃條、紅點都在，送出後消失（`coached_pending()` 資料庫函式依身分過濾）
- 尚未約考提醒信（每兩天一封）｜`supabase/coached_reminder_schema.sql`（`coached_reminder_run()`、pg_cron 排程 `coached_reminder_daily`、改善單新增 `last_reminded_at`／`reminder_count`）、`supabase/coached_reminder_verify_fake.sql`｜按「已輔導」後第 2 天起每 2 天一封給該門市店長，台北時間 09:00；店長送出待考回報或改善單作廢／結案即停止；信件記在 `mail_outbox`（kind=coached_reminder），客服部在「寄信紀錄」看得到。驗證：SQL Editor 執行 `select public.coached_reminder_run();` 回傳整數（本次寫入的封數）

## 名冊加技師、公務機與官方 LINE 回覆權限（網頁已寫好，尚未連真實資料庫；需先依 supabase/README_roster.md「LINE 權限與新類別」備份並執行 roster_line_schema.sql）

- 技師、公務機類別｜`roster.html`、`js/line-core.js`｜新增人員選職級「技師」或「公務機」：納入考核預設否、回覆狀態預設已上線；列表職級顯示有色標籤，納入考核欄顯示「否（免健檢）」；員編公務機用 OF-0000（也接受 MI／PT）
- 技師、公務機自動排除各名單｜`supabase/*.sql`（皆靠 `include_in_assessment`）、`supabase/roster_line_verify_fake.sql`｜驗證腳本區段 F：考核名單、抽查名單、待考回報候選、健檢資格都排除（即使被誤設成考核期）
- 官方 LINE 回覆權限欄與篩選｜`roster.html`｜名冊多一欄：部分權限顯示一個個標籤、12 個全有顯示黑底「全部 12 個 LINE」、沒有顯示「—」；工具列多「類別」「LINE」「在職狀態（預設只看在職）」三個篩選
- 客服部編輯 LINE 權限｜`roster.html`、`js/api.js`｜新增／編輯人員視窗有 12 個勾選框，存檔呼叫 `roster_set_line_access`（整批成功或不變）；LINE 權限沒改就不呼叫；主管與店長唯讀，店長只看到自己門市人員的 LINE 權限
- LINE 權限資料庫｜`supabase/roster_line_schema.sql`、`supabase/roster_line_verify_fake.sql`｜新表 line_accounts（12 個）、line_access；員編約束放寬；驗證腳本結尾自動復原，結果表最後一個查詢顯示
- LINE 純函式測試｜`js/line-core.js`、`tests/line-core.test.js`｜`node tests/line-core.test.js` 印出「通過 58 項」且結束碼 0
- LINE 權限匯入產生器｜`supabase/import/gen_line_import.js`｜依賴 exceljs 與本機規則檔 line_rules.local.json；執行後產生 import_line.local.sql（含個資，不進倉庫），終端機只印數量彙總

## 階段 1 資料庫設計稿（尚未執行）

- 三張表與權限規則｜`supabase/roster_schema.sql`｜待老闆同意後在 Supabase 執行；驗證步驟見 `supabase/README_roster.md`
- 假資料｜`supabase/roster_seed_fake.sql`｜測試用，不含任何真實人員

## 第一期：考核期、固定 3 題組、弱項追加題、待開通（網頁已寫好，尚未連真實資料庫；需先執行 supabase/phase1_schema.sql，規格見 supabase/README_phase1.md）

- 固定 3 題組｜`assess.html`、`js/assess-api.js`｜選考生按「準備考核・去抽題」後自動呼叫 assess_core_categories 取得核心分類，再用 assess_draw 一次抽齊（每分類 1 題）並直接進評分，不再顯示「弱項與建議題組」面板；步驟列為「固定 3 題組／評分／弱項追加題／送出結果」；若抽題失敗（例如題庫缺題）顯示錯誤並可按「改用自選分類」回到舊的選分類流程；繼續草稿時已有題就直接進評分、沒題就自動抽核心題組
- 弱項追加題｜`assess.html`、`js/suggest.js`、`js/assess-api.js`｜核心題組評完才出現「分析弱項」（先暫存評分再呼叫 assess_draft_weak）；有弱項顯示面向與得分率、語氣／文字偏低提醒、建議追加題（Suggest 選題，允許同分類，題數預設 2、可選 1～4，可換一題，題庫不足有提示，已在核心題組內的題不會被選到）與「追加弱項題」「不追加，直接送出」；沒有弱項只顯示「沒有明顯弱項，可直接送出」；按「追加弱項題」呼叫 assess_add_extra 後回評分畫面，追加題標示「追加題・不算總分」並顯示追加開始時間（只顯示時間）；追加題沒評完不能前往結算與送出
- 送出結果頁（第一期）｜`assess.html`｜總分、判定、題組數只看核心題組；追加題另列「弱項追加題・不算入總分」；送出後讀 reply_activations 與 period_status：有待開通紀錄顯示「已加入待開通回覆權限清單」，仍在考核期顯示「仍在考核期，可再約補考」；回考核期者合格線 85 的顯示照舊
- 成績單追加題區塊｜`backoffice.html`（近期考核分頁）、`js/recent-reports.js`、`js/assess-api.js`｜成績單詳情（客服部版與主管／店長版）追加題獨立區塊「弱項追加題・不算入總分」；雷達圖與題組列表只用核心題組；主管與店長版追加題不含題組名稱、步驟、考點
- 待開通回覆權限清單｜`requests.html`、`js/requests-api.js`｜只有客服部看得到；讀 reply_activations（人員、門市、通過日期、狀態），可依門市與狀態篩選，待開通排前面；「已開通」按鈕（先跳確認視窗）呼叫 activation_mark_done，已開通者顯示開通日期；清單讀取失敗只在該區塊提示；導覽紅點由 exam_req_badge 提供
- 考核期與新人標籤｜`roster.html`｜身分標籤依 employees_with_tenure 的 period_status 與 tenure_group：考核期者顯示「考核期」，到職 90 天內另顯示「新人」，其餘顯示「已上線」，未填到職日者另加「未填到職日」；既有門市篩選與搜尋不變；標籤判斷只看 period_status（資料庫遷移與 spot_register 回考核期都會同步，不再看 probation_since）
- 名冊「回覆狀態」欄位｜`roster.html`｜新增／編輯人員表單多「回覆狀態」下拉（考核期／已上線），只有客服部看得到；新增預設考核期（資料庫預設是已上線，所以新增時一定明確帶 period_status），編輯顯示目前值並可手動調整，存檔寫入 period_status，不動 passed_on；`js/api.js` 直接傳入整列，不需改
- 第一期網頁驗證方式｜以 jsdom 搭配假的 Api 物件逐項驗證（有弱項／無弱項／不追加／追加題未評完不能送出／核心抽題失敗改自選／繼續草稿／放棄／通過與未通過結果頁／成績單追加題區塊／待開通清單／名冊標籤）；`node tests/suggest.test.js`、`tests/scoring.test.js`、`tests/requests-core.test.js` 皆結束碼 0

## 第二期：每年健檢（網頁已寫好，尚未連真實資料庫；需先執行 supabase/checkup_schema.sql，規格見 supabase/README_checkup.md）

- 健檢頁｜`checkup.html`、`js/checkup-api.js`、`js/checkup-core.js`｜導覽列「登記&健檢」（現為四分頁之後兩個，見文末「登記&健檢整併」）；兩個頁籤：門市季次表（客服部可改 Q1～Q4，主管與店長唯讀，頂端四季統計即時更新）、健檢名單【已停用 2026-11：改為「健檢單」分頁，見文末「健檢單」；原功能——狀態待排定／已排定／已完成、首次健檢標籤、客服部排定／取消排定／開始／繼續健檢、已完成者查看建議單——介面已拿掉，資料庫函式 checkup_roster／checkup_schedule／checkup_unschedule 與歷史資料保留】；頁內有「抽查（黃單／紅單）」連結｜`node tests/checkup-core.test.js` 通過 77 項；開頁看兩個頁籤
- 導覽列抽查換健檢｜各頁 html 的 `ab-tab`｜導覽列指向抽查的分頁改為「登記&健檢」（現指向 spotcheck.html）｜任一頁導覽列顯示「登記&健檢」且不再有「抽查」
- 健檢考試流程【已停用 2026-11：入口（健檢名單的「開始健檢」）已拿掉，頁面與資料庫函式保留，歷史成績單照常可看】｜`assess.html?mode=checkup&emp=<員編>&year=<年>&quarter=<季>`、`js/assess-api.js`、`js/assess-checkup-core.js`｜客服部由健檢名單進入，沿用現有核心 3 題組抽題與評分，身分正式、及格線 85；結果頁顯示總分、判定、「健檢結果只記錄在建議單」，連結建議單與健檢名單；非客服部只看到提示；一般考核流程不變｜`node tests/assess-checkup-core.test.js` 通過 37 項
- 一般考核草稿標示健檢｜`assess.html`｜進行中草稿含健檢者顯示「健檢 年 季」標籤，「繼續」連到健檢網址｜開一般考核頁，有健檢草稿時見標籤
- 建議單｜`advice.html?assessment=<成績單 id>`、`js/advice-api.js`、`js/advice-core.js`、`js/advice-pdf.js`｜A4 一頁：考生資料、總分與判定（及格線 85）、七面向雷達圖（本次實線、上一次健檢虛線）、各面向得分率與差異、與上一次比較、歷年健檢走勢；首次健檢顯示「首次健檢，沒有上一次可比較」；「下載 PDF」直接下載（檔名 建議單_姓名_健檢日期.pdf）；客服部、主管、該店店長可看｜`node tests/advice-core.test.js` 通過 93 項；開頁按下載 PDF 為 1 頁
- 成績單列表標示健檢｜`backoffice.html`（近期考核分頁與歷次成績單）、`js/recent-reports.js`、`js/backoffice-api.js`｜歷次成績單與成績單列表的健檢列顯示「健檢 年 Qn」標籤，操作改為「建議單」連結（一般考核列不變）；結案複檢候選排除健檢；成績單 PDF 的上一次與走勢只含一般考核｜開考核後台歷次成績單，健檢列有標籤與建議單連結
- 健檢資料庫｜`supabase/checkup_schema.sql`、`supabase/checkup_verify_fake.sql`｜門市季次表（種子 Q1 中和、新莊、樹林；Q2 桃園中壢、新竹、花蓮；Q3 旗艦、南台中、太平；Q4 台南、高雄）、健檢排定表、成績單分「考核／健檢」；健檢送出不動考核期、通過日、待開通、不開改善單；兩張新表不開直接讀取｜假環境驗證 250/250，既有各支驗證全過

## 成績單併入考核後台（網頁已寫好；沒有資料庫改動，不需執行新 SQL；真實登入後的讀取尚未實測）

- 近期考核分頁｜`backoffice.html#recent`、`js/recent-reports.js`、`js/recent-reports-core.js`、`tests/recent-reports-core.test.js`｜考核後台新增第一個、也是預設的分頁「近期考核」（原成績單頁全部功能）：搜尋考生（編號、姓名、暱稱）、篩選（門市、日期區間含起訖當天、判定、類型＝一般考核／健檢）、預設最近 20 筆新到舊、「載入更多」每次再 20 筆、計數「顯示 N / 共 M 筆」；點整列開成績單詳情（客服部完整版可作廢、主管與店長精簡版）；健檢列顯示「健檢 年 Qn」標籤與「建議單」連結；草稿與作廢、手動指定、考核期標籤規則同原成績單頁；操作欄固定在右側；詳情視窗點視窗外空白處可關閉｜`node tests/recent-reports-core.test.js` 通過 73 項；開 `backoffice.html` 預設停在「近期考核」
- 舊網址 reports.html 轉址｜`reports.html`｜極簡轉址頁，用 location.replace 轉到 `backoffice.html` ＋原網址參數 ＋ `#recent`；不載入 Supabase、不顯示導覽列｜開 `reports.html` 會跳到 `backoffice.html#recent`
- 近期考核與原分頁共用同一個 Supabase client｜`js/assess-api.js`、`js/backoffice-api.js`｜兩檔都改成先看 `window.__sbSharedClient` 有沒有，沒有才建立（只載入其中一檔的頁面行為不變）；近期考核沿用 AssessApi 的 loadSummaries、loadItemsFull、loadItemsLimited、voidReport、signedUrl｜開 `backoffice.html` 登入事件不重複、沒有 Multiple GoTrueClient 警告

## 版面升級（貳輪嶼 CI）

- 共用版面與配色｜`app.css`、`js/appbar.js`、`img/*`｜6 個頁面頁首為黑底導覽列＋黑色標題橫幅，CI 色黑藍黃白；開 `roster.html` 登入後見黑底導覽、選中分頁黃底、頭像為信箱首字
- 登入頁 LOGO｜`index.html`｜登入卡片頂部顯示貳輪嶼 LOGO，登入鈕黑底
- 雷達圖（七面向得分率）｜`js/radar.js`、`backoffice.html`（近期考核的成績單詳情，客服部與主管/店長版都有；以及人員歷史）、`js/recent-reports.js`｜開一張成績單，標頭下方出現七面向雷達圖、最弱面向橘色，下方表格仍在；人員歷史的「七面向平均得分率」也是雷達圖
- 名冊姓名連結｜`roster.html`、`backoffice.html`｜點名冊裡的姓名／暱稱，會跳到考核後台並直接打開那位同仁的歷史成績；沒有考核資料的人（離職或未納入考核且無成績單）顯示提示
- PDF 走勢圖標籤避讓｜`js/report-pdf-core.js`（trendLabelLayout）、`js/report-pdf.js`、`js/advice-pdf.js`、`tests/report-pdf-core.test.js`｜成績單與建議單 PDF 的走勢折線圖：合格線文字與分數／判定標籤自動避開彼此、折線與圓點（例：74.5 夾在 85 與 70 兩線間、81.5 貼近 85）；跑 `node tests/report-pdf-core.test.js` 全過

- 名冊表格版面調整（2026-11-11）：到職日欄不在表格顯示（編輯視窗仍可填、仍存資料庫，新人／正式標籤照常）；操作欄固定在右側；LINE 標籤改深藍外框｜`roster.html`｜客服部登入名冊：表格無到職日欄、窄螢幕也不用左右拖就看到「編輯」

### 抽查登記改版（勾可改善面向＋截圖＋說明；網頁與資料庫腳本已寫好，尚未在真實 Supabase 執行；老闆已核可樣品 健檢改版樣品 A 分頁）

- 抽查登記改版｜`spotcheck.html`（登記區）、`js/spotdims-core.js`、`js/spotcheck-api.js`、`supabase/spotdims_schema.sql`｜七面向打分拿掉，改成可改善面向（七選多，0～7 個，優良回覆也能勾）＋截圖（可多張，選檔／貼上／拖曳，縮圖後上傳）＋一句說明（選填）；判定與黃單規則不變（紅單／回考核期已於 2026-11 停用，見文末「停用紅單與回考核期」）；LINE 網址仍必填、待加強回覆原因仍必填；按登記時鎖住按鈕、同一個抽查 id 只能登記一次（擋重複送出）；驗證：`node tests/spotdims-core.test.js` 通過 50 項、`supabase/spotdims_verify_fake.sql`（結尾復原）第一列「112/112 項通過」
- 判定顯示改名（共用對照）｜`js/spotdims-core.js` 的 `verdictLabel`｜畫面「適當→優良回覆、不適當→待加強回覆」；資料庫存的判定值仍是適當／不適當，不改不遷移；驗證：`node tests/spotdims-core.test.js`
- 抽查紀錄表（含優良回覆）與黃單列顯示面向／說明／截圖｜`spotcheck.html`（單據清單下方「抽查紀錄」）｜客服部、主管看全部，店長只看自己門市；可按門市與判定篩選；「查看截圖」開簽名網址視窗；舊紀錄照常顯示並標「舊制分數 N」；驗證：`supabase/spotdims_verify_fake.sql` 區段 4、5
- 舊抽查紀錄不動｜`supabase/spotdims_schema.sql`（levels、total_score 放寬為可空；舊 spot_register 原封不動）｜舊列內容 md5 在新登記前後相同；驗證：spotdims_verify_fake.sql 區段 4
- 抽查截圖儲存與權限｜`supabase/spotdims_schema.sql`（沿用私有 bucket assess-notes，路徑 spot/{抽查id}/{uuid}.jpg，新增 3 條 assess_spot_shots_* policy）｜讀：客服部、主管全部，店長只讀自己門市；傳：只有客服部且抽查尚未登記；刪：只有客服部且僅限孤兒檔；驗證：spotdims_verify_fake.sql 區段 5

### 登記&健檢整併（導覽改名與四分頁；純前端，不動資料庫）

- 導覽「登記&健檢」（原「健檢」）｜各頁 `ab-tab`，指向 `spotcheck.html`｜在 spotcheck.html 與 checkup.html 兩頁都亮黃底；375px 不爆版
- 四個膠囊分頁（登記、登記歷程、門市季次表、健檢單；第四個原名「健檢名單」，已改名）｜`spotcheck.html`（登記、抽查紀錄，頁內切換）、`checkup.html`（門市季次表、健檢名單）｜另一頁的分頁是連結；網址 #reg、#records、#stores、#list 直接開啟；客服部預設進登記，店長與主管沒有登記分頁、預設進抽查紀錄；舊的「抽查（黃單／紅單）」連結已拿掉
- 登記歷程分頁頂端「門市」下拉｜`spotcheck.html`｜同時篩選人員抽查狀態、單據清單、抽查紀錄三區塊（原三個區塊各自的門市下拉合併為這一個）；店長不顯示；其餘篩選、作廢、回填輔導、截圖、LINE 網址照舊（標記已執行、取消回考核期已於 2026-11 停用拿掉）
- 停用紅單與回考核期（老闆 2026-11 定案）｜`supabase/noredticket_schema.sql`、`spotcheck.html`、`js/spotcheck-api.js`、`js/spotdims-core.js`、`requests.html`、`js/requests-core.js`、`js/coached-core.js`｜黃單照開（待加強回覆）、可作廢、可回填輔導；不再有「滿 5 張黃單開紅單」「紅單滿 2 回考核期」「建議移除官方 LINE 權限」與「已執行／取消回考核期」；assess_start 不再依 probation_since 改身分、assess_submit 不再有「考核期成績單 >= 85 清除」；待考回報只剩「新人」「複檢」兩種情況（舊的「回考核期」回報仍可顯示）；資料表與欄位都保留｜驗證：`supabase/noredticket_verify_fake.sql`（PGlite 81/81）；網頁見 `tests/`
- 待考回報的「回考核期」情況｜`requests.html`、`js/requests-core.js`、`js/coached-core.js`｜【已停用 2026-11】不再提供選項，也不再預填；KIND_LABEL 保留「回考核期再考」只為舊紀錄顯示

### 健檢單（D 健檢改版第 2 段，2026-11；純前端，不動資料庫；尚未連真實 Supabase 實測）

- 健檢單清單｜`checkup.html#list`（第四個膠囊分頁「健檢單」，取代原「健檢名單」）、`js/checkup-sheet-core.js`、`js/checkup-api.js`（sheetInspections、signedUrl）、`tests/checkup-sheet-core.test.js`｜篩選：年度、季次（日曆季：Q1＝1–3 月…，以登記日 checked_on 計）、門市（店長固定自己門市、不顯示篩選）；列出該季有登記紀錄的業務，沒紀錄的不出現（畫面文字一律用「紀錄／登記」，不用「抽查」）；欄位：姓名與員編、門市、本季登記次數、待加強回覆次數、被勾最多的面向（並列全列）、下載 PDF；不另存，用 spot_inspections 該季資料現算，RLS 決定可見範圍｜`node tests/checkup-sheet-core.test.js`；客服部／主管看全部、店長只看自己門市
- 健檢單 PDF｜`js/checkup-sheet-pdf.js`（沿用成績單 PDF 的 html2canvas／jsPDF 載入與 layoutPages 分頁）、`js/checkup-sheet-core.js`、`js/spotdims-core.js`（DIM_SUBTITLE 七面向副標，單一處定義）｜A4：標題（姓名／門市／年度季）、登記次數與優良回覆／待加強回覆次數、季度健檢單（所有季都有，含第四季；第四季不再附年度頁）：單季星狀圖（面向分數＝1 − 被勾次數 ÷ 當季登記次數，整季沒被勾＝最外圈 100%、越需加強越往內縮；本季黃綠填色＋黑粗實線，上一季藍色虛線疊圖，圖例寫「對比：第N季」與各季紀錄筆數；第一季對比去年第四季；上季沒紀錄只畫實線並註明「上季無紀錄」；每個軸標籤＝粗體「面向（百分比）」＋灰色副標，過長自動折行；圖上加紅色虛線「60% 待加強線」；最強（≥85%，並列全列）面向標籤與點用綠色加「★ 本季強項」、最弱用紅色加「▲ 最需要加強」；圖不被裁切、沒有 tooltip）、本季小結（以色塊標籤「強項／進步／待加強／感謝」條列，需建議的列下方多一行「建議：…」；系統自動：進步或 ≥90% 的優秀面向鼓勵最多 3 個；分數最低最多 2 個不足面向給建議，≥90% 不算不足，建議句在 `DIM_ADVICE` 單一常數表，老闆確認文字後只改這張表；無括號、不提次數）、登記紀錄與截圖改成「登記截圖卡片」（老闆確認公版：風格 D1 淺灰）：每張卡片＝一筆登記的一張截圖，一筆有多張截圖時第 2、3 張做續卡（日期旁標 (2/3)，日期、判定、面向、說明重複）；沒有截圖的登記做一張沒有截圖框的小卡；卡片很淡的灰底（#F5F6F8，1px 極淡外框、分隔線 #E3E6EA）、左側 8px 粗色條（優良回覆綠、待加強回覆紅）貼合圓角，頁首列＝日期「11/13（五）」（星期依實際曆法）＋右上判定徽章（SVG 笑臉／驚嘆號，不用 emoji）、「可改善面向」小標＋只列被勾面向的七色膠囊（沒有就不顯示）、白色說明框（沒有說明不顯示，最多約 2 行、超過以「…」截斷）、截圖預設滿版橫式（寬度撐滿卡片可用寬度、高度依比例；過高的圖限制在框高內置中縮小，contain 不裁切不拉伸；圓角、細框、柔和陰影）、右下角「截圖 n/N」（單張只寫「截圖」）；一頁 2 張有截圖的卡片，單數張時最後一頁一張，卡片不會被切在兩頁中間；卡片配色集中在 core 的 CARD 常數、版面常數 CARD_H／CARD_GAP，分頁與資料組裝是 core 的 buildCards／paginateCards（有單測）；截圖用 storage 簽名網址（不改權限與 bucket），取不到的該卡顯示「截圖載入失敗」（第二行小字「可私訊客服部確認聊天室網址」），不中斷整份 PDF；登記紀錄從新的一頁開始；頁尾「本單由系統自動彙整，僅供改善參考，不計分」；上一季（年度檔另抓全年）紀錄用 `CheckupApi.sheetInspections` 再抓一次（不新增資料表、RLS 照舊）｜客服部、店長（限自己門市）、總公司主管都可下載；清單按「下載健檢單」（第四季那列是「下載季度健檢單」與「下載年度健檢單」兩顆按鈕，各自有下載中狀態與訊息）；季度按鈕只抓當季與上一季；`node tests/checkup-sheet-core.test.js`
- 年度健檢單（第四季才有，獨立一份 PDF）｜`js/checkup-sheet-pdf.js`（buildYearHtml、kind=year）、`js/checkup-sheet-core.js`（yearInsights、yearCards、totalSvg、lineChartSvg、yearTableModel、yearItems、fileNameYear、yearRange）、`checkup.html`（第四季列的「下載年度健檢單」按鈕）｜檔名「年度健檢單_姓名_年度.pdf」；內容照老闆設計圖：頁首（姓名　年度健檢單）、4 張摘要卡（全年強項＝最高且 ≥85% 並列全列、最需要加強＝全年最低、Q4 進步最多 ▲差距、Q4 需要留意 ▼差距；沒有符合者顯示「—」）、全年綜合星狀圖（60% 紅虛線；最強綠 ★ 全年強項、最弱紅 ▲ 最需要加強；副標單行過長以「…」截斷）、各面向四季折線圖（預設「重點三條」彩色＝全年最低紅、Q4 進步最多藍、Q4 退步最多金，同一面向不重複、重複者改取次要者，其餘四條灰色細線，線尾標籤防重疊並保留引線，約 78% 寬置中；下方膠囊圖例）、全年數值表（≥85% 淡綠底、<60% 淡紅底紅字、與上一季差距 ≥10 在格內標 ▲▼ 數字，Q1 不標，面向名稱下有副標，最後一欄「全年綜合」，表下圖例說明）、年度分析（色塊標籤＋文字：感謝／強項／待加強／進步／留意；需建議的列下方灰字「建議：…」，建議取自 DIM_ADVICE；沒有退步或進步就不產生該列）；年度檔不含當季登記紀錄與截圖；年度資料（當年 1/1～12/31，依員編，沒有紀錄的季不畫點）只在按年度按鈕時才抓；配色與門檻集中在 core 的 COLORS、STRONG_MIN(85%)、WEAK_LINE(60%)、DIFF_MIN(10)｜`node tests/checkup-sheet-core.test.js`；第四季那列按兩顆按鈕各下載一份，確認季度檔沒有年度頁、年度檔沒有登記紀錄
- 舊成績型健檢介面停用｜`checkup.html`｜【已停用】排定、取消排定、開始／繼續健檢、分數與判定、待排定／首次健檢標籤；assess.html 的健檢模式、advice.html、checkup_* 資料表與函式、歷史成績單（近期考核等處）全部保留不動｜開 checkup.html 不再有上述按鈕與欄位；門市季次表分頁原樣
- 寄給業務（副本店長）【暫緩，未做】｜—｜老闆尚未決定業務信箱來源與副本做法；本次沒有寄信按鈕、checkup_sheet_sends 表、mail_outbox 寫入｜—
