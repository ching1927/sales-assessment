-- ============================================================
-- 業務考核系統：弱項建議題組 資料庫結構（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 唯一規格：README_weak_suggest.md（規則、資料庫物件、函式簽名）。
-- 前提：roster_schema.sql、assess_schema.sql、bank_schema.sql 已在同一個專案執行過
--       （考題抽選器的 questions／drawn／category_last 也要在）。
--       spotcheck_schema.sql、notes_visible_schema.sql、url_patch.sql、backoffice_schema.sql
--       有沒有執行都不影響本檔（本檔不讀它們新增的任何東西）。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 專案內原本沒有 question_dims、weak_profile、suggest_pool、assess_pick、bank_set_dims 這些名稱。
-- 本檔新增的名稱：
--   資料表：question_dims（題組的重點面向標記）
--   約束：question_dims_dims_valid、question_dims_pkey（主鍵）、外鍵 question_dims_question_id_fkey
--   RLS policy：question_dims_select
--   函式（全部授權 authenticated，函式內自己驗角色，只有客服部能用）：
--     bank_set_dims(bigint, text[])
--     assess_weak_profile(text)
--     assess_suggest_pool(text)
--     assess_pick(uuid, bigint[])
-- 本檔不改動任何既有資料表、函式、policy、觸發器（assess_draw、bank_*、assess_start、assess_submit 都不碰）。
--
-- 怎麼執行（之後老闆同意才做）：
--   0. 先到 Supabase 備份（Dashboard → Database → Backups）。
--   1. Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   2. 再跑 weak_suggest_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 單一交易：整份是 begin; … commit;，中途任何一步報錯整份自動回復，什麼都沒改。
-- 開頭設了 lock_timeout：拿不到鎖就報錯並整份回復，不會卡住別人，稍後重跑即可。
-- 請不要在中途自己手動下 commit／rollback。
--
-- 可重複執行：資料表 if not exists、policy 先 drop 再建、函式 create or replace；
-- 重跑不會報錯，也不會動到既有資料（包含已經勾好的面向標記）。
--
-- 安全設計：
--   * question_dims 開 RLS，只有客服部能 select；直接寫入（insert／update／delete／truncate）
--     對所有網頁角色一律收回，只能經 bank_set_dims 寫入。
--   * 全部函式 security definer、固定 search_path；不是客服部（含未登入、沒帳號、總公司主管、店長）
--     一律 raise exception '沒有權限'。收回 public／anon 的 execute，只授權 authenticated。
--   * 題組名稱屬機密，assess_suggest_pool 只有客服部能呼叫。
--   * assess_pick 與 assess_draw 共用同一把 advisory lock
--     （pg_advisory_xact_lock(hashtext('exam_draw_questions'))），選題、抽題、題庫管理不會同時發生。
--
-- 緊急還原：
--   本檔只新增物件，既有功能完全不依賴它們；要移除可執行
--     drop function if exists public.assess_pick(uuid, bigint[]);
--     drop function if exists public.assess_suggest_pool(text);
--     drop function if exists public.assess_weak_profile(text);
--     drop function if exists public.bank_set_dims(bigint, text[]);
--     drop table if exists public.question_dims;   -- 會刪掉所有面向標記，請先備份
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯並整份回復，不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.questions') is null
     or to_regclass('public.drawn') is null
     or to_regclass('public.category_last') is null
     or to_regclass('public.employees') is null
     or to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null then
    raise exception '請先執行考題抽選器的 schema.sql、roster_schema.sql 與 assess_schema.sql';
  end if;
  if to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_dim_order()') is null
     or to_regprocedure('public.assess_level_pct(text)') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_email()') is null then
    raise exception '請先執行 roster_schema.sql 與 assess_schema.sql（缺少必要函式）';
  end if;
  if to_regprocedure('public.bank_assert_cs()') is null then
    raise exception '請先執行 bank_schema.sql';
  end if;
end
$$;

-- ---------- 1. 資料表：題組重點面向標記 ----------
-- 一題一列；沒有列＝未標記（未標記的題組不會被當成弱項題）。
-- 可標記的面向只有 5 個（語氣與禮貌、文字品質每題都評，不標記）。
-- dims 的合法性（只能是 5 個面向、不重複、1～3 個）在資料表層再擋一次，
-- 即使有人繞過函式（例如以資料庫擁有者身分）寫入，也寫不進不合法的內容。
create table if not exists public.question_dims (
  question_id bigint primary key
    references public.questions(id) on delete cascade,   -- 題組被刪，標記一併刪除
  dims text[] not null,
  updated_at timestamptz not null default now(),
  updated_by text,
  constraint question_dims_dims_valid check (
    coalesce(
      cardinality(dims) between 1 and 3
      and array_ndims(dims) = 1
      and dims <@ array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識']::text[]
      and (cardinality(dims) < 2 or dims[1] <> dims[2])
      and (cardinality(dims) < 3 or (dims[1] <> dims[3] and dims[2] <> dims[3])),
      false)
  )
);

-- ---------- 2. 權限與 RLS ----------
alter table public.question_dims enable row level security;

-- 先全收回；只給 authenticated「讀」，沒有任何人有直接寫入權限（只能透過 bank_set_dims 寫）
revoke all on table public.question_dims from public, anon, authenticated;
grant select on public.question_dims to authenticated;

-- 只有客服部能讀（總公司主管、店長、未開通帳號都是 0 筆；anon 連 select 權限都沒有）
drop policy if exists question_dims_select on public.question_dims;
create policy question_dims_select on public.question_dims
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- ---------- 3. bank_set_dims：客服部替題組勾選重點面向 ----------
-- p_dims 空陣列＝刪除標記（回到未標記）；有內容＝新增或覆蓋（以最後一次設定為準）。
-- 驗證：不可為 null；不可含空值；只能是 5 個面向；不可重複；最多 3 個；題組必須存在。
-- 存入時一律依固定順序（資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識）排列。
-- 寫入前取與抽題相同的那把鎖，避免和「刪題組」同時發生。
create or replace function public.bank_set_dims(p_question_id bigint, p_dims text[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ok constant text[] := array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識'];
  v_bad text;
  v_dims text[];
begin
  perform public.bank_assert_cs();

  if p_question_id is null then
    raise exception '題組編號不可空白';
  end if;
  if p_dims is null then
    raise exception '面向不可為 null（要清除標記請傳空陣列）';
  end if;

  -- 空陣列＝刪除標記，不需要驗證內容；有內容才驗證
  if cardinality(p_dims) > 0 then
    if array_ndims(p_dims) > 1 then
      raise exception '面向格式不正確，必須是一維清單';
    end if;
    if exists (select 1 from unnest(p_dims) as t(d) where t.d is null) then
      raise exception '面向不可有空值';
    end if;

    select t.d into v_bad
    from unnest(p_dims) with ordinality as t(d, n)
    where not (t.d = any(v_ok))
    order by t.n
    limit 1;
    if v_bad is not null then
      raise exception '面向不正確：%（只能是資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識）', v_bad;
    end if;

    if (select count(distinct t.d) from unnest(p_dims) as t(d)) <> cardinality(p_dims) then
      raise exception '面向不可重複';
    end if;
    if cardinality(p_dims) > 3 then
      raise exception '最多只能選 3 個面向（目前 % 個）', cardinality(p_dims);
    end if;
  end if;

  -- 與抽題、題庫管理共用同一把鎖
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  if not exists (select 1 from public.questions q where q.id = p_question_id) then
    raise exception '找不到題組：%', p_question_id;
  end if;

  if cardinality(p_dims) = 0 then
    delete from public.question_dims where question_id = p_question_id;
    return;
  end if;

  -- 依固定順序存（同時去掉順序差異）
  select array_agg(o.d order by o.n) into v_dims
  from unnest(v_ok) with ordinality as o(d, n)
  where o.d = any(p_dims);

  insert into public.question_dims (question_id, dims, updated_at, updated_by)
  values (p_question_id, v_dims, now(), public.roster_my_email())
  on conflict (question_id) do update
    set dims = excluded.dims,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;
end;
$$;

-- ---------- 4. assess_weak_profile：考生的弱項分析 ----------
-- 回傳 jsonb：
--   n          取到的成績單張數（0～3）
--   rates      七個面向（固定順序）各自的平均得分率 [{"dim","pct"}]，沒資料的 pct 為 null
--   weak       5 個可勾選面向中得分率最低的至多 2 個，由低到高 [{"dim","pct"}]
--   always_low 語氣與禮貌、文字品質中平均 < 70 者（依面向固定順序）[{"dim","pct"}]
-- 得分率定義與考核後台 backoffice.html 的 dimRates 一致：
--   以「題組」為單位，把取到的所有題組中該面向的等級百分比取平均
--   （優 100／良 70／待加強 40／不及格 0；「不適用」與未評＝assess_level_pct 回 null，不計入）。
-- 成績單範圍：該員工「已送出（submitted）」的成績單（作廢 voided、草稿 draft 不算），
--   依 submitted_at 由新到舊取最近 3 張（同一時刻再依 created_at、id 由新到舊，結果固定）。
-- 判斷（< 70、取最低 2 個）一律用未四捨五入的平均；輸出的 pct 四捨五入到小數 1 位。
--   平均值是 10 的倍數除以題組數，題組數不到 200 時四捨五入不可能讓 < 70 的值變成 70，所以兩者不會矛盾。
-- weak 並列時（得分率相同）依面向固定順序取先者。完全沒有成績單：n = 0、weak 與 always_low 為空陣列。
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
             where i.assessment_id = any(v_ids)) as pct
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

-- ---------- 5. assess_suggest_pool：建議題組用的整個題庫 ----------
-- 回傳整個題庫（每題一列），供網頁依規則挑選與換題：
--   dims             該題的重點面向標記；未標記為空陣列（不是 null）
--   taken_before     該考生考過這題（以其「已送出」或「已作廢」考核的題組為準，草稿不算；
--                    與 assess_draw 的 v_taken 同一個判斷）
--   drawn_this_round 目前在抽選器 drawn 內（本輪已被抽過）
-- 排序同 bank_list_questions：分類依「第一次出現」（該分類最小 id）、同分類內依 id。
create or replace function public.assess_suggest_pool(p_employee_id text)
returns table(question_id bigint, category text, title text, dims text[],
              taken_before boolean, drawn_this_round boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.assess_assert_cs();

  if not exists (select 1 from public.employees e where e.id = p_employee_id) then
    raise exception '找不到員工：%', p_employee_id;
  end if;

  return query
    select q.id,
           q.category,
           q.title,
           coalesce(qd.dims, '{}'::text[]),
           exists (select 1
                   from public.assessment_items ai
                   join public.assessment_item_secrets sx on sx.item_id = ai.id
                   join public.assessments x on x.id = ai.assessment_id
                   where x.employee_id = p_employee_id
                     and x.status in ('submitted', 'voided')
                     and sx.question_id = q.id),
           exists (select 1 from public.drawn d where d.question_id = q.id)
    from public.questions q
    left join public.question_dims qd on qd.question_id = q.id
    order by min(q.id) over (partition by q.category), q.id;
end;
$$;

-- ---------- 6. assess_pick：用指定題組建立考核題目 ----------
-- 與 assess_draw 的差別只有「題組由呼叫者指定，不再隨機挑」；其餘寫入方式逐項照 assess_draw：
--   * 先鎖該張考核（for update）；只限草稿、只限建立者本人
--   * 同一把 advisory lock（hashtext('exam_draw_questions')）
--   * 每題前：該分類若已全部在 drawn 內，先清掉該分類的 drawn 開新一輪（new_round = true）
--   * repeated：該考生以前考過這題（已送出或已作廢，草稿不算）
--   * was_drawn_before：在寫入 drawn 之前（若剛開新一輪，則是清完之後）這題是否已在 drawn 內
--   * 寫入 drawn（on conflict 更新 drawn_at）、category_last（on conflict 更新題號）、
--     assessment_items（seq 接在目前最大值後面）、assessment_item_secrets
--   * 回傳欄位與 assess_draw 完全相同
-- 題組數上限：assess_draw 唯一的上限是「一場每個分類最多一個題組」（資料表 unique(assessment_id, category)），
--   所以這裡的上限也是同一條：選的題組彼此分類不可重複、也不可與這場已有題組的分類重複
--   （錯誤訊息沿用 assess_draw 的文字）。另外不可選這場已經有的題組。
-- 整個呼叫是單一交易：任何一題不合規就整批回復，不會只寫入一部分。
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

-- ---------- 7. 函式權限：收回 public／anon，只授權 authenticated ----------
-- 客服部與否由函式內部檢查（bank_assert_cs／assess_assert_cs）。
revoke execute on function public.bank_set_dims(bigint, text[])        from public, anon, authenticated;
revoke execute on function public.assess_weak_profile(text)            from public, anon, authenticated;
revoke execute on function public.assess_suggest_pool(text)            from public, anon, authenticated;
revoke execute on function public.assess_pick(uuid, bigint[])          from public, anon, authenticated;

grant execute on function public.bank_set_dims(bigint, text[])         to authenticated;
grant execute on function public.assess_weak_profile(text)             to authenticated;
grant execute on function public.assess_suggest_pool(text)             to authenticated;
grant execute on function public.assess_pick(uuid, bigint[])           to authenticated;

commit;
