-- ============================================================
-- 業務考核系統：雙考官輪流考核（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（idempotent）：重跑不報錯、不刪任何資料。
--
-- ---------- 本檔結構（分段追加；每一段都是「單一交易 begin/commit」）----------
--   第一段（本包 DB-1）：資料模型＋抽籤＋抽題
--     A. assessments 新欄位／約束／新唯一索引；assessment_items.examiner_slot 與 one_core_per_category 索引改寫
--     B. 考官名單 assess_examiner_pool（只建表，名單由本機種子檔寫入，公開倉庫不放真實信箱）；考官表 assessment_examiners（RLS＋鎖定觸發器）
--     C. app_settings 配額 exam_dual_quota（預設 基礎3／進階2／綜合1）
--     D. assess_resolve_tenure（內部小函式）、assess_draw_dual_items（內部抽題）、
--        assess_start_dual（對外：抽籤＋抽題）、assess_my_drafts（對外：我是考官之一的草稿）
--     E. assess_draw、assess_pick：只多一道「雙考官草稿拒絕」守衛，其餘逐行不變
--   第二段（DB-2）：擁有者改寫（assess_owns_item、assess_save_item 等、assess_abandon、storage policy）
--   第三段（DB-3）：交卷與收尾（assess_submit_part、assess_unsubmit_part、assess_finalize、assess_submit 薄包裝）
--   （第二、三段由後續工作在本檔後面追加，各自用「-- ===== 第N段：… =====」分隔。）
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   roster → assess → bank → accounts → notes_visible → backoffice → spotcheck → url_patch → weak_suggest →
--   exam_request → phase1 → checkup → roster_line／coached_reminder → grade3 → fullreport → spotdims →
--   【noredticket_schema.sql】→ 【本檔 dual_examiner_schema.sql】→ dual_examiner_verify_fake.sql（可選）
--   （question_images_schema.sql 與本檔互不依賴，先後不拘。）
--   ⚠️ 本檔之後不要重跑 assess_schema／weak_suggest_schema（會把 assess_draw／assess_pick 蓋回沒有守衛的版本）；
--      萬一重跑過，再執行一次本檔即可。
--
-- ---------- 備份提醒（執行本檔之前先做；備份表必須啟用 row level security）----------
--   drop table if exists public.bak_dual_assessments;
--   create table public.bak_dual_assessments as select * from public.assessments;
--   alter table public.bak_dual_assessments enable row level security;
--   drop table if exists public.bak_dual_items;
--   create table public.bak_dual_items as select * from public.assessment_items;
--   alter table public.bak_dual_items enable row level security;
--   drop table if exists public.bak_dual_funcs;
--   create table public.bak_dual_funcs as
--     select p.oid::regprocedure::text as func, pg_get_functiondef(p.oid) as def
--     from pg_proc p
--     where p.pronamespace = 'public'::regnamespace
--       and p.proname in ('assess_draw', 'assess_pick', 'assess_start');
--   alter table public.bak_dual_funcs enable row level security;
--   （備份表不開任何 policy ＝ 網頁角色完全讀不到；確認無誤後可 drop）
--
-- ---------- 老闆定案規則（本段相關）----------
--   考官只有名單內 2 位（assess_examiner_pool：UNA、PENNY；信箱不放在本檔，用本機種子檔寫入）。開考（assess_start_dual）時由資料庫用 random() 抽籤
--   決定考官1（只考基礎 3 題）與考官2（考進階 2＋綜合 1），鎖定不可重抽；開考者也可能被抽到考官2。
--   同一位員工同時只會有一張雙考官草稿；重複開考回傳既有那張。該員工已有舊式單人草稿時拒絕開考。
--   健檢（kind='checkup'）與舊式單人流程完全不動：assess_start 不改；assess_draw／assess_pick 只對雙考官草稿多拒絕。
--
-- ---------- 已知事項（給主工程）----------
--   * 舊 assess_start 完全沒改：開考者若已有雙考官草稿又呼叫舊 assess_start，會因舊索引 (examiner_email, employee_id)
--     回傳那張雙考官草稿的 id（不會建新的）；對方考官呼叫舊 assess_start 則會建出單人草稿。前端雙考官模式應只走 assess_start_dual。
-- ============================================================

-- ===== 第一段：資料模型＋抽籤＋抽題 =====
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null
     or to_regclass('public.questions') is null
     or to_regclass('public.drawn') is null
     or to_regclass('public.category_last') is null
     or to_regclass('public.app_settings') is null
     or to_regclass('public.app_users') is null
     or to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_draw(uuid, text[])') is null
     or to_regprocedure('public.assess_pick(uuid, bigint[])') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 roster、assess、bank、weak_suggest、exam_request、phase1、checkup … noredticket 等前面的檔案';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'assessments' and column_name = 'kind') then
    raise exception '前提不滿足：請先執行 checkup_schema.sql（assessments.kind）';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'assessment_items' and column_name = 'is_extra') then
    raise exception '前提不滿足：請先執行 phase1_schema.sql（assessment_items.is_extra）';
  end if;
end
$$;

-- ---------- A1. assessments 新欄位與約束 ----------
alter table public.assessments add column if not exists is_dual boolean not null default false;
alter table public.assessments add column if not exists slot1_name text;
alter table public.assessments add column if not exists slot2_name text;

comment on column public.assessments.is_dual is
  '雙考官輪流考核（true）：開考時抽籤決定考官1／考官2，題組分工、各自交卷；examiner_email 語意＝開考者。舊單、單人、健檢一律 false。';
comment on column public.assessments.slot1_name is '雙考官：考官1（基礎）的暱稱快照（抽籤時存，不含信箱）。';
comment on column public.assessments.slot2_name is '雙考官：考官2（進階＋綜合）的暱稱快照（抽籤時存，不含信箱）。';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.assessments'::regclass and conname = 'assessments_dual_kind') then
    alter table public.assessments
      add constraint assessments_dual_kind check (not is_dual or kind = 'exam');
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.assessments'::regclass and conname = 'assessments_dual_names') then
    alter table public.assessments
      add constraint assessments_dual_names check (
        (is_dual and nullif(btrim(slot1_name), '') is not null and nullif(btrim(slot2_name), '') is not null)
        or (not is_dual and slot1_name is null and slot2_name is null));
  end if;
end
$$;

-- 同一位員工同時只能有一張雙考官草稿（資料庫最後一道防線；與舊的 (examiner_email, employee_id) 單人草稿索引互不影響）
create unique index if not exists assessments_one_dual_draft_per_employee
  on public.assessments(employee_id) where status = 'draft' and kind = 'exam' and is_dual;

-- ---------- A2. assessment_items.examiner_slot 與核心題組唯一索引改寫 ----------
alter table public.assessment_items add column if not exists examiner_slot smallint;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.assessment_items'::regclass and conname = 'assessment_items_examiner_slot_check') then
    alter table public.assessment_items
      add constraint assessment_items_examiner_slot_check check (examiner_slot is null or examiner_slot in (1, 2));
  end if;
end
$$;

comment on column public.assessment_items.examiner_slot is
  '雙考官：這個題組的負責考官（1＝考官1 基礎；2＝考官2 進階＋綜合）。null＝舊單、單人、健檢。';

-- 原本「同一場每個分類只有一個核心題組」的唯一索引：雙考官的基礎有 3 題，所以只對 examiner_slot 為空者生效。
-- 雙考官題組彼此不重複靠 assess_draw_dual_items 保證（同場挑題時排除已挑的題）。重跑時已是新版就略過。
do $$
declare
  v_def text;
begin
  select i.indexdef into v_def from pg_indexes i
   where i.schemaname = 'public' and i.indexname = 'assessment_items_one_core_per_category';
  if v_def is null or v_def not like '%examiner_slot%' then
    drop index if exists public.assessment_items_one_core_per_category;
    create unique index assessment_items_one_core_per_category
      on public.assessment_items(assessment_id, category)
      where not is_extra and examiner_slot is null;
  end if;
end
$$;

-- ---------- B1. 考官名單 assess_examiner_pool ----------
create table if not exists public.assess_examiner_pool (
  email text primary key check (email = lower(btrim(email)) and length(email) > 0),
  display_name text not null check (length(btrim(display_name)) > 0),
  active boolean not null default true
);

comment on table public.assess_examiner_pool is
  '雙考官的考官名單（只有名單內且啟用的人可開考）。開考時需恰好 2 位啟用中、且在 app_users 都是 cs_admin。只能在 SQL Editor 改。';

alter table public.assess_examiner_pool enable row level security;
revoke all on table public.assess_examiner_pool from public, anon, authenticated;
grant select on public.assess_examiner_pool to authenticated;

drop policy if exists assess_examiner_pool_select on public.assess_examiner_pool;
create policy assess_examiner_pool_select on public.assess_examiner_pool
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- 名單資料不在本檔：真實信箱不進公開倉庫。執行完本檔後，另外執行本機種子檔「雙考官名單_種子.sql」寫入 2 位考官。
-- 名單為空時開考會顯示「尚未設定考官名單」。

-- ---------- B2. 考官表 assessment_examiners ----------
create table if not exists public.assessment_examiners (
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  slot smallint not null check (slot in (1, 2)),
  email text not null check (email = lower(btrim(email)) and length(email) > 0),
  display_name text not null check (length(btrim(display_name)) > 0),
  scope text not null check (scope in ('基礎', '進階＋綜合')),
  submitted_at timestamptz,        -- 這位考官交卷的時間（不碰 assessments.submitted_at）
  last_saved_at timestamptz,       -- 這位考官最後一次暫存的時間
  primary key (assessment_id, slot),
  unique (assessment_id, email),
  constraint assessment_examiners_scope_slot check (
    (slot = 1 and scope = '基礎') or (slot = 2 and scope = '進階＋綜合'))
);

comment on table public.assessment_examiners is
  '雙考官考核的兩位考官（抽籤結果，開考時寫入並鎖定）。信箱只有客服部讀得到。';

alter table public.assessment_examiners enable row level security;
revoke all on table public.assessment_examiners from public, anon, authenticated;
grant select on public.assessment_examiners to authenticated;

drop policy if exists assessment_examiners_select on public.assessment_examiners;
create policy assessment_examiners_select on public.assessment_examiners
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- 鎖定：抽籤結果（考核、slot、信箱、暱稱、分工）不可改，只有 submitted_at／last_saved_at 可更新；
-- 刪除只允許「所屬考核已被刪除」時的連帶刪除（assess_abandon 刪考核會 cascade）。
create or replace function public.assess_examiners_lock()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    if new.assessment_id is distinct from old.assessment_id
       or new.slot is distinct from old.slot
       or new.email is distinct from old.email
       or new.display_name is distinct from old.display_name
       or new.scope is distinct from old.scope then
      raise exception '考官抽籤結果已鎖定，不能更改';
    end if;
    return new;
  end if;
  if exists (select 1 from public.assessments a where a.id = old.assessment_id) then
    raise exception '考官抽籤結果已鎖定，不能刪除';
  end if;
  return old;
end;
$$;

revoke execute on function public.assess_examiners_lock() from public, anon, authenticated;

drop trigger if exists assessment_examiners_lock_trg on public.assessment_examiners;
create trigger assessment_examiners_lock_trg
  before update or delete on public.assessment_examiners
  for each row execute function public.assess_examiners_lock();

-- ---------- C. 系統設定：雙考官題數配額 ----------
-- JSON：分類 → 題數。基礎題組歸考官1，進階、綜合歸考官2；seq 依 基礎→進階→綜合 排列。
insert into public.app_settings (key, value)
values ('exam_dual_quota', '{"基礎":3,"進階":2,"綜合":1}')
on conflict (key) do nothing;

-- ---------- D1. assess_resolve_tenure：新人／正式判斷（內部用，與 noredticket 版 assess_start 同邏輯） ----------
create or replace function public.assess_resolve_tenure(p_emp public.employees, p_tenure_override text)
returns table(tenure text, source text)
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if p_emp.period_status = '考核期' then
    tenure := '新人';
    source := '自動';
  elsif p_emp.hire_date is not null then
    tenure := case
                when ((now() at time zone 'Asia/Taipei')::date - p_emp.hire_date) <= 90 then '新人'
                else '正式'
              end;
    source := '自動';
  else
    if p_tenure_override is null or p_tenure_override not in ('新人', '正式') then
      raise exception '到職日空白，請手動指定「新人」或「正式」';
    end if;
    tenure := p_tenure_override;
    source := '手動指定';
  end if;
  return next;
end;
$$;

revoke execute on function public.assess_resolve_tenure(public.employees, text) from public, anon, authenticated;

-- ---------- D2. assess_draw_dual_items：雙考官抽題（內部用；只由 assess_start_dual 在取鎖後呼叫） ----------
-- 配額讀 app_settings.exam_dual_quota（預設 基礎3／進階2／綜合1）。每次挑題逐項照 assess_draw：
--   該考生沒考過 → 本輪沒抽過 → 不是該分類上一次抽出的 → random()；
--   該分類「（本場已挑以外的）題」都已在 drawn 內就先清掉該分類的 drawn 開新一輪；
--   寫入 drawn、category_last、assessment_items、assessment_item_secrets（含 was_drawn_before）。
-- 新增：硬條件排除「本場已挑的題」（含跨新輪），所以同場題目絕不重複。
-- 題庫不足（任一分類題數 < 配額）：整體回復並報中文訊息。呼叫者已持有 exam_draw_questions 鎖。
create or replace function public.assess_draw_dual_items(p_assessment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_a public.assessments%rowtype;
  v_raw text;
  v_quota jsonb;
  v_cats constant text[] := array['基礎', '進階', '綜合'];
  v_cat text;
  v_n int;
  v_i int;
  v_total int;
  v_short text := '';
  v_chosen bigint[] := '{}'::bigint[];
  v_has_undrawn boolean;
  v_last bigint;
  v_pick bigint;
  v_was boolean;
  v_seq int := 0;
  v_slot smallint;
  v_item uuid;
  v_code text;
  v_title text;
  v_steps jsonb;
begin
  select * into v_a from public.assessments where id = p_assessment_id;
  if not found then
    raise exception '找不到考核';
  end if;

  select s.value into v_raw from public.app_settings s where s.key = 'exam_dual_quota';
  begin
    v_quota := coalesce(nullif(btrim(v_raw), ''), '{"基礎":3,"進階":2,"綜合":1}')::jsonb;
  exception when others then
    raise exception '雙考官題數設定（exam_dual_quota）格式不正確';
  end;
  if jsonb_typeof(v_quota) <> 'object' then
    raise exception '雙考官題數設定（exam_dual_quota）格式不正確';
  end if;
  foreach v_cat in array v_cats loop
    if jsonb_typeof(v_quota -> v_cat) is distinct from 'number'
       or (v_quota ->> v_cat) !~ '^[1-9][0-9]?$' then
      raise exception '雙考官題數設定（exam_dual_quota）格式不正確：「%」必須是 1～99 的整數', v_cat;
    end if;
  end loop;

  -- 先整體檢查題庫夠不夠（不夠就整份回復，什麼都不寫）
  foreach v_cat in array v_cats loop
    v_n := (v_quota ->> v_cat)::int;
    select count(*)::int into v_total from public.questions q where q.category = v_cat;
    if v_total < v_n then
      v_short := v_short || case when v_short = '' then '' else '、' end
                 || format('「%s」需要 %s 題、目前只有 %s 題', v_cat, v_n, v_total);
    end if;
  end loop;
  if v_short <> '' then
    raise exception '題庫題數不足，無法開始雙考官考核：%。請先到題庫補題', v_short;
  end if;

  foreach v_cat in array v_cats loop
    v_n := (v_quota ->> v_cat)::int;
    v_slot := case when v_cat = '基礎' then 1 else 2 end;
    select count(*)::int into v_total from public.questions q where q.category = v_cat;

    for v_i in 1..v_n loop
      -- 該分類（扣掉本場已挑的）都已在 drawn 內 → 清掉該分類的 drawn 開新一輪
      select exists (
        select 1 from public.questions q
        where q.category = v_cat
          and not (q.id = any(v_chosen))
          and not exists (select 1 from public.drawn d where d.question_id = q.id)
      ) into v_has_undrawn;

      if not v_has_undrawn then
        delete from public.drawn d
        where d.question_id in (select q.id from public.questions q where q.category = v_cat);
      end if;

      select l.question_id into v_last from public.category_last l where l.category = v_cat;

      select q.id into v_pick
      from public.questions q
      where q.category = v_cat
        and not (q.id = any(v_chosen))
      order by
        case when exists (select 1
                          from public.assessment_items ai
                          join public.assessment_item_secrets sx on sx.item_id = ai.id
                          join public.assessments x on x.id = ai.assessment_id
                          where x.employee_id = v_a.employee_id
                            and x.status in ('submitted', 'voided')
                            and sx.question_id = q.id) then 1 else 0 end,
        case when exists (select 1 from public.drawn d where d.question_id = q.id) then 1 else 0 end,
        case when v_total > 1 and q.id = v_last then 1 else 0 end,
        random()
      limit 1;

      if v_pick is null then
        raise exception '題庫題數不足，無法開始雙考官考核：「%」挑不出第 % 題。請先到題庫補題', v_cat, v_i;
      end if;
      v_chosen := v_chosen || v_pick;

      v_was := exists (select 1 from public.drawn d where d.question_id = v_pick);

      insert into public.drawn (question_id) values (v_pick)
      on conflict (question_id) do update set drawn_at = now();

      insert into public.category_last (category, question_id) values (v_cat, v_pick)
      on conflict (category) do update set question_id = excluded.question_id;

      select q.code, q.title, q.steps into v_code, v_title, v_steps
      from public.questions q where q.id = v_pick;

      v_seq := v_seq + 1;

      insert into public.assessment_items (assessment_id, seq, category, code, examiner_slot)
      values (v_a.id, v_seq, v_cat, v_code, v_slot)
      returning id into v_item;

      insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps)
      values (v_item, v_pick, v_was, v_title, v_steps);
    end loop;
  end loop;
end;
$$;

revoke execute on function public.assess_draw_dual_items(uuid) from public, anon, authenticated;

-- ---------- D3. assess_start_dual：開考＋抽籤＋抽題（單一交易） ----------
-- 呼叫者必須在考官名單（assess_examiner_pool 啟用中）。名單需恰好 2 位啟用中、且在 app_users 都是 cs_admin。
-- 先取 exam_draw_questions 鎖（與 assess_draw／assess_pick 共用）：該員工已有雙考官草稿 → 回傳既有那張（不重抽籤、不重抽題）；
-- 已有舊式單人草稿 → 拒絕；否則 random() 抽籤（前端沒有任何參數可影響；開考者也可能被抽到考官2）、抽 6 題、寫入。
-- 回傳 {assessment_id, existing, my_slot, slots:[{slot,display_name,scope,is_me}], items:[{item_id,seq,examiner_slot,category,code,title,steps}]}
create or replace function public.assess_start_dual(p_employee_id text, p_tenure_override text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_emp public.employees%rowtype;
  v_pool text[];
  v_names text[];
  v_first int;
  v_tenure text;
  v_source text;
  v_a public.assessments%rowtype;
  v_existing boolean := false;
  v_id uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  if not exists (select 1 from public.assess_examiner_pool p where p.active) then
    raise exception '尚未設定考官名單：請管理者先在資料庫設定 2 位考官（執行本機的雙考官名單種子檔）後再開考';
  end if;
  if not exists (select 1 from public.assess_examiner_pool p where p.email = v_me and p.active) then
    raise exception '只有考官名單內的客服人員可以開始雙考官考核';
  end if;

  -- 同時間只允許一個人抽籤／抽題（與 assess_draw、assess_pick、題庫管理共用同一把鎖）
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception '找不到員工：%', p_employee_id;
  end if;
  if not v_emp.include_in_assessment or v_emp.status <> '在職' then
    raise exception '該員工不在考核名單（需納入考核且在職）';
  end if;

  -- 已有雙考官草稿：回傳既有那張
  select * into v_a from public.assessments a
   where a.employee_id = v_emp.id and a.status = 'draft' and a.kind = 'exam' and a.is_dual;
  if found then
    v_existing := true;
  else
    if exists (select 1 from public.assessments a
                where a.employee_id = v_emp.id and a.status = 'draft' and a.kind = 'exam' and not a.is_dual) then
      raise exception '該員工已有一張舊式單人考核草稿，請先完成或放棄它，才能開始雙考官考核';
    end if;

    -- 考官名單：恰好 2 位啟用中，且都是客服部帳號
    select array_agg(p.email order by p.email), array_agg(p.display_name order by p.email)
      into v_pool, v_names
    from public.assess_examiner_pool p
    where p.active;
    if coalesce(cardinality(v_pool), 0) <> 2
       or (select count(*) from public.app_users u
            where u.email = any(v_pool) and u.role = 'cs_admin') <> 2 then
      raise exception '考官名單設定不正確：需要恰好 2 位啟用中的考官，且都必須是客服部帳號';
    end if;

    select * into v_tenure, v_source from public.assess_resolve_tenure(v_emp, p_tenure_override);

    -- 抽籤：隨機決定誰是考官1（基礎）、誰是考官2（進階＋綜合）；結果寫入後鎖定
    v_first := case when random() < 0.5 then 1 else 2 end;

    insert into public.assessments
      (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot,
       is_dual, slot1_name, slot2_name)
    values
      (v_emp.id,
       coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), '')),
       v_emp.store_code, v_me, 'draft', v_tenure, v_source, v_emp.hire_date,
       true, v_names[v_first], v_names[3 - v_first])
    returning * into v_a;

    insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope)
    values (v_a.id, 1, v_pool[v_first], v_names[v_first], '基礎'),
           (v_a.id, 2, v_pool[3 - v_first], v_names[3 - v_first], '進階＋綜合');

    perform public.assess_draw_dual_items(v_a.id);
  end if;

  return jsonb_build_object(
    'assessment_id', v_a.id,
    'existing', v_existing,
    'my_slot', (select e.slot from public.assessment_examiners e where e.assessment_id = v_a.id and e.email = v_me),
    'slots', (select coalesce(jsonb_agg(jsonb_build_object(
                 'slot', e.slot, 'display_name', e.display_name, 'scope', e.scope, 'is_me', e.email = v_me)
                 order by e.slot), '[]'::jsonb)
              from public.assessment_examiners e where e.assessment_id = v_a.id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                 'item_id', i.id, 'seq', i.seq, 'examiner_slot', i.examiner_slot, 'category', i.category,
                 'code', i.code, 'title', sx.title, 'steps', sx.steps)
                 order by i.seq), '[]'::jsonb)
              from public.assessment_items i
              left join public.assessment_item_secrets sx on sx.item_id = i.id
              where i.assessment_id = v_a.id)
  );
end;
$$;

-- ---------- D4. assess_my_drafts：我是考官之一的雙考官草稿 ----------
-- 只回傳「我在 assessment_examiners 裡」的草稿（所以不是考官的客服部看到空陣列）；
-- 不含任何信箱，對方只給暱稱；進度＝已評完七面向的題組數／該位考官負責的題組數。
create or replace function public.assess_my_drafts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'assessment_id', a.id,
             'employee_id', a.employee_id,
             'employee_label', a.employee_label,
             'store_code', a.store_code,
             'created_at', a.created_at,
             'opened_by_me', a.examiner_email = v_me,
             'slot1_name', a.slot1_name,
             'slot2_name', a.slot2_name,
             'my_slot', me.slot,
             'my_scope', me.scope,
             'my_submitted_at', me.submitted_at,
             'my_last_saved_at', me.last_saved_at,
             'my_progress', jsonb_build_object(
                'done', (select count(*) from public.assessment_items i
                          where i.assessment_id = a.id and i.examiner_slot = me.slot
                            and (select count(*) from jsonb_object_keys(i.levels)) = 7),
                'total', (select count(*) from public.assessment_items i
                           where i.assessment_id = a.id and i.examiner_slot = me.slot)),
             'other_slot', ot.slot,
             'other_name', ot.display_name,
             'other_scope', ot.scope,
             'other_submitted', ot.submitted_at is not null,
             'other_submitted_at', ot.submitted_at,
             'other_last_saved_at', ot.last_saved_at,
             'other_progress', jsonb_build_object(
                'done', (select count(*) from public.assessment_items i
                          where i.assessment_id = a.id and i.examiner_slot = ot.slot
                            and (select count(*) from jsonb_object_keys(i.levels)) = 7),
                'total', (select count(*) from public.assessment_items i
                           where i.assessment_id = a.id and i.examiner_slot = ot.slot))
           ) order by a.created_at desc, a.id)
    from public.assessments a
    join public.assessment_examiners me on me.assessment_id = a.id and me.email = v_me
    join public.assessment_examiners ot on ot.assessment_id = a.id and ot.slot <> me.slot
    where a.status = 'draft' and a.is_dual
  ), '[]'::jsonb);
end;
$$;

-- ---------- E. assess_draw、assess_pick：雙考官草稿一律拒絕（只多一道守衛，其餘逐行不變） ----------
-- 以線上最新生效版本為底：assess_draw 來自 assess_schema.sql，assess_pick 來自 weak_suggest_schema.sql。
-- 簽名、回傳型別、security definer、search_path、權限都不變；差異只有標【雙考官】的那一段。
-- assess_draw（底：assess_schema.sql）
create or replace function public.assess_draw(p_assessment_id uuid, p_cats text[])
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
  v_cat text;
  v_total int;
  v_has_undrawn boolean;
  v_last bigint;
  v_pick bigint;
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

  -- 【雙考官】雙考官考核的題組在開考時已自動抽好（assess_start_dual），不能另外抽題
  if v_a.is_dual then
    raise exception '雙考官考核的題組在開考時已自動抽好，不能另外抽題';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以抽題';
  end if;
  if v_a.examiner_email <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  if p_cats is null or coalesce(array_length(p_cats, 1), 0) = 0 then
    raise exception '請至少選一個分類';
  end if;
  if exists (select 1 from unnest(p_cats) as t(c) where t.c is null or btrim(t.c) = '') then
    raise exception '分類不可空白';
  end if;
  if (select count(distinct t.c) from unnest(p_cats) as t(c)) <> array_length(p_cats, 1) then
    raise exception '一場考核每個分類只能抽一個題組，分類不可重複';
  end if;
  if exists (select 1 from public.assessment_items i
             where i.assessment_id = v_a.id and i.category = any(p_cats)) then
    raise exception '這場考核已抽過其中的分類，每個分類最多一個題組';
  end if;

  -- 同時間只允許一個人抽題（與舊抽選器共用同一把鎖）
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  select coalesce(max(i.seq), 0) into v_seq
  from public.assessment_items i where i.assessment_id = v_a.id;

  for v_cat in select t.c from unnest(p_cats) with ordinality as t(c, n) order by t.n loop
    select count(*)::int into v_total from public.questions q where q.category = v_cat;
    if v_total = 0 then
      raise exception '分類不存在：%', v_cat;
    end if;

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

    select l.question_id into v_last from public.category_last l where l.category = v_cat;

    select q.id,
           exists (select 1
                   from public.assessment_items ai
                   join public.assessment_item_secrets sx on sx.item_id = ai.id
                   join public.assessments x on x.id = ai.assessment_id
                   where x.employee_id = v_a.employee_id
                     and x.status in ('submitted', 'voided')
                     and sx.question_id = q.id)
      into v_pick, v_taken
    from public.questions q
    where q.category = v_cat
    order by
      case when exists (select 1
                        from public.assessment_items ai
                        join public.assessment_item_secrets sx on sx.item_id = ai.id
                        join public.assessments x on x.id = ai.assessment_id
                        where x.employee_id = v_a.employee_id
                          and x.status in ('submitted', 'voided')
                          and sx.question_id = q.id) then 1 else 0 end,
      case when exists (select 1 from public.drawn d where d.question_id = q.id) then 1 else 0 end,
      case when v_total > 1 and q.id = v_last then 1 else 0 end,
      random()
    limit 1;

    v_was := exists (select 1 from public.drawn d where d.question_id = v_pick);

    insert into public.drawn (question_id) values (v_pick)
    on conflict (question_id) do update set drawn_at = now();

    insert into public.category_last (category, question_id) values (v_cat, v_pick)
    on conflict (category) do update set question_id = excluded.question_id;

    select q.code, q.title, q.steps into v_code, v_title, v_steps
    from public.questions q where q.id = v_pick;

    v_seq := v_seq + 1;

    insert into public.assessment_items (assessment_id, seq, category, code)
    values (v_a.id, v_seq, v_cat, v_code)
    returning id into v_item;

    insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps)
    values (v_item, v_pick, v_was, v_title, v_steps);

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

-- assess_pick（底：weak_suggest_schema.sql）
create or replace function public.assess_pick(p_assessment_id uuid, p_question_ids bigint[])
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
  v_qid bigint;
  v_cat text;
  v_missing bigint;
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

  -- 【雙考官】雙考官考核的題組在開考時已自動抽好（assess_start_dual），不能另外選題
  if v_a.is_dual then
    raise exception '雙考官考核的題組在開考時已自動抽好，不能另外選題';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以選題';
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

  -- 同時間只允許一個人抽題（與 assess_draw、題庫管理共用同一把鎖）
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

  if (select count(distinct x.category)
        from public.questions x
       where x.id = any(p_question_ids)) <> cardinality(p_question_ids) then
    raise exception '一場考核每個分類只能抽一個題組，分類不可重複';
  end if;
  if exists (select 1
             from public.assessment_items i
             join public.questions x on x.category = i.category
             where i.assessment_id = v_a.id
               and x.id = any(p_question_ids)) then
    raise exception '這場考核已抽過其中的分類，每個分類最多一個題組';
  end if;

  select coalesce(max(i.seq), 0) into v_seq
  from public.assessment_items i where i.assessment_id = v_a.id;

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

    -- 該考生以前考過這題（與 assess_draw 相同的判斷：已送出與已作廢，草稿不算）
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

    insert into public.assessment_items (assessment_id, seq, category, code)
    values (v_a.id, v_seq, v_cat, v_code)
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

-- ---------- F. 函式權限：收回 public／anon，只授權 authenticated ----------
revoke execute on function public.assess_start_dual(text, text) from public, anon;
grant  execute on function public.assess_start_dual(text, text) to authenticated;
revoke execute on function public.assess_my_drafts()            from public, anon;
grant  execute on function public.assess_my_drafts()            to authenticated;
-- 既有函式權限沿用原本設定（create or replace 不會改權限），這裡重申一次
revoke execute on function public.assess_draw(uuid, text[])     from public, anon;
grant  execute on function public.assess_draw(uuid, text[])     to authenticated;
revoke execute on function public.assess_pick(uuid, bigint[])   from public, anon;
grant  execute on function public.assess_pick(uuid, bigint[])   to authenticated;

commit;

-- ============================================================
-- 驗證查詢（執行完第一段後貼上跑；每一列的「結果」都應該是 通過）
-- ============================================================
select '考官名單表已建立（名單內容由本機種子檔寫入，種子檔另附檢查）' as 項目,
       case when to_regclass('public.assess_examiner_pool') is not null then '通過' else '失敗' end as 結果
union all
select '新欄位與新表都在',
       case when exists (select 1 from information_schema.columns where table_schema = 'public'
                          and table_name = 'assessments' and column_name = 'is_dual')
             and exists (select 1 from information_schema.columns where table_schema = 'public'
                          and table_name = 'assessment_items' and column_name = 'examiner_slot')
             and to_regclass('public.assessment_examiners') is not null then '通過' else '失敗' end
union all
select 'one_core_per_category 索引已加 examiner_slot 條件',
       case when exists (select 1 from pg_indexes where schemaname = 'public'
                          and indexname = 'assessment_items_one_core_per_category'
                          and indexdef like '%examiner_slot%') then '通過' else '失敗' end
union all
select 'assess_draw、assess_pick 已有雙考官守衛',
       case when (select count(*) from pg_proc p
                   where p.oid in ('public.assess_draw(uuid, text[])'::regprocedure,
                                   'public.assess_pick(uuid, bigint[])'::regprocedure)
                     and p.prosrc like '%is_dual%') = 2 then '通過' else '失敗' end
union all
select '新函式權限：登入者可執行、anon 不可',
       case when has_function_privilege('authenticated', 'public.assess_start_dual(text, text)', 'execute')
             and not has_function_privilege('anon', 'public.assess_start_dual(text, text)', 'execute')
             and has_function_privilege('authenticated', 'public.assess_my_drafts()', 'execute')
             and not has_function_privilege('anon', 'public.assess_my_drafts()', 'execute')
             and not has_function_privilege('authenticated', 'public.assess_draw_dual_items(uuid)', 'execute')
        then '通過' else '失敗' end;


-- ===== 第二段：擁有者改寫＋放棄規則＋追加題拒絕（DB-2）=====
-- 本段內容（單一交易 begin/commit；可重複執行，重跑不報錯、不刪任何資料）：
--   A. assess_owns_item（內部）：判斷「這個題組是不是我負責、而且我還能改」
--        非雙考官＝建立者本人（examiner_email = me）；雙考官＝我是該題組 examiner_slot 對應的考官，且該 slot 尚未交卷。
--      B. assess_i_own_item（只給 storage policy 用的薄包裝，只能問「我自己」）
--   C. 改寫 assess_save_item（4 參數）、assess_save_dim_notes、assess_add_image、assess_remove_image：
--        擁有者檢查改呼叫 assess_owns_item；雙考官時對考核列只取共享鎖（for share）並更新自己的 last_saved_at。
--        他人題組不可寫、自己已交卷不可寫。非雙考官路徑逐行不變。
--   D. assess_abandon：雙考官草稿任何客服部可放棄整張；只要有任何一位考官已交卷就拒絕（請先撤回送出，撤回函式在第三段）。
--   E. assess_draft_weak、assess_add_extra：雙考官草稿一律拒絕（規則5：不做弱項追加題）
--   F. assess_start（舊單人開考）：該員工已有進行中的雙考官草稿 → 拒絕
--   G. storage policy assess_notes_insert、assess_notes_delete：改用題組擁有者判斷（條數、名稱不變；delete 保留清孤兒檔那一支）
--
-- 鎖順序統一：assessments → assessment_examiners → assessment_items。
-- 新增的內部函式（assess_owns_item）不授權 authenticated；assess_i_own_item 是唯一授權的新函式，
--   原因：RLS policy 的函式權限是用「查詢者本人」身分檢查，policy 呼叫的函式必須讓 authenticated 可執行；
--   它不吃信箱參數、只回答「我自己」是不是題組擁有者，不能拿來探查別人。
--
-- ---------- 備份提醒（執行第二段之前先做；備份表必須啟用 row level security）----------
--   drop table if exists public.bak_dual2_funcs;
--   create table public.bak_dual2_funcs as
--     select p.oid::regprocedure::text as func, pg_get_functiondef(p.oid) as def
--     from pg_proc p
--     where p.pronamespace = 'public'::regnamespace
--       and p.proname in ('assess_save_item', 'assess_save_dim_notes', 'assess_add_image', 'assess_remove_image',
--                         'assess_abandon', 'assess_draft_weak', 'assess_add_extra', 'assess_start');
--   alter table public.bak_dual2_funcs enable row level security;
--   drop table if exists public.bak_dual2_policies;
--   create table public.bak_dual2_policies as
--     select policyname, cmd, roles::text as roles, qual, with_check from pg_policies
--     where schemaname = 'storage' and tablename = 'objects' and policyname in ('assess_notes_insert', 'assess_notes_delete');
--   alter table public.bak_dual2_policies enable row level security;
--
-- ---------- 已知事項 ----------
--   * assess_start 的新守衛沒有取 exam_draw_questions 鎖（為了保持舊函式「只多一道守衛」）；兩個人在同一瞬間，
--     一個走舊 assess_start、一個走 assess_start_dual 開同一位員工，理論上可能各建一張。前端雙考官模式只走 assess_start_dual，實務上不會發生。
--   * 本檔之後不要重跑 assess_schema／url_patch／grade3_schema／phase1_schema／noredticket_schema（會把本段改寫的函式與 policy 蓋回舊版）；
--     萬一重跑過，再執行一次本檔即可。
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'assessments' and column_name = 'is_dual')
     or to_regclass('public.assessment_examiners') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_items' and column_name = 'examiner_slot') then
    raise exception '前提不滿足：請先執行本檔第一段（資料模型＋抽籤＋抽題）';
  end if;
  if to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is null
     or to_regprocedure('public.assess_save_dim_notes(uuid, jsonb)') is null
     or to_regprocedure('public.assess_add_image(uuid, text, text, int)') is null
     or to_regprocedure('public.assess_remove_image(uuid)') is null
     or to_regprocedure('public.assess_abandon(uuid)') is null
     or to_regprocedure('public.assess_draft_weak(uuid)') is null
     or to_regprocedure('public.assess_add_extra(uuid, bigint[])') is null
     or to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_safe_uuid(text)') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 assess、url_patch、phase1、grade3、noredticket 等前面的檔案';
  end if;
end
$$;

-- ---------- A. assess_owns_item：題組擁有者判斷（內部用；不授權 authenticated） ----------
-- 非雙考官（含舊單、單人、健檢）＝建立者本人（examiner_email = p_me）。
-- 雙考官＝p_me 是該題組 examiner_slot 對應的那位考官，而且那位考官還沒交卷（assessment_examiners.submitted_at 為空）。
-- 只回答「擁有者」，不檢查草稿狀態（呼叫者自己檢查 status）。找不到題組、p_me 空白一律 false。
create or replace function public.assess_owns_item(p_item_id uuid, p_me text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select case
             when not a.is_dual then a.examiner_email = p_me
             else exists (select 1 from public.assessment_examiners e
                           where e.assessment_id = a.id
                             and e.slot = i.examiner_slot
                             and e.email = p_me
                             and e.submitted_at is null)
           end
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
  ), false);
$$;

revoke execute on function public.assess_owns_item(uuid, text) from public, anon, authenticated;

-- ---------- B. assess_i_own_item：給 storage policy 用的薄包裝（只問「我自己」） ----------
create or replace function public.assess_i_own_item(p_item_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.assess_owns_item(p_item_id, public.roster_my_email());
$$;

revoke execute on function public.assess_i_own_item(uuid) from public, anon;
grant  execute on function public.assess_i_own_item(uuid) to authenticated;

-- ---------- C. assess_save_item／assess_save_dim_notes／assess_add_image／assess_remove_image：擁有者檢查改用 assess_owns_item ----------
-- 以線上最新生效版本為底（assess_save_item：url_patch.sql；assess_save_dim_notes：grade3_schema.sql；assess_add_image、assess_remove_image：assess_schema.sql）。
-- 簽名、回傳型別、security definer、search_path、權限都不變；非雙考官路徑逐行照舊，差異只有標【雙考官】／【擁有者檢查】的那幾段。
create or replace function public.assess_save_item(p_item_id uuid, p_levels jsonb, p_note text, p_note_url text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
  v_url text := nullif(btrim(coalesce(p_note_url, ''), E' \t\r\n' || chr(12288)), '');
  v_dual boolean;
  v_aid uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 【雙考官】先看這個題組是不是雙考官考核的（不加鎖）。雙考官對考核列只取共享鎖：兩位考官同時各存各的題組不會互卡，
  -- 交卷（for update）會等存檔做完；非雙考官走原本的 for update，逐行照舊。
  select a.is_dual into v_dual
  from public.assessment_items i
  join public.assessments a on a.id = i.assessment_id
  where i.id = p_item_id;

  if v_dual then
    select a.id, a.status, a.examiner_email into v_aid, v_status, v_owner
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
    for share of a;
  else
    select a.status, a.examiner_email into v_status, v_owner
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
    for update of a;
  end if;
  if not found then
    raise exception '找不到題組';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以暫存評分';
  end if;
  -- 【擁有者檢查】非雙考官＝建立者本人；雙考官＝自己負責的題組且自己還沒交卷
  if not public.assess_owns_item(p_item_id, v_me) then
    if v_dual then
      raise exception '這個題組不是你負責的，或你已送出自己的題組（要修改請先撤回送出）';
    end if;
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  perform public.assess_check_levels(p_levels, false);

  -- 【新增】備註網址（非必填；空白視為 null）；排在所有既有檢查之後
  if v_url is not null and (v_url !~* '^https?://[^[:space:]]+$' or length(v_url) > 500) then
    raise exception '備註網址格式不正確（需 http 或 https 開頭，不可含空白，最長 500 字）';
  end if;

  -- 【雙考官】更新自己的「最後暫存時間」（鎖順序：考核 → 考官表 → 題組）
  if v_dual then
    update public.assessment_examiners e
       set last_saved_at = now()
     where e.assessment_id = v_aid and e.email = v_me;
  end if;

  update public.assessment_items
     set levels = p_levels,
         note = nullif(btrim(p_note), ''),
         note_url = v_url
   where id = p_item_id;
end;
$$;

create or replace function public.assess_save_dim_notes(p_item_id uuid, p_dim_notes jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
  v_levels jsonb;
  v_dims text[] := public.assess_dim_order();
  v_out jsonb := '{}'::jsonb;
  k text;
  v jsonb;
  v_txt text;
  v_n int;
  v_dual boolean;
  v_aid uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 【雙考官】鎖法同 assess_save_item：雙考官取共享鎖，非雙考官照舊 for update
  select a.is_dual into v_dual
  from public.assessment_items i
  join public.assessments a on a.id = i.assessment_id
  where i.id = p_item_id;

  if v_dual then
    select a.id, a.status, a.examiner_email, i.levels into v_aid, v_status, v_owner, v_levels
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
    for share of a;
  else
    select a.status, a.examiner_email, i.levels into v_status, v_owner, v_levels
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
    for update of a;
  end if;
  if not found then
    raise exception '找不到題組';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以暫存評分';
  end if;
  -- 【擁有者檢查】非雙考官＝建立者本人；雙考官＝自己負責的題組且自己還沒交卷
  if not public.assess_owns_item(p_item_id, v_me) then
    if v_dual then
      raise exception '這個題組不是你負責的，或你已送出自己的題組（要修改請先撤回送出）';
    end if;
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  if p_dim_notes is null or jsonb_typeof(p_dim_notes) <> 'object' then
    raise exception '面向備註格式不正確，必須是物件';
  end if;

  for k, v in select key, value from jsonb_each(p_dim_notes) loop
    if not (k = any(v_dims)) then
      raise exception '未知的面向：%', k;
    end if;
    if jsonb_typeof(v) <> 'string' then
      raise exception '面向「%」的備註必須是文字', k;
    end if;
    v_txt := btrim(v #>> '{}', E' \t\r\n' || chr(12288));
    if length(v_txt) > 2000 then
      raise exception '面向「%」的備註太長（最多 2000 字）', k;
    end if;
    if v_txt <> '' and (v_levels ->> k) in ('尚可', '待加強') then
      v_out := v_out || jsonb_build_object(k, v_txt);
    end if;
  end loop;

  -- 【雙考官】更新自己的「最後暫存時間」（鎖順序：考核 → 考官表 → 題組）
  if v_dual then
    update public.assessment_examiners e
       set last_saved_at = now()
     where e.assessment_id = v_aid and e.email = v_me;
  end if;

  update public.assessment_item_secrets set dim_notes = v_out where item_id = p_item_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception '找不到題組資料';
  end if;
end;
$$;

create or replace function public.assess_add_image(p_item_id uuid, p_path text, p_mime text, p_size int)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_aid uuid;
  v_status text;
  v_owner text;
  v_prefix text;
  v_id uuid;
  v_dual boolean;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 【雙考官】鎖法同 assess_save_item：雙考官取共享鎖，非雙考官照舊 for update
  select a.is_dual into v_dual
  from public.assessment_items i
  join public.assessments a on a.id = i.assessment_id
  where i.id = p_item_id;

  if v_dual then
    select a.id, a.status, a.examiner_email into v_aid, v_status, v_owner
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
    for share of a;
  else
    select a.id, a.status, a.examiner_email into v_aid, v_status, v_owner
    from public.assessment_items i
    join public.assessments a on a.id = i.assessment_id
    where i.id = p_item_id
    for update of a;
  end if;
  if not found then
    raise exception '找不到題組';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以增減圖片';
  end if;
  -- 【擁有者檢查】非雙考官＝建立者本人；雙考官＝自己負責的題組且自己還沒交卷
  if not public.assess_owns_item(p_item_id, v_me) then
    if v_dual then
      raise exception '這個題組不是你負責的，或你已送出自己的題組（要修改請先撤回送出）';
    end if;
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  if p_mime is null or p_mime not in ('image/jpeg', 'image/png', 'image/webp') then
    raise exception '圖片格式只能是 jpeg、png、webp';
  end if;
  if p_size is null or p_size < 1 or p_size > 2097152 then
    raise exception '圖片大小必須在 2MB 以內';
  end if;

  v_prefix := v_aid::text || '/' || p_item_id::text || '/';
  if p_path is null or length(p_path) <= length(v_prefix) or left(p_path, length(v_prefix)) <> v_prefix then
    raise exception '圖片路徑必須以「考核id/題組id/」開頭';
  end if;

  if (select count(*) from public.assessment_item_images g where g.item_id = p_item_id) >= 5 then
    raise exception '每個題組最多 5 張圖片';
  end if;

  -- 【雙考官】更新自己的「最後暫存時間」（鎖順序：考核 → 考官表 → 題組）
  if v_dual then
    update public.assessment_examiners e
       set last_saved_at = now()
     where e.assessment_id = v_aid and e.email = v_me;
  end if;

  insert into public.assessment_item_images (item_id, storage_path, mime, size_bytes)
  values (p_item_id, p_path, p_mime, p_size)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.assess_remove_image(p_image_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
  v_path text;
  v_dual boolean;
  v_item uuid;
  v_aid uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 【雙考官】先看這張圖屬於哪個題組、是不是雙考官考核的（不加鎖）；鎖法同 assess_save_item
  select a.is_dual, i.id into v_dual, v_item
  from public.assessment_item_images g
  join public.assessment_items i on i.id = g.item_id
  join public.assessments a on a.id = i.assessment_id
  where g.id = p_image_id;

  if v_dual then
    select g.storage_path, a.id, a.status, a.examiner_email into v_path, v_aid, v_status, v_owner
    from public.assessment_item_images g
    join public.assessment_items i on i.id = g.item_id
    join public.assessments a on a.id = i.assessment_id
    where g.id = p_image_id
    for share of a;
  else
    select g.storage_path, a.status, a.examiner_email into v_path, v_status, v_owner
    from public.assessment_item_images g
    join public.assessment_items i on i.id = g.item_id
    join public.assessments a on a.id = i.assessment_id
    where g.id = p_image_id
    for update of a;
  end if;
  if not found then
    raise exception '找不到圖片';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以增減圖片';
  end if;
  -- 【擁有者檢查】非雙考官＝建立者本人；雙考官＝自己負責的題組且自己還沒交卷
  if not public.assess_owns_item(v_item, v_me) then
    if v_dual then
      raise exception '這個題組不是你負責的，或你已送出自己的題組（要修改請先撤回送出）';
    end if;
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  -- 【雙考官】更新自己的「最後暫存時間」（鎖順序：考核 → 考官表 → 題組）
  if v_dual then
    update public.assessment_examiners e
       set last_saved_at = now()
     where e.assessment_id = v_aid and e.email = v_me;
  end if;

  delete from public.assessment_item_images where id = p_image_id;

  return v_path;
end;
$$;

-- ---------- D. assess_abandon：雙考官放棄規則（單人草稿逐行不變） ----------
-- 底：assess_schema.sql。簽名與回傳（text[]）不變，所以用 create or replace，不需 drop。
create or replace function public.assess_abandon(p_assessment_id uuid)
returns text[]
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_a public.assessments%rowtype;
  v_paths text[];
begin
  perform public.assess_assert_cs();

  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以放棄';
  end if;

  -- 【雙考官】任何客服部都可放棄整張（上面 assess_assert_cs 已限客服部）；但只要有任何一位考官已交卷就拒絕，
  -- 要先「撤回送出」。鎖順序：考核（上面 for update）→ 考官表 → 題組（下面 cascade 刪除）。
  if v_a.is_dual then
    perform 1 from public.assessment_examiners e where e.assessment_id = v_a.id for update;
    if exists (select 1 from public.assessment_examiners e
                where e.assessment_id = v_a.id and e.submitted_at is not null) then
      raise exception '已有考官送出自己的題組，不能直接放棄這張考核；請先撤回送出';
    end if;
  end if;

  -- 動到 drawn 前先取同一把鎖，避免和別人抽題打架
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  -- 先收集圖片路徑（刪除考核時圖片列會連帶刪除）
  select coalesce(array_agg(g.storage_path order by g.created_at, g.storage_path), '{}'::text[])
    into v_paths
  from public.assessment_item_images g
  join public.assessment_items i on i.id = g.item_id
  where i.assessment_id = v_a.id;

  delete from public.drawn d
  where d.question_id in (
    select sx.question_id
    from public.assessment_items i
    join public.assessment_item_secrets sx on sx.item_id = i.id
    where i.assessment_id = v_a.id and not sx.was_drawn_before
  );

  delete from public.assessments where id = v_a.id;  -- items、secrets、images 由 cascade 一併刪除

  return v_paths;
end;
$$;

-- ---------- E. assess_draft_weak、assess_add_extra：雙考官草稿一律拒絕（規則5；單人逐行不變） ----------
-- 底：phase1_schema.sql。
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
  -- 【雙考官】不支援弱項追加題
  if v_a.is_dual then
    raise exception '雙考官考核不支援弱項追加題';
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
  -- 【雙考官】不支援弱項追加題
  if v_a.is_dual then
    raise exception '雙考官考核不支援弱項追加題';
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

-- ---------- F. assess_start（舊單人開考）：只加一道守衛 ----------
-- 底：noredticket_schema.sql（線上最新生效版本）。差異只有標【雙考官】的那一段。
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

  -- 【雙考官】該員工已有進行中的雙考官草稿：不能再開單人考核
  if exists (select 1 from public.assessments a
              where a.employee_id = v_emp.id and a.is_dual and a.status = 'draft' and a.kind = 'exam') then
    raise exception '這位考生已有進行中的雙考官考核，請從草稿清單進入';
  end if;

  -- 【回考核期停用】不再因 probation_since 有值就改成「正式／考核期」；身分只看考核期新人（period_status）與到職日
  if v_emp.period_status = '考核期' then
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

-- ---------- G. storage policy：assess_notes_insert、assess_notes_delete 改用題組擁有者判斷 ----------
-- 底：assess_schema.sql（之後沒有任何檔案覆蓋）。條數（assess_notes_* 共 3 條）、名稱、命令、角色都不變；assess_notes_select 完全不動。
-- 差異只有：
--   insert：非雙考官維持原判斷（考官是本人）；雙考官改成「我是這個題組的擁有者」（assess_i_own_item：security definer，
--           所以不會在 policy 內再讀考官表而觸發巢狀 RLS）。
--   delete：「本人的草稿」那一支，非雙考官維持原判斷（考核是本人的草稿），雙考官改成「路徑第二段的題組屬於該考核、且我是擁有者」；
--           「考核已不存在（清孤兒檔）」那一支完全不動。
-- （非雙考官的判斷刻意保持原文：既有 assess_verify 會檢查 policy 內容含 draft 與 roster_my_email，且單人路徑必須逐行不變。）
-- 雙考官的路徑一樣是 {assessment_id}/{item_id}/{uuid}.jpg|png|webp。
drop policy if exists assess_notes_insert on storage.objects;
create policy assess_notes_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'assess-notes'
    and public.roster_my_role() = 'cs_admin'
    and storage.objects.name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
    and exists (
      select 1
      from public.assessments a
      join public.assessment_items i on i.assessment_id = a.id
      where a.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 1))
        and a.status = 'draft'
        and i.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 2))
        and (
          (not a.is_dual and a.examiner_email = public.roster_my_email())
          or (a.is_dual and public.assess_i_own_item(i.id))
        )
    )
  );

drop policy if exists assess_notes_delete on storage.objects;
create policy assess_notes_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'assess-notes'
    and public.roster_my_role() = 'cs_admin'
    and (
      -- 本人的草稿（非雙考官）；或雙考官草稿中「我負責而且還沒交卷」的題組
      exists (
        select 1 from public.assessments a
        where a.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 1))
          and a.status = 'draft'
          and (
            (not a.is_dual and a.examiner_email = public.roster_my_email())
            or (a.is_dual and exists (
                  select 1 from public.assessment_items i
                  where i.assessment_id = a.id
                    and i.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 2))
                    and public.assess_i_own_item(i.id)))
          )
      )
      -- 或：路徑第一段是合法 uuid，但該考核已不存在（清孤兒檔）
      or (
        public.assess_safe_uuid(split_part(storage.objects.name, '/', 1)) is not null
        and not exists (
          select 1 from public.assessments a
          where a.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 1))
        )
      )
    )
  );

-- ---------- H. 函式權限 ----------
-- 既有函式權限沿用原本設定（create or replace 不會改權限），這裡重申一次；內部函式 assess_owns_item 不授權 authenticated。
revoke execute on function public.assess_save_item(uuid, jsonb, text, text)  from public, anon;
grant  execute on function public.assess_save_item(uuid, jsonb, text, text)  to authenticated;
revoke execute on function public.assess_save_dim_notes(uuid, jsonb)         from public, anon;
grant  execute on function public.assess_save_dim_notes(uuid, jsonb)         to authenticated;
revoke execute on function public.assess_add_image(uuid, text, text, int)    from public, anon;
grant  execute on function public.assess_add_image(uuid, text, text, int)    to authenticated;
revoke execute on function public.assess_remove_image(uuid)                  from public, anon;
grant  execute on function public.assess_remove_image(uuid)                  to authenticated;
revoke execute on function public.assess_abandon(uuid)                       from public, anon;
grant  execute on function public.assess_abandon(uuid)                       to authenticated;
revoke execute on function public.assess_draft_weak(uuid)                    from public, anon;
grant  execute on function public.assess_draft_weak(uuid)                    to authenticated;
revoke execute on function public.assess_add_extra(uuid, bigint[])           from public, anon;
grant  execute on function public.assess_add_extra(uuid, bigint[])           to authenticated;
revoke execute on function public.assess_start(text, text)                   from public, anon;
grant  execute on function public.assess_start(text, text)                   to authenticated;
revoke execute on function public.assess_owns_item(uuid, text)               from public, anon, authenticated;

commit;

-- ============================================================
-- 驗證查詢（執行完第二段後貼上跑；每一列的「結果」都應該是 通過）
-- ============================================================
select '第二段：改寫後的函式都用 assess_owns_item、且有雙考官分支' as 項目,
       case when (select count(*) from pg_proc p
                   where p.pronamespace = 'public'::regnamespace
                     and p.proname in ('assess_save_item', 'assess_save_dim_notes', 'assess_add_image', 'assess_remove_image')
                     and p.prosrc like '%assess_owns_item%' and p.prosrc like '%for share of a%') = 4 then '通過' else '失敗' end as 結果
union all
select 'assess_abandon、assess_draft_weak、assess_add_extra、assess_start 都有雙考官守衛',
       case when (select count(*) from pg_proc p
                   where p.pronamespace = 'public'::regnamespace
                     and p.proname in ('assess_abandon', 'assess_draft_weak', 'assess_add_extra', 'assess_start')
                     and p.prosrc like '%is_dual%') = 4 then '通過' else '失敗' end
union all
select 'storage assess_notes_* 仍是 3 條（DELETE、INSERT、SELECT），insert／delete 已改用題組擁有者判斷',
       case when (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                    and policyname like 'assess_notes_%') = 3
             and (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
                    and policyname in ('assess_notes_insert', 'assess_notes_delete')
                    and coalesce(qual, '') || coalesce(with_check, '') like '%assess_i_own_item%') = 2
            then '通過' else '失敗' end
union all
select '內部函式 assess_owns_item 登入者不可直接呼叫；policy 用的 assess_i_own_item 登入者可呼叫、anon 不可',
       case when not has_function_privilege('authenticated', 'public.assess_owns_item(uuid, text)', 'execute')
             and not has_function_privilege('anon', 'public.assess_owns_item(uuid, text)', 'execute')
             and has_function_privilege('authenticated', 'public.assess_i_own_item(uuid)', 'execute')
             and not has_function_privilege('anon', 'public.assess_i_own_item(uuid)', 'execute')
            then '通過' else '失敗' end;


-- ===== 第三段：各自交卷＋撤回＋完成收尾（DB-3）=====
-- 本段內容（單一交易 begin/commit；可重複執行，重跑不報錯、不刪任何資料）：
--   A. assess_finalize（內部，不授權 authenticated）：把舊 assess_submit「驗證之後」的全部收尾邏輯原封不動抽出來
--      （逐題算分寫回、至少 1 題組、總分、assess_verdict、status='submitted'、submitted_at、
--        新人通過轉已上線與待開通）。整場只有這裡做「一次」update assessments，所以改善單、待考回報、
--      新人面向備註把關等觸發器的行為與以前完全相同。
--   B. assess_submit：改成薄包裝。單人（含舊單、健檢）路徑的驗證與訊息逐行不變，驗證完呼叫 assess_finalize；
--      雙考官草稿丟「請用雙考官交卷」。
--   C. assess_submit_part（對外）：雙考官其中一位送出「我的題組」。鎖順序：考核 → 考官表 → 題組。
--      自己的每個題組都要七面向評完才行；寫自己的 submitted_at；兩位都交卷了就呼叫 assess_finalize 並回 done=true。
--      重複送出：明確報錯「你已經送出自己的題組了」（不做冪等，避免前端以為又成功了一次）。
--   D. assess_unsubmit_part（對外）：整張完成前可撤回自己的送出（清自己的 submitted_at）；整張完成後拒絕。
--      目前沒有送出就撤回：明確報錯「你還沒有送出自己的題組，不需要撤回」。
--   E. 權限：assess_submit_part、assess_unsubmit_part 授權 authenticated；assess_finalize 不授權。
--
-- 注意：成績單的 examiner_email 維持「開考者」；兩位考官的分工與各自交卷時間在 assessment_examiners。
-- 非雙考官（舊單、單人、健檢）完全不會走到 assess_submit_part／assess_unsubmit_part（會被拒絕並提示改用一般交卷）。
--
-- ---------- 備份提醒（執行第三段之前先做；備份表必須啟用 row level security）----------
--   drop table if exists public.bak_dual3_funcs;
--   create table public.bak_dual3_funcs as
--     select p.oid::regprocedure::text as func, pg_get_functiondef(p.oid) as def
--     from pg_proc p
--     where p.pronamespace = 'public'::regnamespace and p.proname = 'assess_submit';
--   alter table public.bak_dual3_funcs enable row level security;
--
-- ---------- 已知事項 ----------
--   * 本檔之後不要重跑 assess_schema／checkup_schema／noredticket_schema 等會重新定義 assess_submit 的檔案
--     （會把薄包裝蓋回舊版而繞過 assess_finalize）；萬一重跑過，再執行一次本檔即可。
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'assessments' and column_name = 'is_dual')
     or to_regclass('public.assessment_examiners') is null then
    raise exception '前提不滿足：請先執行本檔第一段（資料模型＋抽籤＋抽題）';
  end if;
  if to_regprocedure('public.assess_owns_item(uuid, text)') is null then
    raise exception '前提不滿足：請先執行本檔第二段（擁有者改寫）';
  end if;
  if to_regprocedure('public.assess_submit(uuid)') is null
     or to_regprocedure('public.assess_score_item(jsonb)') is null
     or to_regprocedure('public.assess_score_session(jsonb)') is null
     or to_regprocedure('public.assess_verdict(numeric, text)') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 assess … noredticket 等前面的檔案';
  end if;
end
$$;

-- ---------- A. assess_finalize：完成收尾（內部用；不授權 authenticated） ----------
-- 內容＝noredticket_schema.sql 版 assess_submit「驗證（找得到、草稿、建立者本人）之後」的全部，逐行照搬。
-- 呼叫者必須已經用 assess_assert_cs 與各自的擁有者檢查驗證過身分；本函式只負責算分與完成。
-- 為了保險，額外多兩道內部防線（對單人路徑不會觸發）：只有草稿能完成；雙考官必須兩位考官都已送出。
create or replace function public.assess_finalize(p_assessment_id uuid)
returns table(total_score numeric, verdict text, pass_line int, weakest_dims text[],
              tenure text, item_count int)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
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
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以送出';
  end if;
  -- 【雙考官】內部防線：兩位考官都已送出才能完成
  if v_a.is_dual and exists (select 1 from public.assessment_examiners e
                              where e.assessment_id = v_a.id and e.submitted_at is null) then
    raise exception '雙考官考核必須兩位考官都送出自己的題組，才能完成';
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

  -- 【回考核期停用】原本在這裡的「考核期成績單 >= 85 清除回考核期標記、回考核期紀錄改已通過」已拿掉
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

revoke execute on function public.assess_finalize(uuid) from public, anon, authenticated;

-- ---------- B. assess_submit：薄包裝 ----------
-- 底：noredticket_schema.sql（線上最新生效版本）。簽名、回傳型別、security definer、search_path、權限都不變。
-- 非雙考官：驗證（找不到考核／只有草稿／只有建立者本人）與訊息、順序逐行照舊；通過後交給 assess_finalize。
-- 差異只有標【雙考官】的那一段：雙考官草稿不能用一般交卷。
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
  -- 【雙考官】雙考官草稿要各自交卷（assess_submit_part）
  if v_a.is_dual then
    raise exception '請用雙考官交卷';
  end if;
  if v_a.examiner_email <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  return query
    select f.total_score, f.verdict, f.pass_line, f.weakest_dims, f.tenure, f.item_count
    from public.assess_finalize(p_assessment_id) as f;
end;
$$;

-- ---------- C. assess_submit_part：送出「我的題組」 ----------
-- 回傳 {done boolean, waiting_for_slot smallint|null}：
--   done=true ＝ 兩位都送出了，整張已完成（成績單、判定都已產生）；
--   done=false、waiting_for_slot＝還在等的那位考官（slot 1 或 2）。
create or replace function public.assess_submit_part(p_assessment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_me text;
  v_a public.assessments%rowtype;
  v_slot smallint;
  v_mine_done timestamptz;
  v_other smallint;
  v_other_done timestamptz;
  r record;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 鎖順序：考核 → 考官表 → 題組
  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if not v_a.is_dual then
    raise exception '這不是雙考官考核，請用一般的送出';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以送出';
  end if;

  perform 1 from public.assessment_examiners e where e.assessment_id = v_a.id order by e.slot for update;

  select e.slot, e.submitted_at into v_slot, v_mine_done
  from public.assessment_examiners e
  where e.assessment_id = v_a.id and e.email = v_me;
  if not found then
    raise exception '只有這張考核的考官可以送出題組';
  end if;
  if v_mine_done is not null then
    raise exception '你已經送出自己的題組了';
  end if;

  -- 自己負責的每個題組都要七面向評完
  for r in
    select i.seq, i.levels
    from public.assessment_items i
    where i.assessment_id = v_a.id and i.examiner_slot = v_slot
    order by i.seq
  loop
    begin
      perform public.assess_score_item(r.levels);
    exception when others then
      raise exception '第 % 題組評分不完整或不正確：%', r.seq, sqlerrm;
    end;
  end loop;

  update public.assessment_examiners e
     set submitted_at = now()
   where e.assessment_id = v_a.id and e.slot = v_slot;

  v_other := 3 - v_slot;
  select e.submitted_at into v_other_done
  from public.assessment_examiners e
  where e.assessment_id = v_a.id and e.slot = v_other;

  if v_other_done is not null then
    perform public.assess_finalize(v_a.id);
    return jsonb_build_object('done', true, 'waiting_for_slot', null);
  end if;
  return jsonb_build_object('done', false, 'waiting_for_slot', v_other);
end;
$$;

-- ---------- D. assess_unsubmit_part：撤回我的送出 ----------
create or replace function public.assess_unsubmit_part(p_assessment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_me text;
  v_a public.assessments%rowtype;
  v_slot smallint;
  v_mine_done timestamptz;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 鎖順序：考核 → 考官表
  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if not v_a.is_dual then
    raise exception '這不是雙考官考核，沒有可以撤回的送出';
  end if;
  if v_a.status <> 'draft' then
    raise exception '這張考核已經完成（或已作廢），不能撤回送出';
  end if;

  perform 1 from public.assessment_examiners e where e.assessment_id = v_a.id order by e.slot for update;

  select e.slot, e.submitted_at into v_slot, v_mine_done
  from public.assessment_examiners e
  where e.assessment_id = v_a.id and e.email = v_me;
  if not found then
    raise exception '只有這張考核的考官可以撤回送出';
  end if;
  if v_mine_done is null then
    raise exception '你還沒有送出自己的題組，不需要撤回';
  end if;

  update public.assessment_examiners e
     set submitted_at = null
   where e.assessment_id = v_a.id and e.slot = v_slot;
end;
$$;

-- ---------- E. 函式權限 ----------
revoke execute on function public.assess_finalize(uuid)       from public, anon, authenticated;
revoke execute on function public.assess_submit(uuid)         from public, anon;
grant  execute on function public.assess_submit(uuid)         to authenticated;
revoke execute on function public.assess_submit_part(uuid)    from public, anon;
grant  execute on function public.assess_submit_part(uuid)    to authenticated;
revoke execute on function public.assess_unsubmit_part(uuid)  from public, anon;
grant  execute on function public.assess_unsubmit_part(uuid)  to authenticated;

commit;

-- ============================================================
-- 驗證查詢（執行完第三段後貼上跑；每一列的「結果」都應該是 通過）
-- ============================================================
select '第三段：assess_submit 是薄包裝（呼叫 assess_finalize、有雙考官守衛）' as 項目,
       case when exists (select 1 from pg_proc p where p.oid = 'public.assess_submit(uuid)'::regprocedure
                         and p.prosrc like '%assess_finalize%' and p.prosrc like '%請用雙考官交卷%') then '通過' else '失敗' end as 結果
union all
select 'assess_finalize 內文有收尾邏輯（算分、判定、完成、新人轉已上線）',
       case when exists (select 1 from pg_proc p where p.oid = 'public.assess_finalize(uuid)'::regprocedure
                         and p.prosrc like '%assess_score_session%' and p.prosrc like '%assess_verdict%'
                         and p.prosrc like '%reply_activations%' and p.prosrc like '%''submitted''%') then '通過' else '失敗' end
union all
select '權限：交卷／撤回登入者可執行、anon 不可；assess_finalize 登入者不可直接呼叫',
       case when has_function_privilege('authenticated', 'public.assess_submit_part(uuid)', 'execute')
             and has_function_privilege('authenticated', 'public.assess_unsubmit_part(uuid)', 'execute')
             and has_function_privilege('authenticated', 'public.assess_submit(uuid)', 'execute')
             and not has_function_privilege('anon', 'public.assess_submit_part(uuid)', 'execute')
             and not has_function_privilege('anon', 'public.assess_unsubmit_part(uuid)', 'execute')
             and not has_function_privilege('anon', 'public.assess_submit(uuid)', 'execute')
             and not has_function_privilege('authenticated', 'public.assess_finalize(uuid)', 'execute')
             and not has_function_privilege('anon', 'public.assess_finalize(uuid)', 'execute')
        then '通過' else '失敗' end;
