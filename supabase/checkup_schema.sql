-- ============================================================
-- 業務考核系統：第二期「每年健檢」資料庫結構（任務 1：資料庫）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。
--
-- 唯一規格：README_checkup.md（規則、函式合約、稽核表、遷移前後人工檢查）。
-- 前提（缺任何一個，開頭會用中文錯誤訊息擋下並整份回復）：
--   考題抽選器 schema.sql、roster、assess、bank、accounts、notes_visible、backoffice、spotcheck、url_patch、
--   weak_suggest、exam_request、phase1（第一期）都已在同一個專案執行過。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 專案內原本沒有 checkup、checkups、checkup_store_quarter、kind、checkup_year、checkup_quarter 這些名稱。
-- 本檔新增的名稱：
--   欄位：assessments.kind、assessments.checkup_year、assessments.checkup_quarter
--   約束／索引：assessments_kind_check、assessments_kind_fields、assessments_checkup_formal（check）、
--         assessments_one_checkup_per_year（唯一部分索引）、
--         assessments_one_draft_per_pair（既有索引改成只管 kind='exam'，名稱不變）、
--         checkup_store_quarter_pkey、checkups_pkey、checkups_employee_year_key（unique(employee_id, year)）、
--         checkups_assessment_uni（唯一部分索引）、checkups_store_idx、checkups_year_quarter_idx
--   資料表：checkup_store_quarter（門市季次表）、checkups（排定表）
--   RLS policy：checkup_store_quarter_select、checkups_select
--   對外函式（授權 authenticated，函式內自己驗角色）：
--     checkup_quarters_list()、checkup_quarter_set(text, int)、checkup_roster(int, int)、
--     checkup_schedule(text, int, int, timestamptz, text)、checkup_unschedule(uuid)、checkup_begin(text, int, int)
--   內部函式（任何網頁角色都不能直接呼叫）：checkup_first_day(int, int)、checkup_eligible(text, int, int)
--   被改寫的既有物件（簽名、回傳型別都不變；kind='exam' 的行為與改寫前逐行相同，差異說明見 README_checkup.md）：
--     函式：assess_start(text, text)、assess_submit(uuid)、assess_weak_profile(text)、improve_close(uuid, uuid, text)、
--           phase1_migrate_period_status()
--     觸發器函式：improvement_auto_open()、exam_req_auto_complete()（觸發器本身沒動）
--     檢視：assessment_summaries（尾端追加 kind、checkup_year、checkup_quarter）
--
-- 怎麼執行（之後老闆同意才做）：
--   0. 先到 Supabase 備份（Dashboard → Database → Backups），並先跑 README_checkup.md「遷移前檢查」查詢。
--   1. Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。拿不到鎖會在 5 秒後整份回復，稍後重跑即可。
--   2. 再跑 checkup_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 單一交易：整份是 begin; … commit;，中途任何一步報錯整份自動回復，什麼都沒改。請不要在中途自己手動下 commit／rollback。
-- 可重複執行：欄位 add column if not exists、約束與索引先查再建、資料表 if not exists、函式 create or replace、
--   policy 先 drop 再建、檢視 create or replace；門市季次種子 on conflict do nothing（重跑不會蓋掉客服部改過的季次）。
--
-- 安全設計：checkup_store_quarter、checkups 開 RLS，直接寫入一律不給，只能透過函式；日期一律用台北時間。
--   健檢成績單（kind='checkup'）送出時：不動 employees、不建待開通、不開改善單、不完成待考回報、不改 spot_probations。
--
-- 緊急還原：
--   * 新欄位、新資料表、新函式留著不影響舊功能（既有資料全是 kind='exam'）。
--   * 還原被改寫的函式：分別重新執行 phase1_schema.sql 內的 assess_start／assess_submit／assess_weak_profile／
--     phase1_migrate_period_status、backoffice_schema.sql 的 improvement_auto_open／improve_close、
--     exam_request_schema.sql 的 exam_req_auto_complete（若已有健檢成績單資料，還原後它們會被當一般考核處理，請先不要還原）。
--   * 檢視還原：重新執行 phase1_schema.sql 的 assessment_summaries。
--   * 還原 assess_start 之前要先把 assessments_one_draft_per_pair 改回「只 where status = 'draft'」的版本：
--       drop index public.assessments_one_draft_per_pair;
--       create unique index assessments_one_draft_per_pair on public.assessments(examiner_email, employee_id) where status = 'draft';
--     （前提：沒有健檢草稿與考核草稿撞在同一考官同一員工）
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
  if to_regclass('public.reply_activations') is null
     or to_regprocedure('public.assess_core_categories()') is null
     or to_regprocedure('public.phase1_migrate_period_status()') is null then
    raise exception '請先執行 phase1_schema.sql（第一期）';
  end if;
  if to_regclass('public.improvement_tickets') is null
     or to_regprocedure('public.improvement_auto_open()') is null
     or to_regprocedure('public.improve_close(uuid, uuid, text)') is null then
    raise exception '請先執行 backoffice_schema.sql';
  end if;
  if to_regprocedure('public.exam_req_auto_complete()') is null then
    raise exception '請先執行 exam_request_schema.sql';
  end if;
  if to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_verdict(numeric, text)') is null
     or to_regprocedure('public.exam_req_label(text, text)') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null
     or to_regprocedure('public.roster_my_email()') is null then
    raise exception '缺少必要函式，請先執行 roster／assess／exam_request 各 schema';
  end if;
  -- 確認被改寫的函式目前是第一期（或本檔已套用過）的版本——本檔以那一版為基礎逐行改寫
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.assess_submit(uuid)'::regprocedure
                   and p.prosrc like '%reply_activations%' and p.prosrc like '%is_extra%')
     or not exists (select 1 from pg_proc p
                    where p.oid = 'public.assess_start(text, text)'::regprocedure
                      and p.prosrc like '%period_status%')
     or not exists (select 1 from pg_proc p
                    where p.oid = 'public.assess_weak_profile(text)'::regprocedure
                      and p.prosrc like '%is_extra%') then
    raise exception 'assess_start／assess_submit／assess_weak_profile 不是第一期（phase1_schema.sql）的版本，請先執行 phase1_schema.sql';
  end if;
end
$$;

-- ---------- 1. assessments：成績單種類（考核／健檢） ----------
-- kind：'exam'（一般考核，既有資料全是這個）／'checkup'（每年健檢）。
-- 健檢成績單一律「正式」身分（合格線 85，沿用 assess_verdict 的正式判定）；checkup_begin 建的草稿來源一律「自動」。
alter table public.assessments add column if not exists kind text not null default 'exam';
alter table public.assessments add column if not exists checkup_year int;
alter table public.assessments add column if not exists checkup_quarter int;

comment on column public.assessments.kind is
  'exam＝一般考核（含考核期、補考、複檢）；checkup＝每年健檢（只記錄，不改考核期、不開改善單、不進待開通）。';
comment on column public.assessments.checkup_year is '健檢年度（只有 kind=checkup 才有值）。';
comment on column public.assessments.checkup_quarter is '健檢季次 1～4（只有 kind=checkup 才有值）。';

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.assessments'::regclass and conname = 'assessments_kind_check') then
    alter table public.assessments
      add constraint assessments_kind_check check (kind in ('exam', 'checkup'));
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.assessments'::regclass and conname = 'assessments_kind_fields') then
    alter table public.assessments
      add constraint assessments_kind_fields check (
        (kind = 'exam' and checkup_year is null and checkup_quarter is null)
        or (kind = 'checkup' and checkup_year is not null and checkup_quarter is not null
              and checkup_year between 2000 and 2100 and checkup_quarter between 1 and 4));
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.assessments'::regclass and conname = 'assessments_checkup_formal') then
    alter table public.assessments
      add constraint assessments_checkup_formal check (
        kind <> 'checkup' or tenure = '正式');
  end if;
end
$$;

-- 同一員工同一年度最多一張「未作廢」的健檢（含草稿）；作廢後可再建
create unique index if not exists assessments_one_checkup_per_year
  on public.assessments(employee_id, checkup_year)
  where kind = 'checkup' and status <> 'voided';

-- 既有「同考官同員工只能有一張草稿」索引：改成只管一般考核（kind='exam'），名稱不變。
-- 原因：assess_start 的 on conflict 依賴它；若健檢草稿也算進去，考官手上有健檢草稿時開一般考核，
-- 會誤把健檢草稿當成考核草稿回傳。一般考核的行為不變（既有資料全是 exam）。重跑時索引已是新版就略過。
do $$
declare
  v_def text;
begin
  select i.indexdef into v_def from pg_indexes i
   where i.schemaname = 'public' and i.indexname = 'assessments_one_draft_per_pair';
  if v_def is null or v_def not like '%kind%' then
    drop index if exists public.assessments_one_draft_per_pair;
    create unique index assessments_one_draft_per_pair
      on public.assessments(examiner_email, employee_id)
      where status = 'draft' and kind = 'exam';
  end if;
end
$$;

-- ---------- 2. 門市季次表 ----------
create table if not exists public.checkup_store_quarter (
  store_code text primary key references public.stores(code) on update cascade,
  quarter int not null check (quarter between 1 and 4),
  updated_at timestamptz not null default now(),
  updated_by text
);
comment on table public.checkup_store_quarter is
  '每年健檢：門市所屬季次（全年共用一份，不分年度）。客服部可改（checkup_quarter_set），改了從下一次起算；總公司不在表內。';

alter table public.checkup_store_quarter enable row level security;
drop policy if exists checkup_store_quarter_select on public.checkup_store_quarter;
create policy checkup_store_quarter_select on public.checkup_store_quarter
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );
revoke all on table public.checkup_store_quarter from public, anon, authenticated;
grant select on public.checkup_store_quarter to authenticated;

-- 預設季次種子（老闆指定）：Q1 中和、新莊、樹林；Q2 桃園中壢、新竹、花蓮；Q3 旗艦、南台中、太平；Q4 台南、高雄。
-- 門市代碼＝門市名稱（import_roster 與 js/api.js STORE_ORDER 一致）；stores 沒有的門市不會種入（下面會提醒）。
-- on conflict do nothing：重跑不會蓋掉客服部之後改過的季次。
insert into public.checkup_store_quarter (store_code, quarter, updated_by)
select s.code, v.q, '(系統預設)'
from (values ('中和', 1), ('新莊', 1), ('樹林', 1),
             ('桃園中壢', 2), ('新竹', 2), ('花蓮', 2),
             ('旗艦', 3), ('南台中', 3), ('太平', 3),
             ('台南', 4), ('高雄', 4)) as v(code, q)
join public.stores s on s.code = v.code
on conflict (store_code) do nothing;

do $$
declare
  v_missing text;
begin
  select string_agg(v.code, '、') into v_missing
  from (values ('中和'), ('新莊'), ('樹林'), ('桃園中壢'), ('新竹'), ('花蓮'),
               ('旗艦'), ('南台中'), ('太平'), ('台南'), ('高雄')) as v(code)
  where not exists (select 1 from public.checkup_store_quarter q where q.store_code = v.code);
  if v_missing is not null then
    raise warning '健檢季次種子：以下門市在 stores 表找不到，沒有種入季次（請確認門市代碼）：%', v_missing;
  end if;
end
$$;

-- ---------- 3. 排定表 ----------
-- 一列＝這位人員這一年已被排定健檢。狀態由資料推得：
--   沒有列＝待排定；有列且 assessment 未送出（沒有、草稿、已作廢）＝已排定；assessment 已送出且未作廢＝已完成。
-- store_code 是排定當下的門市快照。assessment_id 由 checkup_begin 連上；成績單被放棄（刪除）時自動變回空。
create table if not exists public.checkups (
  id uuid primary key default gen_random_uuid(),
  employee_id text not null references public.employees(id) on update cascade on delete cascade,
  year int not null check (year between 2000 and 2100),
  quarter int not null check (quarter between 1 and 4),
  store_code text not null references public.stores(code) on update cascade,
  scheduled_at timestamptz not null,
  scheduled_by text not null,
  note text check (note is null or char_length(note) <= 500),
  assessment_id uuid references public.assessments(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint checkups_employee_year_key unique (employee_id, year)
);
create unique index if not exists checkups_assessment_uni on public.checkups(assessment_id) where assessment_id is not null;
create index if not exists checkups_store_idx on public.checkups(store_code);
create index if not exists checkups_year_quarter_idx on public.checkups(year, quarter);

alter table public.checkups enable row level security;
drop policy if exists checkups_select on public.checkups;
create policy checkups_select on public.checkups
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );
revoke all on table public.checkups from public, anon, authenticated;
grant select on public.checkups to authenticated;

-- ---------- 4. 內部小函式 ----------
-- 該年該季第一天（Q1＝1/1、Q2＝4/1、Q3＝7/1、Q4＝10/1）
create or replace function public.checkup_first_day(p_year int, p_quarter int)
returns date
language sql
immutable
set search_path = public, pg_temp
as $$
  select make_date(p_year, (p_quarter - 1) * 3 + 1, 1);
$$;

-- 這位員工「依規則」是否在該年該季的健檢名單內（不看是否已排定／已完成，那由呼叫端另外判斷）：
--   在職、納入考核、period_status＝已上線、門市目前屬於該季；
--   若有 passed_on，必須早於該季第一天（通過考核期的人要「下一個輪到自己門市的季」才第一次健檢）；passed_on 為空視為長期已上線。
create or replace function public.checkup_eligible(p_employee text, p_year int, p_quarter int)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.employees e
    join public.checkup_store_quarter q on q.store_code = e.store_code and q.quarter = p_quarter
    where e.id = p_employee
      and e.status = '在職'
      and e.include_in_assessment
      and e.period_status = '已上線'
      and (e.passed_on is null or e.passed_on < public.checkup_first_day(p_year, p_quarter))
  );
$$;

-- ---------- 5. checkup_quarters_list：門市季次＋目前應健檢人數 ----------
create or replace function public.checkup_quarters_list()
returns table(store_code text, store_name text, quarter int, headcount int, updated_at timestamptz, updated_by text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_store text;
begin
  if v_role not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if v_role = 'store_manager' then
    v_store := public.roster_my_store();
  end if;

  return query
    select q.store_code,
           s.name,
           q.quarter,
           (select count(*) from public.employees e
             where e.store_code = q.store_code
               and e.status = '在職'
               and e.include_in_assessment
               and e.period_status = '已上線')::int,
           q.updated_at,
           case when v_role = 'cs_admin' then q.updated_by else null end
    from public.checkup_store_quarter q
    join public.stores s on s.code = q.store_code
    where v_store is null or q.store_code = v_store
    order by q.quarter, q.store_code;
end;
$$;

-- ---------- 6. checkup_quarter_set：改門市季次（只有客服部） ----------
-- 只能改季次表內已有的門市（總公司或不存在的門市會被擋）；改了不影響已排定的健檢，從下一次起算。
create or replace function public.checkup_quarter_set(p_store text, p_quarter int)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_store text := btrim(coalesce(p_store, ''));
begin
  perform public.assess_assert_cs();
  if p_quarter is null or p_quarter not between 1 and 4 then
    raise exception '季次必須是 1 到 4';
  end if;

  update public.checkup_store_quarter
     set quarter = p_quarter,
         updated_at = now(),
         updated_by = public.roster_my_email()
   where store_code = v_store;
  if not found then
    raise exception '這間門市不在健檢季次表內（總公司或不存在的門市）：%', v_store;
  end if;
end;
$$;

-- ---------- 7. checkup_roster：某年某季的健檢名單 ----------
-- 名單 ＝（A）該年該季已有排定列的人（不論之後門市改季次或人員狀態變動，排定了就留在原季）
--       ＋（B）依規則在名單內、且該年還沒有排定列也沒有未作廢健檢成績單的人（見 checkup_eligible）。
-- 店長只看自己門市；客服部、總公司主管全看。草稿狀態只有客服部看得到（其他角色把草稿當「尚未開始」）。
create or replace function public.checkup_roster(p_year int, p_quarter int)
returns table(employee_id text, display_name text, store_code text, store_name text, hire_date date,
              is_first boolean, status text, scheduled_at timestamptz, checkup_id uuid, assessment_id uuid,
              score numeric, verdict text, assessment_status text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_store text;
begin
  if v_role not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_year is null or p_year not between 2000 and 2100 then
    raise exception '年度不正確';
  end if;
  if p_quarter is null or p_quarter not between 1 and 4 then
    raise exception '季次必須是 1 到 4';
  end if;
  if v_role = 'store_manager' then
    v_store := public.roster_my_store();
  end if;

  return query
    with cand as (
      select c.employee_id as emp, c.store_code as st
      from public.checkups c
      where c.year = p_year and c.quarter = p_quarter
      union all
      select e.id, e.store_code
      from public.employees e
      join public.checkup_store_quarter q on q.store_code = e.store_code and q.quarter = p_quarter
      where e.status = '在職'
        and e.include_in_assessment
        and e.period_status = '已上線'
        and (e.passed_on is null or e.passed_on < public.checkup_first_day(p_year, p_quarter))
        and not exists (select 1 from public.checkups c2
                         where c2.employee_id = e.id and c2.year = p_year)
        and not exists (select 1 from public.assessments a2
                         where a2.employee_id = e.id and a2.kind = 'checkup'
                           and a2.checkup_year = p_year and a2.status <> 'voided')
    )
    select e.id,
           public.exam_req_label(e.nickname, e.full_name),
           cand.st,
           s.name,
           e.hire_date,
           not exists (select 1 from public.assessments h
                        where h.employee_id = e.id and h.kind = 'checkup' and h.status = 'submitted'
                          and (h.checkup_year < p_year
                               or (h.checkup_year = p_year and h.checkup_quarter < p_quarter))),
           case when c.id is null then '待排定'
                when a.status = 'submitted' then '已完成'
                else '已排定' end,
           c.scheduled_at,
           c.id,
           case when a.status = 'submitted' or (a.status = 'draft' and v_role = 'cs_admin') then a.id end,
           case when a.status = 'submitted' then a.total_score end,
           case when a.status = 'submitted' then a.verdict end,
           case when a.status = 'submitted' then 'submitted'
                when a.status = 'draft' and v_role = 'cs_admin' then 'draft' end
    from cand
    join public.employees e on e.id = cand.emp
    left join public.stores s on s.code = cand.st
    left join public.checkups c on c.employee_id = e.id and c.year = p_year
    left join public.assessments a on a.id = c.assessment_id
    where v_store is null or cand.st = v_store
    order by cand.st, e.id;
end;
$$;

-- ---------- 8. checkup_schedule：排定（只有客服部） ----------
create or replace function public.checkup_schedule(p_employee text, p_year int, p_quarter int,
                                                   p_scheduled_at timestamptz, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_emp public.employees%rowtype;
  v_ex public.checkups%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288)), '');
  v_id uuid;
begin
  perform public.assess_assert_cs();
  if p_year is null or p_year not between 2000 and 2100 then
    raise exception '年度不正確';
  end if;
  if p_quarter is null or p_quarter not between 1 and 4 then
    raise exception '季次必須是 1 到 4';
  end if;
  if p_scheduled_at is null then
    raise exception '請指定健檢日期與時間';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception '備註最多 500 字';
  end if;

  -- 鎖住人員那一列（只鎖不改）：同一個人的並發排定在這裡排隊
  select * into v_emp from public.employees where id = p_employee for update;
  if not found then
    raise exception '找不到員工：%', p_employee;
  end if;

  select * into v_ex from public.checkups where employee_id = v_emp.id and year = p_year;
  if found then
    raise exception '這位人員 % 年已排定健檢（第 % 季）；要改期請先取消排定再重新排定', p_year, v_ex.quarter;
  end if;
  if exists (select 1 from public.assessments a
              where a.employee_id = v_emp.id and a.kind = 'checkup'
                and a.checkup_year = p_year and a.status <> 'voided') then
    raise exception '這位人員 % 年已有健檢成績單，不能再排定', p_year;
  end if;
  if not public.checkup_eligible(v_emp.id, p_year, p_quarter) then
    raise exception '這位人員不在 % 年第 % 季的健檢名單內（需在職、納入考核、已上線、門市屬於該季，且通過考核期的日期早於該季第一天）', p_year, p_quarter;
  end if;

  begin
    insert into public.checkups (employee_id, year, quarter, store_code, scheduled_at, scheduled_by, note)
    values (v_emp.id, p_year, p_quarter, v_emp.store_code, p_scheduled_at, public.roster_my_email(), v_note)
    returning id into v_id;
  exception when unique_violation then
    raise exception '這位人員 % 年已排定健檢，要改期請先取消排定再重新排定', p_year;
  end;
  return v_id;
end;
$$;

-- ---------- 9. checkup_unschedule：取消排定（只有客服部） ----------
-- 已完成（成績單已送出且未作廢）不可取消；已開始（有未送出的草稿）也不可取消，要先放棄草稿。
create or replace function public.checkup_unschedule(p_checkup_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c public.checkups%rowtype;
  v_st text;
begin
  perform public.assess_assert_cs();

  select * into v_c from public.checkups where id = p_checkup_id for update;
  if not found then
    raise exception '找不到這筆健檢排定';
  end if;

  if v_c.assessment_id is not null then
    select a.status into v_st from public.assessments a where a.id = v_c.assessment_id for share;
    if v_st = 'submitted' then
      raise exception '已完成的健檢不能取消排定';
    elsif v_st = 'draft' then
      raise exception '這場健檢已經開始（有未送出的考核草稿），請先放棄草稿再取消排定';
    end if;
  end if;

  delete from public.checkups where id = v_c.id;
end;
$$;

-- ---------- 10. checkup_begin：開始健檢（只有客服部、只能對已排定的人） ----------
-- 另寫一支新函式（不呼叫、也不複製 assess_start 的身分判斷邏輯）：建立 kind='checkup' 的成績單草稿，
-- 身分固定「正式」、來源「自動」（合格線 85）；把 checkups.assessment_id 連起來。
-- 已有自己的草稿 → 回傳那張（可接續）；已完成 → 擋；成績單被作廢或草稿被放棄後 → 建新的。
-- 之後的抽題、評分、追加題、送出、放棄、作廢都沿用既有 assess_* 函式。
create or replace function public.checkup_begin(p_employee text, p_year int, p_quarter int)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_emp public.employees%rowtype;
  v_c public.checkups%rowtype;
  v_a public.assessments%rowtype;
  v_id uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();
  if p_year is null or p_year not between 2000 and 2100 then
    raise exception '年度不正確';
  end if;
  if p_quarter is null or p_quarter not between 1 and 4 then
    raise exception '季次必須是 1 到 4';
  end if;

  select * into v_emp from public.employees where id = p_employee;
  if not found then
    raise exception '找不到員工：%', p_employee;
  end if;

  select * into v_c from public.checkups where employee_id = v_emp.id and year = p_year for update;
  if not found then
    raise exception '這位人員 % 年尚未排定健檢，請先排定', p_year;
  end if;
  if v_c.quarter <> p_quarter then
    raise exception '這位人員 % 年排定的是第 % 季，不是第 % 季', p_year, v_c.quarter, p_quarter;
  end if;
  if not v_emp.include_in_assessment or v_emp.status <> '在職' then
    raise exception '該員工不在考核名單（需納入考核且在職）';
  end if;

  if v_c.assessment_id is not null then
    select * into v_a from public.assessments where id = v_c.assessment_id for update;
    if found then
      if v_a.status = 'submitted' then
        raise exception '這位人員 % 年的健檢已完成，不能再開始', p_year;
      elsif v_a.status = 'draft' then
        if v_a.examiner_email <> v_me then
          raise exception '這場健檢已由其他客服部同仁開始，請由該同仁繼續，或請他先放棄草稿';
        end if;
        return v_a.id;
      end if;
      -- 已作廢：往下建立新的草稿
    end if;
  end if;

  begin
    insert into public.assessments
      (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot,
       kind, checkup_year, checkup_quarter)
    values
      (v_emp.id,
       coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), '')),
       v_emp.store_code, v_me, 'draft', '正式', '自動', v_emp.hire_date,
       'checkup', p_year, p_quarter)
    returning id into v_id;
  exception when unique_violation then
    raise exception '這位人員 % 年已有進行中或已完成的健檢成績單', p_year;
  end;

  update public.checkups set assessment_id = v_id where id = v_c.id;
  return v_id;
end;
$$;

-- ============================================================
-- 11. 被改寫的既有函式（簽名與回傳型別不變；kind='exam' 行為逐行相同，差異只有下面標【健檢】的幾行）
-- ============================================================

-- ---------- A. assess_start：只對一般考核草稿（kind='exam'）做「同考官同員工一張草稿」的判斷 ----------
-- 以 phase1_schema.sql 的版本逐字複製，只改兩處（on conflict 的索引條件、回傳既有草稿時的查詢多一個 kind = 'exam'），
-- 跟著上面索引 assessments_one_draft_per_pair 的新條件走。新增的成績單 kind 取欄位預設值 'exam'，一般考核行為與改寫前相同。
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
  elsif v_emp.period_status = '考核期' then
    -- 【第一期新增】考核期新人：一律「新人」（合格線 70），來源維持「自動」；到職日空白也不需要手動指定
    v_tenure := '新人';
    v_source := '自動';
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
  on conflict (examiner_email, employee_id) where status = 'draft' and kind = 'exam' do nothing
  returning id into v_id;

  if v_id is null then
    select a.id into v_id
    from public.assessments a
    where a.employee_id = v_emp.id and a.examiner_email = v_me and a.status = 'draft' and a.kind = 'exam';
  end if;

  return v_id;
end;
$$;

-- ---------- B. assess_submit：健檢成績單送出只記錄 ----------
-- 以 phase1_schema.sql 的版本逐字複製，只在兩個「送出後處理考核期」的 if 條件前面加 v_a.kind = 'exam'。
-- 健檢成績單（kind='checkup'）：身分固定「正式」、判定沿用 assess_verdict（85 及格、95 優秀），
-- 不進這兩段，所以不會改 employees（period_status／passed_on／probation_since 都不動）、不建 reply_activations、
-- 不改 spot_probations；改善單與待考回報自動完成由觸發器處理（下面 C、D 兩段排除 kind='checkup'）。
-- 一般考核（kind='exam'）的行為與改寫前完全相同。
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
  v_ps text;
  v_prob date;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
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
    select i.id, i.seq, i.levels, i.is_extra
    from public.assessment_items i
    where i.assessment_id = v_a.id
    order by i.seq
  loop
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

    -- 【第一期】追加題（is_extra）一樣要評完、一樣寫入自己的分數，但不進總分、判定、最弱面向與題組數
    if not r.is_extra then
      v_cnt := v_cnt + 1;
      v_levels := v_levels || jsonb_build_array(r.levels);
    end if;
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
  -- 【健檢】只有一般考核（kind = 'exam'）才處理考核期；健檢成績單只記錄，絕不改 employees、spot_probations、待開通
  if v_a.kind = 'exam' and v_a.tenure_source = '考核期' and v_total >= 85 then
    -- 【第一期】守門：先鎖員工列；只有員工「目前仍在考核期」（probation_since 有值，或 period_status 是考核期）時
    --   才清除考核期、轉已上線、記通過日、新增待開通。員工已是已上線且 probation_since 為空
    --   （例如客服部已取消回考核期、或另一張草稿已先通過）時，只正常送出成績單，什麼都不再改。
    select e.probation_since, e.period_status into v_prob, v_ps
      from public.employees e where e.id = v_a.employee_id for update;
    if v_prob is not null or v_ps = '考核期' then
      update public.employees
         set probation_since = null, period_status = '已上線', passed_on = v_today
       where id = v_a.employee_id;
      insert into public.reply_activations
        (employee_id, employee_label, store_code, assessment_id, passed_on, status)
      values
        (v_a.employee_id, v_a.employee_label, v_a.store_code, v_a.id, v_today, '待開通')
      on conflict (assessment_id) where assessment_id is not null do nothing;
    end if;

    update public.spot_probations
       set status = '已通過',
           passed_assessment_id = v_a.id
     where employee_id = v_a.employee_id
       and status in ('待執行', '已執行');
  end if;

  -- 【第一期新增】考核期新人通過：身分是「新人」、總分 >= 70、員工目前是考核期 → 已上線、記通過日、新增待開通
  -- 【健檢】同上：健檢成績單（身分一律正式）不進這一段
  if v_a.kind = 'exam' and v_a.tenure = '新人' and v_total >= 70 then
    select e.period_status into v_ps from public.employees e where e.id = v_a.employee_id for update;
    if v_ps = '考核期' then
      update public.employees
         set period_status = '已上線', passed_on = v_today
       where id = v_a.employee_id;
      insert into public.reply_activations
        (employee_id, employee_label, store_code, assessment_id, passed_on, status)
      values
        (v_a.employee_id, v_a.employee_label, v_a.store_code, v_a.id, v_today, '待開通')
      on conflict (assessment_id) where assessment_id is not null do nothing;
    end if;
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

-- ---------- E. assess_weak_profile：弱項建議的取題依據排除健檢成績單 ----------
-- 以 phase1_schema.sql 的版本逐字複製，只在「最近 3 張已送出成績單」的條件多一行 a.kind = 'exam'。
-- 弱項建議是否要納入健檢成績單，列為「待老闆決定」（README_checkup.md 稽核表），目前先排除。
create or replace function public.assess_weak_profile(p_employee_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pick constant text[] := array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識'];
  v_ids uuid[];
  v_n int;
  v_out jsonb;
begin
  perform public.assess_assert_cs();

  if not exists (select 1 from public.employees e where e.id = p_employee_id) then
    raise exception '找不到員工：%', p_employee_id;
  end if;

  select coalesce(array_agg(r.id order by r.rn), '{}'::uuid[]) into v_ids
  from (
    select a.id,
           row_number() over (order by a.submitted_at desc, a.created_at desc, a.id desc) as rn
    from public.assessments a
    where a.employee_id = p_employee_id
      and a.status = 'submitted'
      and a.kind = 'exam'   -- 【健檢】弱項建議的取題依據先排除健檢成績單（是否納入待老闆決定）
  ) r
  where r.rn <= 3;
  v_n := coalesce(cardinality(v_ids), 0);

  with rr as (
    select d.dim, d.n,
           (select avg(public.assess_level_pct(i.levels ->> d.dim))
              from public.assessment_items i
             where i.assessment_id = any(v_ids) and not i.is_extra) as pct
    from unnest(public.assess_dim_order()) with ordinality as d(dim, n)
  )
  select jsonb_build_object(
           'n', v_n,
           'rates', (select coalesce(jsonb_agg(
                        jsonb_build_object('dim', x.dim,
                                           'pct', case when x.pct is null then null
                                                       else trim_scale(round(x.pct, 1)) end)
                        order by x.n), '[]'::jsonb)
                     from rr x),
           'weak', (select coalesce(jsonb_agg(
                        jsonb_build_object('dim', w.dim, 'pct', trim_scale(round(w.pct, 1)))
                        order by w.pct, w.n), '[]'::jsonb)
                    from (select x.dim, x.n, x.pct
                          from rr x
                          where x.dim = any(v_pick) and x.pct is not null
                          order by x.pct, x.n
                          limit 2) w),
           'always_low', (select coalesce(jsonb_agg(
                        jsonb_build_object('dim', l.dim, 'pct', trim_scale(round(l.pct, 1)))
                        order by l.n), '[]'::jsonb)
                    from rr l
                    where l.dim in ('語氣與禮貌', '文字品質')
                      and l.pct is not null and l.pct < 70)
         )
    into v_out;

  return v_out;
end;
$$;

-- ---------- C. improvement_auto_open（觸發器函式）：健檢不自動開改善單 ----------
-- 以 backoffice_schema.sql 的版本逐字複製，只在開單條件多一行 new.kind = 'exam'。觸發器本身沒動。
create or replace function public.improvement_auto_open()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'submitted'
     and old.status is distinct from 'submitted'
     and new.verdict in ('需複訓', '不及格')
     and new.kind = 'exam' then   -- 【健檢】健檢沒過只記錄，不自動開改善單
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

-- ---------- D. exam_req_auto_complete（觸發器函式）：健檢送出不完成待考回報 ----------
-- 以 exam_request_schema.sql 的版本逐字複製，只在條件多一行 new.kind = 'exam'。觸發器本身沒動。
create or replace function public.exam_req_auto_complete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted'
     and new.kind = 'exam' then   -- 【健檢】健檢成績單送出不會把店長的待考回報標成已完成
    begin
      update public.exam_requests
         set status = '已完成',
             assessment_id = new.id,
             mgr_seen = false
       where employee_id = new.employee_id
         and status in ('待處理', '已排定');
    exception when others then
      raise warning '待處理回報自動完成失敗：%', sqlerrm;
    end;
  end if;
  return null;
end;
$$;

-- ---------- F. improve_close：健檢成績單不能當複檢成績單 ----------
-- 以 backoffice_schema.sql 的版本逐字複製，只在「已送出」檢查之後多一段 kind 檢查（一般考核不受影響）。
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
  if v_a.kind <> 'exam' then   -- 【健檢】健檢成績單不能當複檢成績單（複檢資格只看一般考核）
    raise exception '健檢成績單不能當作複檢成績單';
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

-- ---------- G. phase1_migrate_period_status：遷移時健檢及格不算通過考核期 ----------
-- 以 phase1_schema.sql 的版本逐字複製，只在「已有及格以上成績單」的條件多一行 a.kind = 'exam'。
-- 平常有 phase1_migrated_on 記號整段略過；只有老闆刻意刪記號重遷移時才會用到。
create or replace function public.phase1_migrate_period_status()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids text[];
  v_bad text;
  v_n int := 0;
begin
  if exists (select 1 from public.app_settings s where s.key = 'phase1_migrated_on') then
    return 0;
  end if;

  select coalesce(array_agg(x.id order by x.id), '{}'::text[]) into v_ids
  from (
    select e.id
    from public.employees_with_tenure e
    where e.probation_since is not null
       or (e.status = '在職'
           and e.include_in_assessment
           and e.tenure_group = '新人'
           and not exists (select 1 from public.assessments a
                           where a.employee_id = e.id
                             and a.status = 'submitted'
                             and a.kind = 'exam'   -- 【健檢】健檢及格不算通過考核期
                             and a.verdict in ('及格', '優秀')))
  ) x;

  select string_agg(e.id, '、' order by e.id) into v_bad
  from public.employees e
  where e.id = any(v_ids) and char_length(e.job_title) > 20;
  if v_bad is not null then
    raise exception '這些人員的職稱超過 20 字，無法更新考核期狀態，請先到人員名冊縮短職稱再重跑：%', v_bad;
  end if;

  update public.employees set period_status = '考核期' where id = any(v_ids);
  get diagnostics v_n = row_count;

  insert into public.app_settings (key, value)
  values ('phase1_migrated_on', (now() at time zone 'Asia/Taipei')::date::text);

  return v_n;
end;
$$;

-- ============================================================
-- 12. 檢視：assessment_summaries 尾端追加欄位（原欄位順序與名稱完全不變）
-- ============================================================
-- 成績單列表：尾端追加 kind、checkup_year、checkup_quarter（其餘與 phase1_schema.sql 完全相同）
create or replace view public.assessment_summaries
with (security_invoker = true) as
select
  a.id,
  a.employee_id,
  a.employee_label,
  a.store_code,
  s.name as store_name,
  (a.created_at at time zone 'Asia/Taipei')::date as assessed_on,
  a.created_at,
  a.submitted_at,
  a.examiner_email,
  a.tenure,
  a.tenure_source,
  a.total_score,
  a.verdict,
  a.pass_line,
  a.weakest_dims,
  a.status,
  a.voided_at,
  a.void_reason,
  (select count(*) from public.assessment_items i
    where i.assessment_id = a.id and not i.is_extra)::int as item_count,
  a.kind,
  a.checkup_year,
  a.checkup_quarter
from public.assessments a
left join public.stores s on s.code = a.store_code;

revoke all on table public.assessment_summaries from public, anon, authenticated;
grant select on public.assessment_summaries to authenticated;

-- ============================================================
-- 13. 函式權限：收回 public／anon，只授權 authenticated
-- ============================================================
-- 對外函式的角色檢查在函式內部（非授權角色一律丟「沒有權限」）。
revoke execute on function public.checkup_quarters_list()                                  from public, anon, authenticated;
revoke execute on function public.checkup_quarter_set(text, int)                           from public, anon, authenticated;
revoke execute on function public.checkup_roster(int, int)                                 from public, anon, authenticated;
revoke execute on function public.checkup_schedule(text, int, int, timestamptz, text)      from public, anon, authenticated;
revoke execute on function public.checkup_unschedule(uuid)                                 from public, anon, authenticated;
revoke execute on function public.checkup_begin(text, int, int)                            from public, anon, authenticated;
-- 內部：連 authenticated 都不開放直接呼叫
revoke execute on function public.checkup_first_day(int, int)                              from public, anon, authenticated;
revoke execute on function public.checkup_eligible(text, int, int)                         from public, anon, authenticated;
-- 被改寫的既有函式：權限與改寫前相同（create or replace 會保留，這裡再明確設一次，與 phase1_schema.sql 一致）
revoke execute on function public.assess_start(text, text)                                 from public, anon, authenticated;
revoke execute on function public.assess_submit(uuid)                                      from public, anon, authenticated;
revoke execute on function public.assess_weak_profile(text)                                from public, anon, authenticated;
revoke execute on function public.improve_close(uuid, uuid, text)                          from public, anon, authenticated;
revoke execute on function public.phase1_migrate_period_status()                           from public, anon, authenticated;
revoke execute on function public.improvement_auto_open()                                  from public, anon, authenticated;
revoke execute on function public.exam_req_auto_complete()                                 from public, anon, authenticated;

grant execute on function public.checkup_quarters_list()                                   to authenticated;
grant execute on function public.checkup_quarter_set(text, int)                            to authenticated;
grant execute on function public.checkup_roster(int, int)                                  to authenticated;
grant execute on function public.checkup_schedule(text, int, int, timestamptz, text)       to authenticated;
grant execute on function public.checkup_unschedule(uuid)                                  to authenticated;
grant execute on function public.checkup_begin(text, int, int)                             to authenticated;
grant execute on function public.assess_start(text, text)                                  to authenticated;
grant execute on function public.assess_submit(uuid)                                       to authenticated;
grant execute on function public.assess_weak_profile(text)                                 to authenticated;
grant execute on function public.improve_close(uuid, uuid, text)                           to authenticated;

commit;
