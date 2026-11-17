-- ============================================================
-- 業務考核系統：健檢單下載管制＋客服下載紀錄（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（建表 if not exists、函式 create or replace，不動既有資料）。
--
-- ---------- 老闆定案 ----------
--   1. 開放日期（台北時間、含當日）：Q1→當年 4/10、Q2→7/10、Q3→10/10；Q4 的季度健檢單與年度健檢單→隔年 1/10。
--      店長沒到日期不能下載（資料庫在「記錄下載」時把關，網頁要先記錄成功才產生檔案）。
--      客服部（cs_admin）不受限；總公司主管（hq_viewer）比照客服部不受限。
--   2. 單人下載、一鍵下載（全店 ZIP）都要記一筆；季度與年度分開記。
--   3. 下載紀錄只有客服部讀得到；店長、主管、未開通帳號、未登入一律「沒有權限」。紀錄只增不改（append-only）。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   … → roster_schema → spotcheck_schema → checkup_schema → …
--   【本檔 checkup_download_schema.sql】 → checkup_download_verify_fake.sql（可選）
--   網頁（checkup.html 的健檢單下載與「下載紀錄」分頁）要在本檔執行「之後」才上線：
--   網頁下載前會先呼叫 checkup_log_download，函式不存在時網頁會顯示「下載管制功能尚未啟用」並不產生檔案。
--
-- ---------- 本檔做了什麼 ----------
--   資料表 checkup_download_log（網頁角色完全沒有直接權限，只能經由下列函式；只增不改，觸發器擋 update／delete／truncate）。
--   內部函式 checkup_download_open_date、checkup_download_is_open（網頁角色不能呼叫）。
--   對外函式：checkup_log_download（寫入）、checkup_download_summary（各店彙總，只有客服部）、checkup_download_list（明細，只有客服部）。
--   不改任何既有函式與資料表。
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.stores') is null
     or to_regclass('public.employees') is null
     or to_regclass('public.app_users') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null then
    raise exception '前提不滿足：請先執行 roster_schema.sql';
  end if;
end
$$;

-- ---------- 1. 下載紀錄表 ----------
create table if not exists public.checkup_download_log (
  id bigint generated always as identity primary key,
  downloaded_at timestamptz not null default now(),
  store_code text not null references public.stores(code) on update cascade,   -- 被下載的門市
  by_email text not null,                                                      -- 下載人信箱
  by_name text not null,                                                       -- 下載人顯示名：門市名-暱稱（客服部／主管：總公司-名字）
  method text not null check (method in ('一鍵下載', '單人下載')),
  kind text not null check (kind in ('季度', '年度')),
  year int not null check (year between 2000 and 2100),
  quarter int not null check (quarter between 1 and 4),                        -- 年度健檢單固定記 4
  employee_id text,                                                            -- 單人下載：被下載人員編
  employee_name text,                                                          -- 單人下載：被下載人姓名
  people_count int check (people_count is null or people_count >= 0),          -- 一鍵下載：打包人數
  constraint checkup_download_log_shape check (
    (method = '單人下載' and employee_id is not null and people_count is null)
    or (method = '一鍵下載' and employee_id is null and employee_name is null and people_count is not null)),
  constraint checkup_download_log_year_q4 check (kind = '季度' or quarter = 4)
);

create index if not exists checkup_download_log_at_idx on public.checkup_download_log(downloaded_at desc);
create index if not exists checkup_download_log_store_idx on public.checkup_download_log(store_code);

alter table public.checkup_download_log enable row level security;

-- 先全收回（含 service_role），網頁角色完全不能直接讀寫；寫入與讀取都只走下面的 security definer 函式。
revoke all on table public.checkup_download_log from public, anon, authenticated, service_role;

-- 只增不改：就算有人（含擁有者）直接 update／delete／truncate，也一律拒絕。
-- 限制：資料庫擁有者仍可先停用這些觸發器再改。
create or replace function public.checkup_download_log_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '下載紀錄只增不改';
end;
$$;

drop trigger if exists checkup_download_log_no_update_trg on public.checkup_download_log;
create trigger checkup_download_log_no_update_trg
  before update on public.checkup_download_log
  for each row execute function public.checkup_download_log_immutable();

drop trigger if exists checkup_download_log_no_delete_trg on public.checkup_download_log;
create trigger checkup_download_log_no_delete_trg
  before delete on public.checkup_download_log
  for each row execute function public.checkup_download_log_immutable();

drop trigger if exists checkup_download_log_no_truncate_trg on public.checkup_download_log;
create trigger checkup_download_log_no_truncate_trg
  before truncate on public.checkup_download_log
  for each statement execute function public.checkup_download_log_immutable();

revoke all on function public.checkup_download_log_immutable() from public, anon, authenticated;

-- ---------- 2. 開放日期（內部函式，與 js/checkup-download-core.js 的 openDate 同一份規則） ----------
-- p_kind：'季度' 或 '年度'（年度不看季次）。參數不合法回 null。
create or replace function public.checkup_download_open_date(p_year int, p_quarter int, p_kind text)
returns date
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p_year is null or p_year < 2000 or p_year > 2100 then null
    when p_kind = '年度' then make_date(p_year + 1, 1, 10)
    when p_kind <> '季度' or p_quarter is null or p_quarter < 1 or p_quarter > 4 then null
    when p_quarter = 4 then make_date(p_year + 1, 1, 10)
    when p_quarter = 1 then make_date(p_year, 4, 10)
    when p_quarter = 2 then make_date(p_year, 7, 10)
    else make_date(p_year, 10, 10)
  end;
$$;

-- p_today 預設台北今天；驗證腳本會傳固定日期測邊界（含當日）
create or replace function public.checkup_download_is_open(
  p_year int, p_quarter int, p_kind text,
  p_today date default (now() at time zone 'Asia/Taipei')::date)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(p_today >= public.checkup_download_open_date(p_year, p_quarter, p_kind), false);
$$;

revoke execute on function public.checkup_download_open_date(int, int, text) from public, anon, authenticated;
revoke execute on function public.checkup_download_is_open(int, int, text, date) from public, anon, authenticated;

-- ---------- 3. checkup_log_download：記一筆下載（網頁要先呼叫它成功，才產生檔案） ----------
-- 店長：只能記自己門市；日期沒到開放日 → 丟例外拒絕。客服部、總公司主管：任何門市、不受日期限制。
-- 單人下載：p_employee_id 必填，p_employee_name 為被下載人姓名；一鍵下載：p_people_count 為打包人數。
-- 回傳新紀錄的 id。
create or replace function public.checkup_log_download(
  p_store text, p_method text, p_kind text, p_year int, p_quarter int,
  p_employee_id text default null, p_employee_name text default null, p_people_count int default null)
returns bigint
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  v_open date;
  v_prefix text;
  v_nick text;
  v_by text;
  v_ename text;
  v_id bigint;
begin
  if v_role not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_method is null or p_method not in ('一鍵下載', '單人下載') then
    raise exception '下載方式不正確';
  end if;
  if p_kind is null or p_kind not in ('季度', '年度') then
    raise exception '下載種類不正確';
  end if;
  if p_year is null or p_year < 2000 or p_year > 2100 or p_quarter is null or p_quarter < 1 or p_quarter > 4 then
    raise exception '年度或季次不正確';
  end if;
  if p_kind = '年度' and p_quarter <> 4 then
    raise exception '年度健檢單的季次必須是第 4 季';
  end if;
  if p_store is null or not exists (select 1 from public.stores s where s.code = p_store) then
    raise exception '門市不存在';
  end if;
  if p_method = '單人下載' and (nullif(btrim(p_employee_id), '') is null) then
    raise exception '單人下載必須帶人員編號';
  end if;
  if p_method = '一鍵下載' and (p_people_count is null or p_people_count < 0) then
    raise exception '一鍵下載必須帶打包人數';
  end if;

  -- 店長：只能自己門市，且日期要到
  if v_role = 'store_manager' then
    if p_store is distinct from public.roster_my_store() then
      raise exception '只能下載自己門市的健檢單';
    end if;
    v_open := public.checkup_download_open_date(p_year, p_quarter, p_kind);
    if not public.checkup_download_is_open(p_year, p_quarter, p_kind) then
      raise exception '這份健檢單 %/% 起開放下載', extract(month from v_open)::int, extract(day from v_open)::int;
    end if;
  end if;

  -- 下載人顯示名：門市名-暱稱（暱稱優先、沒有用姓名；客服部／主管顯示「總公司-名字」；都找不到用信箱前綴）
  select coalesce(nullif(btrim(e.nickname), ''), nullif(btrim(e.full_name), '')),
         case when u.role = 'store_manager' then (select s.name from public.stores s where s.code = u.store_code)
              else '總公司' end
    into v_nick, v_prefix
    from public.app_users u
    left join public.employees e on e.id = u.employee_id
   where u.email = v_email;
  v_by := coalesce(v_prefix, '總公司') || '-' || coalesce(v_nick, split_part(v_email, '@', 1));

  if p_method = '單人下載' then
    v_ename := left(coalesce(nullif(btrim(p_employee_name), ''),
                             (select coalesce(nullif(btrim(e.nickname), ''), nullif(btrim(e.full_name), ''))
                                from public.employees e where e.id = btrim(p_employee_id)),
                             btrim(p_employee_id)), 50);
  end if;

  insert into public.checkup_download_log
    (store_code, by_email, by_name, method, kind, year, quarter, employee_id, employee_name, people_count)
  values
    (p_store, v_email, v_by, p_method, p_kind, p_year, p_quarter,
     case when p_method = '單人下載' then left(btrim(p_employee_id), 20) end,
     v_ename,
     case when p_method = '一鍵下載' then p_people_count end)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- 4. checkup_download_summary：各店彙總（只有客服部） ----------
-- p_method：null＝全部，或 '一鍵下載'／'單人下載'。每家門市一列（總公司不列），沒下載過的店次數為 0、最近一次為空。
create or replace function public.checkup_download_summary(p_method text default null)
returns table(store_code text, store_name text, total int, bulk int, single int, last_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;
  if p_method is not null and p_method not in ('一鍵下載', '單人下載') then
    raise exception '下載方式不正確';
  end if;
  return query
    select s.code, s.name,
           count(l.id)::int,
           (count(l.id) filter (where l.method = '一鍵下載'))::int,
           (count(l.id) filter (where l.method = '單人下載'))::int,
           max(l.downloaded_at)
      from public.stores s
      left join public.checkup_download_log l
        on l.store_code = s.code and (p_method is null or l.method = p_method)
     where s.code <> '總公司'
     group by s.code, s.name
     order by s.code;
end;
$$;

-- ---------- 5. checkup_download_list：明細（只有客服部），新到舊，最多 p_limit 筆（上限 2000） ----------
create or replace function public.checkup_download_list(
  p_store text default null, p_method text default null, p_limit int default 500)
returns table(id bigint, downloaded_at timestamptz, store_code text, store_name text, by_email text, by_name text,
              method text, kind text, year int, quarter int, employee_id text, employee_name text, people_count int)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;
  if p_method is not null and p_method not in ('一鍵下載', '單人下載') then
    raise exception '下載方式不正確';
  end if;
  return query
    select l.id, l.downloaded_at, l.store_code, s.name, l.by_email, l.by_name,
           l.method, l.kind, l.year, l.quarter, l.employee_id, l.employee_name, l.people_count
      from public.checkup_download_log l
      join public.stores s on s.code = l.store_code
     where (p_store is null or p_store = '' or l.store_code = p_store)
       and (p_method is null or p_method = '' or l.method = p_method)
     order by l.downloaded_at desc, l.id desc
     limit least(greatest(coalesce(p_limit, 500), 1), 2000);
end;
$$;

-- ---------- 6. 函式權限：收回 public／anon，只授權 authenticated（角色檢查在函式內部） ----------
revoke execute on function public.checkup_log_download(text, text, text, int, int, text, text, int) from public, anon, authenticated;
revoke execute on function public.checkup_download_summary(text) from public, anon, authenticated;
revoke execute on function public.checkup_download_list(text, text, int) from public, anon, authenticated;
grant  execute on function public.checkup_log_download(text, text, text, int, int, text, text, int) to authenticated;
grant  execute on function public.checkup_download_summary(text) to authenticated;
grant  execute on function public.checkup_download_list(text, text, int) to authenticated;

commit;
