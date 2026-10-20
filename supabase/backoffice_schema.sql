-- ============================================================
-- 業務考核系統：階段 3 考核後台（改善單＋弱項分析資料來源）資料庫結構（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 前提：roster_schema.sql（人員名冊）與 assess_schema.sql（評分與成績單）已在同一個專案執行過。
-- 本檔只「新增」東西；不修改、不刪除任何既有資料表、函式、policy、觸發器、欄位。
-- 唯一碰到既有資料表的地方：在 assessments 上「掛上兩個新觸發器」（見下方說明），
-- 不改 assessments 的欄位、policy、既有觸發器，也不改 assess_submit／assess_void 任何一行。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 已逐一檢查 supabase\ 底下所有 .sql／.md、js\、根目錄 html／md，
-- 專案內原本沒有任何 improve_、improvement_、analytics_ 開頭的名稱。
-- 既有名稱（本檔不會碰）：
--   舊考題抽選器：questions、drawn、category_last、app_secret、_pw_ok、_assert_pw、list_categories、
--                 draw_questions、admin_login、admin_list_questions、admin_save_question、
--                 admin_delete_question、admin_rename_category、admin_reset
--   人員名冊：stores、employees、app_users、employees_with_tenure、roster_my_email、roster_my_role、
--             roster_my_store、roster_touch_updated_at、roster_keepalive
--   帳號管理：app_users_audit、accounts_* 系列（函式、觸發器、檢視）
--   評分：assessments、assessment_items、assessment_item_secrets、assessment_item_images、
--         assessment_summaries、assess_* 系列函式（共 19 個）
-- 本檔新增的名稱（全部以 improve_、improvement_ 或 analytics_ 開頭，與上面皆不重複）：
--   資料表：improvement_tickets
--   索引：improvement_tickets_employee_idx、improvement_tickets_store_status_idx
--   觸發器（掛在 improvement_tickets 上）：improvement_tickets_touch_trg
--   觸發器（掛在 assessments 上，新增）：improvement_auto_open_trg、improvement_auto_cancel_trg
--   觸發器函式：improvement_auto_open、improvement_auto_cancel
--   小工具函式：improvement_status_zh（狀態值轉中文，給錯誤訊息用）
--   函式：improve_update_plan、improve_mark_coached、improve_close、improve_cancel
--   RLS policy（掛在 improvement_tickets 上）：improvement_tickets_select
--   檢視：improvement_ticket_view、analytics_dim_rates
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   執行完再跑 backoffice_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 可重複執行：資料表／索引 if not exists、函式與檢視 create or replace、
-- policy 與 trigger 先 drop 再建，重跑不會報錯，也不會刪掉既有改善單。
-- 需要 Postgres 15 以上（view 的 security_invoker）；Supabase 新專案皆符合。
--
-- 安全設計：改善單開 RLS，直接寫入權限（insert／update／delete／truncate）一律不給，
-- 只能透過下面的函式與觸發器寫入。
--
-- 緊急停用自動開單／自動取消（不影響成績單送出與作廢）：
--   drop trigger if exists improvement_auto_open_trg   on public.assessments;
--   drop trigger if exists improvement_auto_cancel_trg on public.assessments;
-- ============================================================

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.employees') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.app_users') is null then
    raise exception '請先執行 roster_schema.sql 與 assess_schema.sql';
  end if;
  if to_regprocedure('public.assess_dim_order()') is null
     or to_regprocedure('public.assess_level_pct(text)') is null
     or to_regprocedure('public.roster_touch_updated_at()') is null
     or to_regprocedure('public.roster_my_role()') is null then
    raise exception '請先執行 roster_schema.sql 與 assess_schema.sql（缺少必要函式）';
  end if;
end
$$;

-- ---------- 資料表：改善單 ----------
create table if not exists public.improvement_tickets (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null unique
    references public.assessments(id) on delete cascade,        -- 來源成績單，一張成績單最多一張改善單
  employee_id text not null
    references public.employees(id) on update cascade,
  store_code text not null,                                     -- 開單當下的門市快照，取自成績單，之後調店不改
  status text not null default 'open'
    check (status in ('open', 'coached', 'closed', 'cancelled')),  -- 待改善／已輔導／已結案／已取消
  target_dims text[] not null default '{}'::text[]
    check (target_dims <@ public.assess_dim_order()),           -- 改善面向，只能是七個面向的名稱
  due_date date not null,
  coached_on date,
  coach_note text,
  coached_by text,
  coached_at timestamptz,
  closed_by text,
  closed_at timestamptz,
  closed_by_assessment_id uuid
    references public.assessments(id) on delete set null,       -- 複檢成績單
  close_note text,
  cancelled_by text,
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists improvement_tickets_employee_idx
  on public.improvement_tickets(employee_id);
create index if not exists improvement_tickets_store_status_idx
  on public.improvement_tickets(store_code, status);

-- 更新時間自動更新（沿用名冊的函式）
drop trigger if exists improvement_tickets_touch_trg on public.improvement_tickets;
create trigger improvement_tickets_touch_trg
  before update on public.improvement_tickets
  for each row execute function public.roster_touch_updated_at();

-- ---------- 權限與 RLS ----------
alter table public.improvement_tickets enable row level security;

-- 先全收回；只給 authenticated「讀」，沒有任何人有直接寫入權限（只能透過函式與觸發器寫）
revoke all on table public.improvement_tickets from public, anon, authenticated;
grant select on public.improvement_tickets to authenticated;

-- 客服部：全看（含已取消）；總公司主管：全看但不含已取消；店長：只看自己門市且不含已取消
drop policy if exists improvement_tickets_select on public.improvement_tickets;
create policy improvement_tickets_select on public.improvement_tickets
  for select to authenticated
  using (
    public.roster_my_role() = 'cs_admin'
    or (status <> 'cancelled'
        and (public.roster_my_role() = 'hq_viewer'
             or (public.roster_my_role() = 'store_manager'
                 and store_code = public.roster_my_store())))
  );

-- ---------- 觸發器：自動開單 ----------
-- 成績單 status 由非 submitted 變成 submitted，且判定為「需複訓」或「不及格」→ 自動開一張改善單。
-- 同一張成績單只開一次（已存在就略過）。以函式擁有者身分寫入（security definer）。
-- 刻意不吞例外：這裡若失敗，assess_submit 會整筆失敗（成績單維持草稿、可重試），
-- 好過成績單送出成功卻靜默漏開單。緊急時用檔頭的 drop trigger 停用。
create or replace function public.improvement_auto_open()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'submitted'
     and old.status is distinct from 'submitted'
     and new.verdict in ('需複訓', '不及格') then
    insert into public.improvement_tickets
      (assessment_id, employee_id, store_code, status, target_dims, due_date)
    values
      (new.id, new.employee_id, new.store_code, 'open',
       coalesce(new.weakest_dims, '{}'::text[]),
       (now() at time zone 'Asia/Taipei')::date + 14)
    on conflict (assessment_id) do nothing;
  end if;
  return null;
end;
$$;

drop trigger if exists improvement_auto_open_trg on public.assessments;
create trigger improvement_auto_open_trg
  after update of status on public.assessments
  for each row
  when (old.status is distinct from 'submitted' and new.status = 'submitted')
  execute function public.improvement_auto_open();

-- ---------- 觸發器：成績單作廢時自動取消改善單 ----------
-- 成績單 status 變成 voided：對應改善單中 open／coached 的改為 cancelled；
-- 已結案（closed）與已取消的不動（取捨：結案是客服部已確認的歷史，不隨來源成績單作廢而翻動）。
create or replace function public.improvement_auto_cancel()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'voided' and old.status is distinct from 'voided' then
    update public.improvement_tickets
       set status = 'cancelled',
           cancelled_by = '(系統：成績單作廢)',
           cancelled_at = now(),
           cancel_reason = '成績單已作廢'
     where assessment_id = new.id
       and status in ('open', 'coached');
  end if;
  return null;
end;
$$;

drop trigger if exists improvement_auto_cancel_trg on public.assessments;
create trigger improvement_auto_cancel_trg
  after update of status on public.assessments
  for each row
  when (old.status is distinct from 'voided' and new.status = 'voided')
  execute function public.improvement_auto_cancel();

-- ---------- 小工具：狀態值轉中文（錯誤訊息只給中文，不印英文狀態值） ----------
create or replace function public.improvement_status_zh(p_status text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_status
           when 'open' then '待改善'
           when 'coached' then '已輔導'
           when 'closed' then '已結案'
           when 'cancelled' then '已取消'
           when 'draft' then '草稿'
           when 'submitted' then '已送出'
           when 'voided' then '已作廢'
           else '未知'
         end;
$$;

-- ---------- 函式：客服部調整改善面向與期限 ----------
create or replace function public.improve_update_plan(p_ticket_id uuid, p_target_dims text[], p_due_date date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t public.improvement_tickets%rowtype;
  v_dims text[];
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;

  select * into v_t from public.improvement_tickets where id = p_ticket_id for update;
  if not found then
    raise exception '找不到改善單';
  end if;
  if v_t.status not in ('open', 'coached') then
    raise exception '改善單狀態必須是待改善或已輔導（目前：%）', public.improvement_status_zh(v_t.status);
  end if;

  if p_target_dims is null or coalesce(array_length(p_target_dims, 1), 0) = 0 then
    raise exception '改善面向至少要選 1 個';
  end if;
  if exists (select 1 from unnest(p_target_dims) as t(d)
             where t.d is null or not (t.d = any(public.assess_dim_order()))) then
    raise exception '改善面向必須是七個面向之一';
  end if;

  if p_due_date is null then
    raise exception '期限不可空白';
  end if;
  if p_due_date < (v_t.created_at at time zone 'Asia/Taipei')::date then
    raise exception '期限不可早於開單日';
  end if;

  -- 去重並照固定順序存
  select array_agg(o.d order by o.n) into v_dims
  from unnest(public.assess_dim_order()) with ordinality as o(d, n)
  where o.d = any(p_target_dims);

  update public.improvement_tickets
     set target_dims = v_dims,
         due_date = p_due_date
   where id = p_ticket_id;
end;
$$;

-- ---------- 函式：回填「已輔導」（客服部，或自己門市的店長） ----------
create or replace function public.improve_mark_coached(p_ticket_id uuid, p_coached_on date, p_note text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_t public.improvement_tickets%rowtype;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_note text := btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288));   -- 去前後空白（含全形空白與換行）
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;

  select * into v_t from public.improvement_tickets where id = p_ticket_id for update;
  -- 店長（非客服部）：找不到、別間門市、不是待改善／已輔導的單，一律回同一句通用訊息，
  -- 不讓店長藉由單號探知別間門市或已取消、已結案單的存在
  if v_role = 'store_manager'
     and (not found
          or v_t.store_code is distinct from public.roster_my_store()
          or v_t.status not in ('open', 'coached')) then
    raise exception '找不到這張改善單或沒有權限';
  end if;
  if not found then
    raise exception '找不到改善單';
  end if;
  if v_t.status not in ('open', 'coached') then
    raise exception '改善單狀態必須是待改善或已輔導（目前：%）', public.improvement_status_zh(v_t.status);
  end if;

  if p_coached_on is null then
    raise exception '輔導日期不可空白';
  end if;
  if p_coached_on > v_today then
    raise exception '輔導日期不可晚於今天';
  end if;
  if p_coached_on < (v_t.created_at at time zone 'Asia/Taipei')::date then
    raise exception '輔導日期不可早於開單日';
  end if;
  if v_note = '' then
    raise exception '輔導備註不可為空';
  end if;

  update public.improvement_tickets
     set status = 'coached',
         coached_on = p_coached_on,
         coach_note = v_note,
         coached_by = public.roster_my_email(),
         coached_at = now()
   where id = p_ticket_id;
end;
$$;

-- ---------- 函式：結案（客服部確認複檢通過，連到複檢成績單） ----------
create or replace function public.improve_close(p_ticket_id uuid, p_recheck_assessment_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t public.improvement_tickets%rowtype;
  v_a public.assessments%rowtype;
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;

  select * into v_t from public.improvement_tickets where id = p_ticket_id for update;
  if not found then
    raise exception '找不到改善單';
  end if;
  if v_t.status not in ('open', 'coached') then
    raise exception '改善單狀態必須是待改善或已輔導（目前：%）', public.improvement_status_zh(v_t.status);
  end if;

  select * into v_a from public.assessments where id = p_recheck_assessment_id for share;
  if not found then
    raise exception '找不到複檢成績單';
  end if;
  if v_a.status <> 'submitted' then
    raise exception '複檢成績單必須是已送出的成績單（目前：%）', public.improvement_status_zh(v_a.status);
  end if;
  if v_a.employee_id <> v_t.employee_id then
    raise exception '複檢成績單必須是同一位考生的成績單';
  end if;
  if v_a.id = v_t.assessment_id then
    raise exception '複檢成績單不可以是來源成績單';
  end if;
  if v_a.submitted_at <= v_t.created_at then
    raise exception '複檢成績單必須在開單之後才送出';
  end if;
  if v_a.verdict not in ('及格', '優秀') then
    raise exception '複檢成績單判定必須是及格或優秀（目前：%）', v_a.verdict;
  end if;

  update public.improvement_tickets
     set status = 'closed',
         closed_by = public.roster_my_email(),
         closed_at = now(),
         closed_by_assessment_id = v_a.id,
         close_note = nullif(btrim(p_note, E' \t\r\n' || chr(12288)), '')
   where id = p_ticket_id;
end;
$$;

-- ---------- 函式：取消改善單（考生離職或轉調等，客服部） ----------
create or replace function public.improve_cancel(p_ticket_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t public.improvement_tickets%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''), E' \t\r\n' || chr(12288));
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;

  select * into v_t from public.improvement_tickets where id = p_ticket_id for update;
  if not found then
    raise exception '找不到改善單';
  end if;
  if v_t.status not in ('open', 'coached') then
    raise exception '改善單狀態必須是待改善或已輔導（目前：%）', public.improvement_status_zh(v_t.status);
  end if;
  if v_reason = '' then
    raise exception '取消原因不可空白';
  end if;

  update public.improvement_tickets
     set status = 'cancelled',
         cancelled_by = public.roster_my_email(),
         cancelled_at = now(),
         cancel_reason = v_reason
   where id = p_ticket_id;
end;
$$;

-- ---------- 檢視：改善單列表（含考生名稱、來源成績單摘要、逾期） ----------
-- security_invoker = true：以查詢者本人權限讀底層資料表，RLS 照樣生效，不會繞過。
-- 來源成績單用 left join：店長／主管看不到「已作廢」的成績單，
-- 但仍看得到已結案的改善單（只是來源成績單那幾欄會是空的）。
create or replace view public.improvement_ticket_view
with (security_invoker = true) as
select
  t.id,
  t.assessment_id,
  t.employee_id,
  a.employee_label,
  t.store_code,
  t.status,
  t.target_dims,
  t.due_date,
  t.coached_on,
  t.coach_note,
  t.coached_by,
  t.coached_at,
  t.closed_by,
  t.closed_at,
  t.closed_by_assessment_id,
  t.close_note,
  t.cancelled_by,
  t.cancelled_at,
  t.cancel_reason,
  t.created_at,
  t.updated_at,
  (a.created_at at time zone 'Asia/Taipei')::date as source_assessed_on,
  a.total_score as source_total_score,
  a.verdict as source_verdict,
  a.tenure as source_tenure,
  (t.status = 'open'
   and t.due_date < (now() at time zone 'Asia/Taipei')::date) as is_overdue,
  case when t.status = 'open'
            and t.due_date < (now() at time zone 'Asia/Taipei')::date
       then (now() at time zone 'Asia/Taipei')::date - t.due_date
       else 0
  end as days_overdue
from public.improvement_tickets t
left join public.assessments a on a.id = t.assessment_id;

revoke all on table public.improvement_ticket_view from public, anon, authenticated;
grant select on public.improvement_ticket_view to authenticated;

-- ---------- 檢視：弱項分析資料來源（每張已送出成績單、每個題組、每個面向一列） ----------
-- 只含 status = 'submitted' 的成績單；level_pct 為等級百分比（不適用為 null）。
-- 不 join 機密表，因此不含題組名稱、步驟、考點、備註；可見範圍與成績單 RLS 一致
-- （security_invoker：主管全看、店長自己門市、客服部全看；草稿與作廢的不會出現）。
create or replace view public.analytics_dim_rates
with (security_invoker = true) as
select
  a.id as assessment_id,
  a.employee_id,
  a.store_code,
  a.submitted_at,
  i.id as item_id,
  i.seq,
  d.dim,
  public.assess_level_pct(i.levels ->> d.dim)::int as level_pct
from public.assessments a
join public.assessment_items i on i.assessment_id = a.id
cross join lateral unnest(public.assess_dim_order()) as d(dim)
where a.status = 'submitted';

revoke all on table public.analytics_dim_rates from public, anon, authenticated;
grant select on public.analytics_dim_rates to authenticated;

-- ---------- 函式權限：收回 public／anon，只授權 authenticated ----------
-- 對外函式的身分檢查在函式內部（非授權角色一律丟「沒有權限」）。
revoke execute on function public.improve_update_plan(uuid, text[], date)  from public, anon;
revoke execute on function public.improve_mark_coached(uuid, date, text)   from public, anon;
revoke execute on function public.improve_close(uuid, uuid, text)          from public, anon;
revoke execute on function public.improve_cancel(uuid, text)               from public, anon;
-- 觸發器函式：任何網頁角色都不能直接呼叫
revoke execute on function public.improvement_status_zh(text)              from public, anon, authenticated;
revoke execute on function public.improvement_auto_open()                  from public, anon, authenticated;
revoke execute on function public.improvement_auto_cancel()                from public, anon, authenticated;

grant execute on function public.improve_update_plan(uuid, text[], date)   to authenticated;
grant execute on function public.improve_mark_coached(uuid, date, text)    to authenticated;
grant execute on function public.improve_close(uuid, uuid, text)           to authenticated;
grant execute on function public.improve_cancel(uuid, text)                to authenticated;
