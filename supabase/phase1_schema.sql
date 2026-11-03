-- ============================================================
-- 業務考核系統：第一期 資料庫結構（考核期、固定 3 題組、弱項追加題、待開通）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 唯一規格：README_phase1.md（規則、資料庫物件、函式簽名、與既有函式的串接；實作說明在該檔第四節）。
-- 前提（缺任何一個，開頭會用中文錯誤訊息擋下並整份回復）：
--   考題抽選器 schema.sql、roster_schema.sql、assess_schema.sql、bank_schema.sql、accounts_schema.sql、
--   notes_visible_schema.sql、backoffice_schema.sql、spotcheck_schema.sql、url_patch.sql、
--   weak_suggest_schema.sql、exam_request_schema.sql 都已在同一個專案執行過。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 專案內原本沒有 phase1、reply_activations、activation_、assess_core_categories、assess_draft_weak、
-- assess_add_extra、is_extra、extra_started_at、period_status、passed_on、exam_core_categories 這些名稱。
-- 本檔新增的名稱：
--   欄位：employees.period_status、employees.passed_on、assessment_items.is_extra、assessments.extra_started_at
--   約束／索引：employees_period_status_check（check）、assessment_items_one_core_per_category（唯一部分索引，
--         取代原本的 unique (assessment_id, category)）、reply_activations_pkey、reply_activations_one_per_assessment
--         （唯一部分索引）、reply_activations_status_idx、reply_activations_store_idx、reply_activations_status_fields（check）
--   資料表：reply_activations（待開通回覆權限）
--   RLS policy：reply_activations_select
--   app_settings 新增兩列：exam_core_categories（預設「基礎,進階,綜合」，已有就不動）、
--         phase1_migrated_on（遷移完成記號，見下）
--   對外函式（授權 authenticated，函式內自己驗角色）：
--     assess_core_categories()、assess_draft_weak(uuid)、assess_add_extra(uuid, bigint[])、activation_mark_done(uuid)
--   內部函式（任何網頁角色都不能直接呼叫）：phase1_migrate_period_status()
--   被改寫的既有物件（簽名、回傳型別都不變，原有行為全部保留）：
--     函式：assess_start(text, text)、assess_submit(uuid)、assess_weak_profile(text)、
--           exam_req_candidates(text)、exam_req_create(text, text, date[], boolean, text, uuid)、exam_req_badge()、
--           spot_register(text, date, text, jsonb, text, text)（回考核期時同步設 period_status＝考核期）、
--           spot_cancel_probation(uuid, text)（取消時同步把 period_status 設回已上線）、
--           spot_candidates()（名單排除考核期的人；spot_register 的資格檢查同步排除）
--     檢視：employees_with_tenure（drop 後重建，內容與 spotcheck_schema.sql 最新版相同，新欄位由 e.* 帶出）、
--           assessment_summaries（item_count 只算核心題組）、analytics_dim_rates（排除追加題）
--     資料表約束：assessment_items 的 unique (assessment_id, category) 改成「只對核心題組生效」的部分唯一索引
--
-- 怎麼執行（之後老闆同意才做）：
--   0. 先到 Supabase 備份（Dashboard → Database → Backups）。
--   1. Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   2. 再跑 phase1_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 單一交易：整份是 begin; … commit;，中途任何一步報錯整份自動回復，什麼都沒改。
-- 開頭設了 lock_timeout：拿不到資料表鎖（例如有人正在送出成績單）就報錯並整份回復，不會卡住別人，
-- 稍後重跑即可。請不要在中途自己手動下 commit／rollback。
--
-- 可重複執行：欄位 add column if not exists、約束先查再 drop／add、資料表與索引 if not exists、
-- 函式 create or replace、policy 先 drop 再建、檢視 drop 後重建或 create or replace；
-- 重跑不會報錯，也不會刪掉既有資料。
-- 「既有資料遷移」只會在第一次執行時做：做完會在 app_settings 寫入 phase1_migrated_on 記號，
-- 之後重跑看到記號就整段略過，所以重跑不會把已上線的人改回考核期（也不會改掉客服部之後手動調整的結果）。
--
-- 安全設計：reply_activations 開 RLS，直接寫入（insert／update／delete／truncate）一律不給，只能透過函式與
-- assess_submit 寫入；日期一律用台北時間（Asia/Taipei）。
--
-- 緊急還原：
--   * 新欄位、新資料表、新函式留著不影響舊功能。
--   * 還原 assess_start／assess_submit：先把 spotcheck_schema.sql 內這兩個函式整段重新執行
--     （追加題欄位 is_extra 還在，但舊版 assess_submit 會把追加題算進總分——若已有追加題資料，請先不要還原）。
--   * 還原 assess_weak_profile／exam_req_*：分別重新執行 weak_suggest_schema.sql、exam_request_schema.sql 內該函式。
--   * 檢視還原：重新執行 assess_schema.sql 的 assessment_summaries、backoffice_schema.sql 的 analytics_dim_rates。
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
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null
     or to_regclass('public.questions') is null
     or to_regclass('public.drawn') is null
     or to_regclass('public.category_last') is null then
    raise exception '請先執行考題抽選器的 schema.sql、roster_schema.sql 與 assess_schema.sql';
  end if;
  if to_regclass('public.spot_probations') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'employees' and column_name = 'probation_since') then
    raise exception '請先執行 spotcheck_schema.sql（缺少 spot_probations 或 employees.probation_since）';
  end if;
  if to_regclass('public.improvement_tickets') is null
     or to_regclass('public.analytics_dim_rates') is null then
    raise exception '請先執行 backoffice_schema.sql';
  end if;
  if to_regclass('public.question_dims') is null
     or to_regprocedure('public.assess_weak_profile(text)') is null
     or to_regprocedure('public.assess_pick(uuid, bigint[])') is null then
    raise exception '請先執行 weak_suggest_schema.sql';
  end if;
  if to_regclass('public.exam_requests') is null
     or to_regclass('public.app_settings') is null
     or to_regprocedure('public.exam_req_candidates(text)') is null
     or to_regprocedure('public.exam_req_create(text, text, date[], boolean, text, uuid)') is null
     or to_regprocedure('public.exam_req_badge()') is null then
    raise exception '請先執行 exam_request_schema.sql';
  end if;
  if to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_score_item(jsonb)') is null
     or to_regprocedure('public.assess_dim_order()') is null
     or to_regprocedure('public.assess_level_pct(text)') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null
     or to_regprocedure('public.roster_my_email()') is null then
    raise exception '缺少必要函式，請先執行 roster_schema.sql 與 assess_schema.sql';
  end if;
  -- 確認 assess_start／assess_submit 目前是「抽查系統」那一版（本檔以那一版為基礎改寫）
  if not exists (select 1 from pg_proc p
                 where p.oid = 'public.assess_start(text, text)'::regprocedure and p.prosrc like '%probation_since%')
     or not exists (select 1 from pg_proc p
                    where p.oid = 'public.assess_submit(uuid)'::regprocedure and p.prosrc like '%spot_probations%') then
    raise exception 'assess_start／assess_submit 不是 spotcheck_schema.sql 的版本，請先執行 spotcheck_schema.sql';
  end if;
end
$$;

-- ---------- 1. 名冊新欄位：考核期狀態、通過日 ----------
-- period_status：考核期＝尚不能回覆顧客；已上線＝可回覆。既有資料的遷移見第 7 段。
alter table public.employees
  add column if not exists period_status text not null default '已上線';

-- check 約束：欄位已存在的重跑情況下 add column 不會重建約束，所以用名稱檢查補上
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.employees'::regclass and conname = 'employees_period_status_check') then
    alter table public.employees
      add constraint employees_period_status_check check (period_status in ('考核期', '已上線'));
  end if;
end
$$;

alter table public.employees add column if not exists passed_on date;

comment on column public.employees.period_status is
  '考核期／已上線。考核期＝尚不能回覆顧客（新人合格線 70）；通過考核後由 assess_submit 改成已上線並記 passed_on。';
comment on column public.employees.passed_on is
  '通過考核（轉為已上線）的台北日期；遷移前就已上線的人為空。';

-- ---------- 2. 名冊檢視：重建以帶出新欄位 ----------
-- 與 spotcheck_schema.sql 的最新版內容完全相同（e.* ＋ tenure_group）；新欄位 period_status、passed_on 由 e.* 帶出。
-- e.* 是「建立當下」展開的，所以必須 drop 後重建（create or replace 不能把新欄位插在中間）。
-- 沒有其他檢視依賴它（若有，drop 會報錯停下，整份回復）。重做權限。
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

-- ---------- 3. 成績單新欄位、題組唯一限制改寫 ----------
alter table public.assessment_items add column if not exists is_extra boolean not null default false;
alter table public.assessments add column if not exists extra_started_at timestamptz;

comment on column public.assessment_items.is_extra is
  '弱項追加題（true）：不算入總分、判定、最弱面向、七面向分析與改善單，只記在成績單上當輔導參考。';
comment on column public.assessments.extra_started_at is
  '第一次追加弱項題的時間（只寫第一次；追加題不做倒數）。';

-- 原本 assess_schema.sql 的 unique (assessment_id, category)（一場每個分類最多一個題組）：
-- 查出「只管 assessment_id＋category 這兩欄」的唯一約束（不寫死名稱）並 drop，改成只對核心題組生效的部分唯一索引。
do $$
declare
  v_a smallint;
  v_c smallint;
  v_con record;
begin
  select a.attnum into v_a from pg_attribute a
   where a.attrelid = 'public.assessment_items'::regclass and a.attname = 'assessment_id' and not a.attisdropped;
  select a.attnum into v_c from pg_attribute a
   where a.attrelid = 'public.assessment_items'::regclass and a.attname = 'category' and not a.attisdropped;

  for v_con in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.assessment_items'::regclass
      and c.contype = 'u'
      and c.conkey::smallint[] <@ array[v_a, v_c]
      and c.conkey::smallint[] @> array[v_a, v_c]
  loop
    execute format('alter table public.assessment_items drop constraint %I', v_con.conname);
  end loop;
end
$$;

create unique index if not exists assessment_items_one_core_per_category
  on public.assessment_items(assessment_id, category) where not is_extra;

-- ---------- 4. 資料表：待開通回覆權限 ----------
create table if not exists public.reply_activations (
  id uuid primary key default gen_random_uuid(),
  employee_id text not null references public.employees(id) on update cascade on delete cascade,
  employee_label text not null,                 -- 通過當下的暱稱或姓名（顯示用快照）
  store_code text not null,                     -- 通過當下的門市快照（取自成績單）
  assessment_id uuid references public.assessments(id) on delete set null,   -- 通過的那張成績單
  passed_on date not null,                      -- 通過日（台北日期）
  status text not null default '待開通' check (status in ('待開通', '已開通')),
  done_on date,                                 -- 已開通日期（台北日期）
  done_by text,                                 -- 按「已開通」的人（信箱）
  created_at timestamptz not null default now(),
  constraint reply_activations_status_fields check (
    (status = '待開通' and done_on is null and done_by is null)
    or (status = '已開通' and done_on is not null and done_by is not null)
  )
);

create index if not exists reply_activations_status_idx on public.reply_activations(status);
create index if not exists reply_activations_store_idx on public.reply_activations(store_code, status);
-- 同一張成績單最多一筆待開通（資料庫最後一道防線）
create unique index if not exists reply_activations_one_per_assessment
  on public.reply_activations(assessment_id) where assessment_id is not null;

alter table public.reply_activations enable row level security;

-- 先全收回；只給 authenticated「讀」，沒有任何人有直接寫入權限（只能透過函式寫）
revoke all on table public.reply_activations from public, anon, authenticated;
grant select on public.reply_activations to authenticated;

-- 客服部、總公司主管：全看；店長：只看自己門市；其他（含沒帳號）什麼都看不到
drop policy if exists reply_activations_select on public.reply_activations;
create policy reply_activations_select on public.reply_activations
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );

-- ---------- 5. 系統設定：核心題組分類 ----------
insert into public.app_settings (key, value)
values ('exam_core_categories', '基礎,進階,綜合')
on conflict (key) do nothing;

-- ---------- 6. 既有資料遷移（只做一次） ----------
-- 規則（規格第二節）：
--   * employees_with_tenure.tenure_group = '新人'（到職 90 天內）、在職、納入考核，
--     且「沒有任何已送出未作廢、判定為及格或優秀的成績單」→ 考核期
--   * probation_since 有值者一律 → 考核期
--   * 其餘維持已上線（新欄位預設值）
-- 做法：記號 app_settings.phase1_migrated_on 存在就整段略過（所以重跑不會把已上線的人改回考核期）；
--   不存在才遷移，做完寫記號。回傳這次改成考核期的人數（略過時回傳 0）。
-- 注意：accounts_schema.sql 的 accounts_employees_job_title_len 是 NOT VALID 約束，
--   「被更新的列」會被檢查；若有人職稱超過 20 字，更新會失敗。所以先檢查，有就用中文訊息停下（整份回復）。
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

select public.phase1_migrate_period_status();

-- ---------- 7. assess_core_categories：核心題組分類清單 ----------
-- 讀 app_settings.exam_core_categories（逗號分隔；半形「,」與全形「，」都可以），
-- 去頭尾空白、去空項、去重（保留第一次出現的順序）；沒設定或解析後是空的 → 預設三類。
create or replace function public.assess_core_categories()
returns text[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_raw text;
  v_out text[];
begin
  perform public.assess_assert_cs();

  select s.value into v_raw from public.app_settings s where s.key = 'exam_core_categories';

  select coalesce(array_agg(y.c order by y.n), '{}'::text[]) into v_out
  from (
    select x.c, min(x.n) as n
    from (
      select btrim(t.c, E' \t\r\n' || chr(12288)) as c, t.n
      from unnest(string_to_array(translate(coalesce(v_raw, ''), '，', ','), ',')) with ordinality as t(c, n)
    ) x
    where x.c <> ''
    group by x.c
  ) y;

  if cardinality(v_out) = 0 then
    v_out := array['基礎', '進階', '綜合']::text[];
  end if;
  return v_out;
end;
$$;

-- ---------- 8. 開始考核（assess_start） ----------
-- 以 spotcheck_schema.sql 的版本為基礎，原有行為全部保留，只新增一段：
--   員工 probation_since 為空且 period_status = '考核期' → 身分「新人」（合格線 70），tenure_source 維持 '自動'
--   （忽略到職日與 p_tenure_override；到職日空白也不需要手動指定）。
--   probation_since 有值維持既有（正式、考核期、85）；period_status = '已上線' 維持既有判斷。
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

-- ---------- 9. 送出（assess_submit） ----------
-- 以 spotcheck_schema.sql 的版本為基礎，原有行為全部保留，只改：
--   * 總分、題組分數平均、判定、weakest_dims、item_count 只用 is_extra = false 的題組；
--     追加題一樣要求評完才能送出（並照常寫入各自的 item_score 等欄位，只是不進總分）
--   * 送出後的考核期處理：
--       新人（tenure = '新人'）總分 >= 70 且員工 period_status = '考核期' → 已上線＋passed_on＋新增待開通
--       回考核期（tenure_source = '考核期'）總分 >= 85 → 先鎖員工列；只有員工目前 probation_since 有值或 period_status = '考核期' 時，
--         才清除 probation_since、設已上線＋passed_on＋新增待開通（已是已上線且 probation_since 為空——例如已取消回考核期、
--         或另一張草稿已先通過——只正常送出成績單）；spot_probations 改已通過的既有更新照舊
--     同一張成績單不會重複新增待開通（唯一部分索引＋on conflict do nothing）。
--     assess_void（作廢成績單）不倒回，維持現狀。
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
  if v_a.tenure_source = '考核期' and v_total >= 85 then
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
  if v_a.tenure = '新人' and v_total >= 70 then
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

-- ---------- 10. assess_draft_weak：用「這一場」核心題組找弱項 ----------
-- 客服部、自己的草稿；只用 is_extra = false 的題組、每題都必須已評完（七面向齊全）。
-- 回傳 { "rates": [{dim,pct}]（七個面向，固定順序，沒資料的 pct 為 null）,
--        "weak": [{dim,pct}]（5 個可標記面向中得分率 < 85 的最低至多 2 個，由低到高；剛好 85 不算）,
--        "always_low": [{dim,pct}]（語氣與禮貌、文字品質 < 70） }。
-- 得分率定義與 assess_weak_profile 完全一致（各題組該面向的等級百分比取平均；不適用不計入；
-- 判斷用未四捨五入的平均，輸出的 pct 四捨五入到小數 1 位）。weak 並列時依面向固定順序取先者。
create or replace function public.assess_draft_weak(p_assessment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pick constant text[] := array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識'];
  v_me text;
  v_a public.assessments%rowtype;
  r record;
  v_cnt int := 0;
  v_out jsonb;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_a from public.assessments where id = p_assessment_id;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以分析弱項';
  end if;
  if v_a.examiner_email <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  for r in
    select i.seq, i.levels
    from public.assessment_items i
    where i.assessment_id = v_a.id and not i.is_extra
    order by i.seq
  loop
    v_cnt := v_cnt + 1;
    begin
      perform public.assess_score_item(r.levels);
    exception when others then
      raise exception '第 % 題組尚未評完或評分不正確：%', r.seq, sqlerrm;
    end;
  end loop;
  if v_cnt = 0 then
    raise exception '這場考核還沒有核心題組';
  end if;

  with rr as (
    select d.dim, d.n,
           (select avg(public.assess_level_pct(i.levels ->> d.dim))
              from public.assessment_items i
             where i.assessment_id = v_a.id and not i.is_extra) as pct
    from unnest(public.assess_dim_order()) with ordinality as d(dim, n)
  )
  select jsonb_build_object(
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
                          where x.dim = any(v_pick) and x.pct is not null and x.pct < 85
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

-- ---------- 11. assess_add_extra：追加弱項題 ----------
-- 與 assess_pick 同一個範本（題組由呼叫者指定；同一把 advisory lock；每題前該分類若已全部在 drawn 內先開新一輪；
-- repeated＝該考生以前考過這題；was_drawn_before、drawn、category_last、機密表的寫入方式逐項照 assess_pick），
-- 回傳欄位與 assess_draw 完全相同。差異：
--   * 寫入 is_extra = true，不受「每分類一題」限制（可與核心題組同分類）
--   * 核心題組（is_extra = false）必須已有且全部評完才能追加
--   * 題組不存在、重複、已在這場考核內（核心或追加）都拒絕
--   * 一次最多 4 題；整場追加題最多 4 題
--   * 第一次追加時寫 assessments.extra_started_at（之後不再改）
-- 整個呼叫是單一交易：任何一題不合規就整批回復。
create or replace function public.assess_add_extra(p_assessment_id uuid, p_question_ids bigint[])
returns table(item_id uuid, category text, code text, title text, steps jsonb,
              repeated boolean, new_round boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_me text;
  v_a public.assessments%rowtype;
  r record;
  v_qid bigint;
  v_cat text;
  v_missing bigint;
  v_core int := 0;
  v_extra int;
  v_has_undrawn boolean;
  v_taken boolean;
  v_new boolean;
  v_was boolean;
  v_seq int;
  v_item uuid;
  v_code text;
  v_title text;
  v_steps jsonb;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以追加題組';
  end if;
  if v_a.examiner_email <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  if p_question_ids is null or coalesce(cardinality(p_question_ids), 0) = 0 then
    raise exception '請至少選一個題組';
  end if;
  if exists (select 1 from unnest(p_question_ids) as t(q) where t.q is null) then
    raise exception '題組編號不可空白';
  end if;
  if (select count(distinct t.q) from unnest(p_question_ids) as t(q)) <> cardinality(p_question_ids) then
    raise exception '題組不可重複選取';
  end if;
  if cardinality(p_question_ids) > 4 then
    raise exception '一次最多追加 4 題（目前 % 題）', cardinality(p_question_ids);
  end if;

  -- 核心題組（is_extra = false）必須已有，且七面向都已評完
  for r in
    select i.seq, i.levels
    from public.assessment_items i
    where i.assessment_id = v_a.id and not i.is_extra
    order by i.seq
  loop
    v_core := v_core + 1;
    begin
      perform public.assess_score_item(r.levels);
    exception when others then
      raise exception '核心題組尚未評完，不能追加弱項題（第 % 題組：%）', r.seq, sqlerrm;
    end;
  end loop;
  if v_core = 0 then
    raise exception '這場考核還沒有核心題組，不能追加弱項題';
  end if;

  -- 同時間只允許一個人抽題（與 assess_draw、assess_pick、題庫管理共用同一把鎖）
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  -- 以下與題庫內容有關的檢查，都放在取鎖之後（題庫可能同時被改名、被刪）
  select t.q into v_missing
  from unnest(p_question_ids) with ordinality as t(q, n)
  where not exists (select 1 from public.questions x where x.id = t.q)
  order by t.n
  limit 1;
  if v_missing is not null then
    raise exception '題組不存在：%', v_missing;
  end if;

  if exists (select 1
             from public.assessment_items i
             join public.assessment_item_secrets sx on sx.item_id = i.id
             where i.assessment_id = v_a.id
               and sx.question_id = any(p_question_ids)) then
    raise exception '這個題組已在這場考核內，不可重複選取';
  end if;

  select count(*)::int into v_extra
  from public.assessment_items i where i.assessment_id = v_a.id and i.is_extra;
  if v_extra + cardinality(p_question_ids) > 4 then
    raise exception '整場追加題最多 4 題（已追加 % 題，這次要再追加 % 題）', v_extra, cardinality(p_question_ids);
  end if;

  select coalesce(max(i.seq), 0) into v_seq
  from public.assessment_items i where i.assessment_id = v_a.id;

  -- 第一次追加才寫（之後不改）
  update public.assessments
     set extra_started_at = now()
   where id = v_a.id and extra_started_at is null;

  for v_qid in select t.q from unnest(p_question_ids) with ordinality as t(q, n) order by t.n loop
    select q.category into v_cat from public.questions q where q.id = v_qid;

    v_new := false;

    select exists (
      select 1 from public.questions q
      where q.category = v_cat
        and not exists (select 1 from public.drawn d where d.question_id = q.id)
    ) into v_has_undrawn;

    if not v_has_undrawn then
      delete from public.drawn d
      where d.question_id in (select q.id from public.questions q where q.category = v_cat);
      v_new := true;
    end if;

    -- 該考生以前考過這題（與 assess_draw／assess_pick 相同的判斷：已送出與已作廢，草稿不算）
    select exists (select 1
                   from public.assessment_items ai
                   join public.assessment_item_secrets sx on sx.item_id = ai.id
                   join public.assessments x on x.id = ai.assessment_id
                   where x.employee_id = v_a.employee_id
                     and x.status in ('submitted', 'voided')
                     and sx.question_id = v_qid)
      into v_taken;

    v_was := exists (select 1 from public.drawn d where d.question_id = v_qid);

    insert into public.drawn (question_id) values (v_qid)
    on conflict (question_id) do update set drawn_at = now();

    insert into public.category_last (category, question_id) values (v_cat, v_qid)
    on conflict (category) do update set question_id = excluded.question_id;

    select q.code, q.title, q.steps into v_code, v_title, v_steps
    from public.questions q where q.id = v_qid;

    v_seq := v_seq + 1;

    insert into public.assessment_items (assessment_id, seq, category, code, is_extra)
    values (v_a.id, v_seq, v_cat, v_code, true)
    returning id into v_item;

    insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps)
    values (v_item, v_qid, v_was, v_title, v_steps);

    item_id := v_item;
    category := v_cat;
    code := v_code;
    title := v_title;
    steps := v_steps;
    repeated := v_taken;
    new_round := v_new;
    return next;
  end loop;
end;
$$;

-- ---------- 12. activation_mark_done：標記已開通 ----------
-- 客服部；待開通 → 已開通，記 done_on（台北日期）與 done_by（信箱）；已開通者拒絕。
create or replace function public.activation_mark_done(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_r public.reply_activations%rowtype;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_r from public.reply_activations where id = p_id for update;
  if not found then
    raise exception '找不到待開通紀錄';
  end if;
  if v_r.status <> '待開通' then
    raise exception '這筆已經是「已開通」，不可重複標記';
  end if;

  update public.reply_activations
     set status = '已開通',
         done_on = (now() at time zone 'Asia/Taipei')::date,
         done_by = v_me
   where id = p_id;
end;
$$;

-- ---------- 13. 待考回報（exam_req_candidates／exam_req_create／exam_req_badge） ----------
-- 以 exam_request_schema.sql 的版本為基礎，原有行為全部保留，只改：
--   * 新人資格：在職、納入考核、period_status = '考核期' 且 probation_since is null（不再用到職 90 天判斷）
--   * 回考核期、複檢：不變
--   * exam_req_badge：客服部 = 待處理回報數 ＋ 待開通數；其餘角色不變
create or replace function public.exam_req_candidates(p_kind text)
returns table(employee_id text, label text, store_code text, ticket_id uuid, ticket_note text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_store text;
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_kind is null or p_kind not in ('新人', '回考核期', '複檢') then
    raise exception '情況必須是「新人」「回考核期」或「複檢」';
  end if;
  if v_role = 'store_manager' then
    v_store := public.roster_my_store();
  end if;

  if p_kind in ('新人', '回考核期') then
    return query
      select e.id,
             public.exam_req_label(e.nickname, e.full_name),
             e.store_code,
             null::uuid,
             null::text
      from public.employees_with_tenure e
      where e.status = '在職'
        and e.include_in_assessment
        and (v_store is null or e.store_code = v_store)
        and ((p_kind = '新人' and e.probation_since is null and e.period_status = '考核期')
             or (p_kind = '回考核期' and e.probation_since is not null))
        and not exists (select 1 from public.exam_requests r
                        where r.employee_id = e.id and r.kind = p_kind
                          and r.status = any(public.exam_req_status_open()))
      order by e.store_code, e.id;
  else
    return query
      select e.id,
             public.exam_req_label(e.nickname, e.full_name),
             e.store_code,
             t.id,
             t.coach_note
      from public.improvement_tickets t
      join public.employees e on e.id = t.employee_id
      where t.status = 'coached'
        and e.status = '在職'
        and e.include_in_assessment
        and (v_store is null or e.store_code = v_store)
        and not exists (select 1 from public.exam_requests r
                        where r.improvement_ticket_id = t.id and r.kind = '複檢'
                          and r.status = any(public.exam_req_status_open()))
        -- 已完成的複檢（連到的成績單目前仍是已送出）不再列；成績單被作廢者可重報
        and not exists (select 1 from public.exam_requests r
                        join public.assessments a on a.id = r.assessment_id
                        where r.improvement_ticket_id = t.id and r.kind = '複檢'
                          and r.status = '已完成' and a.status = 'submitted')
      order by e.store_code, e.id, t.created_at;
  end if;
end;
$$;

create or replace function public.exam_req_create(
  p_kind text,
  p_employee_id text,
  p_dates date[],
  p_video boolean,
  p_note text,
  p_ticket_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_emp public.employees%rowtype;
  v_tk public.improvement_tickets%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288)), '');
  v_id uuid;
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_kind is null or p_kind not in ('新人', '回考核期', '複檢') then
    raise exception '情況必須是「新人」「回考核期」或「複檢」';
  end if;

  -- 每日頻率限制：同一個回報人當天（台北日期）已建立 20 筆（含已取消）就拒絕
  if (select count(*) from public.exam_requests r
      where r.requested_by = public.roster_my_email()
        and (r.created_at at time zone 'Asia/Taipei')::date = v_today) >= 20 then
    raise exception '今天回報次數已達上限（20 筆），請明天再試或聯絡客服部';
  end if;

  -- 鎖住人員那一列：同一個人的並發回報在這裡排隊
  select * into v_emp from public.employees where id = p_employee_id for update;
  -- 店長：找不到或別間門市一律回同一句，不讓店長藉編號探知別間門市的人
  if not found
     or (v_role = 'store_manager' and v_emp.store_code is distinct from public.roster_my_store()) then
    raise exception '找不到這位人員或沒有權限';
  end if;

  -- 資格（三種情況都要求在職且納入考核）
  if v_emp.status <> '在職' then
    raise exception '這位人員已離職，不能回報';
  end if;
  if not v_emp.include_in_assessment then
    raise exception '這位人員未納入考核，不能回報';
  end if;
  if p_kind in ('新人', '回考核期') then
    if p_kind = '新人' then
      if v_emp.probation_since is not null then
        raise exception '這位人員目前在考核期，只能以「回考核期」回報';
      end if;
      if v_emp.period_status is distinct from '考核期' then
        raise exception '這位人員不是新人（考核期者才能以「新人」回報，已上線者不行）';
      end if;
    else
      if v_emp.probation_since is null then
        raise exception '這位人員目前不在考核期，不能以「回考核期」回報';
      end if;
    end if;
  else
    if p_ticket_id is null then
      raise exception '複檢必須指定改善單';
    end if;
    select * into v_tk from public.improvement_tickets where id = p_ticket_id for update;
    if not found or v_tk.employee_id <> v_emp.id then
      raise exception '找不到這位人員的這張改善單';
    end if;
    if v_tk.status <> 'coached' then
      raise exception '這張改善單還不能回報複檢（必須是已輔導的改善單）';
    end if;
    if exists (select 1 from public.exam_requests r
               join public.assessments a on a.id = r.assessment_id
               where r.improvement_ticket_id = v_tk.id and r.kind = '複檢'
                 and r.status = '已完成' and a.status = 'submitted') then
      raise exception '這張改善單的複檢已經完成，不能再回報';
    end if;
  end if;

  -- 日期：1～3 個、不可有空值、不可重複、不可早於今天（台北時間；今天可）
  if p_dates is null or coalesce(cardinality(p_dates), 0) not between 1 and 3 then
    raise exception '希望考核日期請填 1 到 3 個';
  end if;
  if exists (select 1 from unnest(p_dates) as t(d) where t.d is null) then
    raise exception '希望考核日期不可空白';
  end if;
  if (select count(distinct t.d) from unnest(p_dates) as t(d)) <> cardinality(p_dates) then
    raise exception '希望考核日期不可重複';
  end if;
  if exists (select 1 from unnest(p_dates) as t(d) where t.d < v_today) then
    raise exception '希望考核日期不可早於今天';
  end if;

  -- 影片：新人必須勾選；其他情況不適用（一律存 null）
  if p_kind = '新人' and p_video is not true then
    raise exception '新人必須勾選「已看完線上回覆實戰全攻略影片」';
  end if;

  -- 備註
  if v_note is not null and char_length(v_note) > 500 then
    raise exception '備註最多 500 字';
  end if;

  -- 防重複
  if p_kind = '複檢' then
    if exists (select 1 from public.exam_requests r
               where r.improvement_ticket_id = v_tk.id and r.kind = '複檢'
                 and r.status = any(public.exam_req_status_open())) then
      raise exception '這張改善單已有複檢回報在處理中';
    end if;
  else
    if exists (select 1 from public.exam_requests r
               where r.employee_id = v_emp.id and r.kind = p_kind
                 and r.status = any(public.exam_req_status_open())) then
      raise exception '這位人員已有一筆「%」回報在處理中', p_kind;
    end if;
  end if;

  begin
    insert into public.exam_requests
      (kind, employee_id, employee_label, store_code, requested_by, requested_role,
       desired_dates, video_done, note, improvement_ticket_id)
    values
      (p_kind, v_emp.id, public.exam_req_label(v_emp.nickname, v_emp.full_name), v_emp.store_code,
       public.roster_my_email(),
       case when v_role = 'cs_admin' then '客服部' else '店長' end,
       p_dates,
       case when p_kind = '新人' then true else null end,
       v_note,
       case when p_kind = '複檢' then v_tk.id else null end)
    returning id into v_id;
  exception when unique_violation then
    raise exception '這位人員（或這張改善單）已有同一種情況的回報在處理中';
  end;

  perform public.exam_req_notify('new', v_id);
  return v_id;
end;
$$;

create or replace function public.exam_req_badge()
returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_n int;
begin
  if v_role = 'cs_admin' then
    select ((select count(*) from public.exam_requests where status = '待處理')
            + (select count(*) from public.reply_activations where status = '待開通'))::int
      into v_n;
  elsif v_role = 'store_manager' then
    select count(*)::int into v_n from public.exam_requests
     where store_code = public.roster_my_store() and mgr_seen = false;
  elsif v_role = 'hq_viewer' then
    v_n := 0;
  else
    raise exception '沒有權限';
  end if;
  return v_n;
end;
$$;

-- ---------- 13b. 抽查：拉回考核期與取消回考核期（spot_register／spot_cancel_probation） ----------
-- 老闆 2026-11-03 決定：period_status 成為「是否考核期」的單一事實。
--   * spot_register（以 url_patch.sql 版本為基礎）：觸發回考核期時，除了設 probation_since，也設 period_status = '考核期'（資格檢查見下方說明）
--   * spot_cancel_probation（以 spotcheck_schema.sql 版本為基礎）：取消（誤判復原）時，除了清除 probation_since，
--     也把 period_status 設回 已上線；已通過的回考核期不可取消等既有規則不變
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
  v_url text := btrim(coalesce(p_message, ''), E' \t\r\n' || chr(12288));
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
  if v_emp.probation_since is not null or v_emp.period_status = '考核期' then   -- 【第一期】period_status 也算考核期
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

  -- 訊息抽檢-LINE聊天室網址（排在其他驗證之後）
  if v_url !~* '^https?://[^[:space:]]+$' or length(v_url) > 500 then
    raise exception '請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）';
  end if;

  v_label := coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), ''));

  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels,
     total_score, dim_points, weakest_dims, verdict, reason, examiner_email)
  values
    (v_emp.id, v_label, v_emp.store_code, p_checked_on, v_url, p_levels,
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

        -- 【第一期】period_status 同步設為考核期（讓它成為「是否考核期」的單一事實）
        update public.employees set probation_since = v_today, period_status = '考核期' where id = v_emp.id;
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
    -- 【第一期】取消＝誤判復原：同時把 period_status 設回已上線
    update public.employees set probation_since = null, period_status = '已上線' where id = v_p.employee_id;
  end if;
end;
$$;

-- 抽查資格排除考核期的人（老闆 2026-11-03 決定）：考核期的人不能回覆顧客、不應被抽查。
--   * spot_candidates（以 spotcheck_schema.sql 版為基礎）：名單多一個條件 period_status <> '考核期'
--   * spot_register（同上 13b 那份）：資格檢查「該員工目前在考核期」改成 probation_since 有值 或 period_status = '考核期'
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
      and e.period_status <> '考核期'   -- 【第一期】考核期的人不能回覆顧客，不抽查
      and (e.hire_date is null or (v_today - e.hire_date) > 90)
    order by e.store_code, e.id;
end;
$$;

-- ---------- 14. 排除追加題：分析檢視與函式 ----------
-- 所有以 assessment_items 計算「面向平均得分率、弱項分析、改善單判定」的檢視與函式，都排除 is_extra = true。
-- 逐一盤點結果見 README_phase1.md 第四節。

-- 成績單列表檢視：item_count 只算核心題組（其餘欄位與 assess_schema.sql 完全相同）
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
    where i.assessment_id = a.id and not i.is_extra)::int as item_count
from public.assessments a
left join public.stores s on s.code = a.store_code;

revoke all on table public.assessment_summaries from public, anon, authenticated;
grant select on public.assessment_summaries to authenticated;

-- 弱項分析資料來源檢視：排除追加題（其餘與 backoffice_schema.sql 完全相同）
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
where a.status = 'submitted'
  and not i.is_extra;

revoke all on table public.analytics_dim_rates from public, anon, authenticated;
grant select on public.analytics_dim_rates to authenticated;

-- 考生弱項分析：只取核心題組的成績（其餘與 weak_suggest_schema.sql 完全相同）
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

-- ---------- 15. 函式權限：收回 public／anon，只授權 authenticated ----------
-- 對外函式的角色檢查在函式內部（非授權角色一律丟「沒有權限」）。
revoke execute on function public.assess_core_categories()                    from public, anon, authenticated;
revoke execute on function public.assess_draft_weak(uuid)                     from public, anon, authenticated;
revoke execute on function public.assess_add_extra(uuid, bigint[])            from public, anon, authenticated;
revoke execute on function public.activation_mark_done(uuid)                  from public, anon, authenticated;
revoke execute on function public.assess_start(text, text)                    from public, anon, authenticated;
revoke execute on function public.assess_submit(uuid)                         from public, anon, authenticated;
revoke execute on function public.assess_weak_profile(text)                   from public, anon, authenticated;
revoke execute on function public.exam_req_candidates(text)                   from public, anon, authenticated;
revoke execute on function public.exam_req_create(text, text, date[], boolean, text, uuid) from public, anon, authenticated;
revoke execute on function public.exam_req_badge()                            from public, anon, authenticated;
revoke execute on function public.spot_register(text, date, text, jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.spot_cancel_probation(uuid, text)           from public, anon, authenticated;
revoke execute on function public.spot_candidates()                           from public, anon, authenticated;
-- 內部：連 authenticated 都不開放直接呼叫
revoke execute on function public.phase1_migrate_period_status()              from public, anon, authenticated;

grant execute on function public.assess_core_categories()                     to authenticated;
grant execute on function public.assess_draft_weak(uuid)                      to authenticated;
grant execute on function public.assess_add_extra(uuid, bigint[])             to authenticated;
grant execute on function public.activation_mark_done(uuid)                   to authenticated;
grant execute on function public.assess_start(text, text)                     to authenticated;
grant execute on function public.assess_submit(uuid)                          to authenticated;
grant execute on function public.assess_weak_profile(text)                    to authenticated;
grant execute on function public.exam_req_candidates(text)                    to authenticated;
grant execute on function public.exam_req_create(text, text, date[], boolean, text, uuid) to authenticated;
grant execute on function public.exam_req_badge()                             to authenticated;
grant execute on function public.spot_register(text, date, text, jsonb, text, text) to authenticated;
grant execute on function public.spot_cancel_probation(uuid, text)            to authenticated;
grant execute on function public.spot_candidates()                            to authenticated;

commit;
