-- ============================================================
-- 業務考核系統：人員名冊資料庫結構（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 與既有「考題抽選器」共用同一個 Supabase 專案。
-- 考題抽選器已使用的名稱（本檔不得與之衝突、也不會碰它們）：
--   資料表：questions、drawn、category_last、app_secret
--   函式：_pw_ok、_assert_pw、list_categories、draw_questions、
--         admin_login、admin_list_questions、admin_save_question、
--         admin_delete_question、admin_rename_category、admin_reset
-- 本檔新增的名稱（皆不重複）：
--   資料表：stores、employees、app_users
--   檢視：employees_with_tenure
--   函式：roster_my_email、roster_my_role、roster_my_store、roster_touch_updated_at
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--
-- 可重複執行：資料表 if not exists、函式 create or replace、
-- policy 與 trigger 先 drop 再建，重跑不會報錯，也不會刪掉既有資料。
--
-- 登入者身分來源：Google 登入後 JWT 內的 email，統一轉小寫比對
-- （app_users.email 也用 check 強制為小寫）。
-- 資料表權限：收回 anon（未登入）全部權限；authenticated 只在 RLS 允許下才看得到／改得到。
-- 需要 Postgres 15 以上（view 的 security_invoker）；Supabase 新專案皆符合。
-- ============================================================

-- ---------- 資料表 ----------

-- 門市（含總公司）
create table if not exists public.stores (
  code text primary key check (length(btrim(code)) > 0),
  name text not null unique check (length(btrim(name)) > 0)
);

-- 人員名冊
create table if not exists public.employees (
  id text primary key
    check (id ~ '^(MI|PT)-[0-9]{4}$'),   -- MI-xxxx（正式編號）或 PT-xxxx（工讀，須各有唯一號碼）
  nickname text,
  full_name text,
  store_code text not null references public.stores(code) on update cascade,
  job_title text not null check (length(btrim(job_title)) > 0),
  hire_date date,                                   -- 之後匯入，可空
  status text not null default '在職' check (status in ('在職', '離職')),
  include_in_assessment boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 暱稱、姓名至少一個有內容
  constraint employees_name_present
    check (nullif(btrim(nickname), '') is not null
        or nullif(btrim(full_name), '') is not null)
);

create index if not exists employees_store_code_idx on public.employees(store_code);

-- 登入帳號對應（公司信箱 → 系統角色）
create table if not exists public.app_users (
  email text primary key
    check (email = lower(btrim(email)) and length(email) > 0),  -- 強制小寫
  role text not null check (role in ('cs_admin', 'hq_viewer', 'store_manager')),
  store_code text references public.stores(code) on update cascade,
  employee_id text references public.employees(id) on update cascade on delete set null,
  -- 店長必填門市；其他角色必須為空
  constraint app_users_store_by_role
    check ((role = 'store_manager' and store_code is not null)
        or (role <> 'store_manager' and store_code is null))
);

-- ---------- 更新時間自動更新 ----------

create or replace function public.roster_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists employees_touch_updated_at on public.employees;
create trigger employees_touch_updated_at
  before update on public.employees
  for each row execute function public.roster_touch_updated_at();

-- ---------- 身分小工具（給 policy 用） ----------
-- 用 security definer 讀 app_users，避免 policy 自己查自己造成無限遞迴。
-- 只回傳「目前登入者自己」的資料，不洩漏他人。
-- 沒有對應 app_users（或未登入）就回傳 null → 所有 policy 判斷為不通過 → 什麼都看不到。

create or replace function public.roster_my_email()
returns text
language sql
stable
as $$
  select lower(btrim(auth.jwt() ->> 'email'));
$$;

create or replace function public.roster_my_role()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select u.role from public.app_users u
  where u.email = lower(btrim(auth.jwt() ->> 'email'));
$$;

create or replace function public.roster_my_store()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select u.store_code from public.app_users u
  where u.email = lower(btrim(auth.jwt() ->> 'email'));
$$;

revoke execute on function public.roster_my_email() from public, anon;
revoke execute on function public.roster_my_role()  from public, anon;
revoke execute on function public.roster_my_store() from public, anon;
grant  execute on function public.roster_my_email() to authenticated;
grant  execute on function public.roster_my_role()  to authenticated;
grant  execute on function public.roster_my_store() to authenticated;

-- ---------- 新人／正式 檢視 ----------
-- 到職日起 90 天內（含第 90 天）＝新人，其餘＝正式；到職日為空＝未填到職日。
-- 以台北時間的今天計算。
-- security_invoker = true：檢視以「查詢者本人」的權限讀底層 employees，
-- 所以 employees 的 RLS 照樣生效（店長仍只看到自己門市）。
-- 沒設這個的話檢視會以擁有者身分執行而繞過 RLS，是錯的。

create or replace view public.employees_with_tenure
with (security_invoker = true) as
select
  e.*,
  case
    when e.hire_date is null then '未填到職日'
    when ((now() at time zone 'Asia/Taipei')::date - e.hire_date) <= 90 then '新人'
    else '正式'
  end as tenure_group
from public.employees e;

-- ---------- 權限與 RLS ----------

alter table public.stores    enable row level security;
alter table public.employees enable row level security;
alter table public.app_users enable row level security;

-- 先全收回，再只給 authenticated（實際能做什麼由 RLS 決定）；anon 完全沒有
revoke all on table public.stores    from public, anon, authenticated;
revoke all on table public.employees from public, anon, authenticated;
revoke all on table public.app_users from public, anon, authenticated;
revoke all on table public.employees_with_tenure from public, anon, authenticated;

grant select, insert, update, delete on public.stores    to authenticated;
grant select, insert, update, delete on public.employees to authenticated;
grant select, insert, update, delete on public.app_users to authenticated;
grant select on public.employees_with_tenure to authenticated;

-- stores：客服部全權；總公司主管讀全部；店長只讀自己門市
drop policy if exists stores_select on public.stores;
create policy stores_select on public.stores
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and code = public.roster_my_store())
  );

drop policy if exists stores_cs_write on public.stores;
create policy stores_cs_write on public.stores
  for all to authenticated
  using (public.roster_my_role() = 'cs_admin')
  with check (public.roster_my_role() = 'cs_admin');

-- employees：客服部全權；總公司主管讀全部；店長只讀自己門市
drop policy if exists employees_select on public.employees;
create policy employees_select on public.employees
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );

drop policy if exists employees_cs_write on public.employees;
create policy employees_cs_write on public.employees
  for all to authenticated
  using (public.roster_my_role() = 'cs_admin')
  with check (public.roster_my_role() = 'cs_admin');

-- app_users：每個人只能讀自己那一列（前端要知道自己是什麼角色）；客服部全權
drop policy if exists app_users_select_self on public.app_users;
create policy app_users_select_self on public.app_users
  for select to authenticated
  using (email = public.roster_my_email());

drop policy if exists app_users_cs_write on public.app_users;
create policy app_users_cs_write on public.app_users
  for all to authenticated
  using (public.roster_my_role() = 'cs_admin')
  with check (public.roster_my_role() = 'cs_admin');
