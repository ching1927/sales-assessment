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

### 正式版（已執行 SQL、已審查；客服部流程已用測試考生實測通過，店長與主管的真實登入尚未測）

- 進行考核（只有客服部）｜`assess.html`｜選考生（可依門市下拉篩選，只列有人的門市並顯示人數，選擇記在 sessionStorage；每位考生那列按「準備考核・去抽題」直接開始，到職日空白則就地展開「新人／正式」兩鍵）→ 抽題 → 七面向評分並自動暫存 → 結算（以資料庫計算為準，與預覽不一致會警告）→ 送出；可接續草稿、放棄考核
- 備註附圖（正式版）｜`assess.html`、`js/assess-api.js`｜貼上、拖曳、選檔；上傳到私有 bucket assess-notes；每題組最多 5 張；顯示用簽名網址
- 成績單（所有已開通角色）｜`reports.html`｜客服部看完整內容並可作廢；主管看已送出的精簡版；店長只看自己門市已送出的精簡版；精簡版含附圖，不含備註文字、題組名稱、步驟、考點
- 導覽統一（現含 `backoffice.html`、`accounts.html`，導覽已加入「考核後台」）｜`roster.html`、`assess.html`、`reports.html`｜頁首「進行考核」（只有客服部，實心藍膠囊）、「成績單」「人員名冊」（淡藍膠囊）、登出（灰色小字）；身分資訊（信箱與角色標籤，灰色邊框方塊）與導覽之間有分隔線，手機上導覽自成一行；名冊頁標題為「貳輪嶼官方LINE訊息回覆人員名冊」；客服部另有「帳號管理」淡藍膠囊（accounts.html 頁首導覽同款）

### 題庫管理（正式版寫好、已審查；需先在 Supabase 執行 bank_schema.sql；尚未用真實登入實測）

- 題庫管理頁（只有客服部）｜`questions.html`、`js/questions-api.js`｜取代舊管理頁，Google 登入；讀寫呼叫 bank_list_questions／bank_save_question／bank_delete_question／bank_rename_category／bank_reset 與 assess_categories；功能對應舊管理頁（分類下拉、統計、題組列表、新增編輯與步驟編輯器、草稿保留、刪除與洗牌二次確認、分類改名與合併）；題庫內容不寫入 console 或瀏覽器儲存；載入失敗時停用表單與洗牌
- 導覽「題庫管理」｜`roster.html`、`assess.html`、`reports.html`、`accounts.html`、`backoffice.html`｜只有客服部看得到，放在「帳號管理」之後

### 題庫管理（樣品與設計稿）

- 題庫管理樣品（假資料）｜`樣品/questions.html`｜完整對應舊管理頁：分類下拉（含「全部分類」與特殊名稱）、統計小卡、收合列表與步驟展開、新增與編輯題組（步驟編輯器 1～30、上下移）、草稿保留、刪除二次確認（4 秒還原）、分類改名與合併、洗牌（單一與全部，二次確認）；底部註明題庫內容含考點只有客服部可見
- 題庫管理設計稿｜`supabase/bank_schema.sql`、`bank_verify_fake.sql`、`README_bank.md`｜bank_list_questions／bank_save_question／bank_delete_question／bank_rename_category／bank_reset，只有客服部能呼叫，行為與舊 admin_* 函式一致，與抽題共用 advisory lock（寫入函式）；驗證腳本結尾自動復原
- 停用舊抽選器腳本（單獨、可還原、尚未執行）｜`supabase/bank_retire_legacy.sql`｜收回 anon 對 8 個舊函式的 execute，不刪函式與資料；開頭防護：有其他物件引用舊函式就中止；還原段在註解內

### 考核後台（正式版；SQL 已在 Supabase 執行，161 項驗證通過；網頁尚未用真實登入實測）

- 考核後台頁｜`backoffice.html`、`js/backoffice-api.js`｜所有已開通角色可進；三個分頁「人員歷史」「弱項分析」「改善單」，網址 #history、#insights、#tickets；資料皆讀資料庫（不查機密表）；改善單動作呼叫 improve_update_plan／improve_close／improve_cancel（客服部）、improve_mark_coached（店長自己門市或客服部）；主管只讀；已取消單只有客服部看得到；主管與店長視角的改善單紀錄不顯示他人信箱（頁首仍顯示自己的信箱）
- 導覽「考核後台」｜`roster.html`、`assess.html`、`reports.html`、`accounts.html`｜所有已開通角色看得到；順序：進行考核（客服部）、成績單、考核後台、人員名冊、帳號管理（客服部）
- 自動開單與自動取消｜資料庫觸發器（backoffice_schema.sql）｜成績單送出且判定需複訓或不及格時自動開單（期限 14 天）；成績單作廢時 open／coached 的單自動取消；**上線後要用真實流程送一張不及格成績單驗證**

### 考核後台（樣品與設計稿，已被正式版取代）

- 考核後台樣品（假資料）｜`樣品/backoffice.html`｜三個分頁「人員歷史」（列表、走勢圖、七面向平均、歷次成績單）、「弱項分析」（全公司或單一門市、最近 3 次或全部、門市×面向熱度表）、「改善單」（狀態與門市篩選；客服部編輯面向與期限、結案需複檢成績單、取消；店長回填已輔導，備註必填不限字數；主管只讀）；右上角可切換身分示範
- 改善單與分析設計稿｜`supabase/backoffice_schema.sql`、`supabase/backoffice_verify_fake.sql`、`supabase/README_backoffice.md`｜成績單送出且判定需複訓或不及格時自動開單（預設 14 天）；成績單作廢時 open／coached 的單自動取消；improve_update_plan／improve_mark_coached／improve_close／improve_cancel；improvement_ticket_view、analytics_dim_rates；驗證腳本含真實 assess_submit／assess_void 流程，結尾自動復原

### 帳號管理（正式版；SQL 已在 Supabase 執行並通過 113 項驗證；網頁尚未用真實登入實測）

- 帳號管理頁（只有客服部）｜`accounts.html`、`js/accounts-api.js`｜列出帳號（信箱、角色、門市、對應員工），新增、編輯、移除（二次確認）；護欄由資料庫把關，訊息直接顯示；底部操作紀錄（新到舊、每次 50 筆、載入更多、只增不改）
- 導覽「帳號管理」｜`roster.html`、`assess.html`、`reports.html`｜淡藍膠囊，只有客服部看得到
- 職級「其他（自行輸入）」｜`roster.html`｜新增／編輯人員可自訂職級（必填、最長 20 字）；輸入框失焦或送出時，若恰好等於標準六種職稱就改用標準職級並套用納入考核預設；編輯時職級不在六種內自動選「其他」
- 編輯帳號的保護｜`accounts.html`｜原門市不在清單、或找不到對應員編時，保留原值並提示，不會悄悄改掉

### 帳號管理（樣品，已被正式版取代）

- 帳號管理樣品（假資料）｜`樣品/accounts.html`｜客服部新增、編輯、移除帳號；護欄：不能移除或降級自己、至少留一位客服部、信箱只收 @2motor.tw、店長須選門市；操作紀錄只增不改；有「只剩一位客服部」示範開關
- 職級「其他（自行輸入）」樣品｜`樣品/roster.html`｜新增／編輯人員時可自行輸入職級（必填、最長 20 字）；輸入標準職稱會自動改用標準職級
- 護欄與操作紀錄（已在 Supabase 執行，113 項驗證通過，由正式版採用）｜`supabase/accounts_schema.sql`、`supabase/accounts_verify_fake.sql`、`supabase/README_accounts.md`｜最後一位客服部不能被刪除或降級、不能移除或降級自己（含改自己信箱）、信箱網域檢查、操作紀錄表 app_users_audit 只增不改；在 SQL Editor 操作時護欄 1、2 不啟動（緊急修復用）；驗證腳本結尾自動復原

### 樣品與設計稿

- 進行考核樣品（假資料）｜`樣品/assess.html`｜登入後依序選考生（到職日空白須手動選新人／正式）→ 抽題 → 七面向評分（不適用每題組最多 2 個）→ 結算 → 送出；兩題組 77.5 與 100.0 平均顯示 88.8；評分時隨時可看目前題組的步驟與考點（桌機左側常駐面板、手機右下角「看腳本」浮動鈕開面板，開關不影響評分進度）；暫存提示不顯示時間
- 成績單樣品（假資料）｜`樣品/reports.html`｜客服部看到題組名稱、步驟、考點、備註並可作廢；主管與店長只看到已送出未作廢的精簡版（含備註附圖），頁面內完全沒有題組名稱、步驟、考點、備註文字
- 考官備註附圖（樣品）｜`樣品/assess.html`｜評分時在備註區 Ctrl+V 貼圖、拖曳或選檔（手機可拍照）；每題組最多 5 張、只收 png／jpeg／webp、自動縮到最長邊 1600px；可移除、點開放大；提醒文字說明主管與該門市店長也看得到圖片
- 備註附圖儲存設計（尚未執行）｜`supabase/assess_schema.sql`｜私有 bucket assess-notes（每張 2MB 內）；客服部可上傳刪除（僅草稿）；主管看已送出的圖、店長看自己門市已送出的圖
- 樣品名冊頁導覽｜`樣品/roster.html`｜右上角多了「進行考核」與「成績單」連結

- 評分計算模組｜`js/scoring.js`｜`node tests/scoring.test.js` 印出「通過 N 項」且結束碼 0；範例（良優良待加強優良優）題組分數 77.5
- 考核資料庫設計稿｜`supabase/assess_schema.sql`、`supabase/assess_verify_fake.sql`｜**尚未在 Supabase 執行**；在 SQL Editor 先執行 schema，再執行 verify（交易內執行並復原），結果表全部通過；說明見 `supabase/README_assess.md`

## 階段 1 資料庫設計稿（尚未執行）

- 三張表與權限規則｜`supabase/roster_schema.sql`｜待老闆同意後在 Supabase 執行；驗證步驟見 `supabase/README_roster.md`
- 假資料｜`supabase/roster_seed_fake.sql`｜測試用，不含任何真實人員
