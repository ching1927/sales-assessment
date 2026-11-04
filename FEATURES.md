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

- 進行考核（只有客服部）｜`assess.html`｜選考生（可依門市下拉篩選，只列有人的門市並顯示人數，選擇記在 sessionStorage；每位考生那列按「準備考核・去抽題」直接開始，到職日空白則就地展開「新人／正式」兩鍵）→ 自動抽固定核心題組（失敗可改自選分類）→ 七面向評分並自動暫存 → 核心評完分析弱項、可追加弱項題（弱項分析失敗可重試或略過直接送出）→ 結算（以資料庫計算為準，與預覽不一致會警告）→ 送出；可接續草稿、放棄考核
- 考官備註文字對主管與店長可見｜`supabase/notes_visible_schema.sql`、`supabase/notes_visible_verify_fake.sql`（驗證，結尾自動復原）、`supabase/README_notes_visible.md`、`assess.html`、`reports.html`、`js/assess-api.js`｜備註改存 assessment_items.note（舊 secrets.note 停用並清空）；客服部、主管、同門市店長讀得到（主管與店長限已送出未作廢）；備註框與附圖區提醒考官不要貼腳本或考點
- 備註附圖（正式版）｜`assess.html`、`js/assess-api.js`｜貼上、拖曳、選檔；上傳到私有 bucket assess-notes；每題組最多 5 張；顯示用簽名網址
- 成績單（所有已開通角色）｜`reports.html`｜客服部看完整內容並可作廢；主管看已送出的精簡版；店長只看自己門市已送出的精簡版；精簡版含考官備註文字與備註附圖，不含題組名稱、步驟、考點（備註存在 assessment_items.note；需先在 Supabase 執行 notes_visible_schema.sql）
- 導覽統一（現含 `backoffice.html`、`accounts.html`，導覽已加入「考核後台」）｜`roster.html`、`assess.html`、`reports.html`｜頁首黑底導覽列（貳輪嶼 LOGO、圖示分頁、目前頁黃底、頭像、登出圖示；窄螢幕分頁自成一行、信箱隱藏只留角色標籤）；分頁順序：人員名冊、進行考核（客服部）、成績單、考核後台、題庫管理（客服部）、帳號管理（客服部）；名冊頁標題為「貳輪嶼官方LINE訊息回覆人員名冊」

### 抽查系統（網頁已寫好，尚未連真實資料庫；需先執行 supabase/spotcheck_schema.sql，規格見 supabase/README_spotcheck.md）

- 抽查頁｜`spotcheck.html`、`js/spotcheck-api.js`｜所有已開通角色可進；開頁見「人員抽查狀態」表（本月黃單／本季紅單計量格，可用門市下拉選單篩選；店長只有自己門市，不顯示下拉）與單據清單（可依門市、種類、人員、狀態篩選；選門市後人員下拉只列該門市；店長不顯示門市下拉）；寫入全走 RPC（spot_register／spot_void_ticket／spot_coach／spot_mark_executed／spot_cancel_probation）
- 登記抽查（只有客服部）｜`spotcheck.html`｜「登記一次抽查」區塊在「人員抽查狀態」之前（警示列仍最上面；主管與店長沒有登記區塊，直接看狀態表）；選人員、日期、判定、七面向等級、原因（不適當必填）；「訊息抽檢-LINE聊天室網址」為必填單行網址（去空白、http／https 開頭、無空白、500 字內，否則顯示繁中提示不送出），以 p_message 傳送；登記後顯示開了黃單／紅單／回考核期；單據清單有「聊天室」欄（黃單用 inspection_id 對應 spot_inspections.message，http／https 開頭才顯示可點的「開啟 LINE 聊天室」連結，否則純文字；紅單顯示「—」；三種角色都看得到）
- 備註網址（非必填）｜`assess.html`、`reports.html`、`js/assess-api.js`｜考官備註下方多一個網址欄，隨題組自動暫存（assess_save_item 第四參數 p_note_url，空字串傳 null），草稿重開會帶回；格式不合（非 http／https、含空白、超過 500 字）顯示提示、該題組不暫存、無法送出；成績單詳情（客服部與主管／店長版）有網址時在備註旁顯示「備註網址」連結，只有 http／https 才成連結（javascript: 等不會）
- 回考核期警示列｜`spotcheck.html`｜待執行時客服部見「標記已執行」與「取消回考核期」（取消原因必填）；已執行時只剩取消；主管與店長只看
- 單據作廢與輔導回填｜`spotcheck.html`｜客服部可作廢（原因必填）；客服部與該門市店長可回填輔導（日期＋備註必填）；總公司主管無任何操作按鈕
- 導覽「抽查」｜`roster.html`、`assess.html`、`reports.html`、`backoffice.html`、`questions.html`、`accounts.html`、`spotcheck.html`｜所有已開通角色看得到，在「考核後台」之後
- 考核期標籤｜`roster.html`、`reports.html`、`assess.html`｜成績單與進行考核的「考核時身分」在 tenure_source 為「考核期」時顯示「考核期」標籤（名冊的標籤已改為第一期規則，見「第一期」一節）

### 題庫管理（正式版；bank_schema.sql 已在 Supabase 執行，162 項驗證通過；老闆用測試分類實測通過）

- 題庫管理頁（只有客服部）｜`questions.html`、`js/questions-api.js`｜取代舊管理頁，Google 登入；讀寫呼叫 bank_list_questions／bank_save_question／bank_delete_question／bank_rename_category／bank_reset 與 assess_categories；功能對應舊管理頁（分類下拉、統計、題組列表、新增編輯與步驟編輯器、草稿保留、刪除與洗牌二次確認、分類改名與合併）；題庫內容不寫入 console 或瀏覽器儲存；載入失敗時停用表單與洗牌
- 導覽「題庫管理」｜`roster.html`、`assess.html`、`reports.html`、`accounts.html`、`backoffice.html`｜只有客服部看得到，在「帳號管理」之前

### 題庫管理（樣品與設計稿）

- 題庫管理樣品（假資料）｜`樣品/questions.html`｜完整對應舊管理頁：分類下拉（含「全部分類」與特殊名稱）、統計小卡、收合列表與步驟展開、新增與編輯題組（步驟編輯器 1～30、上下移）、草稿保留、刪除二次確認（4 秒還原）、分類改名與合併、洗牌（單一與全部，二次確認）；底部註明題庫內容含考點只有客服部可見
- 題庫管理設計稿｜`supabase/bank_schema.sql`、`bank_verify_fake.sql`、`README_bank.md`｜bank_list_questions／bank_save_question／bank_delete_question／bank_rename_category／bank_reset，只有客服部能呼叫，行為與舊 admin_* 函式一致，與抽題共用 advisory lock（寫入函式）；驗證腳本結尾自動復原
- 停用舊抽選器腳本（單獨、可還原、尚未執行）｜`supabase/bank_retire_legacy.sql`｜收回 anon 對 8 個舊函式的 execute，不刪函式與資料；開頭防護：有其他物件引用舊函式就中止；還原段在註解內

### 考核後台（正式版；SQL 已在 Supabase 執行，161 項驗證通過；網頁尚未用真實登入實測）

- 考核後台頁｜`backoffice.html`、`js/backoffice-api.js`｜所有已開通角色可進；三個分頁「人員歷史」「弱項分析」「改善單」，網址 #history、#insights、#tickets；資料皆讀資料庫（不查機密表）；改善單動作呼叫 improve_update_plan／improve_close／improve_cancel（客服部）、improve_mark_coached（店長自己門市或客服部）；主管只讀；已取消單只有客服部看得到；主管與店長視角的改善單紀錄不顯示他人信箱（頁首仍顯示自己的信箱）
- 歷次成績單下載 PDF｜`backoffice.html`、`js/report-pdf.js`、`js/report-pdf-core.js`、`js/backoffice-api.js`、`tests/report-pdf-core.test.js`｜考核後台打開考生 →「歷次成績單」每列最右「下載 PDF」，產生 A4 兩頁（題組多自動三頁）成績單，檔名 成績單_姓名_日期.pdf；版面同 `樣品/成績單PDF樣品.html`（總分判定、雷達圖與面向得分率、與上一次比較、每題得分、全部歷次走勢）；加考題標「加考」不計入；客服部 PDF 顯示題名，主管與店長只顯示題組編號與分類（前端完全不查 assessment_item_secrets，資料庫也只放行客服部）；html2canvas 1.4.1／jsPDF 2.5.1 第一次按下載才動態載入；驗證：`node tests/report-pdf-core.test.js` 印出「通過 175 項」且結束碼 0
- 導覽「考核後台」｜`roster.html`、`assess.html`、`reports.html`、`accounts.html`｜所有已開通角色看得到；順序：人員名冊、進行考核（客服部）、成績單、考核後台、題庫管理（客服部）、帳號管理（客服部）
- 自動開單與自動取消｜資料庫觸發器（backoffice_schema.sql）｜成績單送出且判定需複訓或不及格時自動開單（期限 14 天）；成績單作廢時 open／coached 的單自動取消；**上線後要用真實流程送一張不及格成績單驗證**

### 考核後台（樣品與設計稿，已被正式版取代）

- 考核後台樣品（假資料）｜`樣品/backoffice.html`｜三個分頁「人員歷史」（列表、走勢圖、七面向平均、歷次成績單）、「弱項分析」（全公司或單一門市、最近 3 次或全部、門市×面向熱度表）、「改善單」（狀態與門市篩選；客服部編輯面向與期限、結案需複檢成績單、取消；店長回填已輔導，備註必填不限字數；主管只讀）；右上角可切換身分示範
- 改善單與分析設計稿｜`supabase/backoffice_schema.sql`、`supabase/backoffice_verify_fake.sql`、`supabase/README_backoffice.md`｜成績單送出且判定需複訓或不及格時自動開單（預設 14 天）；成績單作廢時 open／coached 的單自動取消；improve_update_plan／improve_mark_coached／improve_close／improve_cancel；improvement_ticket_view、analytics_dim_rates；驗證腳本含真實 assess_submit／assess_void 流程，結尾自動復原

### 帳號管理（正式版；SQL 已在 Supabase 執行並通過 113 項驗證；網頁尚未用真實登入實測）

- 帳號管理頁（只有客服部）｜`accounts.html`、`js/accounts-api.js`｜列出帳號（信箱、角色、門市、對應員工），新增、編輯、移除（二次確認）；護欄由資料庫把關，訊息直接顯示；底部操作紀錄（新到舊、每次 50 筆、載入更多、只增不改）
- 導覽「帳號管理」｜`roster.html`、`assess.html`、`reports.html`｜導覽分頁，只有客服部看得到
- 職級「其他（自行輸入）」｜`roster.html`｜新增／編輯人員可自訂職級（必填、最長 20 字）；輸入框失焦或送出時，若恰好等於標準六種職稱就改用標準職級並套用納入考核預設；編輯時職級不在六種內自動選「其他」
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
- 導覽「待考回報」｜`roster.html`、`assess.html`、`reports.html`、`backoffice.html`、`questions.html`、`accounts.html`、`spotcheck.html`、`requests.html`｜所有已開通角色看得到，在「考核後台」之後、「抽查」之前
- 導覽紅點｜`js/appbar.js`、`app.css`｜登入後呼叫 exam_req_badge()，大於 0 時在「待考回報」分頁文字旁顯示紅色數字（超過 99 顯示 99+）；只從 localStorage 讀目前 session 的 access_token（sb-專案代號-auth-token），建不存 session、不換 token、不監聽登入的 client 以 Authorization 標頭呼叫，絕不 refresh、不寫 storage；讀不到 token、JSON 壞掉、token 過期或任何失敗都安靜忽略；登入頁不載入；requests.html 做完動作會呼叫 window.AppBadge.refresh() 重抓
- 選考生標記「已回報待考」｜`assess.html`、`js/assess-api.js`｜進行考核步驟 1 的清單，已有待處理／已排定回報的人排最前面並顯示黃底「已回報待考」（已排定者附排定時間）；讀取 exam_requests 失敗就照原樣，不擋考核

## 階段 1 資料庫設計稿（尚未執行）

- 三張表與權限規則｜`supabase/roster_schema.sql`｜待老闆同意後在 Supabase 執行；驗證步驟見 `supabase/README_roster.md`
- 假資料｜`supabase/roster_seed_fake.sql`｜測試用，不含任何真實人員

## 第一期：考核期、固定 3 題組、弱項追加題、待開通（網頁已寫好，尚未連真實資料庫；需先執行 supabase/phase1_schema.sql，規格見 supabase/README_phase1.md）

- 固定 3 題組｜`assess.html`、`js/assess-api.js`｜選考生按「準備考核・去抽題」後自動呼叫 assess_core_categories 取得核心分類，再用 assess_draw 一次抽齊（每分類 1 題）並直接進評分，不再顯示「弱項與建議題組」面板；步驟列為「固定 3 題組／評分／弱項追加題／送出結果」；若抽題失敗（例如題庫缺題）顯示錯誤並可按「改用自選分類」回到舊的選分類流程；繼續草稿時已有題就直接進評分、沒題就自動抽核心題組
- 弱項追加題｜`assess.html`、`js/suggest.js`、`js/assess-api.js`｜核心題組評完才出現「分析弱項」（先暫存評分再呼叫 assess_draft_weak）；有弱項顯示面向與得分率、語氣／文字偏低提醒、建議追加題（Suggest 選題，允許同分類，題數預設 2、可選 1～4，可換一題，題庫不足有提示，已在核心題組內的題不會被選到）與「追加弱項題」「不追加，直接送出」；沒有弱項只顯示「沒有明顯弱項，可直接送出」；按「追加弱項題」呼叫 assess_add_extra 後回評分畫面，追加題標示「追加題・不算總分」並顯示追加開始時間（只顯示時間）；追加題沒評完不能前往結算與送出
- 送出結果頁（第一期）｜`assess.html`｜總分、判定、題組數只看核心題組；追加題另列「弱項追加題・不算入總分」；送出後讀 reply_activations 與 period_status：有待開通紀錄顯示「已加入待開通回覆權限清單」，仍在考核期顯示「仍在考核期，可再約補考」；回考核期者合格線 85 的顯示照舊
- 成績單追加題區塊｜`reports.html`、`js/assess-api.js`｜成績單詳情（客服部版與主管／店長版）追加題獨立區塊「弱項追加題・不算入總分」；雷達圖與題組列表只用核心題組；主管與店長版追加題不含題組名稱、步驟、考點
- 待開通回覆權限清單｜`requests.html`、`js/requests-api.js`｜只有客服部看得到；讀 reply_activations（人員、門市、通過日期、狀態），可依門市與狀態篩選，待開通排前面；「已開通」按鈕（先跳確認視窗）呼叫 activation_mark_done，已開通者顯示開通日期；清單讀取失敗只在該區塊提示；導覽紅點由 exam_req_badge 提供
- 考核期與新人標籤｜`roster.html`｜身分標籤依 employees_with_tenure 的 period_status 與 tenure_group：考核期者顯示「考核期」，到職 90 天內另顯示「新人」，其餘顯示「已上線」，未填到職日者另加「未填到職日」；既有門市篩選與搜尋不變；標籤判斷只看 period_status（資料庫遷移與 spot_register 回考核期都會同步，不再看 probation_since）
- 名冊「回覆狀態」欄位｜`roster.html`｜新增／編輯人員表單多「回覆狀態」下拉（考核期／已上線），只有客服部看得到；新增預設考核期（資料庫預設是已上線，所以新增時一定明確帶 period_status），編輯顯示目前值並可手動調整，存檔寫入 period_status，不動 passed_on；`js/api.js` 直接傳入整列，不需改
- 第一期網頁驗證方式｜以 jsdom 搭配假的 Api 物件逐項驗證（有弱項／無弱項／不追加／追加題未評完不能送出／核心抽題失敗改自選／繼續草稿／放棄／通過與未通過結果頁／成績單追加題區塊／待開通清單／名冊標籤）；`node tests/suggest.test.js`、`tests/scoring.test.js`、`tests/requests-core.test.js` 皆結束碼 0

## 版面升級（貳輪嶼 CI）

- 共用版面與配色｜`app.css`、`js/appbar.js`、`img/*`｜6 個頁面頁首為黑底導覽列＋黑色標題橫幅，CI 色黑藍黃白；開 `roster.html` 登入後見黑底導覽、選中分頁黃底、頭像為信箱首字
- 登入頁 LOGO｜`index.html`｜登入卡片頂部顯示貳輪嶼 LOGO，登入鈕黑底
- 雷達圖（七面向得分率）｜`js/radar.js`、`reports.html`（成績單詳情，客服部與主管/店長版都有）、`backoffice.html`（人員歷史）｜開一張成績單，標頭下方出現七面向雷達圖、最弱面向橘色，下方表格仍在；人員歷史的「七面向平均得分率」也是雷達圖
- 名冊姓名連結｜`roster.html`、`backoffice.html`｜點名冊裡的姓名／暱稱，會跳到考核後台並直接打開那位同仁的歷史成績；沒有考核資料的人（離職或未納入考核且無成績單）顯示提示
