-- ============================================================
-- 業務考核系統：黃單「輔導紀錄」可編輯，但每次編輯都留版本（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（if not exists／create or replace／drop 後重建，
--   既有版本紀錄不會被刪；補第 1 版只補「還沒有任何版本」的黃單）。
--
-- ---------- 老闆定案（2026-11）----------
--   店長與客服部仍可編輯黃單的輔導紀錄（日期與備註），但每次儲存都新增一筆「版本」，舊內容不會被蓋掉。
--   第一次回填也算第 1 版。版本只能新增，不能改、不能刪（做法比照「帳號管理」的 app_users_audit）。
--   誰看得到版本：客服部、該黃單所屬門市的店長（沿用黃單既有可見範圍）；總公司主管與其他人一律「沒有權限」。
--   與「改善單輔導紀錄版本」（coach_history_schema.sql）規則相同，但資料表、函式都獨立，互不依賴、執行順序不拘。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   … → roster_schema → accounts_schema → spotcheck_schema（黃單與 spot_coach）→ …（spotdims、noredticket 等照原順序）
--   【本檔 spot_coach_history_schema.sql】 → spot_coach_history_verify_fake.sql（可選）
--   網頁（spotcheck.html 單據清單）要在本檔執行「之後」才會顯示編輯紀錄；沒執行前頁面照常運作，只是不顯示版本資訊。
--
-- ---------- 本檔做了什麼 ----------
--   資料表：spot_ticket_coach_versions（只增不改；故意不設外鍵，歷史紀錄不跟著黃單被連帶刪除）
--   函式：spot_coach_editor_label（內部用，算「門市-暱稱」）、
--         spot_coach_versions（對外：讀某張黃單的版本）、
--         spot_coach_version_stats（對外：單據清單用，一次回傳每張黃單的版本數與最後編輯時間，避免逐張查詢）
--   觸發器（掛在版本表上）：spot_coach_ver_no_update_trg／no_delete_trg／no_truncate_trg（一律擋）
--   RLS policy（掛在版本表上）：spot_coach_ver_select_cs（只有客服部能直接讀；店長走函式）
--   覆蓋：spot_coach（create or replace，簽名、權限、作廢單不能回填、店長限自己門市、各種檢查訊息全部保留，
--     只多做「同一個交易裡新增一筆版本」）
--   補資料：既有已有輔導紀錄的黃單（含已作廢者），各補一筆「第 1 版」
--     （用現有 coached_by／coached_at／coach_note／coached_on）。
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.spot_tickets') is null
     or to_regclass('public.app_users') is null
     or to_regclass('public.employees') is null
     or to_regclass('public.stores') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_email()') is null
     or to_regprocedure('public.roster_my_store()') is null
     or to_regprocedure('public.spot_coach(uuid, date, text)') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 roster_schema、spotcheck_schema 等前面的檔案';
  end if;
end
$$;

-- ---------- 1. 版本表（只增不改） ----------
create table if not exists public.spot_ticket_coach_versions (
  id bigint generated always as identity primary key,
  ticket_id uuid not null,                       -- 黃單 id（不設外鍵：歷史紀錄獨立保存）
  version_no int not null check (version_no >= 1),
  coached_on date not null,                      -- 該版的輔導日期
  coach_note text not null,                      -- 該版的輔導備註
  edited_by text not null,                       -- 編輯人信箱；沒有登入者記為 '(SQL Editor)'
  editor_label text not null,                    -- 編輯人顯示名「門市-暱稱」（當下的快照，之後換店或改名不影響歷史）
  edited_at timestamptz not null default now(),  -- 編輯時間（網頁以台北時間顯示）
  constraint spot_coach_ver_uniq unique (ticket_id, version_no)
);

alter table public.spot_ticket_coach_versions enable row level security;

-- 先全收回（含 service_role；insert／update／delete／truncate 一併收回），
-- 只給 authenticated「讀」（再由 policy 限制只有客服部直接讀得到）；anon 完全沒有。
-- 寫入只由 security definer 函式（以擁有者身分）進行，不需要任何網頁角色有寫入權限。
revoke all on table public.spot_ticket_coach_versions from public, anon, authenticated, service_role;
grant select on public.spot_ticket_coach_versions to authenticated;

drop policy if exists spot_coach_ver_select_cs on public.spot_ticket_coach_versions;
create policy spot_coach_ver_select_cs on public.spot_ticket_coach_versions
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- 第二道鎖：就算有人（含擁有者）直接 update／delete／truncate，也一律拒絕。
-- 寫入走 insert，不經過這三個觸發器，不受影響。
-- 限制：資料庫擁有者仍可先停用這些觸發器再改（與 app_users_audit 相同）。
create or replace function public.spot_coach_ver_immutable()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception '輔導紀錄的編輯版本只增不改';
end;
$$;

drop trigger if exists spot_coach_ver_no_update_trg on public.spot_ticket_coach_versions;
create trigger spot_coach_ver_no_update_trg
  before update on public.spot_ticket_coach_versions
  for each row execute function public.spot_coach_ver_immutable();

drop trigger if exists spot_coach_ver_no_delete_trg on public.spot_ticket_coach_versions;
create trigger spot_coach_ver_no_delete_trg
  before delete on public.spot_ticket_coach_versions
  for each row execute function public.spot_coach_ver_immutable();

drop trigger if exists spot_coach_ver_no_truncate_trg on public.spot_ticket_coach_versions;
create trigger spot_coach_ver_no_truncate_trg
  before truncate on public.spot_ticket_coach_versions
  for each statement execute function public.spot_coach_ver_immutable();

revoke all on function public.spot_coach_ver_immutable() from public, anon, authenticated;

-- ---------- 2. 內部小工具：編輯人顯示名「門市-暱稱」 ----------
-- 店長：「門市名稱-暱稱」；客服部、總公司主管：「總公司-名字」。
-- 名字＝綁定員工的暱稱，沒有暱稱用姓名；兩個都沒有寫「（未填暱稱）」。
-- 找不到帳號（已被移除）寫「（已移除帳號）」；沒有登入者（SQL Editor）寫「（系統）」。
create or replace function public.spot_coach_editor_label(p_email text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_label text;
begin
  if p_email is null or btrim(p_email) = '' or p_email = '(SQL Editor)' then
    return '（系統）';
  end if;
  select (case when u.role = 'store_manager' then coalesce(s.name, u.store_code) else '總公司' end)
         || '-' || coalesce(nullif(btrim(e.nickname), ''), nullif(btrim(e.full_name), ''), '（未填暱稱）')
    into v_label
  from public.app_users u
  left join public.employees e on e.id = u.employee_id
  left join public.stores s on s.code = u.store_code
  where u.email = lower(btrim(p_email));
  return coalesce(v_label, '（已移除帳號）');
end;
$$;

revoke execute on function public.spot_coach_editor_label(text) from public, anon, authenticated;

-- ---------- 3. 補第 1 版：既有已有輔導紀錄的黃單 ----------
-- 只補「還沒有任何版本」的單；重跑不會重複補。
-- spot_tickets 的輔導欄位有檢查（要嘛全空、要嘛日期／備註／填寫人／時間都有），所以這些欄位一定有值。
insert into public.spot_ticket_coach_versions
  (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label, edited_at)
select t.id, 1, t.coached_on, t.coach_note,
       coalesce(nullif(btrim(t.coached_by), ''), '(SQL Editor)'),
       public.spot_coach_editor_label(t.coached_by),
       t.coached_at
from public.spot_tickets t
where t.coached_on is not null
  and nullif(btrim(coalesce(t.coach_note, '')), '') is not null
  and not exists (select 1 from public.spot_ticket_coach_versions v where v.ticket_id = t.id);

-- ---------- 4. 覆蓋：回填／編輯輔導紀錄（多寫一筆版本） ----------
-- 與 spotcheck_schema.sql 的原版相同：簽名、權限（客服部或自己門市店長）、店長對找不到／別店的單一律通用訊息、
-- 作廢的單不能回填、日期與備註檢查、訊息全部保留；唯一新增：更新黃單後，同一個交易裡新增一筆版本
-- （版本序號＝目前最大＋1）。單列已在函式開頭 for update 鎖住，同一張單同時儲存不會產生重複序號。
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
  v_email text := public.roster_my_email();
  v_now timestamptz := now();
  v_ver int;
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
         coached_by = v_email,
         coached_at = v_now
   where id = p_ticket_id;

  -- 新增一筆版本（第一次回填＝第 1 版）
  select coalesce(max(v.version_no), 0) + 1 into v_ver
  from public.spot_ticket_coach_versions v
  where v.ticket_id = p_ticket_id;

  insert into public.spot_ticket_coach_versions
    (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label, edited_at)
  values
    (p_ticket_id, v_ver, p_coached_on, v_note,
     coalesce(nullif(v_email, ''), '(SQL Editor)'),
     public.spot_coach_editor_label(v_email),
     v_now);
end;
$$;

-- ---------- 5. 對外函式：讀某張黃單的輔導紀錄版本（新到舊） ----------
-- 客服部：任何黃單；店長：自己門市的黃單（含已作廢者，與黃單既有可見範圍一致）；
-- 其他人（含總公司主管、沒開通帳號）一律「沒有權限」。
-- 信箱只給客服部看（店長不看任何信箱）；版本表沒有資料就回空清單。
create or replace function public.spot_coach_versions(p_ticket_id uuid)
returns table (
  version_no int,
  coached_on date,
  coach_note text,
  edited_at timestamptz,
  editor_label text,
  edited_by text,
  is_current boolean
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_t public.spot_tickets%rowtype;
begin
  select * into v_t from public.spot_tickets t where t.id = p_ticket_id;

  if v_role = 'cs_admin' then
    if not found then
      raise exception '找不到單據';
    end if;
  elsif v_role = 'store_manager'
        and found
        and v_t.store_code is not distinct from public.roster_my_store() then
    null;   -- 自己門市：放行
  else
    raise exception '沒有權限';
  end if;

  return query
    select v.version_no, v.coached_on, v.coach_note, v.edited_at, v.editor_label,
           case when v_role = 'cs_admin' then v.edited_by else null end,
           v.version_no = (select max(x.version_no) from public.spot_ticket_coach_versions x where x.ticket_id = p_ticket_id)
    from public.spot_ticket_coach_versions v
    where v.ticket_id = p_ticket_id
    order by v.version_no desc;
end;
$$;

-- ---------- 6. 對外函式：單據清單用的版本統計（每張黃單：版本數、最後編輯時間） ----------
-- 客服部：全部黃單；店長：自己門市；其他人一律「沒有權限」。只回「有版本」的單。
create or replace function public.spot_coach_version_stats()
returns table (ticket_id uuid, version_count int, last_edited_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;

  return query
    select v.ticket_id, count(*)::int, max(v.edited_at)
    from public.spot_ticket_coach_versions v
    join public.spot_tickets t on t.id = v.ticket_id
    where v_role = 'cs_admin' or t.store_code is not distinct from public.roster_my_store()
    group by v.ticket_id;
end;
$$;

-- ---------- 7. 函式權限：收回 public／anon，只授權 authenticated ----------
revoke execute on function public.spot_coach(uuid, date, text) from public, anon;
grant  execute on function public.spot_coach(uuid, date, text) to authenticated;
revoke execute on function public.spot_coach_versions(uuid) from public, anon;
grant  execute on function public.spot_coach_versions(uuid) to authenticated;
revoke execute on function public.spot_coach_version_stats() from public, anon;
grant  execute on function public.spot_coach_version_stats() to authenticated;

commit;
