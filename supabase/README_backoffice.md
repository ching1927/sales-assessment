# 考核後台（階段 3）資料庫說明：改善單與弱項分析資料來源

> ⚠️ 這兩支 SQL **尚未執行**，待老闆同意後才在 Supabase 執行。
> 規則依據：`階段0定義文件.md` 第八節（2026-10-21 已確認）。

## 一句話講完

成績單送出後，只要判定是「需複訓」或「不及格」，系統**自動開一張改善單**；客服部補改善面向與期限，店長回填「已輔導」，考生之後複檢通過由客服部結案。另外提供一個檢視，讓後台算「七面向平均得分率」。

## 檔案

| 檔案 | 用途 |
|---|---|
| `backoffice_schema.sql` | 資料庫結構（要執行的那份），全部是「新增」，可重複執行 |
| `backoffice_verify_fake.sql` | 驗證腳本：只用假資料、全程 rollback，不留任何資料 |
| `README_backoffice.md` | 本說明 |

## 新增了什麼

名稱一律以 `improve_`、`improvement_`、`analytics_` 開頭，與既有名稱（`roster_*`、`assess_*`、`accounts_*`、舊抽選器）都不重複。

### 資料表 `improvement_tickets`（改善單）

| 欄位 | 白話 |
|---|---|
| `assessment_id` | 來源成績單，一張成績單最多一張改善單 |
| `employee_id`、`store_code` | 考生、開單當下的門市（快照，之後調店不改） |
| `status` | `open` 待改善／`coached` 已輔導／`closed` 已結案／`cancelled` 已取消 |
| `target_dims`、`due_date` | 要改善的面向（只能是七面向名稱）、期限 |
| `coached_on`、`coach_note`、`coached_by`、`coached_at` | 輔導日期、備註（不限字數）、誰填的、何時填的 |
| `closed_by`、`closed_at`、`closed_by_assessment_id`、`close_note` | 結案資訊，含複檢成績單 |
| `cancelled_by`、`cancelled_at`、`cancel_reason` | 取消資訊 |

開了 RLS，**任何網頁角色都沒有直接 insert／update／delete／truncate 權限**，只能透過下面的觸發器與函式寫入。

### 觸發器（掛在已上線的 `assessments` 上，是「新增物件」）

| 名稱 | 做什麼 |
|---|---|
| `improvement_auto_open_trg` | 成績單狀態由非 submitted 變成 submitted，且判定為「需複訓」或「不及格」→ 自動開單：`open`、改善面向＝該成績單的最弱面向、期限＝台北時間今天＋14 天。同一張成績單只開一次 |
| `improvement_auto_cancel_trg` | 成績單狀態變成 voided（作廢）→ 對應的 `open`／`coached` 改善單自動改 `cancelled`（取消人記為「(系統：成績單作廢)」，原因「成績單已作廢」） |

**取捨：已結案（closed）的改善單不隨成績單作廢而動。** 結案是客服部已確認複檢通過的歷史紀錄，不應被翻動；原本就是已取消的單也保留當初的取消人與原因。

**對既有流程沒有影響：** `assess_submit`、`assess_void` 一行都沒改。它們照常 UPDATE 成績單，觸發器是在 UPDATE 之後另外跑；觸發器內只寫改善單這張新表、不碰成績單任何欄位。`assessments` 的欄位、policy、既有觸發器（本來就沒有）都沒動。

### 函式（皆 security definer、固定 search_path；收回 public／anon，只授權 authenticated；非授權角色一律丟「沒有權限」）

| 函式 | 誰能用 | 規則 |
|---|---|---|
| `improve_update_plan(改善單, 面向[], 期限)` | 只限客服部 | 單須是 open／coached；面向至少 1 個且皆為七面向之一（重複會去重、照固定順序存）；期限不可早於開單日（台北日期） |
| `improve_mark_coached(改善單, 輔導日期, 備註)` | 客服部，或「自己門市」的店長 | 單須是 open／coached（已輔導可重填修改）；日期不可晚於台北今天、不可早於開單日；備註去前後空白（含全形空白、換行）後不可為空，**不限字數**；記錄操作人信箱與時間；狀態改 coached。店長若對「找不到、別間門市、已取消、已結案」的單呼叫，一律只回同一句「找不到這張改善單或沒有權限」，不讓店長藉單號探知別的單是否存在 |
| `improve_close(改善單, 複檢成績單, 備註)` | 只限客服部 | 單須是 open／coached；複檢成績單須：已送出、同一位考生、不是來源成績單、送出時間晚於開單、判定為「及格」或「優秀」；不符就報錯並說明哪一項；成功才改 closed 並寫入欄位 |
| `improve_cancel(改善單, 原因)` | 只限客服部 | 單須是 open／coached；原因去空白後不可為空；用於考生離職或轉調 |

操作人信箱一律取自 `roster_my_email()`；「今天」一律是台北時間。

### 檢視（security_invoker，沿用底層資料表的 RLS，不會繞過權限）

- `improvement_ticket_view`：改善單 ＋ 考生顯示名稱（成績單當時的快照）、來源成績單的考核日期／總分／判定／考核時身分，以及 `is_overdue`（待改善且期限已過）與 `days_overdue`（逾期天數，沒逾期為 0）。已輔導的單即使過了期限也不算逾期。
- `analytics_dim_rates`：每張**已送出**成績單的每個題組、每個面向一列（成績單、考生、門市、送出時間、題組、序號、面向名稱、等級百分比；不適用為空值）。**完全不碰機密表**，不含題組名稱、步驟、考點、備註。後台用它算「七面向平均得分率」（個人／門市／全公司、最近 3 次或全部）。

## 權限一覽

| 角色 | 改善單（資料表與檢視） | analytics_dim_rates | 能做的事 |
|---|---|---|---|
| 客服部 | 全看（含已取消） | 全看 | 調整面向期限、回填輔導、結案、取消 |
| 總公司主管 | 全看，**不含已取消** | 全看 | 只看 |
| 店長 | 只看自己門市，**不含已取消** | 只看自己門市 | 回填自己門市的「已輔導」 |
| 有登入但沒帳號 | 什麼都看不到 | 什麼都看不到 | 無 |
| 未登入（anon） | 被拒絕 | 被拒絕 | 無 |

analytics_dim_rates 只含已送出的成績單，草稿與作廢的不會出現，可見範圍與成績單一致。

## 怎麼執行（老闆同意後才做）

0. **動手前先到 Supabase 備份**（Dashboard → Database → Backups），或至少先記下 `assessments` 與 `improvement_tickets`（若已存在）的筆數，執行後再比對。
1. Supabase 專案 → SQL Editor → New query → 貼上 `backoffice_schema.sql` 整份 → Run（前提：`roster_schema.sql`、`assess_schema.sql` 已執行過）。
2. 再開新的 query，貼上 `backoffice_verify_fake.sql` 整份 → Run。

## 驗證結果表怎麼看

驗證腳本跑完會顯示一張表：**序號／測項／預期／實際／通過**。

- 第一列「總結」會寫「N/M 項通過」，**「通過」欄全是「通過」才算驗證成功**。
- 任何一列「失敗」：看「預期」與「實際」的差異，並停下回報，不要自己放行。
- 若畫面出現兩張一樣的表，看最後一張。
- 腳本全程包在 `begin; … rollback;` 內，假門市（ZZ-B1／ZZ-B2）、假員工（MI-9701～9704）、假信箱（vr-xxx@2motor.tw）、假成績單與假改善單跑完全部消失，不會留在資料庫。
- 涵蓋：區段 1～9 以直接寫資料表模擬的自動開單、作廢自動取消、四個函式的成功與被拒情況、各角色可見筆數、直接寫入被拒、機密欄位、逾期計算、既有物件仍在（用「存在」「不少於」判斷，不寫死總數）；區段 10 是「真實流程」：以客服部身分真的呼叫 `assess_start`、`assess_draw`、`assess_save_item`、`assess_submit`、`assess_void`（前置的假題庫沿用 `assess_verify_fake.sql` 的建法，草稿、題組、機密表由真函式自己建），確認優秀／及格不開單、需複訓／不及格自動開單，作廢後 open／coached 的單自動取消、closed 的不動。

## 已知限制與只能用讀的確認

這份是「只寫檔、沒有執行過」的成果，下列項目目前**只能用讀程式碼確認，尚未實際跑過**，執行驗證腳本時才會得到實證：

1. 所有 SQL 語法與邏輯，只經過逐條人工核對，尚未在 Postgres 實際執行。
2. 觸發器與 `assess_submit`／`assess_void` 的配合：驗證腳本區段 10 已設計成真的呼叫這兩個函式，但整份尚未執行，所以仍只是「寫好、未實證」。上線後**必須**用網頁的真實流程送出一張「不及格」成績單，確認有開出改善單，再作廢它確認改善單被取消。
3. 觸發器只認 **UPDATE**（成績單由草稿改成已送出）。如果有人用 INSERT 直接寫入一張已送出的成績單，不會自動開單（現有流程不會這樣做）。
4. 店長、主管看不到「已作廢」的成績單，所以若一張已結案的改善單，其來源成績單日後被作廢，他們在檢視中仍看得到這張改善單，但「來源成績單」那幾欄（`employee_label`、`source_total_score`、`source_verdict`、`source_tenure`、`source_assessed_on`）會是 **null**（驗證區段 10 有實測此行為）。**前端必須能處理這些欄位為 null**（例如考生名稱改用名冊補、或顯示「—」）。
5. 改善單只能由程式（函式與觸發器）寫入，沒有「手動補開單」的功能；若要補，需另行討論。
6. 驗證腳本的「assessments 上沒有其他觸發器」一項，是依 `assess_schema.sql` 本來就沒有定義觸發器而訂（預期 0 個）；若日後該表另外加了觸發器，這一項要跟著更新。

## 設計取捨：自動開單在觸發器內失敗，會讓 assess_submit 整個失敗

自動開單寫在 `assessments` 的 AFTER UPDATE 觸發器裡，**沒有吞掉例外**。若開單那一步出錯（例如改善單表被改壞），成績單「送出」會跟著整筆失敗（同一個交易，一起回復），客服部會看到錯誤、成績單仍是草稿，可以重試。

我們刻意選擇不吞例外：吞掉的話，錯誤會靜默發生，成績單送出成功卻漏開單，沒有人會發現。寧可送出時明確失敗，也不要悄悄少一張單。

代價是：觸發器若壞掉，會暫時擋住所有成績單送出。遇到這種情況，用下面的緊急停用 SQL 先讓送出恢復，再修好觸發器。**上線後務必用真實流程送一張不及格成績單驗證一次。**

## 緊急停用自動開單／自動取消

不影響成績單送出與作廢，也不會刪任何已開的改善單。在 SQL Editor 執行：

```sql
drop trigger if exists improvement_auto_open_trg   on public.assessments;
drop trigger if exists improvement_auto_cancel_trg on public.assessments;
```

要恢復：重新執行 `backoffice_schema.sql`（可重複執行，會把觸發器建回來）。

完全移除本次新增的東西（極端情況，會刪掉所有改善單）：先執行上面兩行，再依序 drop 檢視 `improvement_ticket_view`、`analytics_dim_rates`、函式 `improve_*` 與 `improvement_auto_*`、資料表 `improvement_tickets`。
