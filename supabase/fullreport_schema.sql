-- ============================================================
-- 業務考核系統：成績單「完整版」開放給店長（自己門市）與總公司主管（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（重跑不報錯、不改任何資料）。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   … → grade3_schema.sql（需要 assessment_item_secrets.dim_notes 欄位）→ 【本檔 fullreport_schema.sql】 → fullreport_verify_fake.sql（可選）
--   網頁（js/、backoffice.html）要在本檔執行「之後」才上線（新網頁會呼叫本檔的函式；舊網頁不受影響）。
--
-- ---------- 備份提醒（執行本檔之前先做；備份表必須啟用 row level security）----------
--   本檔只「新增一個函式」，不改任何資料表、欄位、policy、觸發器，所以不會動到資料；
--   仍照慣例備份機密表當保險：
--   drop table if exists public.bak_fullreport_secrets;
--   create table public.bak_fullreport_secrets as select * from public.assessment_item_secrets;
--   alter table public.bak_fullreport_secrets enable row level security;
--   （備份表不開任何 policy ＝ 網頁角色完全讀不到；確認無誤後可 drop）
--
-- ---------- 這次改了什麼（老闆已批准）----------
-- 店長（只限自己門市）與總公司主管的成績單，從「精簡版」改成「完整版」：
--   多顯示【題目名稱】與【考官備註】（題組備註＋面向備註）。
--   【考官信箱】仍然只有客服部看得到，不開放。
--   步驟與考點仍然只有客服部看得到（本檔不回傳）。
--
-- ---------- 怎麼做（最小且安全）----------
-- 機密表 assessment_item_secrets 仍然「整表只有客服部能讀」，本檔完全不動它的授權與 policy。
-- 題組備註（assessment_items.note）本來就依既有 RLS 對主管與店長可見，不用新增。
-- 缺的只有「題目名稱」與「面向備註」（都在機密表），所以新增一個 security definer 函式：
--     public.fullreport_items(p_assessment_ids uuid[])
--   回傳欄位只有 4 個：item_id、assessment_id、title、dim_notes。
--   ★ 不回傳考官信箱（assessments.examiner_email）、不回傳步驟與考點（steps）、不回傳題庫題號（question_id）。
--   身分規則（函式內自己判斷，不靠前端隱藏）：
--     * 沒登入、沒帳號、角色不在 客服部／總公司主管／店長 之內 → 報錯「沒有權限」
--       （anon 連執行權都被收回，直接被資料庫擋下）
--     * 客服部：任何成績單（含草稿、已作廢）
--     * 總公司主管：只有「已送出且未作廢」的成績單
--     * 店長：只有「自己門市」且「已送出且未作廢」的成績單；別間門市、草稿、作廢的一律不回傳（回傳空，不報錯、不透露是否存在）
--     這個規則與 assessments 的 RLS（assessments_select）完全一致。
--   一次最多查 50 張成績單（防濫用；網頁最多一次查 2 張）。
--
-- ---------- 本檔新增的東西（名稱衝突自查：全專案 sql 沒有 fullreport_ 開頭的名稱）----------
--   * 函式 public.fullreport_items(uuid[])（create or replace）
--   不新增資料表、欄位、檢視、索引、policy、觸發器；不動既有函式。
--
-- ---------- 如何還原 ----------
--   drop function if exists public.fullreport_items(uuid[]);
--   （網頁若已上線新版，主管與店長的成績單會退回精簡版並顯示載入失敗提示，請一併還原網頁。）
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '5s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null
     or to_regclass('public.app_users') is null then
    raise exception '請先執行 assess_schema.sql 與 roster_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_item_secrets'
                   and column_name = 'dim_notes') then
    raise exception '請先執行 grade3_schema.sql（assessment_item_secrets 還沒有 dim_notes 欄位）';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null then
    raise exception '找不到 roster_my_role／roster_my_store，請先執行 roster_schema.sql';
  end if;
end
$$;

-- ---------- 1. fullreport_items：完整版成績單要補的資料（題目名稱＋面向備註）----------
create or replace function public.fullreport_items(p_assessment_ids uuid[])
returns table(item_id uuid, assessment_id uuid, title text, dim_notes jsonb)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role  text := public.roster_my_role();
  v_store text := public.roster_my_store();
begin
  if coalesce(v_role, '') not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_assessment_ids is null then
    return;
  end if;
  if coalesce(array_length(p_assessment_ids, 1), 0) > 50 then
    raise exception '一次最多查 50 張成績單';
  end if;

  return query
    select i.id, a.id, s.title, coalesce(s.dim_notes, '{}'::jsonb)
      from public.assessments a
      join public.assessment_items i on i.assessment_id = a.id
      left join public.assessment_item_secrets s on s.item_id = i.id
     where a.id = any(p_assessment_ids)
       and (   v_role = 'cs_admin'
            or (a.status = 'submitted'
                and (   v_role = 'hq_viewer'
                     or (v_role = 'store_manager' and v_store is not null and a.store_code = v_store))))
     order by a.id, i.seq;
end;
$$;

revoke execute on function public.fullreport_items(uuid[]) from public, anon;
grant  execute on function public.fullreport_items(uuid[]) to authenticated;

commit;
