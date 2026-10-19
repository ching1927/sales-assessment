-- ============================================================
-- 業務考核系統：評分與成績單資料庫結構（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 前提：roster_schema.sql（人員名冊）與考題抽選器的 schema.sql 都已在同一個專案執行過。
-- 本檔只「新增」東西；不修改、不刪除舊考題抽選器與名冊的任何資料表／函式／權限。
-- 新函式以 security definer 讀寫 questions／drawn／category_last
-- （這三張表已收回一般權限，只有函式能動）。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 既有名稱（本檔不會碰）：
--   考題抽選器：questions、drawn、category_last、app_secret、
--               _pw_ok、_assert_pw、list_categories、draw_questions、admin_login、
--               admin_list_questions、admin_save_question、admin_delete_question、
--               admin_rename_category、admin_reset
--   人員名冊：stores、employees、app_users、employees_with_tenure、
--             roster_my_email、roster_my_role、roster_my_store、
--             roster_touch_updated_at、roster_keepalive
-- 本檔新增的名稱（全部以 assess_ 或 assessment 開頭，與上面皆不重複）：
--   資料表：assessments、assessment_items、assessment_item_secrets
--   檢視：assessment_summaries
--   函式：assess_dim_order、assess_dim_points、assess_level_pct、assess_check_levels、
--         assess_score_item、assess_score_session、assess_verdict、assess_assert_cs、
--         assess_candidates、assess_categories、assess_start、assess_draw、
--         assess_save_item、assess_submit、assess_void、assess_abandon
--   索引：assessments_employee_idx、assessments_store_status_idx、
--         assessments_one_draft_per_pair、assessment_item_secrets_question_idx
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   執行完再跑 assess_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 可重複執行：資料表／索引 if not exists、函式 create or replace、
-- policy 先 drop 再建，重跑不會報錯，也不會刪掉既有資料。
-- 需要 Postgres 15 以上（view 的 security_invoker、trim_scale）；Supabase 新專案皆符合。
--
-- 安全設計：三張新表全部開 RLS，直接寫入權限（insert／update／delete）一律不給，
-- 只能透過下面的函式寫入；機密（題組名稱、步驟、考官備註）獨立放在
-- assessment_item_secrets，只有客服部（cs_admin）讀得到。
-- 分數一律由資料庫算，函式不接受前端傳來的分數。
-- ============================================================

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.employees') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.app_users') is null
     or to_regclass('public.questions') is null
     or to_regclass('public.drawn') is null
     or to_regclass('public.category_last') is null then
    raise exception '請先執行 roster_schema.sql 與考題抽選器的 schema.sql';
  end if;
end
$$;

-- ---------- 計算用的小工具（純計算，不碰任何資料表） ----------

-- 七個面向的固定順序
create or replace function public.assess_dim_order()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識','語氣與禮貌','文字品質']::text[];
$$;

-- 七個面向的配分（合計 100）
create or replace function public.assess_dim_points()
returns jsonb
language sql
immutable
set search_path = public, pg_temp
as $$
  select '{"資訊正確性":20,"預設訊息運用":15,"問題掌握":15,"主動引導":15,"風險意識":15,"語氣與禮貌":10,"文字品質":10}'::jsonb;
$$;

-- 等級 → 百分比；不是四級之一（含「不適用」）一律回傳 null
create or replace function public.assess_level_pct(p_level text)
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select (case p_level
            when '優' then 100
            when '良' then 70
            when '待加強' then 40
            when '不及格' then 0
          end)::numeric;
$$;

-- 檢查評分物件：鍵必須是七面向之一、值必須是四級或「不適用」、不適用最多 2 個；
-- p_require_all = true 時七個面向必須全部有值（送出用），false 允許只填一部分（暫存用）
create or replace function public.assess_check_levels(p_levels jsonb, p_require_all boolean)
returns void
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_dims text[] := public.assess_dim_order();
  k text;
  v jsonb;
  v_txt text;
  v_na int := 0;
begin
  if p_levels is null or jsonb_typeof(p_levels) <> 'object' then
    raise exception '評分格式不正確，必須是物件';
  end if;

  for k, v in select key, value from jsonb_each(p_levels) loop
    if not (k = any(v_dims)) then
      raise exception '未知的面向：%', k;
    end if;
    if jsonb_typeof(v) <> 'string' then
      raise exception '面向「%」的等級必須是文字', k;
    end if;
    v_txt := v #>> '{}';
    if v_txt = '不適用' then
      v_na := v_na + 1;
    elsif public.assess_level_pct(v_txt) is null then
      raise exception '面向「%」的等級不正確：%', k, v_txt;
    end if;
  end loop;

  if v_na > 2 then
    raise exception '不適用最多 2 個面向（目前 % 個）', v_na;
  end if;

  -- 鍵都已確認屬於七面向且不會重複，所以數量 = 7 就代表七個全有
  if p_require_all and (select count(*) from jsonb_object_keys(p_levels)) <> 7 then
    raise exception '七個面向必須全部有值';
  end if;
end;
$$;

-- 一個題組的分數：
--   題組分數 = Σ(適用面向配分 × 等級%) ÷ 適用面向配分合計，numeric 精確計算，四捨五入到小數 1 位
--   最弱面向 = 適用面向中等級%最低者，並列全列（依固定順序）
create or replace function public.assess_score_item(p_levels jsonb)
returns table(item_score numeric, dim_points jsonb, na_dims text[], weakest_dims text[])
language plpgsql
immutable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_dims text[] := public.assess_dim_order();
  v_pts jsonb := public.assess_dim_points();
  v_sum_pts numeric;   -- 適用面向配分合計
  v_sum_x numeric;     -- Σ(配分 × 等級%)，單位是「配分×百分點」
  v_min numeric;
begin
  perform public.assess_check_levels(p_levels, true);

  select sum((v_pts ->> t.d)::numeric),
         sum((v_pts ->> t.d)::numeric * public.assess_level_pct(p_levels ->> t.d))
    into v_sum_pts, v_sum_x
  from unnest(v_dims) as t(d)
  where p_levels ->> t.d <> '不適用';

  -- Σ(配分×等級%/100) ÷ Σ配分 ×100  =  Σ(配分×等級%) ÷ Σ配分
  item_score := round(v_sum_x / v_sum_pts, 1);

  -- 各面向得分（配分×等級%÷100）；不適用 → null
  select jsonb_object_agg(
           t.d,
           case when p_levels ->> t.d = '不適用' then null
                else to_jsonb(trim_scale(round(
                       (v_pts ->> t.d)::numeric * public.assess_level_pct(p_levels ->> t.d) / 100, 2)))
           end)
    into dim_points
  from unnest(v_dims) as t(d);

  select min(public.assess_level_pct(p_levels ->> t.d))
    into v_min
  from unnest(v_dims) as t(d)
  where p_levels ->> t.d <> '不適用';

  select array_agg(t.d order by t.n)
    into weakest_dims
  from unnest(v_dims) with ordinality as t(d, n)
  where p_levels ->> t.d <> '不適用'
    and public.assess_level_pct(p_levels ->> t.d) = v_min;

  select coalesce(array_agg(t.d order by t.n), '{}'::text[])
    into na_dims
  from unnest(v_dims) with ordinality as t(d, n)
  where p_levels ->> t.d = '不適用';

  return next;
end;
$$;

-- 整場的總分與最弱面向。p_levels_list 是 jsonb 陣列，每個元素是一個題組的七面向評分。
--   總分 = 各題組「已四捨五入的題組分數」平均，再四捨五入到小數 1 位
--   最弱面向 = 每個面向取各題組中「該面向適用者」的等級%平均，最低者；並列全列；
--              某面向所有題組皆不適用則排除。比較用交叉相乘，避免除不盡造成並列誤判。
create or replace function public.assess_score_session(p_levels_list jsonb)
returns table(total_score numeric, weakest_dims text[])
language plpgsql
immutable
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  if p_levels_list is null
     or jsonb_typeof(p_levels_list) <> 'array'
     or jsonb_array_length(p_levels_list) = 0 then
    raise exception '至少要有 1 個題組';
  end if;

  select round(sum(s.item_score) / count(*), 1)
    into total_score
  from jsonb_array_elements(p_levels_list) as e(v)
  cross join lateral public.assess_score_item(e.v) as s;

  with x as (
    select d.key as dim,
           sum(public.assess_level_pct(d.value #>> '{}')) as tot,
           count(*) as cnt
    from jsonb_array_elements(p_levels_list) as e(v)
    cross join lateral jsonb_each(e.v) as d
    where d.value #>> '{}' <> '不適用'
    group by d.key
  )
  select array_agg(x.dim order by array_position(public.assess_dim_order(), x.dim))
    into weakest_dims
  from x
  where not exists (select 1 from x o where o.tot * x.cnt < x.tot * o.cnt);

  return next;
end;
$$;

-- 判定與合格線（依考核當天身分）
--   新人：>=85 優秀、>=70 及格、>=60 需複訓、其餘不及格（合格線 70）
--   正式：>=95 優秀、>=85 及格、>=75 需複訓、其餘不及格（合格線 85）
create or replace function public.assess_verdict(p_total numeric, p_tenure text)
returns table(verdict text, pass_line int)
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_total is null or p_total < 0 or p_total > 100 then
    raise exception '總分必須介於 0 到 100';
  end if;

  if p_tenure = '新人' then
    pass_line := 70;
    verdict := case when p_total >= 85 then '優秀'
                    when p_total >= 70 then '及格'
                    when p_total >= 60 then '需複訓'
                    else '不及格' end;
  elsif p_tenure = '正式' then
    pass_line := 85;
    verdict := case when p_total >= 95 then '優秀'
                    when p_total >= 85 then '及格'
                    when p_total >= 75 then '需複訓'
                    else '不及格' end;
  else
    raise exception '身分必須是「新人」或「正式」';
  end if;

  return next;
end;
$$;

-- ---------- 資料表 ----------

-- 一次考核（一場）
create table if not exists public.assessments (
  id uuid primary key default gen_random_uuid(),
  employee_id text not null references public.employees(id) on update cascade,
  employee_label text not null,         -- 開始考核當下員工的暱稱或姓名（顯示用快照），之後改名、調店都不變
  store_code text not null references public.stores(code) on update cascade,  -- 開始考核當下的門市快照，之後調店不改
  examiner_email text not null
    check (examiner_email = lower(btrim(examiner_email)) and length(examiner_email) > 0),
  status text not null default 'draft' check (status in ('draft', 'submitted', 'voided')),
  tenure text not null check (tenure in ('新人', '正式')),
  tenure_source text not null check (tenure_source in ('自動', '手動指定')),
  hire_date_snapshot date,
  total_score numeric(4,1) check (total_score between 0 and 100),
  verdict text check (verdict in ('優秀', '及格', '需複訓', '不及格')),
  pass_line int check (pass_line in (70, 85)),
  weakest_dims text[],
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  voided_at timestamptz,
  voided_by text,
  void_reason text,
  -- 各狀態該有／不該有的欄位
  constraint assessments_status_fields check (
    (status = 'draft'
       and total_score is null and verdict is null and submitted_at is null and voided_at is null)
    or (status = 'submitted'
       and total_score is not null and verdict is not null and pass_line is not null
       and submitted_at is not null and voided_at is null)
    or (status = 'voided'
       and total_score is not null and submitted_at is not null and voided_at is not null
       and nullif(btrim(void_reason), '') is not null)
  )
);

create index if not exists assessments_employee_idx on public.assessments(employee_id);
create index if not exists assessments_store_status_idx on public.assessments(store_code, status);
-- 同一位考官對同一位員工同時只能有一張草稿
create unique index if not exists assessments_one_draft_per_pair
  on public.assessments(examiner_email, employee_id) where status = 'draft';

-- 一場裡的每個題組（不含機密）
create table if not exists public.assessment_items (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  seq int not null check (seq >= 1),
  category text not null,
  code text,
  levels jsonb not null default '{}'::jsonb check (jsonb_typeof(levels) = 'object'),
  item_score numeric(4,1),
  dim_points jsonb,
  na_dims text[],
  weakest_dims text[],
  unique (assessment_id, seq),
  unique (assessment_id, category)      -- 一場每個分類最多一個題組
);

-- 機密：題庫題號、題組名稱、步驟與考點快照、考官備註；只有客服部讀得到
-- （question_id 與 was_drawn_before 也放這裡，避免主管／店長從題號反推題目）
create table if not exists public.assessment_item_secrets (
  item_id uuid primary key references public.assessment_items(id) on delete cascade,
  question_id bigint not null,          -- 不設外鍵：題庫日後可能被刪
  was_drawn_before boolean not null,    -- 抽這題「之前」它是否已在 drawn 內（放棄考核時用）
  title text,
  steps jsonb,
  note text
);

create index if not exists assessment_item_secrets_question_idx
  on public.assessment_item_secrets(question_id);

-- ---------- 權限與 RLS ----------

alter table public.assessments            enable row level security;
alter table public.assessment_items       enable row level security;
alter table public.assessment_item_secrets enable row level security;

-- 先全收回；只給 authenticated「讀」，沒有任何人有直接寫入權限（只能透過函式寫）
revoke all on table public.assessments             from public, anon, authenticated;
revoke all on table public.assessment_items        from public, anon, authenticated;
revoke all on table public.assessment_item_secrets from public, anon, authenticated;

grant select on public.assessments             to authenticated;
grant select on public.assessment_items        to authenticated;
grant select on public.assessment_item_secrets to authenticated;

-- assessments：客服部全看（含草稿、作廢）；總公司主管只看已送出；店長只看自己門市的已送出
drop policy if exists assessments_select on public.assessments;
create policy assessments_select on public.assessments
  for select to authenticated
  using (
    public.roster_my_role() = 'cs_admin'
    or (status = 'submitted'
        and (public.roster_my_role() = 'hq_viewer'
             or (public.roster_my_role() = 'store_manager'
                 and store_code = public.roster_my_store())))
  );

-- assessment_items：看得到母考核才看得到題組。
-- 子查詢讀 assessments 時會套用上面那條 policy，所以可見範圍與 assessments 完全一致。
drop policy if exists assessment_items_select on public.assessment_items;
create policy assessment_items_select on public.assessment_items
  for select to authenticated
  using (
    exists (select 1 from public.assessments a where a.id = assessment_items.assessment_id)
  );

-- assessment_item_secrets：只有客服部
drop policy if exists assessment_item_secrets_select on public.assessment_item_secrets;
create policy assessment_item_secrets_select on public.assessment_item_secrets
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- ---------- 成績單列表檢視（不含機密欄位） ----------
-- security_invoker = true：以查詢者本人權限讀底層資料表，RLS 照樣生效，不會繞過。
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
  (select count(*) from public.assessment_items i where i.assessment_id = a.id)::int as item_count
from public.assessments a
left join public.stores s on s.code = a.store_code;

revoke all on table public.assessment_summaries from public, anon, authenticated;
grant select on public.assessment_summaries to authenticated;

-- ---------- 身分檢查（內部用，不開放給前端直接呼叫） ----------
-- 不是客服部（含未登入、沒帳號、總公司主管、店長）一律丟「沒有權限」。
create or replace function public.assess_assert_cs()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;
end;
$$;

-- ---------- 名單與分類 ----------

-- 納入考核＝是且在職的員工
create or replace function public.assess_candidates()
returns table(id text, nickname text, full_name text, store_code text,
              job_title text, hire_date date, tenure_group text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.assess_assert_cs();
  return query
    select e.id, e.nickname, e.full_name, e.store_code, e.job_title, e.hire_date, e.tenure_group
    from public.employees_with_tenure e
    where e.include_in_assessment and e.status = '在職'
    order by e.store_code, e.id;
end;
$$;

-- 各分類總題數與本輪剩餘（同舊 list_categories，改用客服部身分檢查）
create or replace function public.assess_categories()
returns table(category text, total int, remaining int)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.assess_assert_cs();
  return query
    select q.category,
           count(*)::int,
           (count(*) - count(d.question_id))::int
    from public.questions q
    left join public.drawn d on d.question_id = q.id
    group by q.category
    order by min(q.id);
end;
$$;

-- ---------- 開始考核 ----------
-- 到職日有值：自動算（台北時間今天，到職日起 90 天內含第 90 天＝新人），忽略 override。
-- 到職日空白：p_tenure_override 必須是「新人」或「正式」，記「手動指定」。
-- 同一位考官對同一員工已有草稿：回傳既有那張（並行呼叫也一樣）。
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

  if v_emp.hire_date is not null then
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

-- ---------- 抽題 ----------
-- 沿用舊抽題：同時只允許一個人抽（同一把鎖）、各分類抽完一輪才重複、新一輪第一題避開上一題。
-- 新增：優先避開「該考生以前考過」的題組（以其 submitted 與 voided 考核的 question_id（存在機密表）為準，草稿不算）。
-- 挑題優先順序（越前面越優先）：
--   1. 該考生沒考過的   2. 本輪還沒被抽過的   3. 不是該分類上一次抽出的   4. 隨機
-- 若該分類本輪已全數被抽過，先清掉該分類的已抽記錄開新一輪（new_round = true）。
-- 挑到的題組若該考生以前考過（整個分類都考過了才會發生）→ repeated = true。
-- was_drawn_before：在「寫入 drawn 之前」（若剛開新一輪，則是清完之後）它是否已在 drawn 內。
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

-- ---------- 暫存評分 ----------
-- 只限草稿且本人建立；允許只填部分面向（完整性在送出時檢查）。
-- 每次呼叫會整份取代該題組的評分與備註（備註傳 null 或空白＝清除備註）。
create or replace function public.assess_save_item(p_item_id uuid, p_levels jsonb, p_note text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select a.status, a.examiner_email into v_status, v_owner
  from public.assessment_items i
  join public.assessments a on a.id = i.assessment_id
  where i.id = p_item_id
  for update of a;
  if not found then
    raise exception '找不到題組';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以暫存評分';
  end if;
  if v_owner <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  perform public.assess_check_levels(p_levels, false);

  update public.assessment_items set levels = p_levels where id = p_item_id;
  update public.assessment_item_secrets set note = nullif(btrim(p_note), '') where item_id = p_item_id;
end;
$$;

-- ---------- 送出 ----------
-- 檢查每個題組七面向齊全 → 資料庫算每題組分數、面向得分、不適用、最弱面向，
-- 再算整場總分、判定、合格線、最弱面向 → 狀態改 submitted。至少要有 1 個題組。
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

  total_score := v_total;
  verdict := v_ver;
  pass_line := v_line;
  weakest_dims := v_weak;
  tenure := v_a.tenure;
  item_count := v_cnt;
  return next;
end;
$$;

-- ---------- 作廢 ----------
-- 只限已送出；原因不可空白；不刪除、不動 drawn。
create or replace function public.assess_void(p_assessment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select a.status into v_status from public.assessments a where a.id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_status <> 'submitted' then
    raise exception '只有已送出的考核可以作廢';
  end if;
  if v_reason = '' then
    raise exception '作廢原因不可空白';
  end if;

  update public.assessments
     set status = 'voided',
         voided_at = now(),
         voided_by = v_me,
         void_reason = v_reason
   where id = p_assessment_id;
end;
$$;

-- ---------- 放棄考核 ----------
-- 只限草稿；任一客服部都可以放棄任何人的草稿（避免考官離職後草稿卡住題池）。
-- 刪除草稿（題組與機密連帶刪除）；
-- was_drawn_before = false 的題組從 drawn 刪掉（回到題池），true 的不動。
-- 已知限制：不還原 category_last；若放棄期間該分類已開新一輪，可能誤刪別場剛抽的 drawn 記錄（極少見）。
create or replace function public.assess_abandon(p_assessment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_a public.assessments%rowtype;
begin
  perform public.assess_assert_cs();

  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以放棄';
  end if;

  -- 動到 drawn 前先取同一把鎖，避免和別人抽題打架
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  delete from public.drawn d
  where d.question_id in (
    select sx.question_id
    from public.assessment_items i
    join public.assessment_item_secrets sx on sx.item_id = i.id
    where i.assessment_id = v_a.id and not sx.was_drawn_before
  );

  delete from public.assessments where id = v_a.id;  -- items、secrets 由 cascade 一併刪除
end;
$$;

-- ---------- 函式權限：收回 public／anon，只授權 authenticated ----------
-- 對外的函式：執行者是否為客服部由函式內部檢查（assess_assert_cs）。
-- 純計算函式（不碰資料表）同樣只授權 authenticated，方便前端預覽與驗證。

revoke execute on function public.assess_dim_order()                      from public, anon;
revoke execute on function public.assess_dim_points()                     from public, anon;
revoke execute on function public.assess_level_pct(text)                  from public, anon;
revoke execute on function public.assess_check_levels(jsonb, boolean)     from public, anon;
revoke execute on function public.assess_score_item(jsonb)                from public, anon;
revoke execute on function public.assess_score_session(jsonb)             from public, anon;
revoke execute on function public.assess_verdict(numeric, text)           from public, anon;
revoke execute on function public.assess_candidates()                     from public, anon;
revoke execute on function public.assess_categories()                     from public, anon;
revoke execute on function public.assess_start(text, text)                from public, anon;
revoke execute on function public.assess_draw(uuid, text[])               from public, anon;
revoke execute on function public.assess_save_item(uuid, jsonb, text)     from public, anon;
revoke execute on function public.assess_submit(uuid)                     from public, anon;
revoke execute on function public.assess_void(uuid, text)                 from public, anon;
revoke execute on function public.assess_abandon(uuid)                    from public, anon;
-- 內部身分檢查：連 authenticated 都不開放直接呼叫（函式之間以擁有者身分呼叫）
revoke execute on function public.assess_assert_cs()                      from public, anon, authenticated;

grant execute on function public.assess_dim_order()                       to authenticated;
grant execute on function public.assess_dim_points()                      to authenticated;
grant execute on function public.assess_level_pct(text)                   to authenticated;
grant execute on function public.assess_check_levels(jsonb, boolean)      to authenticated;
grant execute on function public.assess_score_item(jsonb)                 to authenticated;
grant execute on function public.assess_score_session(jsonb)              to authenticated;
grant execute on function public.assess_verdict(numeric, text)            to authenticated;
grant execute on function public.assess_candidates()                      to authenticated;
grant execute on function public.assess_categories()                      to authenticated;
grant execute on function public.assess_start(text, text)                 to authenticated;
grant execute on function public.assess_draw(uuid, text[])                to authenticated;
grant execute on function public.assess_save_item(uuid, jsonb, text)      to authenticated;
grant execute on function public.assess_submit(uuid)                      to authenticated;
grant execute on function public.assess_void(uuid, text)                  to authenticated;
grant execute on function public.assess_abandon(uuid)                     to authenticated;
