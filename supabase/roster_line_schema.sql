-- ============================================================
-- 業務考核系統：名冊新增「技師」「公務機」類別＋官方 LINE 回覆權限（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 執行順序（務必照順序，一步一步來）：
--   第 0 步  備份（見下方「備份」，先貼那一小段執行，確認成功）
--   第 1 步  本檔 roster_line_schema.sql（建表、權限、放寬員工編號格式）
--   第 2 步  supabase/import/import_line.local.sql（含真實姓名，只在本機，由 gen_line_import.js 產生）
--   第 3 步  驗證查詢（見 README_roster.md「LINE 權限與新類別」）
-- 前提：必須先執行過 roster_schema.sql（本檔會用到 employees、app_users 與 roster_my_role()、roster_my_store()）。
--
-- ---------- 備份（第 0 步，非技術人員照貼即可） ----------
-- 在 Supabase：SQL Editor → New query → 把下面三行貼上 → Run。
-- 它會把「目前的員工名冊」整份複製成一張叫 bak_line_employees 的備份表（原表不會被改動）：
--
--   drop table if exists public.bak_line_employees;
--   create table public.bak_line_employees as select * from public.employees;
--   alter table public.bak_line_employees enable row level security;
--
-- 看到 Success 就是備份好了。要確認的話再跑：select count(*) from public.bak_line_employees;
-- 數字應該跟名冊人數一樣。若之後要還原某個人的資料，可從這張表查回來。
-- 備份表只是暫時保險，確認一切正常後可以刪掉：drop table public.bak_line_employees;
-- （備份表已開權限控管、一般登入者讀不到，但內含姓名，確認完仍請盡快刪除。）
--
-- 本檔新增的名稱（皆不與既有重複）：
--   資料表：line_accounts（官方 LINE 帳號清單）、line_access（誰有哪個 LINE 的回覆權限）
--   函式：roster_set_line_access(text, text[])（客服部一次改一個人的 LINE 權限，整批要嘛全成功要嘛全不變）
--   約束：重建 employees_id_check（員工編號放寬為 MI／PT／OF 開頭）
--
-- 可重複執行：資料表 if not exists、函式 create or replace、policy 先 drop 再建、
-- 約束先 drop 再建、12 個 LINE 帳號用 on conflict do nothing（重跑不會報錯，也不會刪掉既有資料）。
--
-- 登入者身分來源：沿用 roster_schema.sql —— Google 登入後 JWT 內的 email 轉小寫比對 app_users。
-- 資料表權限：收回 anon（未登入）全部權限；authenticated 只在 RLS 允許下才看得到／改得到。
-- ============================================================

-- ---------- 1. 員工編號格式放寬：MI-xxxx、PT-xxxx、OF-xxxx（公務機） ----------
-- 原本是建表時內建的 check（系統自動命名為 employees_id_check）。
-- 先 drop 再 add，重跑不會報錯；既有編號全是 MI／PT 開頭，一定通過新規則。
alter table public.employees drop constraint if exists employees_id_check;
alter table public.employees
  add constraint employees_id_check
  check (id ~ '^(MI|PT|OF)-[0-9]{4}$');   -- MI-xxxx 正式、PT-xxxx 工讀、OF-xxxx 公務機（OF-0001 起編）

-- ---------- 2. 官方 LINE 帳號清單 ----------
-- code 與 name 相同（沿用 stores 的做法）；畫面標籤直接顯示 name。
create table if not exists public.line_accounts (
  code text primary key check (length(btrim(code)) > 0),
  name text not null unique check (length(btrim(name)) > 0),
  sort_order int not null unique
);

-- 老闆名單的 12 個官方 LINE（xlsx 欄名去掉「LINE」二字）
insert into public.line_accounts (code, name, sort_order) values
  ('總',     '總',     1),
  ('同行',   '同行',   2),
  ('中和',   '中和',   3),
  ('新莊',   '新莊',   4),
  ('樹林',   '樹林',   5),
  ('桃園',   '桃園',   6),
  ('新竹',   '新竹',   7),
  ('旗艦',   '旗艦',   8),
  ('南台中', '南台中', 9),
  ('台南',   '台南',   10),
  ('高雄',   '高雄',   11),
  ('花蓮',   '花蓮',   12)
on conflict (code) do nothing;

-- ---------- 3. 誰有哪個 LINE 的回覆權限 ----------
-- 一人一個 LINE 一列；沒有列＝沒有權限。人員被刪除時權限一併刪除；LINE 帳號有人在用時不能刪。
create table if not exists public.line_access (
  employee_id text not null references public.employees(id) on update cascade on delete cascade,
  line_code text not null references public.line_accounts(code) on update cascade on delete restrict,
  created_at timestamptz not null default now(),
  primary key (employee_id, line_code)
);

create index if not exists line_access_line_code_idx on public.line_access(line_code);

-- ---------- 4. 權限與 RLS ----------
alter table public.line_accounts enable row level security;
alter table public.line_access   enable row level security;

revoke all on table public.line_accounts from public, anon, authenticated;
revoke all on table public.line_access   from public, anon, authenticated;

grant select, insert, update, delete on public.line_accounts to authenticated;
grant select, insert, update, delete on public.line_access   to authenticated;

-- line_accounts：已開通的三種角色都能讀（畫面要顯示標籤）；只有客服部能改
drop policy if exists line_accounts_select on public.line_accounts;
create policy line_accounts_select on public.line_accounts
  for select to authenticated
  using (public.roster_my_role() in ('cs_admin', 'hq_viewer', 'store_manager'));

drop policy if exists line_accounts_cs_write on public.line_accounts;
create policy line_accounts_cs_write on public.line_accounts
  for all to authenticated
  using (public.roster_my_role() = 'cs_admin')
  with check (public.roster_my_role() = 'cs_admin');

-- line_access：客服部讀增改刪；總公司主管只讀全部；店長只讀自己門市人員的紀錄
-- （店長那條用 employees 比對門市；employees 本身的 RLS 也限制店長只看到自己門市，雙重保險）
drop policy if exists line_access_select on public.line_access;
create policy line_access_select on public.line_access
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager'
        and exists (select 1 from public.employees e
                    where e.id = line_access.employee_id
                      and e.store_code = public.roster_my_store()))
  );

drop policy if exists line_access_cs_write on public.line_access;
create policy line_access_cs_write on public.line_access
  for all to authenticated
  using (public.roster_my_role() = 'cs_admin')
  with check (public.roster_my_role() = 'cs_admin');

-- ---------- 5. 客服部改某人的 LINE 權限（一次換成指定清單） ----------
-- 網頁用這個函式存檔：先刪該人全部、再依清單插入，同一個交易，失敗就全部復原。
-- security invoker（預設）：照呼叫者本人的 RLS 執行；另外在開頭明確擋掉非客服部，給白話錯誤。
-- p_codes 傳空陣列或 null＝清空該人的 LINE 權限。
create or replace function public.roster_set_line_access(p_employee_id text, p_codes text[])
returns void
language plpgsql
as $$
begin
  if public.roster_my_role() is distinct from 'cs_admin' then
    raise exception '只有客服部可以修改官方 LINE 回覆權限' using errcode = '42501';
  end if;
  if not exists (select 1 from public.employees e where e.id = p_employee_id) then
    raise exception '找不到這位人員' using errcode = '23503';
  end if;
  delete from public.line_access where employee_id = p_employee_id;
  insert into public.line_access (employee_id, line_code)
  select p_employee_id, c from (select distinct unnest(coalesce(p_codes, '{}'::text[])) as c) x;
end;
$$;

revoke execute on function public.roster_set_line_access(text, text[]) from public, anon;
grant  execute on function public.roster_set_line_access(text, text[]) to authenticated;
