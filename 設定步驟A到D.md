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

**已完成。** 倉庫：`https://github.com/ching1927/sales-assessment`

- 網頁網址（Site URL 用這個）：`https://ching1927.github.io/sales-assessment/`
- 登入後導向網址（Redirect URLs 用這個）：`https://ching1927.github.io/sales-assessment/roster.html`

倉庫是公開的，**只放網頁程式，不放名單與個資**（`.gitignore` 已擋住匯入檔）。

## C. 在 Google Cloud 建立登入憑證

1. 打開 console.cloud.google.com，用一個 Google 帳號登入（建議用公司帳號，之後交接比較容易）。
2. 上方專案選單 → **新增專案**，名稱例如「業務考核系統」。
3. 進入 **Google 驗證平台**，按 **開始**，依精靈填寫：
   - 應用程式名稱填「業務考核系統」，支援電子郵件與聯絡信箱填你的公司信箱。
   - 目標對象（使用者類型）選 **內部**。專案建在公司 Google 組織底下就能選。內部代表只有公司帳號能登入，也不會出現「未驗證的應用程式」提示，不需要發布。
   - 範圍（Scopes）不用加，保持預設。
4. 左側 **用戶端** → **建立用戶端**：
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

- 擋人有三道：Google 內部設定只放行公司帳號；網頁再檢查信箱是不是 @2motor.tw；不在 19 位白名單上的人，就算登入成功也看不到任何名單資料。
- 憑證所在的 Google Cloud 專案屬於建立者的帳號，建立者離職時要交接。
