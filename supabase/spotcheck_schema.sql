-- ============================================================
-- 業務考核系統：階段 4 抽查系統資料庫結構（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 唯一規格：README_spotcheck.md（規則、資料表、函式簽名、與既有函式的串接）。
-- 前提：roster_schema.sql（人員名冊）與 assess_schema.sql（評分與成績單）已在同一個專案執行過。
--       notes_visible_schema.sql、backoffice_schema.sql 有沒有執行都不影響本檔
--       （本檔改寫的 assess_start、assess_submit 與檢視，在這些檔案裡都沒有被重新定義過，
--        所以是以 assess_schema.sql／roster_schema.sql 的版本為基礎，原有行為逐行保留）。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 專案內原本沒有任何 spot_ 開頭、也沒有 probation 的名稱。
-- 本檔新增的名稱：
--   欄位：employees.probation_since（date，可空）
--   約束：assessments_tenure_source_check（重建，多收一個值「考核期」）
--   資料表：spot_inspections、spot_tickets、spot_probations
--   索引：spot_inspections_employee_idx、spot_inspections_store_idx、
--         spot_tickets_employee_idx、spot_tickets_store_idx、spot_tickets_inspection_idx、
--         spot_probations_employee_idx、spot_probations_store_idx
--   觸發器：spot_probations_touch_trg（掛在 spot_probations，更新 updated_at）
--   RLS policy：spot_inspections_select、spot_tickets_select、spot_probations_select
--   對外函式（授權 authenticated，函式內自己驗角色）：
--     spot_candidates、spot_register、spot_void_ticket、spot_coach、
--     spot_mark_executed、spot_cancel_probation、spot_status
--   內部小工具（任何網頁角色都不能直接呼叫）：spot_month_yellow_ids、spot_quarter_red_ids
--   被改寫的既有物件（create or replace／重建，簽名、回傳型別不變，原有行為全部保留）：
--     assess_start(text, text)、assess_submit(uuid)、檢視 employees_with_tenure
--
-- 怎麼執行（之後老闆同意才做）：
--   0. 先到 Supabase 備份（Dashboard → Database → Backups）。
--   1. Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   2. 再跑 spotcheck_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 單一交易：整份是 begin; … commit;，中途任何一步報錯整份自動回復，什麼都沒改。
-- 開頭設了 lock_timeout：拿不到資料表鎖（例如有人正在送出成績單）就報錯並整份回復，不會卡住別人，
-- 稍後重跑即可。請不要在中途自己手動下 commit／rollback。
--
-- 可重複執行：add column if not exists、約束先查名稱再 drop／add、資料表與索引 if not exists、
-- 函式 create or replace、policy 與 trigger 先 drop 再建、檢視 drop 後重建；重跑不會報錯，
-- 也不會刪掉既有資料（唯一會重建的是 employees_with_tenure 檢視，不含資料）。
--
-- 安全設計：三張新表全部開 RLS，直接寫入（insert／update／delete／truncate）一律不給，
-- 只能透過函式寫入；分數一律由資料庫用 assess_score_item 算，函式不接受前端傳來的分數。
-- 月與季一律用台北時間（Asia/Taipei）。
--
-- 並發保護：spot_register、spot_void_ticket、spot_cancel_probation、spot_mark_executed
-- 都先對「該員工那一列」（employees）做 for update 鎖定，再讀取次數與寫入單據；
-- 所以同一個人同時被登記兩次，第二個請求要等第一個提交後才會算次數，不會重複開紅單或重複開回考核期。
-- assess_submit 清除考核期時同樣會鎖員工列，因此與抽查登記也會排隊。
--
-- 次數的「排序基準」：單據的 created_at 預設用 clock_timestamp()（實際寫入時刻，而不是交易開始時刻），
-- 所以同一個交易內先後寫入的黃單與紅單也分得出先後（驗證腳本才測得到「紅單之後」的邊界）。
--
-- 緊急還原：
--   回復 assess_start／assess_submit 的原樣：把 assess_schema.sql 內這兩個函式整段重新執行即可。
--   employees_with_tenure 多出 probation_since 欄位無害。
--   新增的三張表與函式留著也不影響舊功能；真要移除請先備份。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯並整份回復，不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.employees') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.app_users') is null
     or to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null then
    raise exception '請先執行 roster_schema.sql 與 assess_schema.sql';
  end if;
  if to_regprocedure('public.assess_score_item(jsonb)') is null
     or to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_submit(uuid)') is null
     or to_regprocedure('public.roster_touch_updated_at()') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null
     or to_regprocedure('public.roster_my_email()') is null then
    raise exception '缺少必要函式，請先執行 roster_schema.sql 與 assess_schema.sql';
  end if;
end
$$;

-- ---------- 1. 名冊新欄位：考核期起始日 ----------
-- 有值＝目前在「考核期」（之後的考核一律用正式標準、總分 >= 85 才算通過，且不再被抽查）。
-- 由 spot_register（開回考核期）設定；由 assess_submit（通過）與 spot_cancel_probation（取消）清除。
alter table public.employees add column if not exists probation_since date;

comment on column public.employees.probation_since is
  '考核期起始日（台北日期）。有值＝目前在考核期；由抽查系統設定，考核通過或取消回考核期時清除。';

-- ---------- 2. assessments.tenure_source 的 check 加入「考核期」 ----------
-- 做法：先確認既有資料都在新的允許值內，再「查出」這一欄現有的 check 約束名稱（不寫死，
-- 避免名稱與預期不同時 drop 失敗），全部 drop，再以固定名稱重建（多收「考核期」）。
-- 只動「只管 tenure_source 這一欄」的 check；assessments_status_fields 等其他約束完全不碰。
do $$
declare
  v_att smallint;
  v_con record;
begin
  if exists (select 1 from public.assessments
             where tenure_source is null
                or tenure_source not in ('自動', '手動指定', '考核期')) then
    raise exception 'assessments 內有 tenure_source 不在「自動／手動指定／考核期」的資料，已停止（請先檢查）';
  end if;

  select a.attnum into v_att
  from pg_attribute a
  where a.attrelid = 'public.assessments'::regclass
    and a.attname = 'tenure_source'
    and not a.attisdropped;
  if v_att is null then
    raise exception 'assessments 沒有 tenure_source 欄位，與預期不符，已停止';
  end if;

  for v_con in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.assessments'::regclass
      and c.contype = 'c'
      and c.conkey = array[v_att]            -- 只管 tenure_source 這一欄的 check
  loop
    execute format('alter table public.assessments drop constraint %I', v_con.conname);
  end loop;

  alter table public.assessments
    add constraint assessments_tenure_source_check
    check (tenure_source in ('自動', '手動指定', '考核期'));
end
$$;

-- ---------- 3. 資料表 ----------

-- 一次抽查（客服部登記）
create table if not exists public.spot_inspections (
  id uuid primary key default gen_random_uuid(),
  employee_id text not null references public.employees(id) on update cascade,
  employee_label text not null,            -- 登記當下的暱稱或姓名（顯示用快照）
  store_code text not null references public.stores(code) on update cascade,  -- 登記當下的門市快照
  checked_on date not null,                -- 抽查日期（登記人填）
  message text,                            -- 抽到的訊息文字
  levels jsonb not null check (jsonb_typeof(levels) = 'object'),   -- 七面向等級
  total_score numeric(4,1) not null check (total_score between 0 and 100),
  dim_points jsonb,
  weakest_dims text[],
  verdict text not null check (verdict in ('適當', '不適當')),
  reason text,                             -- 判定不適當時必填
  examiner_email text not null
    check (examiner_email = lower(btrim(examiner_email)) and length(examiner_email) > 0),
  created_at timestamptz not null default clock_timestamp(),
  constraint spot_inspections_reason_required
    check (verdict <> '不適當' or nullif(btrim(reason), '') is not null)
);

create index if not exists spot_inspections_employee_idx on public.spot_inspections(employee_id, checked_on);
create index if not exists spot_inspections_store_idx on public.spot_inspections(store_code);

-- 單據：黃單（觀察單）與紅單（改善紅單）
create table if not exists public.spot_tickets (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('黃', '紅')),
  employee_id text not null references public.employees(id) on update cascade,
  employee_label text not null,
  store_code text not null references public.stores(code) on update cascade,
  inspection_id uuid references public.spot_inspections(id),   -- 黃單才有
  source_ticket_ids uuid[],                                    -- 紅單：湊成它的黃單
  reason text,
  issued_on date not null,                 -- 開單日（台北日期）；月與季的次數以它為準
  status text not null default '有效' check (status in ('有效', '作廢')),
  void_reason text,
  voided_by text,
  voided_at timestamptz,
  coached_on date,
  coach_note text,
  coached_by text,
  coached_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),   -- 同交易內也分得出先後
  -- 黃單必須有抽查、不能有來源黃單；紅單相反
  constraint spot_tickets_kind_fields check (
    (kind = '黃' and inspection_id is not null and source_ticket_ids is null)
    or (kind = '紅' and inspection_id is null and source_ticket_ids is not null)
  ),
  -- 作廢欄位：有效的單不能有作廢資料；作廢的單原因、時間、人都要有
  constraint spot_tickets_void_fields check (
    (status = '有效' and void_reason is null and voided_by is null and voided_at is null)
    or (status = '作廢' and nullif(btrim(void_reason), '') is not null
        and voided_by is not null and voided_at is not null)
  ),
  -- 輔導欄位：要嘛全空，要嘛日期、備註、填寫人、時間都有
  constraint spot_tickets_coach_fields check (
    (coached_on is null and coach_note is null and coached_by is null and coached_at is null)
    or (coached_on is not null and nullif(btrim(coach_note), '') is not null
        and coached_by is not null and coached_at is not null)
  )
);

create index if not exists spot_tickets_employee_idx on public.spot_tickets(employee_id, kind, status, issued_on);
create index if not exists spot_tickets_store_idx on public.spot_tickets(store_code);
create index if not exists spot_tickets_inspection_idx on public.spot_tickets(inspection_id);

-- 回考核期紀錄
create table if not exists public.spot_probations (
  id uuid primary key default gen_random_uuid(),
  employee_id text not null references public.employees(id) on update cascade,
  employee_label text not null,
  store_code text not null references public.stores(code) on update cascade,
  red_ticket_ids uuid[] not null,          -- 觸發它的有效紅單（本季、前一筆回考核期之後開出的）
  triggered_on date not null,              -- 開立日（台北日期），employees.probation_since 同一天
  status text not null default '待執行' check (status in ('待執行', '已執行', '已通過', '已取消')),
  executed_on date,
  executed_by text,
  passed_assessment_id uuid references public.assessments(id) on delete set null,
  cancel_reason text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default now(),
  constraint spot_probations_exec_fields check (
    (status <> '待執行' or (executed_on is null and executed_by is null))
    and (status <> '已執行' or (executed_on is not null and executed_by is not null))
  ),
  constraint spot_probations_cancel_fields check (
    status <> '已取消' or nullif(btrim(cancel_reason), '') is not null
  )
);

create index if not exists spot_probations_employee_idx on public.spot_probations(employee_id, status);
create index if not exists spot_probations_store_idx on public.spot_probations(store_code);

-- 更新時間自動更新（沿用名冊的函式）
drop trigger if exists spot_probations_touch_trg on public.spot_probations;
create trigger spot_probations_touch_trg
  before update on public.spot_probations
  for each row execute function public.roster_touch_updated_at();

-- ---------- 4. 權限與 RLS ----------
alter table public.spot_inspections enable row level security;
alter table public.spot_tickets     enable row level security;
alter table public.spot_probations  enable row level security;

-- 先全收回；只給 authenticated「讀」，沒有任何人有直接寫入權限（只能透過函式寫）
revoke all on table public.spot_inspections from public, anon, authenticated;
revoke all on table public.spot_tickets     from public, anon, authenticated;
revoke all on table public.spot_probations  from public, anon, authenticated;

grant select on public.spot_inspections to authenticated;
grant select on public.spot_tickets     to authenticated;
grant select on public.spot_probations  to authenticated;

-- 客服部、總公司主管：全看；店長：只看 store_code 等於自己門市；其他（含沒帳號）什麼都看不到
drop policy if exists spot_inspections_select on public.spot_inspections;
create policy spot_inspections_select on public.spot_inspections
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );

drop policy if exists spot_tickets_select on public.spot_tickets;
create policy spot_tickets_select on public.spot_tickets
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );

drop policy if exists spot_probations_select on public.spot_probations;
create policy spot_probations_select on public.spot_probations
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );

-- ---------- 5. 名冊檢視：帶出 probation_since ----------
-- 檢視裡的 e.* 是「建立當下」展開的，employees 新增欄位後舊檢視不會自動多出新欄位；
-- 而 create or replace view 不能把新欄位插在中間（tenure_group 會被擠後面），所以先 drop 再建。
-- 沒有其他檢視依賴它（assess_candidates 是函式，執行時才解析）。內容與 roster_schema.sql 完全相同。
-- security_invoker = true：以「查詢者本人」權限讀 employees，RLS 照樣生效。
drop view if exists public.employees_with_tenure;

create view public.employees_with_tenure
with (security_invoker = true) as
select
  e.*,
  case
    when e.hire_date is null then '未填到職日'
    when ((now() at time zone 'Asia/Taipei')::date - e.hire_date) <= 90 then '新人'
    else '正式'
  end as tenure_group
from public.employees e;

revoke all on table public.employees_with_tenure from public, anon, authenticated;
grant select on public.employees_with_tenure to authenticated;

-- ---------- 6. 內部小工具（次數計算；只給其他函式用） ----------

-- 「本日曆月（台北）內、最近一張有效紅單之後」的有效黃單 id（依開立先後）。
-- p_today = 台北今天；月份以 issued_on 判斷；「紅單之後」以 created_at 判斷。
-- 作廢的黃單、作廢的紅單都不算（作廢紅單＝它不再是「最近一張有效紅單」，之前的黃單會重新算回來）。
create or replace function public.spot_month_yellow_ids(p_employee_id text, p_today date)
returns uuid[]
language sql
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(t.id order by t.created_at), '{}'::uuid[])
  from public.spot_tickets t
  where t.employee_id = p_employee_id
    and t.kind = '黃'
    and t.status = '有效'
    and t.issued_on >= date_trunc('month', p_today::timestamp)::date
    and t.issued_on <  (date_trunc('month', p_today::timestamp) + interval '1 month')::date
    and t.created_at > coalesce(
          (select max(r.created_at)
             from public.spot_tickets r
            where r.employee_id = p_employee_id and r.kind = '紅' and r.status = '有效'),
          '-infinity'::timestamptz);
$$;

-- 「本日曆季（台北；1–3、4–6、7–9、10–12 月）內、最近一筆回考核期紀錄（任何狀態，含已通過、已取消）建立之後」
-- 才開出的有效紅單 id（依開立先後）；沒有回考核期紀錄時計本季全部有效紅單。
-- 回考核期發生後紅單重新從 0 算，與黃單「紅單之後重算」同一邏輯；以 created_at 比較。
create or replace function public.spot_quarter_red_ids(p_employee_id text, p_today date)
returns uuid[]
language sql
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(t.id order by t.created_at), '{}'::uuid[])
  from public.spot_tickets t
  where t.employee_id = p_employee_id
    and t.kind = '紅'
    and t.status = '有效'
    and t.issued_on >= date_trunc('quarter', p_today::timestamp)::date
    and t.issued_on <  (date_trunc('quarter', p_today::timestamp) + interval '3 months')::date
    and t.created_at > coalesce(
          (select max(p.created_at)
             from public.spot_probations p
            where p.employee_id = p_employee_id),
          '-infinity'::timestamptz);
$$;

-- ---------- 7. 對外函式 ----------

-- 抽查對象名單（客服部）：在職、納入考核、不是新人（到職日起 90 天內算新人；沒填到職日視為正式）、目前不在考核期
create or replace function public.spot_candidates()
returns table(id text, nickname text, full_name text, store_code text, job_title text, hire_date date)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  perform public.assess_assert_cs();
  return query
    select e.id, e.nickname, e.full_name, e.store_code, e.job_title, e.hire_date
    from public.employees e
    where e.status = '在職'
      and e.include_in_assessment
      and e.probation_since is null
      and (e.hire_date is null or (v_today - e.hire_date) > 90)
    order by e.store_code, e.id;
end;
$$;

-- 登記一次抽查（客服部）。
-- 驗證人員資格、七面向等級（缺一不可、不適用最多 2 個）、不適當必填原因；寫入抽查；
-- 不適當就開黃單，並在「同一個交易內」套用紅單與回考核期的規則：
--   * 本日曆月、最近一張有效紅單之後的有效黃單 >= 5 → 自動開一張紅單，黃單從 0 重算
--   * 本日曆季、最近一筆回考核期紀錄之後的有效紅單 >= 2 → 自動開一筆回考核期（待執行），employees.probation_since 設為今天
-- 回傳 {inspection_id, total_score, weakest_dims, yellow_id, red_id, probation_id}（沒有就是 null）。
create or replace function public.spot_register(
  p_employee_id text,
  p_checked_on date,
  p_message text,
  p_levels jsonb,
  p_verdict text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_emp public.employees%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, ''), E' \t\r\n' || chr(12288)), '');
  v_label text;
  s record;
  v_ins uuid;
  v_y uuid;
  v_r uuid;
  v_p uuid;
  v_ys uuid[];
  v_rs uuid[];
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 鎖住這個人的名冊列：同一個人的並發登記、作廢、考核通過會在這裡排隊，次數才不會算重或算漏
  select * into v_emp from public.employees where id = p_employee_id for update;
  if not found then
    raise exception '找不到員工：%', p_employee_id;
  end if;

  -- 抽查對象資格
  if v_emp.status <> '在職' then
    raise exception '該員工已離職，不能抽查';
  end if;
  if not v_emp.include_in_assessment then
    raise exception '該員工不在考核名單（需納入考核），不能抽查';
  end if;
  if v_emp.probation_since is not null then
    raise exception '該員工目前在考核期，不能抽查';
  end if;
  if v_emp.hire_date is not null and (v_today - v_emp.hire_date) <= 90 then
    raise exception '該員工是新人（到職日起 90 天內），不能抽查';
  end if;

  if p_checked_on is null then
    raise exception '抽查日期不可空白';
  end if;
  if p_verdict is null or p_verdict not in ('適當', '不適當') then
    raise exception '判定必須是「適當」或「不適當」';
  end if;
  if p_verdict = '不適當' and v_reason is null then
    raise exception '判定不適當時，原因不可空白';
  end if;

  -- 七面向等級驗證＋計分（鍵必須是七面向、值必須是四級或不適用、七個缺一不可、不適用最多 2 個）
  select * into s from public.assess_score_item(p_levels);

  v_label := coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), ''));

  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels,
     total_score, dim_points, weakest_dims, verdict, reason, examiner_email)
  values
    (v_emp.id, v_label, v_emp.store_code, p_checked_on, p_message, p_levels,
     s.item_score, s.dim_points, s.weakest_dims, p_verdict, v_reason, v_me)
  returning id into v_ins;

  if p_verdict = '不適當' then
    -- 黃單
    insert into public.spot_tickets
      (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on)
    values
      ('黃', v_emp.id, v_label, v_emp.store_code, v_ins, v_reason, v_today)
    returning id into v_y;

    -- 紅單：本日曆月、最近一張有效紅單之後的有效黃單滿 5 張
    v_ys := public.spot_month_yellow_ids(v_emp.id, v_today);
    if coalesce(array_length(v_ys, 1), 0) >= 5 then
      insert into public.spot_tickets
        (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on)
      values
        ('紅', v_emp.id, v_label, v_emp.store_code, v_ys,
         format('同一日曆月內累積 %s 張有效黃單，系統自動開立改善紅單', array_length(v_ys, 1)),
         v_today)
      returning id into v_r;

      -- 回考核期：本日曆季、最近一筆回考核期紀錄（任何狀態）之後的有效紅單滿 2 張
      v_rs := public.spot_quarter_red_ids(v_emp.id, v_today);
      if coalesce(array_length(v_rs, 1), 0) >= 2 then
        insert into public.spot_probations
          (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
        values
          (v_emp.id, v_label, v_emp.store_code, v_rs, v_today, '待執行')
        returning id into v_p;

        update public.employees set probation_since = v_today where id = v_emp.id;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'inspection_id', v_ins,
    'total_score', s.item_score,
    'weakest_dims', to_jsonb(s.weakest_dims),
    'yellow_id', v_y,
    'red_id', v_r,
    'probation_id', v_p
  );
end;
$$;

-- 作廢單據（客服部）：原因必填；不刪除；已作廢不可再作廢。
-- 次數永遠由「有效單」即時計算，作廢後自動少算；
-- 作廢不會倒回去取消已開出的紅單或回考核期（那要靠客服部自己作廢紅單、取消回考核期）。
create or replace function public.spot_void_ticket(p_ticket_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_emp text;
  v_t public.spot_tickets%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''), E' \t\r\n' || chr(12288));
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select t.employee_id into v_emp from public.spot_tickets t where t.id = p_ticket_id;
  if not found then
    raise exception '找不到單據';
  end if;

  -- 與登記同一個鎖順序：先鎖員工列，再鎖單據
  perform 1 from public.employees e where e.id = v_emp for update;
  select * into v_t from public.spot_tickets where id = p_ticket_id for update;

  if v_t.status = '作廢' then
    raise exception '這張單已作廢，不可重複作廢';
  end if;
  if v_reason = '' then
    raise exception '作廢原因不可空白';
  end if;

  update public.spot_tickets
     set status = '作廢',
         void_reason = v_reason,
         voided_by = v_me,
         voided_at = now()
   where id = p_ticket_id;
end;
$$;

-- 回填輔導（客服部，或該門市的店長）：日期、備註必填；作廢的單不能回填；可重填修改。
-- 店長對「找不到、別間門市」的單一律只回同一句通用訊息，不讓店長藉單號探知別間門市的單是否存在。
create or replace function public.spot_coach(p_ticket_id uuid, p_coached_on date, p_note text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_t public.spot_tickets%rowtype;
  v_note text := btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288));
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;

  select * into v_t from public.spot_tickets where id = p_ticket_id for update;
  if v_role = 'store_manager'
     and (not found or v_t.store_code is distinct from public.roster_my_store()) then
    raise exception '找不到這張單據或沒有權限';
  end if;
  if not found then
    raise exception '找不到單據';
  end if;
  if v_t.status = '作廢' then
    raise exception '作廢的單不能回填輔導';
  end if;

  if p_coached_on is null then
    raise exception '輔導日期不可空白';
  end if;
  if v_note = '' then
    raise exception '輔導備註不可為空';
  end if;

  update public.spot_tickets
     set coached_on = p_coached_on,
         coach_note = v_note,
         coached_by = public.roster_my_email(),
         coached_at = now()
   where id = p_ticket_id;
end;
$$;

-- 標記已執行（客服部）：待執行 → 已執行，記日期（台北今天）與人
create or replace function public.spot_mark_executed(p_probation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_emp text;
  v_p public.spot_probations%rowtype;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select p.employee_id into v_emp from public.spot_probations p where p.id = p_probation_id;
  if not found then
    raise exception '找不到回考核期紀錄';
  end if;

  perform 1 from public.employees e where e.id = v_emp for update;
  select * into v_p from public.spot_probations where id = p_probation_id for update;

  if v_p.status <> '待執行' then
    raise exception '回考核期紀錄必須是「待執行」才能標記已執行（目前：%）', v_p.status;
  end if;

  update public.spot_probations
     set status = '已執行',
         executed_on = (now() at time zone 'Asia/Taipei')::date,
         executed_by = v_me
   where id = p_probation_id;
end;
$$;

-- 取消回考核期（客服部，誤判時用）：狀態改已取消、清除 employees.probation_since；原因必填；已通過者不可取消
create or replace function public.spot_cancel_probation(p_probation_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_emp text;
  v_p public.spot_probations%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''), E' \t\r\n' || chr(12288));
begin
  perform public.assess_assert_cs();

  select p.employee_id into v_emp from public.spot_probations p where p.id = p_probation_id;
  if not found then
    raise exception '找不到回考核期紀錄';
  end if;

  perform 1 from public.employees e where e.id = v_emp for update;
  select * into v_p from public.spot_probations where id = p_probation_id for update;

  if v_p.status = '已通過' then
    raise exception '已通過的回考核期不可取消';
  end if;
  if v_p.status = '已取消' then
    raise exception '這筆回考核期已經取消';
  end if;
  if v_reason = '' then
    raise exception '取消原因不可空白';
  end if;

  update public.spot_probations
     set status = '已取消',
         cancel_reason = v_reason
   where id = p_probation_id;

  -- 清除考核期；若同一人（不應發生）還有別筆進行中的回考核期，則不清除
  if not exists (select 1 from public.spot_probations x
                 where x.employee_id = v_p.employee_id
                   and x.id <> v_p.id
                   and x.status in ('待執行', '已執行')) then
    update public.employees set probation_since = null where id = v_p.employee_id;
  end if;
end;
$$;

-- 人員抽查狀態（全部已開通角色；店長只看自己門市）。
-- 範圍：在職、納入考核、而且是「正式或考核期」的人員（新人不列入；沒填到職日視為正式）。
-- yellow_month：呼叫當下的台北日曆月、最近一張有效紅單之後的有效黃單數
-- red_quarter：呼叫當下的台北日曆季內、最近一筆回考核期紀錄之後的有效紅單數（目前還在累計中的紅單數）
-- probation_id／probation_status：該員目前進行中（待執行／已執行）的回考核期；沒有就是 null
create or replace function public.spot_status()
returns table(employee_id text, employee_label text, store_code text,
              yellow_month int, red_quarter int, probation_id uuid, probation_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_store text := public.roster_my_store();
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if v_role not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;

  return query
    select e.id,
           coalesce(nullif(btrim(e.nickname), ''), nullif(btrim(e.full_name), '')),
           e.store_code,
           coalesce(array_length(public.spot_month_yellow_ids(e.id, v_today), 1), 0),
           coalesce(array_length(public.spot_quarter_red_ids(e.id, v_today), 1), 0),
           p.id,
           p.status
    from public.employees e
    left join lateral (
      select pp.id, pp.status
      from public.spot_probations pp
      where pp.employee_id = e.id and pp.status in ('待執行', '已執行')
      order by pp.created_at desc
      limit 1
    ) p on true
    where e.status = '在職'
      and e.include_in_assessment
      and (e.probation_since is not null
           or e.hire_date is null
           or (v_today - e.hire_date) > 90)
      and (v_role in ('cs_admin', 'hq_viewer') or e.store_code = v_store)
    order by e.store_code, e.id;
end;
$$;

-- ---------- 8. 與既有功能的串接 ----------

-- 開始考核：以 assess_schema.sql 的版本為基礎，原有行為全部保留，只新增一段：
--   員工 probation_since 有值（考核期）→ 身分一律「正式」、tenure_source = '考核期'
--   （忽略到職日與 p_tenure_override；到職日空白也不需要手動指定）。
-- 其餘（找不到員工、不在考核名單、到職日自動算新人／正式、空白需手動指定、
--       同考官同員工已有草稿就回傳既有那張）完全不變。
create or replace function public.assess_start(p_employee_id text, p_tenure_override text default null)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_emp public.employees%rowtype;
  v_tenure text;
  v_source text;
  v_id uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception '找不到員工：%', p_employee_id;
  end if;
  if not v_emp.include_in_assessment or v_emp.status <> '在職' then
    raise exception '該員工不在考核名單（需納入考核且在職）';
  end if;

  if v_emp.probation_since is not null then
    -- 【新增】考核期：一律用正式員工標準，來源記「考核期」
    v_tenure := '正式';
    v_source := '考核期';
  elsif v_emp.hire_date is not null then
    v_tenure := case
                  when ((now() at time zone 'Asia/Taipei')::date - v_emp.hire_date) <= 90 then '新人'
                  else '正式'
                end;
    v_source := '自動';
  else
    if p_tenure_override is null or p_tenure_override not in ('新人', '正式') then
      raise exception '到職日空白，請手動指定「新人」或「正式」';
    end if;
    v_tenure := p_tenure_override;
    v_source := '手動指定';
  end if;

  -- 直接嘗試新增；同考官同員工已有草稿（含兩個請求同時進來）時，
  -- 唯一部分索引讓 on conflict do nothing 生效，改回傳既有那張，不報唯一鍵錯誤
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot)
  values
    (v_emp.id,
     coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), '')),
     v_emp.store_code, v_me, 'draft', v_tenure, v_source, v_emp.hire_date)
  on conflict (examiner_email, employee_id) where status = 'draft' do nothing
  returning id into v_id;

  if v_id is null then
    select a.id into v_id
    from public.assessments a
    where a.employee_id = v_emp.id and a.examiner_email = v_me and a.status = 'draft';
  end if;

  return v_id;
end;
$$;

-- 送出：以 assess_schema.sql 的版本為基礎，原有行為全部保留，只在「更新成績單為已送出」之後新增一段：
--   這張成績單 tenure_source = '考核期' 且總分 >= 85 → 清除 employees.probation_since，
--   該員進行中（待執行／已執行）的 spot_probations 改「已通過」並記 passed_assessment_id。
--   總分 < 85 → 什麼都不動（維持考核期）。assess_void（作廢成績單）不倒回已通過的考核期，維持現狀。
create or replace function public.assess_submit(p_assessment_id uuid)
returns table(total_score numeric, verdict text, pass_line int, weakest_dims text[],
              tenure text, item_count int)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_me text;
  v_a public.assessments%rowtype;
  r record;
  s record;
  v_levels jsonb := '[]'::jsonb;
  v_cnt int := 0;
  v_total numeric;
  v_weak text[];
  v_ver text;
  v_line int;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以送出';
  end if;
  if v_a.examiner_email <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  for r in
    select i.id, i.seq, i.levels
    from public.assessment_items i
    where i.assessment_id = v_a.id
    order by i.seq
  loop
    v_cnt := v_cnt + 1;
    begin
      select * into s from public.assess_score_item(r.levels);
    exception when others then
      raise exception '第 % 題組評分不完整或不正確：%', r.seq, sqlerrm;
    end;

    update public.assessment_items
       set item_score = s.item_score,
           dim_points = s.dim_points,
           na_dims = s.na_dims,
           weakest_dims = s.weakest_dims
     where id = r.id;

    v_levels := v_levels || jsonb_build_array(r.levels);
  end loop;

  if v_cnt = 0 then
    raise exception '至少要有 1 個題組';
  end if;

  select ss.total_score, ss.weakest_dims into v_total, v_weak
  from public.assess_score_session(v_levels) as ss;

  select vd.verdict, vd.pass_line into v_ver, v_line
  from public.assess_verdict(v_total, v_a.tenure) as vd;

  update public.assessments
     set status = 'submitted',
         total_score = v_total,
         verdict = v_ver,
         pass_line = v_line,
         weakest_dims = v_weak,
         submitted_at = now()
   where id = v_a.id;

  -- 【新增】考核期通過：來源是「考核期」且總分 >= 85
  if v_a.tenure_source = '考核期' and v_total >= 85 then
    update public.employees set probation_since = null where id = v_a.employee_id;

    update public.spot_probations
       set status = '已通過',
           passed_assessment_id = v_a.id
     where employee_id = v_a.employee_id
       and status in ('待執行', '已執行');
  end if;

  total_score := v_total;
  verdict := v_ver;
  pass_line := v_line;
  weakest_dims := v_weak;
  tenure := v_a.tenure;
  item_count := v_cnt;
  return next;
end;
$$;

-- ---------- 9. 函式權限：收回 public／anon，只授權 authenticated ----------
-- 對外函式的角色檢查在函式內部（非授權角色一律丟「沒有權限」）。
revoke execute on function public.spot_candidates()                          from public, anon;
revoke execute on function public.spot_register(text, date, text, jsonb, text, text) from public, anon;
revoke execute on function public.spot_void_ticket(uuid, text)               from public, anon;
revoke execute on function public.spot_coach(uuid, date, text)               from public, anon;
revoke execute on function public.spot_mark_executed(uuid)                   from public, anon;
revoke execute on function public.spot_cancel_probation(uuid, text)          from public, anon;
revoke execute on function public.spot_status()                              from public, anon;
revoke execute on function public.assess_start(text, text)                   from public, anon;
revoke execute on function public.assess_submit(uuid)                        from public, anon;
-- 內部小工具：連 authenticated 都不開放直接呼叫（函式之間以擁有者身分呼叫）
revoke execute on function public.spot_month_yellow_ids(text, date)          from public, anon, authenticated;
revoke execute on function public.spot_quarter_red_ids(text, date)           from public, anon, authenticated;

grant execute on function public.spot_candidates()                           to authenticated;
grant execute on function public.spot_register(text, date, text, jsonb, text, text) to authenticated;
grant execute on function public.spot_void_ticket(uuid, text)                to authenticated;
grant execute on function public.spot_coach(uuid, date, text)                to authenticated;
grant execute on function public.spot_mark_executed(uuid)                    to authenticated;
grant execute on function public.spot_cancel_probation(uuid, text)           to authenticated;
grant execute on function public.spot_status()                               to authenticated;
grant execute on function public.assess_start(text, text)                    to authenticated;
grant execute on function public.assess_submit(uuid)                         to authenticated;

commit;
