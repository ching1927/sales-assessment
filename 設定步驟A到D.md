# 設定步驟 A 到 D（老闆自己操作，約 30～40 分鐘）

目的：把資料庫建好、名單匯入、Google 登入打通。**密碼、密鑰只在你手上，不要貼給任何人（包含我）。**

順序：A → B → C → D。C 需要 B 的網址，D 需要 C 的憑證。

---

## A. 在 Supabase 建表並匯入名單

用你平常登入考題抽選器那個 Supabase 專案（網址開頭是 uphowxeilvjaoffefoxs）。

1. 登入 supabase.com，進入該專案。
2. 左側選 **SQL Editor**，按 **New query**。
3. 打開本資料夾的 `supabase/roster_schema.sql`，全選複製，貼進去，按 **Run**。看到 Success 就對了。
   - 這一步只新增三張新表，**不會動**考題抽選器的題庫與抽題資料。
4. 再按 **New query**，打開 `supabase/import/import_roster.local.sql`（含真實名單），全選複製貼上，按 **Run**。看到 Success。
5. 左側選 **Table Editor**，確認：`stores` 12 筆、`employees` 60 筆、`app_users` 19 筆。
6. **不要**執行 `roster_seed_fake.sql`，那是測試用假資料，不能放進正式專案。

## B. 建立 GitHub 倉庫並開啟 Pages

這一步我來做（會先問你同意才推上去）。完成後我會給你一個網址，格式像：
`https://ching1927.github.io/倉庫名稱/`

倉庫是公開的，**只放網頁程式，不放名單與個資**（`.gitignore` 已擋住匯入檔）。

## C. 在 Google Cloud 建立登入憑證

1. 打開 console.cloud.google.com，用一個 Google 帳號登入（建議用公司帳號，之後交接比較容易）。
2. 上方專案選單 → **新增專案**，名稱例如「業務考核系統」。
3. 左側 **API 和服務** → **OAuth 同意畫面**：
   - 使用者類型選 **外部**。
   - 應用程式名稱填「業務考核系統」，支援電子郵件與開發人員聯絡信箱填你的公司信箱。
   - 範圍（Scopes）不用加，保持預設。
   - 發布狀態選 **發布應用程式**（In production）。只用基本登入資訊，不需要 Google 審核。若不發布，只有「測試使用者」名單裡的人能登入。
4. 左側 **憑證** → **建立憑證** → **OAuth 用戶端 ID**：
   - 應用程式類型：**網頁應用程式**。
   - 已授權的重新導向 URI 填：`https://uphowxeilvjaoffefoxs.supabase.co/auth/v1/callback`
   - 建立後會顯示 **用戶端 ID** 與 **用戶端密鑰**，先留著，下一步要用。
5. 記下：這組憑證建在哪個帳號底下。那個人離職時要交接。

## D. 把憑證填進 Supabase

1. Supabase 專案 → 左側 **Authentication** → **Providers** → 選 **Google**。
2. 打開開關，貼上 C 步驟的用戶端 ID 與密鑰，按 **Save**。
3. 左側 **Authentication** → **URL Configuration**：
   - **Site URL** 填 B 步驟的網址。
   - **Redirect URLs** 加入 B 步驟網址加上 `roster.html`。
4. 完成後通知我，我會做實測與權限驗證。

---

## 注意

- 登入時，Google 可能出現「未驗證的應用程式」提示，點「進階」→「繼續前往」即可。這是路線 B 的已知現象。
- 擋人的機制：不在 19 位白名單上的人，就算 Google 登入成功，也看不到任何名單資料；網頁也會再檢查信箱是不是 @2motor.tw。
- 之後如果找到公司 Google 管理員，可以把使用者類型改成「內部」，登入畫面的提示就會消失。
