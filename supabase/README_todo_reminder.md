# 待填提醒：紅點＋客服部每週彙整信（資料庫部分）

> 狀態：**尚未在真實 Supabase 執行**，等老闆點頭才做。前端（紅點、清單頁）由另一包工作處理，兩邊靠下面「函式約定」對接。

## 這包做了什麼（講人話）

- 店長該填的東西沒填，導覽列要有紅點；填完紅點才消。
- 客服部每週一早上 09:00（台北）收到一封彙整信：各門市還有多少「回填輔導紀錄」與「未輔導的異常回覆單」沒填、最久幾天、超過 7 天沒填的人是誰。

## 函式約定（前端依此呼叫，名稱與回傳不改）

| 函式 | 回傳 | 誰看到什麼 |
|---|---|---|
| `improve_badge()`（改寫） | 整數 | 只算「改善單還沒回填輔導（status='open'）」的張數。客服部全部、店長只算自己門市、主管 0、其他「沒有權限」。人員要在職且納入考核。**已輔導（coached）不再算。** |
| `spot_badge()`（新） | 整數 | 異常回覆單（黃單）「有效、輔導日為空」的張數。權限規則同上。 |
| `todo_unreported_rows()`（新） | 表：employee_id, employee_label, store_code, reason, since_on | 店長該回報待考但還沒回報的人。店長只看自己門市、客服部全部、主管空、其他「沒有權限」。 |
| `exam_req_badge()`（改寫） | 整數 | 客服部分支與原本逐字相同；店長 ＝ `todo_unreported_rows()` 的筆數（已含「已輔導未約考」，前端可拿掉額外加 `coached_pending_count()` 的那次呼叫）。 |
| `todo_digest_run()`（新，內部） | 整數 | 寫進寄信佇列的封數；網頁帳號不能呼叫，只給排程與老闆在 SQL Editor 手動測試。 |

`todo_unreported_rows()` 的條件（一人最多一列，且要在職、納入考核）：
- A. 考核期：沒有「待處理／已排定」的待考回報，且沒有「待改善（open）」的改善單（還沒輔導的先去輔導）。
- B. 已上線（不是考核期）：有「已輔導」改善單，且比照 `coached_pending()`——有輔導時間、開單後沒有待處理／已排定／已完成的回報。
- `reason`：有「已輔導（coached）」的改善單 → `已輔導未約考`；否則 `新人`。
- `since_on`：已輔導未約考 ＝ 最早那張已輔導改善單的輔導日（優先用 `coached_at` 的台北日期，沒有才用 `coached_on`）；新人 ＝ `coalesce(probation_since, hire_date, 名冊建檔日)`（回考核期的人用進考核期那天；一般新人用到職日；到職日沒填才用建檔日）。

**沒有動**：`coached_pending()`、`coached_pending_count()`、`coached_reminder_run()` 與每兩天一封的提醒信（那封信的文字本來就不含「改善單」，所以不需要改文字）。

## 彙整信規則

- 只寄客服部。收件人從設定表 `app_settings` 讀（見下方）；**沒設或空字串＝整個不寄**。
- 內容：每間門市一列（待回填輔導紀錄張數、未輔導異常回覆單張數、最久天數、超過 7 天未填的人與天數）。天數 ＝ 今天（台北）減開單日（改善單用建立日、異常回覆單用開單日）。
- 同一個台北週只寄一次；信件寫進 `mail_outbox`（種類 `todo_digest`），客服部在「寄信紀錄」看得到；沒設寄信中繼站時狀態會是 skipped，不會報錯。
- 排程：pg_cron 的 `todo_digest_weekly`，每週一 UTC 01:00（＝台北 09:00）。沒啟用 pg_cron 也能執行本檔，只是沒有排程；啟用後把 `todo_reminder_schema.sql` 再跑一次即可。
- 緊急停寄：`select cron.unschedule('todo_digest_weekly');`

## 老闆上線步驟（等同意後才做）

1. 先看一眼網址列是 uphowx… 那個專案；Dashboard → Database → Backups 確認有備份。
2. SQL Editor 執行 `待填提醒_上線前備份.sql`（在 Downloads，不在 repo；把兩個要被改寫的函式存進 `bak_todo_funcs`）。
3. 執行 `supabase/todo_reminder_schema.sql`（可重複執行；缺前置檔會用中文訊息擋下並整份回復）。
4. 執行 `supabase/todo_reminder_verify_fake.sql`，最後結果第一列要顯示「N/N 項通過」（全程假資料、最後 rollback）。
5. 設定彙整信收件人（一定要老闆自己做；信箱不放進程式碼，因為倉庫是公開的）：

```sql
insert into app_settings(key, value)
values ('todo_digest_recipients', '信箱1,信箱2')
on conflict (key) do update set value = excluded.value;
```

   `app_settings` 的欄位就是 `key`（主鍵）與 `value`。要停寄：把 value 改成空字串，或 `delete from app_settings where key = 'todo_digest_recipients';`。
6. 想馬上看信長怎樣：`select public.todo_digest_run();`（回 1 ＝已排入寄信佇列；同一週再跑會回 0）。

## 還原

- 紅點函式：`select def from public.bak_todo_funcs where func like 'improve\_badge(%' or func like 'exam\_req\_badge(%';` 取出 `def` 貼上執行。
- 新函式可 `drop function`；排程用上面的 `cron.unschedule`。

## 已知會因新行為而變的舊驗證

- `badge_lifecycle_verify_fake.sql` 的 10 項斷言（序號 9、13、14、29、30、32、33、34、38、41）已改成新語意（改善單紅點只算 open；店長待考紅點＝未回報清單筆數），全數通過。
- `coached_reminder_verify_fake.sql` 序號 38「店長甲沒有未看回覆仍是 0」會失敗（新算法把該腳本裡已上線＋已輔導的人算進去），尚待決定。
