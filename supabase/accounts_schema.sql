-- ============================================================
-- 業務考核系統：帳號管理護欄與操作紀錄（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（須先執行過 roster_schema.sql）。
--
-- 做什麼：客服部（cs_admin）在網頁上管理 app_users（新增、修改、移除）時，
--   在資料庫層加上「護欄」與「操作紀錄」，網頁就算寫錯或被亂用也守得住：
--   1. 至少保留一位客服部
--   2. 不能移除或降級自己的客服部身分
--   3. 信箱必須是公司網域（@2motor.tw）
--   4. 每次新增／修改／移除都自動記一筆到 app_users_audit（只增不改）
--   5. 在 SQL Editor 直接操作（沒有登入者）時，第 1、2 條不啟動（緊急修復用）；
--      第 3 條與操作紀錄照常生效
--
-- 名稱衝突自查結果（已逐一檢查 supabase\ 底下所有 .sql 與整個專案資料夾）：
--   本檔新增的名稱，專案內原本沒有任何同名物件：
--     資料表：app_users_audit
--     函式：accounts_email_domain_check、accounts_guard、accounts_audit_write、accounts_audit_immutable
--     觸發器（掛在 app_users 上）：accounts_email_domain_trg、accounts_guard_trg、
--       accounts_audit_trg（新增、移除）、accounts_audit_upd_trg（修改且內容真的有變）
--     觸發器（掛在 app_users_audit 上）：accounts_audit_no_update_trg、accounts_audit_no_delete_trg、
--       accounts_audit_no_truncate_trg（一律擋，確保只增不改）
--     約束（掛在 employees 上）：accounts_employees_job_title_len（職稱最多 20 字）
--     檢視：accounts_list
--     RLS policy（掛在 app_users_audit 上）：accounts_audit_select_cs
--   既有的 roster_*、assess_*、舊考題抽選器的名稱，本檔一律不修改、不刪除、不覆蓋；
--   app_users 本身的欄位、policy、權限完全不動，只在它上面「加觸發器」；
--   唯一動到既有資料表的是檔尾獨立小節：employees.job_title 加長度限制（見該小節）。
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--
-- 可重複執行：資料表 if not exists、函式與檢視 create or replace、
--   policy 與 trigger 先 drop 再建，重跑不會報錯，也不會刪掉既有資料與既有操作紀錄。
--
-- 判斷「有沒有登入者」：看 JWT 內有沒有 email（roster_my_email() 不為空）。
--   透過網頁（Supabase API）呼叫＝有 email；SQL Editor（postgres 角色）直接操作＝沒有。
--   （用 service_role 金鑰從後端呼叫也沒有 email，視同 SQL Editor。）
--
-- ⚠️ 本檔生效後，信箱不是 @2motor.tw 結尾的 app_users 資料一律寫不進去，
--   包括 example.invalid 這類假信箱；
--   roster_seed_fake.sql 與 assess_verify_fake.sql 的假信箱已改成 vr-xxx@2motor.tw。
--   信箱格式也要符合 ^[^@\s]+@2motor\.tw$（不能有空白、不能有第二個 @）。
-- ============================================================

-- ---------- 操作紀錄表 ----------
-- 只增不改：任何網頁角色都不能 insert／update／delete，紀錄只由觸發器寫入。

create table if not exists public.app_users_audit (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  by_email text not null,                       -- 操作人信箱；沒有登入者記為 '(SQL Editor)'
  action text not null check (action in ('insert', 'update', 'delete')),
  email text not null,                          -- 被異動的帳號（信箱被改時記改後的新信箱）
  old_row jsonb,                                -- 異動前整列（新增時為空）
  new_row jsonb                                 -- 異動後整列（移除時為空）
);

create index if not exists app_users_audit_email_idx on public.app_users_audit(email);
create index if not exists app_users_audit_at_idx on public.app_users_audit(at desc);

alter table public.app_users_audit enable row level security;

-- 先全收回（含 service_role；insert／update／delete／truncate 一併收回），
-- 只給 authenticated「讀」（再由 policy 限制只有客服部看得到）；anon 完全沒有。
-- 寫入只由 security definer 觸發器（以擁有者身分）進行，不需要任何網頁角色有寫入權限。
revoke all on table public.app_users_audit from public, anon, authenticated, service_role;
grant select on public.app_users_audit to authenticated;

-- 第二道鎖：就算有人（含擁有者）直接 update／delete／truncate，也一律拒絕。
-- 寫入走 AFTER 觸發器的 insert，不經過這三個觸發器，不受影響。
-- 限制：資料庫擁有者仍可先停用這些觸發器再改（見 README_accounts.md 第六節）。
create or replace function public.accounts_audit_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '操作紀錄只增不改';
end;
$$;

drop trigger if exists accounts_audit_no_update_trg on public.app_users_audit;
create trigger accounts_audit_no_update_trg
  before update on public.app_users_audit
  for each row execute function public.accounts_audit_immutable();

drop trigger if exists accounts_audit_no_delete_trg on public.app_users_audit;
create trigger accounts_audit_no_delete_trg
  before delete on public.app_users_audit
  for each row execute function public.accounts_audit_immutable();

drop trigger if exists accounts_audit_no_truncate_trg on public.app_users_audit;
create trigger accounts_audit_no_truncate_trg
  before truncate on public.app_users_audit
  for each statement execute function public.accounts_audit_immutable();

revoke all on function public.accounts_audit_immutable() from public, anon, authenticated;

drop policy if exists accounts_audit_select_cs on public.app_users_audit;
create policy accounts_audit_select_cs on public.app_users_audit
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- ---------- 護欄 3：信箱必須是公司網域 ----------
-- 新增時一定檢查；修改時只有「信箱真的被改了」才檢查（避免擋到改角色等無關操作）。
-- 任何身分（含 SQL Editor）都要遵守。

create or replace function public.accounts_email_domain_check()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  -- 修改時信箱沒變就不檢查（分開寫 if，避免 insert 時去讀不存在的 old）
  if tg_op = 'UPDATE' then
    if new.email = old.email then
      return new;
    end if;
  end if;

  -- 嚴格格式：帳號名稱不可空、不可含空白或 @，網域固定 2motor.tw（前端用同一條規則）
  if new.email !~ '^[^@\s]+@2motor\.tw$' then
    raise exception '只收公司信箱（@2motor.tw）';
  end if;
  return new;
end;
$$;

drop trigger if exists accounts_email_domain_trg on public.app_users;
create trigger accounts_email_domain_trg
  before insert or update on public.app_users
  for each row execute function public.accounts_email_domain_check();

-- ---------- 護欄 1、2：至少保留一位客服部／不能移除或降級自己 ----------
-- 用 AFTER 觸發器：一個語句改完所有列之後才判斷，所以「一次降級全部客服部」也擋得住。
-- security definer：數客服部人數時不受 RLS 限制，才數得完整。
-- 沒有登入者（SQL Editor）時直接放行，這是刻意的緊急修復通道（見 README_accounts.md）。

create or replace function public.accounts_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text := nullif(public.roster_my_email(), '');
  v_hit boolean;
begin
  -- 沒有登入者：護欄不啟動
  if v_me is null then
    return null;
  end if;

  -- 只有「客服部那一列被刪除，或被改成非客服部」才需要檢查
  -- （分開寫 if，避免 delete 時去讀不存在的 new）
  v_hit := false;
  if old.role = 'cs_admin' then
    if tg_op = 'DELETE' then
      v_hit := true;
    elsif new.role <> 'cs_admin' then
      v_hit := true;
    end if;
  end if;

  if v_hit then
    -- 兩個人同時互相移除時，用鎖排隊，後面的人會看到前面已生效的結果
    perform pg_advisory_xact_lock(hashtext('accounts_guard'));

    -- 護欄 1：至少保留一位客服部
    if not exists (select 1 from public.app_users where role = 'cs_admin') then
      raise exception '至少要保留一位客服部';
    end if;

    -- 護欄 2：不能移除或降級自己
    if old.email = v_me then
      raise exception '不能移除或降級自己的客服部身分';
    end if;
  end if;

  -- 護欄 2 補洞：客服部不能把「自己那一列的信箱」改掉（等於移除自己）
  if tg_op = 'UPDATE' then
    if old.role = 'cs_admin' and new.email <> old.email and old.email = v_me then
      raise exception '不能移除或降級自己的客服部身分';
    end if;
  end if;

  return null;
end;
$$;

drop trigger if exists accounts_guard_trg on public.app_users;
create trigger accounts_guard_trg
  after update or delete on public.app_users
  for each row execute function public.accounts_guard();

-- ---------- 操作紀錄：自動寫入 ----------
-- security definer：網頁角色沒有寫入權限，由這個函式（以擁有者身分）代寫。

create or replace function public.accounts_audit_write()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_by text := coalesce(nullif(public.roster_my_email(), ''), '(SQL Editor)');
begin
  if tg_op = 'INSERT' then
    insert into public.app_users_audit (by_email, action, email, old_row, new_row)
    values (v_by, 'insert', new.email, null, to_jsonb(new));
  elsif tg_op = 'UPDATE' then
    insert into public.app_users_audit (by_email, action, email, old_row, new_row)
    values (v_by, 'update', new.email, to_jsonb(old), to_jsonb(new));
  else
    insert into public.app_users_audit (by_email, action, email, old_row, new_row)
    values (v_by, 'delete', old.email, to_jsonb(old), null);
  end if;
  return null;
end;
$$;

-- 新增、移除一律記；修改只有「內容真的有變」才記（避免沒有異動的 UPDATE 灌水）。
-- （insert 觸發器的 when 不能用 old，所以修改另開一個觸發器）
drop trigger if exists accounts_audit_trg on public.app_users;
create trigger accounts_audit_trg
  after insert or delete on public.app_users
  for each row execute function public.accounts_audit_write();

drop trigger if exists accounts_audit_upd_trg on public.app_users;
create trigger accounts_audit_upd_trg
  after update on public.app_users
  for each row
  when (old.* is distinct from new.*)
  execute function public.accounts_audit_write();

-- 觸發器函式不需要（也不該讓人）直接呼叫
revoke all on function public.accounts_email_domain_check() from public, anon, authenticated;
revoke all on function public.accounts_guard()              from public, anon, authenticated;
revoke all on function public.accounts_audit_write()        from public, anon, authenticated;

-- ---------- 給前端：帳號清單檢視 ----------
-- app_users 左接 employees，帶出員編、暱稱、姓名。
-- security_invoker = true：以「查詢者本人」的權限讀底層資料表，沿用現有 RLS——
--   客服部看到全部；其他角色只看到自己那一列。
-- 操作紀錄不另做檢視：前端客服部直接讀 app_users_audit 即可（RLS 已限制只有客服部讀得到），
--   例如：select * from app_users_audit order by id desc limit 100;

create or replace view public.accounts_list
with (security_invoker = true) as
select
  u.email,
  u.role,
  u.store_code,
  u.employee_id,
  e.nickname,
  e.full_name
from public.app_users u
left join public.employees e on e.id = u.employee_id;

revoke all on table public.accounts_list from public, anon, authenticated;
grant select on public.accounts_list to authenticated;

-- ---------- 名冊小補強：職稱最多 20 字（獨立小節，可重複執行） ----------
-- 用 NOT VALID 加上：只檢查「之後新增或修改的資料」，不會因為既有資料有超過 20 字而整段失敗。
-- 既有資料有沒有超過 20 字，用 README_accounts.md 第八節的查詢確認；
-- 確認都沒超過後，可再執行：
--   alter table public.employees validate constraint accounts_employees_job_title_len;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'accounts_employees_job_title_len'
      and conrelid = 'public.employees'::regclass
  ) then
    alter table public.employees
      add constraint accounts_employees_job_title_len
      check (char_length(job_title) <= 20) not valid;
  end if;
end
$$;
