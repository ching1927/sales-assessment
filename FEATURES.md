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

- 進行考核樣品（假資料）｜`樣品/assess.html`｜登入後依序選考生（到職日空白須手動選新人／正式）→ 抽題 → 七面向評分（不適用每題組最多 2 個）→ 結算 → 送出；兩題組 77.5 與 100.0 平均顯示 88.8
- 成績單樣品（假資料）｜`樣品/reports.html`｜客服部看到題組名稱、步驟、考點、備註並可作廢；主管與店長只看到已送出未作廢的精簡版，頁面內完全沒有題組名稱、步驟、考點、備註
- 樣品名冊頁導覽｜`樣品/roster.html`｜右上角多了「進行考核」與「成績單」連結

- 評分計算模組｜`js/scoring.js`｜`node tests/scoring.test.js` 印出「通過 N 項」且結束碼 0；範例（良優良待加強優良優）題組分數 77.5
- 考核資料庫設計稿｜`supabase/assess_schema.sql`、`supabase/assess_verify_fake.sql`｜**尚未在 Supabase 執行**；在 SQL Editor 先執行 schema，再執行 verify（交易內執行並復原），結果表全部通過；說明見 `supabase/README_assess.md`

## 階段 1 資料庫設計稿（尚未執行）

- 三張表與權限規則｜`supabase/roster_schema.sql`｜待老闆同意後在 Supabase 執行；驗證步驟見 `supabase/README_roster.md`
- 假資料｜`supabase/roster_seed_fake.sql`｜測試用，不含任何真實人員
