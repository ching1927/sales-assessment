# 各門市面向分析（checkup_store_dims）

## 用途
「異常回覆預警榜」頁的「各門市面向分析」：依門市彙整登記時勾選的「可改善面向」被勾次數。

## 函式簽名
`public.checkup_store_dims(p_from date, p_to date)`
回傳 `table(store_code text, store_name text, weak_records int, dim_counts int[])`

`dim_counts` 固定 7 個元素，順序：資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識、語氣與禮貌、文字品質。

## 規則
- 只計待加強回覆（verdict＝'不適當'）且至少勾 1 個面向的登記；優良回覆、舊制紀錄、沒勾面向的都不算（分子分母皆不算）。
- 日期以登記日 checked_on 落在 p_from～p_to（含頭尾）；依登記當時的門市歸屬。
- 門市清單：stores 內所有門市（排除總公司）全部列出，不論有沒有人、有沒有紀錄（2026-11-26 老闆指出中和不見了才改）；沒有符合紀錄的門市 weak_records＝0、dim_counts 全 0。
- cs_admin、hq_viewer、store_manager 可看全部門市彙總；其他角色拋「沒有權限」。
- 不回傳登記內容、人員姓名、網址、截圖。

## 貼進 Supabase 的步驟
1. 前提：spotdims_schema.sql、yellow_ranking_schema.sql 等已執行過（缺的話會用中文訊息擋下）。
2. 本函式是新增，不覆蓋既有函式，不需備份。
3. Supabase SQL Editor → New query → 貼上 `store_dim_schema.sql` 整份 → Run（可重複執行）。
4. 驗證（可選）：新 query 貼上 `store_dim_verify_fake.sql` → Run，看最後結果表第一列「N/N 項通過」（假資料全程 rollback）。
