-- ============================================================
-- 業務考核系統：考官備註「文字」開放給總公司主管與店長看（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 前提：assess_schema.sql 已執行（本檔改寫其中的 assess_save_item）。
--
-- ---------- 這次要做什麼（老闆的決定）----------
-- 考官備註的「文字」要讓總公司主管與店長看得到，範圍與備註附圖相同：
--   客服部：全部（含草稿、已作廢）
--   總公司主管：全部「已送出」且未作廢的成績單
--   店長：只有「自己門市」且「已送出」未作廢的成績單
--   草稿與已作廢的：只有客服部
-- 題組名稱、步驟、考點仍然只有客服部看得到（assessment_item_secrets 完全不放寬、本檔不碰它的 policy 與授權）。
-- 原本備註文字放在機密表 assessment_item_secrets.note，主管與店長讀不到，
-- 所以改放到 assessment_items.note（可見範圍由既有 RLS 決定，與成績單一致）。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 本檔不新增任何資料表、檢視、索引、policy、觸發器，也沒有任何以 notes_ 開頭的新名稱需要建立。
-- 本檔只做五件事（全部包在同一個交易內）：
--   1. assessment_items 新增欄位 note（add column if not exists；原本沒有此欄位，grep 全專案 sql 確認無衝突）
--   2. 把舊備註從 assessment_item_secrets.note 複製到 assessment_items.note（只複製、不覆蓋）
--   3. 搬移後，把「items.note 已有值」的列所對應的 secrets.note 設為 null（欄位保留不刪），
--      這樣重跑本檔不會把使用者之後清空的備註從舊欄位搬回來
--   4. 改寫 assess_save_item（create or replace，簽名與回傳型別不變）
--   5. 重新收回／授權 assess_save_item 的執行權限（與 assess_schema.sql 相同，重做是保險）
--
-- ---------- 單一交易（空窗期的處理）----------
-- 整份檔案是一個交易：begin; … commit;。搬移與函式替換是「同時生效」的，
-- 不會出現「資料已搬、但舊函式還在寫舊欄位」的空窗；中途任何一步報錯，整份自動回復，什麼都沒改。
-- 注意：第 2 段搬移是一次性複製。若有人在「按下 Run」到「交易提交」之間，用舊函式暫存備註，
-- 舊函式的寫入要等交易提交後才會看到新函式，這段時間的備註可能只寫進舊欄位，不會被搬到新欄位。
-- 所以請選在沒人暫存備註的離峰時段執行；執行完若懷疑有漏，可再執行一次本檔（第 2 段會把「新欄位仍空」的舊備註補搬過來；
-- 但這只對「items.note 仍為空」的列有效。若某列 items.note 與舊欄位都有值且不同，重跑時第 3 段會把舊值清掉且救不回來，
-- 首次執行不會發生；若需要重跑，請先備份 assessment_item_secrets）。
-- 關於 Supabase SQL Editor 的 begin／commit：Editor 把整份文字當一次查詢送出，
-- 報錯時整份交易自動回復（本專案的驗證腳本也是同樣的 begin…rollback 寫法）。
-- 所以不需要也不要在中途自己手動下 commit／rollback。另外開頭設了 lock_timeout：
-- 拿不到資料表鎖就報錯並整份回復，不會卡住別人。
--
-- ---------- assess_save_item 與原函式（assess_schema.sql 第 806～843 行）的差異（逐行）----------
--   簽名：assess_save_item(p_item_id uuid, p_levels jsonb, p_note text)         → 完全相同
--   回傳：void                                                                   → 完全相同
--   language plpgsql／security definer／set search_path = public, pg_temp         → 完全相同
--   宣告 v_me、v_status、v_owner                                                  → 完全相同
--   perform public.assess_assert_cs()（非客服部一律「沒有權限」）                    → 完全相同
--   v_me := public.roster_my_email()                                              → 完全相同
--   select ... for update of a（找題組、鎖母考核；找不到「找不到題組」）              → 完全相同
--   if v_status <> 'draft'（「只有草稿可以暫存評分」）                               → 完全相同
--   if v_owner <> v_me（「只有建立者本人可以操作這張考核」）                         → 完全相同
--   perform public.assess_check_levels(p_levels, false)（七面向鍵、四級或不適用、
--     不適用 ≤ 2、可只填部分）                                                     → 完全相同
--   原：update public.assessment_items set levels = p_levels where id = p_item_id;
--      update public.assessment_item_secrets set note = nullif(btrim(p_note), '') where item_id = p_item_id;
--   新：update public.assessment_items
--         set levels = p_levels, note = nullif(btrim(p_note), '') where id = p_item_id;
--   → 【唯一差異】備註改寫入 assessment_items.note，不再寫機密表的舊備註欄位。
--     備註的處理方式 nullif(btrim(p_note), '') 與原函式一字不差（null、空字串或「只有半形空白」＝清除備註；btrim 預設只去半形空白，tab、換行、全形空白不會被去掉，與原函式相同；不限字數）。
--     兩個 update 合併成一個，是因為 levels 與 note 現在在同一張表同一列。
--
-- ---------- 全專案讀寫舊備註欄位（assessment_item_secrets.note）的檢查結果 ----------
-- （前端 assess.html、reports.html、js/assess-api.js 已改好，下面是改完後的狀態）
--   [sql] assess_schema.sql 345 行      建表定義 note 欄位              → 保留（舊欄位，已停用、搬移後已清空）
--   [sql] assess_schema.sql 841 行      舊版 assess_save_item 寫入       → 本檔改寫，不再寫
--   [sql] assess_schema.sql 791 行      assess_draw 建立 secrets 列      → 欄位清單沒有 note（預設 null），不需調整
--   [sql] assess_schema.sql 其他函式    assess_submit／assess_void／assess_abandon／
--                                       assess_add_image／assess_remove_image 與檢視 assessment_summaries
--                                       → 都沒有讀寫 note，不需調整
--   [sql] backoffice_schema.sql         analytics_dim_rates 與改善單檢視都不 join 機密表 → 不需調整
--   [sql] accounts／roster／bank 各 schema → 與備註無關
--   [sql] assess_verify_fake.sql 361 行  假資料直接寫入 secrets.note（'機密備註'）用來測機密表權限 → 只是造假資料，不受影響
--   [sql] assess_verify_fake.sql 423～426 行  「assessment_items 沒有 title／steps／note／… 欄位」
--                                       → 本檔執行後 items 有 note 欄位，這條會失敗；已把欄位清單與測項名稱的 note 拿掉
--   [sql] assess_verify_fake.sql 504 行  讀 secrets.note 確認「被拒後備註未被改」→ 讀的是自己造的假資料，不受影響
--   [sql] assess_verify_fake.sql 768～769 行 原本斷言「備註已存入機密表」→ 已改成讀 assessment_items.note
--   [sql] demo_seed.local.sql 65 行      本機示範資料直接寫 secrets.note
--                                       → 示範資料的備註對主管／店長不可見；若要展示可見，需另外改成寫 items.note（只存本機）
--   [前端] js/assess-api.js loadItemsFull   → 已改讀 assessment_items.note
--   [前端] js/assess-api.js loadItemsLimited（主管、店長用）→ select 已加上 note
--   [前端] js/assess-api.js saveItem         → 呼叫 assess_save_item（傳 p_note），函式簽名未變，不需改
--   [前端] reports.html（顯示備註）、assess.html（編輯備註）→ 資料來自上面兩個函式，已同步
--   ⚠️ 前端已改好且改讀新欄位：本檔執行前，舊資料的備註只在舊欄位，新前端讀新欄位會是空的；
--      本檔執行後，舊前端（讀舊欄位）也會讀不到備註（舊欄位已清空）。
--      所以「執行本檔」與「前端上線」要緊接著一起進行：先執行本檔，馬上上線新前端。
--
-- ---------- 可見性檢查結果（讀 assess_schema.sql 的授權與 RLS）----------
--   * assessment_items 的授權是「資料表層級」grant select to authenticated，沒有任何欄位層級授權
--     （全專案沒有 grant select (欄位) 的寫法），所以新欄位 note 自動可被有權限的列讀到。
--   * RLS 是列層級：assessment_items_select 要求母考核在 assessments_select 的可見範圍內
--     （客服部全看；主管看已送出；店長看自己門市已送出；草稿與作廢只有客服部），note 自動跟著同一規則。
--   * 沒有任何檢視會把 note 暴露給不該看的人：assessment_summaries 與 analytics_dim_rates
--     都是明列欄位的 security_invoker 檢視，不含 note；improvement_ticket_view 不碰 assessment_items。
--   * 沒有任何函式回傳 assessment_items 的整列（沒有 select * 或 to_jsonb(i) 之類寫法）。
--   * assessment_item_secrets 的 policy 仍是「只有客服部」，本檔完全不動；
--     所以主管與店長仍讀不到題組名稱、步驟。
--   ※ 與「已作廢」有關的說明：作廢後 assessments_select 對主管與店長不再放行，
--     所以作廢成績單的 note（與題組、圖片）對主管與店長一併消失，只有客服部看得到。
--
-- ---------- 對既有流程的影響 ----------
--   * 客服部在考核頁暫存備註：寫入位置改變，行為（驗證、只限草稿本人）完全不變。
--   * assessment_items.note 新欄位預設空；舊備註在第 2 段複製過來，然後第 3 段清空舊欄位的對應值。
--   * 舊欄位 assessment_item_secrets.note 保留、不再寫入也不再讀取（已停用）；搬移後「已搬到新欄位的列」其舊欄位已清空。
--   * 不動任何既有資料表的其他資料、不動 policy、不動授權、不動觸發器。
--
-- ---------- 如何還原 ----------
--   把 assess_save_item 恢復成舊版：在 Supabase SQL Editor 執行本檔最下方「還原腳本」註解內的 SQL
--   （先把註解符號拿掉）。因為第 3 段已清空舊欄位，還原時必須一併執行還原腳本內的「回填舊欄位」那段，
--   把備註從 assessment_items.note 補回舊欄位，否則舊版函式的使用者會看到備註消失。
--   新增的 assessment_items.note 欄位可留著（無害）；真要移除：
--   alter table public.assessment_items drop column note;（會連同資料刪除，執行前請確認已回填或不需要）
--
-- 怎麼執行（之後老闆同意才做）：
--   選在沒有人暫存備註的離峰時段。
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   執行完再跑 notes_visible_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 可重複執行：add column if not exists、資料搬移只處理「items.note 為空」的列、清舊欄位只處理「items.note 非空」的列、
-- 函式 create or replace、收回與授權重做不會報錯。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯並整份回復，不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null
     or to_regclass('public.assessments') is null then
    raise exception '請先執行 assess_schema.sql';
  end if;
  if to_regprocedure('public.assess_save_item(uuid, jsonb, text)') is null
     or to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_check_levels(jsonb, boolean)') is null then
    raise exception '找不到 assess_save_item 或其相依函式，請先執行 assess_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_item_secrets'
                   and column_name = 'note') then
    raise exception 'assessment_item_secrets 沒有 note 欄位，與預期不符，已停止';
  end if;
end
$$;

-- ---------- 1. 新欄位：備註文字（可為空；可見範圍由 assessment_items 既有 RLS 決定） ----------
alter table public.assessment_items add column if not exists note text;

comment on column public.assessment_items.note is
  '考官備註文字。客服部、總公司主管（已送出）、同門市店長（已送出）可讀；請勿貼題組腳本或考點原文。';
comment on column public.assessment_item_secrets.note is
  '【已停用】舊的考官備註欄位，不再寫入也不再讀取；備註已改存 assessment_items.note。';

-- ---------- 2. 資料搬移：舊備註 → assessment_items.note（可重複執行、不覆蓋已有值） ----------
-- 條件：secrets.note 有內容，且 items.note 為空（null、空字串或只有半形空白；btrim 預設只去半形空白）。
update public.assessment_items i
   set note = s.note
  from public.assessment_item_secrets s
 where s.item_id = i.id
   and nullif(btrim(s.note), '') is not null
   and nullif(btrim(i.note), '') is null;

-- ---------- 3. 清空已搬移（或新欄位已有值）的舊備註 ----------
-- 只處理「items.note 非空」的列；欄位本身保留不刪。
-- 目的：之後使用者把備註清空（items.note 變 null）時，重跑本檔的第 2 段不會把舊備註從舊欄位「復活」。
-- items.note 為空的列，舊欄位不動（保留作為還沒搬的資料）。
update public.assessment_item_secrets s
   set note = null
  from public.assessment_items i
 where i.id = s.item_id
   and nullif(btrim(i.note), '') is not null
   and s.note is not null;

-- ---------- 4. 改寫 assess_save_item：備註改寫入 assessment_items.note ----------
-- 與原函式的差異見檔頭（註解刻意放在函式外，避免函式本體含有舊表名字樣，讓驗證腳本能用文字比對寫入敘述）。
-- 只限草稿且本人建立；允許只填部分面向（完整性在送出時檢查）。
-- 每次呼叫會整份取代該題組的評分與備註（備註傳 null、空字串或只有半形空白＝清除備註；tab、全形空白不算空白，與原函式相同）。
-- 與原函式唯一差異：備註寫進 assessment_items.note，不再寫機密表的舊備註欄位。
create or replace function public.assess_save_item(p_item_id uuid, p_levels jsonb, p_note text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select a.status, a.examiner_email into v_status, v_owner
  from public.assessment_items i
  join public.assessments a on a.id = i.assessment_id
  where i.id = p_item_id
  for update of a;
  if not found then
    raise exception '找不到題組';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以暫存評分';
  end if;
  if v_owner <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  perform public.assess_check_levels(p_levels, false);

  update public.assessment_items
     set levels = p_levels,
         note = nullif(btrim(p_note), '')
   where id = p_item_id;
end;
$$;

-- ---------- 5. 函式權限（與 assess_schema.sql 相同；create or replace 本來就會保留，這裡重做是保險） ----------
revoke execute on function public.assess_save_item(uuid, jsonb, text) from public, anon;
grant  execute on function public.assess_save_item(uuid, jsonb, text) to authenticated;

commit;

-- ============================================================
-- 還原腳本（需要時才把註解符號拿掉執行；建議同樣包在 begin; … commit; 內）
-- ============================================================
-- -- (a) 恢復舊版 assess_save_item（備註寫回 assessment_item_secrets.note）
-- create or replace function public.assess_save_item(p_item_id uuid, p_levels jsonb, p_note text)
-- returns void
-- language plpgsql
-- security definer
-- set search_path = public, pg_temp
-- as $$
-- declare
--   v_me text;
--   v_status text;
--   v_owner text;
-- begin
--   perform public.assess_assert_cs();
--   v_me := public.roster_my_email();
--
--   select a.status, a.examiner_email into v_status, v_owner
--   from public.assessment_items i
--   join public.assessments a on a.id = i.assessment_id
--   where i.id = p_item_id
--   for update of a;
--   if not found then
--     raise exception '找不到題組';
--   end if;
--   if v_status <> 'draft' then
--     raise exception '只有草稿可以暫存評分';
--   end if;
--   if v_owner <> v_me then
--     raise exception '只有建立者本人可以操作這張考核';
--   end if;
--
--   perform public.assess_check_levels(p_levels, false);
--
--   update public.assessment_items set levels = p_levels where id = p_item_id;
--   update public.assessment_item_secrets set note = nullif(btrim(p_note), '') where item_id = p_item_id;
-- end;
-- $$;
-- revoke execute on function public.assess_save_item(uuid, jsonb, text) from public, anon;
-- grant  execute on function public.assess_save_item(uuid, jsonb, text) to authenticated;
--
-- -- (b) 回填舊欄位：本檔第 3 段已清空舊欄位，還原時必須執行這段，把備註從 assessment_items.note 補回
-- --     （不覆蓋舊欄位已有值）。
-- update public.assessment_item_secrets s
--    set note = i.note
--   from public.assessment_items i
--  where i.id = s.item_id
--    and nullif(btrim(i.note), '') is not null
--    and nullif(btrim(s.note), '') is null;
