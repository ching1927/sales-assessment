-- ============================================================
-- 業務考核系統：第二期「每年健檢」驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 phase1_schema.sql 與 checkup_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市（ZZ-C1～ZZ-C5）／假員工（MI-9701～MI-9799）／假帳號（vr-xxx@2motor.tw，符合 accounts 網域檢查）／
--   假題庫（分類一律 ZZ 開頭），用 set_config('request.jwt.claims', …) ＋ set local role 模擬各角色登入，真的呼叫
--   checkup_quarters_list／checkup_quarter_set／checkup_roster／checkup_schedule／checkup_unschedule／checkup_begin 與
--   既有的 assess_start／assess_draw／assess_save_item／assess_submit／assess_void／assess_abandon／improve_close／
--   assess_weak_profile 等函式，把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
--   測試年度用 2031／2032／2033（避免和真實資料撞在一起）。腳本不會更新任何真實員工列。
-- 怎麼看結果：
--   * 因為 SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     腳本在 rollback 之前把結果表存成「預備陳述式 ck_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；有失敗時會附上「第一個失敗」的序號、測項與實際錯誤訊息
--     （以及全部未通過序號，最多列 20 個）。「通過」欄全是「通過」才算驗證成功。預期看到「N/N 項通過」。
-- 注意：
--   * 區段 2「門市季次種子」檢查真實資料表：必須在客服部改過季次「之前」跑；若已改過，那三項失敗屬預期。
--   * 假題庫的 questions.id 會用掉幾個流水號（序號不會因 rollback 倒退），無害。
--   * 腳本會暫時改 app_settings.exam_core_categories 成假分類（交易內，rollback 後原樣保留）。
--   * 第一次執行請選在沒人抽題的時段（腳本執行期間有人抽題，收尾的「真實題庫筆數沒變」比對可能誤報）。
--   * 全程都用 begin…rollback 包住；請不要在中途自己手動下 commit。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯停下（rollback 後無影響），不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.checkups') is null
     or to_regclass('public.checkup_store_quarter') is null
     or to_regprocedure('public.checkup_roster(int, int)') is null
     or to_regprocedure('public.checkup_begin(text, int, int)') is null
     or to_regprocedure('public.checkup_schedule(text, int, int, timestamptz, text)') is null
     or to_regprocedure('public.checkup_unschedule(uuid)') is null
     or to_regprocedure('public.checkup_quarter_set(text, int)') is null
     or to_regprocedure('public.checkup_quarters_list()') is null then
    raise exception '請先執行 checkup_schema.sql';
  end if;
  if to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_draw(uuid, text[])') is null
     or to_regprocedure('public.assess_submit(uuid)') is null
     or to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is null
     or to_regprocedure('public.improve_close(uuid, uuid, text)') is null
     or to_regclass('public.reply_activations') is null then
    raise exception '請先執行既有的 assess／backoffice／phase1 各 schema';
  end if;
end
$$;

-- ---------- 驗證工具（全部是暫存物件，rollback 後消失） ----------
create temp table vr (
  n int generated always as identity primary key,
  grp text,
  name text,
  expected text,
  actual text,
  pass boolean
);
create temp table vr_ctx (k text primary key, v text);

create or replace function pg_temp.vr_rec(p_grp text, p_name text, p_expected text, p_actual text, p_pass boolean)
returns void language plpgsql as $$
begin
  insert into pg_temp.vr (grp, name, expected, actual, pass)
  values (p_grp, p_name, p_expected, coalesce(p_actual, '(null)'), coalesce(p_pass, false));
end $$;

create or replace function pg_temp.vr_eq(p_grp text, p_name text, p_expected text, p_actual text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_rec(p_grp, p_name, p_expected, p_actual, p_expected is not distinct from p_actual);
end $$;

create or replace function pg_temp.vr_set(p_k text, p_v text)
returns void language plpgsql as $$
begin
  insert into pg_temp.vr_ctx values (p_k, p_v)
  on conflict (k) do update set v = excluded.v;
end $$;

create or replace function pg_temp.vr_get(p_k text)
returns text language sql as $$
  select v from pg_temp.vr_ctx where k = p_k;
$$;

-- 以目前身分（資料庫擁有者）執行單一值查詢，回傳文字；沒有值回 '(null)'
create or replace function pg_temp.vr_q1(p_sql text)
returns text language plpgsql as $$
declare
  v text;
begin
  execute p_sql into v;
  return coalesce(v, '(null)');
end $$;

-- 以擁有者身分執行一段 SQL（不換角色）；成功回 'OK'，失敗回 'ERROR: 訊息'（子交易自動回復）
create or replace function pg_temp.vr_owner(p_sql text)
returns text language plpgsql as $$
begin
  begin
    execute p_sql;
    return 'OK';
  exception when others then
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

-- 以指定資料庫角色（authenticated／anon）＋指定 email 執行一段 SQL。
-- p_scalar = true：SQL 必須回傳單一值，回傳該值的文字；false：只執行，成功回 'OK'。
-- 失敗回 'ERROR: 訊息'。失敗時子交易自動回復，不會讓整個腳本中斷。
-- p_email 為 null＝沒有登入者（JWT 為空）。
create or replace function pg_temp.vr_as(p_role text, p_email text, p_sql text, p_scalar boolean)
returns text language plpgsql as $$
declare
  v_res text;
begin
  perform set_config('request.jwt.claims',
    case when p_email is null then ''
         else json_build_object('email', p_email, 'role', p_role)::text end,
    true);
  begin
    execute format('set local role %I', p_role);
    if p_scalar then
      execute p_sql into v_res;
    else
      execute p_sql;
      v_res := 'OK';
    end if;
    reset role;
    return coalesce(v_res, '(null)');
  exception when others then
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

-- 預期「成功」：以 authenticated 身分執行，結果應為 OK
create or replace function pg_temp.vr_ok(p_grp text, p_name text, p_email text, p_sql text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_eq(p_grp, p_name, 'OK', pg_temp.vr_as('authenticated', p_email, p_sql, false));
end $$;

-- 預期「被拒」：結果應為 ERROR 開頭且訊息符合 like 樣式；p_role 可為 authenticated 或 anon
create or replace function pg_temp.vr_deny(p_grp text, p_name text, p_role text, p_email text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare
  v_r text := pg_temp.vr_as(p_role, p_email, p_sql, false);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r,
                         v_r like 'ERROR: ' || p_pattern);
end $$;

-- 客服部（vr-cs）身分的捷徑
create or replace function pg_temp.vr_cs(p_sql text, p_scalar boolean default true)
returns text language sql as $$
  select pg_temp.vr_as('authenticated', 'vr-cs@2motor.tw', p_sql, p_scalar);
$$;

create or replace function pg_temp.vr_csok(p_grp text, p_name text, p_sql text)
returns void language sql as $$
  select pg_temp.vr_ok(p_grp, p_name, 'vr-cs@2motor.tw', p_sql);
$$;

create or replace function pg_temp.vr_csdeny(p_grp text, p_name text, p_sql text, p_pattern text)
returns void language sql as $$
  select pg_temp.vr_deny(p_grp, p_name, 'authenticated', 'vr-cs@2motor.tw', p_sql, p_pattern);
$$;



-- 以下是本檔專用的小工具（暫存物件，rollback 後消失）

-- 七個面向的評分物件：依序＝資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識、語氣與禮貌、文字品質
create or replace function pg_temp.p1_lv(a text, b text, c text, d text, e text, f text, g text)
returns jsonb language sql as $$
  select jsonb_build_object('資訊正確性', a, '預設訊息運用', b, '問題掌握', c, '主動引導', d,
                            '風險意識', e, '語氣與禮貌', f, '文字品質', g);
$$;

create or replace function pg_temp.p1_all(a text)
returns jsonb language sql as $$
  select pg_temp.p1_lv(a, a, a, a, a, a, a);
$$;

-- 台北今天
create or replace function pg_temp.p1_today()
returns date language sql as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

-- 造一位假員工：p_hire_ago＝到職距今天數（null＝未填）、p_period＝考核期／已上線、p_prob_ago＝probation_since 距今天數（null＝無）
create or replace function pg_temp.p1_emp(p_id text, p_store text, p_hire_ago int, p_period text,
                                          p_prob_ago int default null, p_include boolean default true,
                                          p_status text default '在職')
returns void language plpgsql as $$
begin
  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status, probation_since)
  values
    (p_id, '假員' || right(p_id, 4), p_store, '業務',
     case when p_hire_ago is null then null else pg_temp.p1_today() - p_hire_ago end,
     p_status, p_include, p_period,
     case when p_prob_ago is null then null else pg_temp.p1_today() - p_prob_ago end);
end $$;

-- 核心分類（讀設定，擁有者身分）
create or replace function pg_temp.p1_core()
returns text[] language sql as $$
  select string_to_array((select s.value from public.app_settings s where s.key = 'exam_core_categories'), ',');
$$;

-- 以擁有者身分直接造一張成績單（status = submitted／voided／draft）與核心題組（levels 陣列）；
-- p_verdict 只給 submitted／voided 用；p_extras 為追加題的 levels 陣列（可 null）。回傳成績單 id。
create or replace function pg_temp.p1_mkrep(p_emp text, p_status text, p_verdict text, p_items jsonb,
                                            p_extras jsonb default null, p_tenure text default '正式',
                                            p_examiner text default null)
returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_item uuid;
  v_ex text := coalesce(p_examiner,
                 'vr-ex-' || substr(md5(random()::text || clock_timestamp()::text), 1, 10) || '@2motor.tw');
  v_store text;
  i int;
  n int;
begin
  select e.store_code into v_store from public.employees e where e.id = p_emp;
  if p_status = 'submitted' then
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure,
                                    tenure_source, total_score, verdict, pass_line, submitted_at)
    values (p_emp, 'x', v_store, v_ex, 'submitted', p_tenure, '自動', 80, p_verdict,
            case when p_tenure = '新人' then 70 else 85 end, now() - interval '1 hour')
    returning id into v_id;
  elsif p_status = 'voided' then
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure,
                                    tenure_source, total_score, verdict, pass_line, submitted_at,
                                    voided_at, voided_by, void_reason)
    values (p_emp, 'x', v_store, v_ex, 'voided', p_tenure, '自動', 80, p_verdict,
            case when p_tenure = '新人' then 70 else 85 end, now() - interval '1 hour',
            now(), 'x', '測試作廢')
    returning id into v_id;
  else
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure,
                                    tenure_source)
    values (p_emp, 'x', v_store, v_ex, 'draft', p_tenure, '自動')
    returning id into v_id;
  end if;

  n := coalesce(jsonb_array_length(p_items), 0);
  for i in 1 .. n loop
    insert into public.assessment_items (assessment_id, seq, category, code, levels)
    values (v_id, i, 'ZZ報' || i, null, p_items -> (i - 1));
  end loop;
  for i in 1 .. coalesce(jsonb_array_length(p_extras), 0) loop
    insert into public.assessment_items (assessment_id, seq, category, code, levels, is_extra)
    values (v_id, n + i, 'ZZ報' || i, null, p_extras -> (i - 1), true);
  end loop;
  return v_id;
end $$;

-- 客服部開一場：assess_start ＋ assess_draw（預設用設定裡的核心分類）。回傳成績單 id；失敗直接丟例外。
create or replace function pg_temp.p1_open(p_emp text, p_cats text default null, p_ex text default 'vr-cs@2motor.tw')
returns uuid language plpgsql as $$
declare
  v_a text;
  v_r text;
  v_cats text[] := coalesce(string_to_array(p_cats, ','), pg_temp.p1_core());
begin
  v_a := pg_temp.vr_as('authenticated', p_ex, format('select public.assess_start(%L, null)::text', p_emp), true);
  if v_a like 'ERROR%' then raise exception '開考核失敗：%', v_a; end if;
  v_r := pg_temp.vr_as('authenticated', p_ex,
           format('select count(*)::text from public.assess_draw(%L::uuid, %L::text[])', v_a, v_cats::text), true);
  if v_r like 'ERROR%' then raise exception '抽題失敗：%', v_r; end if;
  return v_a::uuid;
end $$;

-- 替某場的第 p_seq 個題組評分（assess_save_item 四參數版）；成功回 OK，失敗回 ERROR: 訊息
create or replace function pg_temp.p1_rate(p_a uuid, p_seq int, p_levels jsonb, p_ex text default 'vr-cs@2motor.tw')
returns text language plpgsql as $$
declare
  v_i uuid;
begin
  select i.id into v_i from public.assessment_items i where i.assessment_id = p_a and i.seq = p_seq;
  if v_i is null then return 'ERROR: 沒有第 ' || p_seq || ' 題組'; end if;
  return pg_temp.vr_as('authenticated', p_ex,
           format('select public.assess_save_item(%L::uuid, %L::jsonb, null, null)', v_i, p_levels::text), false);
end $$;

-- 一次評前三個核心題組
create or replace function pg_temp.p1_rate3(p_a uuid, l1 jsonb, l2 jsonb, l3 jsonb, p_ex text default 'vr-cs@2motor.tw')
returns text language plpgsql as $$
declare
  r text;
begin
  r := pg_temp.p1_rate(p_a, 1, l1, p_ex);
  if r <> 'OK' then return r; end if;
  r := pg_temp.p1_rate(p_a, 2, l2, p_ex);
  if r <> 'OK' then return r; end if;
  return pg_temp.p1_rate(p_a, 3, l3, p_ex);
end $$;

-- 送出：成功回「總分/判定/合格線/題組數/身分」，失敗回 ERROR: 訊息
create or replace function pg_temp.p1_submit(p_a uuid, p_ex text default 'vr-cs@2motor.tw')
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_ex,
    format($q$select s.total_score::text || '/' || s.verdict || '/' || s.pass_line::text || '/' || s.item_count::text || '/' || s.tenure
              from public.assess_submit(%L::uuid) s$q$, p_a), true);
$$;

-- 這場裡還沒有的某分類題組 id（擁有者身分）；p_n 取第幾個（從 1 起，依 id）
create or replace function pg_temp.p1_freeq(p_a uuid, p_cat text, p_n int default 1)
returns bigint language sql as $$
  select q.id from public.questions q
  where q.category = p_cat
    and not exists (select 1 from public.assessment_items i
                    join public.assessment_item_secrets sx on sx.item_id = i.id
                    where i.assessment_id = p_a and sx.question_id = q.id)
  order by q.id
  offset p_n - 1 limit 1;
$$;

-- 追加題：成功回「新增列數」，失敗回 ERROR: 訊息
create or replace function pg_temp.p1_extra(p_a uuid, p_ids bigint[], p_ex text default 'vr-cs@2motor.tw')
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_ex,
    format('select count(*)::text from public.assess_add_extra(%L::uuid, %L::bigint[])', p_a, p_ids::text), true);
$$;

-- 成績單的核心／追加題組數（擁有者身分）
create or replace function pg_temp.p1_cnt(p_a uuid)
returns text language sql as $$
  select (select count(*) from public.assessment_items i where i.assessment_id = p_a and not i.is_extra)::text
         || '/' || (select count(*) from public.assessment_items i where i.assessment_id = p_a and i.is_extra)::text;
$$;

-- 員工目前狀態：「考核期狀態/probation_since 有無/通過日」
create or replace function pg_temp.p1_st(p_emp text)
returns text language sql as $$
  select e.period_status || '/' || case when e.probation_since is null then '無' else '有' end
         || '/' || coalesce(e.passed_on::text, '-')
  from public.employees e where e.id = p_emp;
$$;

-- 員工的待開通筆數
create or replace function pg_temp.p1_act(p_emp text)
returns text language sql as $$
  select count(*)::text from public.reply_activations r where r.employee_id = p_emp;
$$;

-- 所有 public 函式「原始碼＋屬性」的指紋（排除本檔不會動的以外，全部列入；用來確認本腳本沒有改到任何函式）
create or replace function pg_temp.p1_fnmd5()
returns text language sql as $$
  select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid))
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f';
$$;

-- 以下是本檔專用的小工具（暫存物件，rollback 後消失）

-- 造一位假員工：p_period＝考核期／已上線、p_passed＝通過日、p_prob_ago＝probation_since 距今天數（null＝無）
create or replace function pg_temp.ck_emp(p_id text, p_store text, p_period text default '已上線', p_passed date default null,
                                          p_include boolean default true, p_status text default '在職',
                                          p_prob_ago int default null, p_hire_ago int default 400)
returns void language plpgsql as $$
begin
  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status, passed_on, probation_since)
  values
    (p_id, '假員' || right(p_id, 4), p_store, '業務', pg_temp.p1_today() - p_hire_ago, p_status, p_include, p_period, p_passed,
     case when p_prob_ago is null then null else pg_temp.p1_today() - p_prob_ago end);
end $$;

-- 健檢名單（只看假員工 MI-97xx），回傳「編號,編號」；p_email 為登入者
create or replace function pg_temp.ck_ros(p_email text, p_year int, p_q int)
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_email,
    format($q$select coalesce(string_agg(employee_id, ',' order by employee_id), '(空)') from public.checkup_roster(%s, %s) where employee_id like 'MI-97%%'$q$, p_year, p_q), true);
$$;

-- 某人在名單中的某欄位（客服部視角）；找不到回 (null)
create or replace function pg_temp.ck_col(p_email text, p_year int, p_q int, p_emp text, p_col text)
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_email,
    format($q$select %I::text from public.checkup_roster(%s, %s) where employee_id = %L$q$, p_col, p_year, p_q, p_emp), true);
$$;

-- 開始健檢（客服部 vr-cs）：成功回成績單 id，失敗回 ERROR: 訊息
create or replace function pg_temp.ck_begin(p_emp text, p_year int, p_q int, p_ex text default 'vr-cs@2motor.tw')
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_ex, format($q$select public.checkup_begin(%L, %s, %s)::text$q$, p_emp, p_year, p_q), true);
$$;

-- 排定（客服部 vr-cs）：成功回 checkups.id，失敗回 ERROR: 訊息
create or replace function pg_temp.ck_sched(p_emp text, p_year int, p_q int, p_note text default null, p_ex text default 'vr-cs@2motor.tw')
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_ex,
    format($q$select public.checkup_schedule(%L, %s, %s, now() + interval '3 days', %L)::text$q$, p_emp, p_year, p_q, p_note), true);
$$;

-- 對一張草稿抽核心 3 題並評完 3 個題組；成功回 OK
create or replace function pg_temp.ck_rate(p_a uuid, p_core jsonb, p_ex text default 'vr-cs@2motor.tw')
returns text language plpgsql as $$
declare r text;
begin
  r := pg_temp.vr_as('authenticated', p_ex,
         format('select count(*)::text from public.assess_draw(%L::uuid, %L::text[])', p_a, pg_temp.p1_core()::text), true);
  if r like 'ERROR%' then return r; end if;
  return pg_temp.p1_rate3(p_a, p_core -> 0, p_core -> 1, p_core -> 2, p_ex);
end $$;

-- 員工那一列的指紋（含 updated_at）
create or replace function pg_temp.ck_empfp(p_emp text)
returns text language sql as $$
  select md5(row_to_json(e)::text) from public.employees e where e.id = p_emp;
$$;

-- 全域計數指紋：待開通、改善單、待考回報（編號與狀態）、抽查回考核期
create or replace function pg_temp.ck_sidefx()
returns text language sql as $$
  select (select count(*) from public.reply_activations)::text || '/'
      || (select count(*) from public.improvement_tickets)::text || '/'
      || coalesce((select string_agg(r.id::text || r.status, ',' order by r.id) from public.exam_requests r), '') || '/'
      || coalesce((select string_agg(p.id::text || p.status, ',' order by p.id) from public.spot_probations p), '');
$$;

-- 以擁有者身分直接造一張健檢成績單（kind=checkup）
create or replace function pg_temp.ck_mkchk(p_emp text, p_status text, p_year int, p_tenure text default '正式')
returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_store text;
begin
  select e.store_code into v_store from public.employees e where e.id = p_emp;
  if p_status = 'draft' then
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
                                    kind, checkup_year, checkup_quarter)
    values (p_emp, 'x', v_store, 'vr-raw@2motor.tw', 'draft', p_tenure, '自動', 'checkup', p_year, 1)
    returning id into v_id;
  else
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
                                    total_score, verdict, pass_line, submitted_at, kind, checkup_year, checkup_quarter)
    values (p_emp, 'x', v_store, 'vr-raw@2motor.tw', 'submitted', p_tenure, '自動', 90, '及格', 85, now(), 'checkup', p_year, 1)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- ============================================================
-- 建立假資料與基準（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- 假員工 MI-9701～MI-9799；假門市 ZZ-C1～ZZ-C5（ZZ-C1～C4 在測試中指定為 Q1～Q4，ZZ-C5 不在季次表內）；測試年度 2031
-- ============================================================
do $$
declare
  c int;
  k int;
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.vr_set('fn_md5', pg_temp.p1_fnmd5());
  perform pg_temp.vr_set('real_questions',
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_set('real_drawn',
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_set('real_last',
    (select count(*)::text from public.category_last where category not like 'ZZ%'));

  insert into public.stores (code, name) values
    ('ZZ-C1', 'ZZ健檢門市1'), ('ZZ-C2', 'ZZ健檢門市2'), ('ZZ-C3', 'ZZ健檢門市3'), ('ZZ-C4', 'ZZ健檢門市4'), ('ZZ-C5', 'ZZ健檢門市5');

  insert into public.app_users (email, role, store_code) values
    ('vr-cs@2motor.tw',  'cs_admin',      null),
    ('vr-cs2@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm@2motor.tw',  'store_manager', 'ZZ-C1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-C2');

  -- 假題庫：核心三類各 12 題
  for c in 1 .. 3 loop
    for k in 1 .. 12 loop
      insert into public.questions (category, code, title, steps)
      values ('ZZ核' || c, 'K' || c || k, '假題組K' || c || k, '[{"action":"動作","point":"考點"}]'::jsonb);
    end loop;
  end loop;
  insert into public.app_settings (key, value) values ('exam_core_categories', 'ZZ核1,ZZ核2,ZZ核3')
  on conflict (key) do update set value = excluded.value;

  -- 假門市的季次（測試用，擁有者身分直接寫入）
  insert into public.checkup_store_quarter (store_code, quarter, updated_by) values
    ('ZZ-C1', 1, 'seed'), ('ZZ-C2', 2, 'seed'), ('ZZ-C3', 3, 'seed'), ('ZZ-C4', 4, 'seed');

  -- Q1／ZZ-C1：9701 一般；9702 考核期；9703 離職；9704 不納入；9705 通過日 2030-12-31（早於季初）；
  --   9706 通過日 2031-01-01（剛好季初，不早於）；9707 通過日 2031-02-15；9713 已上線但 probation_since 有值（異常資料）；9714 備用
  perform pg_temp.ck_emp('MI-9701', 'ZZ-C1');
  perform pg_temp.ck_emp('MI-9702', 'ZZ-C1', '考核期');
  perform pg_temp.ck_emp('MI-9703', 'ZZ-C1', '已上線', null, true, '離職');
  perform pg_temp.ck_emp('MI-9704', 'ZZ-C1', '已上線', null, false);
  perform pg_temp.ck_emp('MI-9705', 'ZZ-C1', '已上線', date '2030-12-31');
  perform pg_temp.ck_emp('MI-9706', 'ZZ-C1', '已上線', date '2031-01-01');
  perform pg_temp.ck_emp('MI-9707', 'ZZ-C1', '已上線', date '2031-02-15');
  perform pg_temp.ck_emp('MI-9713', 'ZZ-C1', '已上線', null, true, '在職', 5);
  perform pg_temp.ck_emp('MI-9714', 'ZZ-C1');
  -- Q2／ZZ-C2：9708 一般；9709 通過日 2031-03-31（早於 4/1）；9710 通過日 2031-04-01（不早於）
  perform pg_temp.ck_emp('MI-9708', 'ZZ-C2');
  perform pg_temp.ck_emp('MI-9709', 'ZZ-C2', '已上線', date '2031-03-31');
  perform pg_temp.ck_emp('MI-9710', 'ZZ-C2', '已上線', date '2031-04-01');
  -- Q3／ZZ-C3、Q4／ZZ-C4
  perform pg_temp.ck_emp('MI-9711', 'ZZ-C3');
  perform pg_temp.ck_emp('MI-9712', 'ZZ-C4');
  -- 不在任何季次的門市 ZZ-C5：一般考核回歸測試用
  perform pg_temp.ck_emp('MI-9721', 'ZZ-C5', '考核期', null, true, '在職', null, 20);
  perform pg_temp.ck_emp('MI-9722', 'ZZ-C5');
  perform pg_temp.ck_emp('MI-9723', 'ZZ-C5', '考核期', null, true, '在職', 5);
  perform pg_temp.ck_emp('MI-9724', 'ZZ-C5', '考核期', null, true, '在職', 5);
  perform pg_temp.ck_emp('MI-9726', 'ZZ-C5', '考核期', null, true, '在職', 5);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：結構、授權、RLS
-- ============================================================
do $$
declare
  f text;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.vr_eq('1 結構', 'assessments 新欄位 kind／checkup_year／checkup_quarter', 'kind:text:NO:''exam''::text,checkup_year:integer:YES:-,checkup_quarter:integer:YES:-',
    pg_temp.vr_q1($q$select string_agg(column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '-'), ',' order by ordinal_position)
      from information_schema.columns where table_schema = 'public' and table_name = 'assessments' and column_name in ('kind','checkup_year','checkup_quarter')$q$));
  perform pg_temp.vr_eq('1 結構', '既有成績單全是 kind=exam（沒有 checkup、沒有年度）', 'true',
    pg_temp.vr_q1($q$select (not exists (select 1 from public.assessments where kind <> 'exam' and employee_id not like 'MI-97%')
                              and not exists (select 1 from public.assessments where employee_id not like 'MI-97%' and (checkup_year is not null or checkup_quarter is not null)))::text$q$));
  perform pg_temp.vr_eq('1 結構', '三個新資料表開啟 RLS', 'true/true',
    pg_temp.vr_q1($q$select (select relrowsecurity from pg_class where oid = 'public.checkups'::regclass)::text || '/' ||
                            (select relrowsecurity from pg_class where oid = 'public.checkup_store_quarter'::regclass)::text$q$));
  perform pg_temp.vr_eq('1 結構', '檢視 assessment_summaries 欄位順序：原 19 欄不變，尾端追加 kind、checkup_year、checkup_quarter',
    'id,employee_id,employee_label,store_code,store_name,assessed_on,created_at,submitted_at,examiner_email,tenure,tenure_source,total_score,verdict,pass_line,weakest_dims,status,voided_at,void_reason,item_count,kind,checkup_year,checkup_quarter',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'assessment_summaries'$q$));
  perform pg_temp.vr_eq('1 結構', '檢視 analytics_dim_rates 欄位完全沒變（8 欄；要區分健檢請用 assessment_id 對 assessment_summaries.kind）',
    'assessment_id,employee_id,store_code,submitted_at,item_id,seq,dim,level_pct',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema = 'public' and table_name = 'analytics_dim_rates'$q$));
  perform pg_temp.vr_eq('1 結構', '兩個檢視仍是 security_invoker（RLS 照樣生效）', 'true/true',
    pg_temp.vr_q1($q$select (select coalesce('security_invoker=true' = any(reloptions), false) from pg_class where oid = 'public.assessment_summaries'::regclass)::text || '/' ||
                            (select coalesce('security_invoker=true' = any(reloptions), false) from pg_class where oid = 'public.analytics_dim_rates'::regclass)::text$q$));
  perform pg_temp.vr_eq('1 結構', '索引 assessments_one_draft_per_pair 改成只管 kind=exam', 'true',
    pg_temp.vr_q1($q$select (indexdef like '%status = ''draft''%' and indexdef like '%kind = ''exam''%' and indexdef like '%UNIQUE%')::text from pg_indexes where schemaname='public' and indexname='assessments_one_draft_per_pair'$q$));
  perform pg_temp.vr_eq('1 結構', '索引 assessments_one_checkup_per_year（同員工同年度一張未作廢健檢）', 'true',
    pg_temp.vr_q1($q$select (indexdef like '%(employee_id, checkup_year)%' and indexdef like '%UNIQUE%' and indexdef like '%kind = ''checkup''%' and indexdef like '%voided%')::text from pg_indexes where schemaname='public' and indexname='assessments_one_checkup_per_year'$q$));
  perform pg_temp.vr_eq('1 結構', '既有索引都還在', '4',
    pg_temp.vr_q1($q$select count(*)::text from pg_indexes where schemaname='public' and indexname in ('assessments_pkey','assessments_employee_idx','assessments_store_status_idx','assessments_one_draft_per_pair')$q$));
  perform pg_temp.vr_eq('1 結構', '既有觸發器都還在（改善單自動開／取消、待考回報自動完成）', '3',
    pg_temp.vr_q1($q$select count(*)::text from pg_trigger where tgrelid = 'public.assessments'::regclass and not tgisinternal and tgname in ('exam_req_auto_complete_trg','improvement_auto_cancel_trg','improvement_auto_open_trg')$q$));
  perform pg_temp.vr_eq('1 結構', 'checkups unique(employee_id, year)', 'true',
    pg_temp.vr_q1($q$select (count(*) = 1)::text from pg_constraint where conrelid='public.checkups'::regclass and contype='u' and pg_get_constraintdef(oid) like '%(employee_id, year)%'$q$));
  perform pg_temp.vr_eq('1 結構', 'checkups 欄位', 'id,employee_id,year,quarter,store_code,scheduled_at,scheduled_by,note,assessment_id,created_at',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='checkups'$q$));
  perform pg_temp.vr_eq('1 結構', 'checkup_store_quarter 欄位', 'store_code,quarter,updated_at,updated_by',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns where table_schema='public' and table_name='checkup_store_quarter'$q$));
  for f in select unnest(array['checkup_quarters_list()', 'checkup_quarter_set(text,int)', 'checkup_roster(int,int)',
                              'checkup_schedule(text,int,int,timestamptz,text)', 'checkup_unschedule(uuid)', 'checkup_begin(text,int,int)']) loop
    perform pg_temp.vr_eq('1 授權', f || '：authenticated 可執行、anon／public 不可', 'true/false',
      pg_temp.vr_q1(format($q$select has_function_privilege('authenticated', 'public.%s', 'execute')::text || '/' ||
                              has_function_privilege('anon', 'public.%s', 'execute')::text$q$, f, f)));
  end loop;
  perform pg_temp.vr_eq('1 授權', '內部函式 checkup_first_day／checkup_eligible 連 authenticated 都不能執行', 'false/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.checkup_first_day(int,int)', 'execute')::text || '/' ||
                            has_function_privilege('authenticated', 'public.checkup_eligible(text,int,int)', 'execute')::text$q$));
  perform pg_temp.vr_eq('1 授權', '被改寫函式權限沿用：assess_start／assess_submit／assess_weak_profile／improve_close authenticated 可執行、anon 不可', 'true/false',
    pg_temp.vr_q1($q$select (has_function_privilege('authenticated','public.assess_start(text,text)','execute') and has_function_privilege('authenticated','public.assess_submit(uuid)','execute')
                             and has_function_privilege('authenticated','public.assess_weak_profile(text)','execute') and has_function_privilege('authenticated','public.improve_close(uuid,uuid,text)','execute'))::text || '/' ||
                            (has_function_privilege('anon','public.assess_start(text,text)','execute') or has_function_privilege('anon','public.assess_submit(uuid)','execute')
                             or has_function_privilege('anon','public.assess_weak_profile(text)','execute') or has_function_privilege('anon','public.improve_close(uuid,uuid,text)','execute'))::text$q$));
  perform pg_temp.vr_eq('1 授權', '觸發器函式與 phase1_migrate 仍不開放網頁角色', 'false',
    pg_temp.vr_q1($q$select (has_function_privilege('authenticated','public.improvement_auto_open()','execute') or has_function_privilege('authenticated','public.exam_req_auto_complete()','execute')
                             or has_function_privilege('authenticated','public.phase1_migrate_period_status()','execute'))::text$q$));
  -- 直接寫入全被擋
  perform pg_temp.vr_deny('1 授權', 'authenticated（客服部）不能直接 insert checkups', 'authenticated', 'vr-cs@2motor.tw',
    $q$insert into public.checkups (employee_id, year, quarter, store_code, scheduled_at, scheduled_by) values ('MI-9701', 2031, 1, 'ZZ-C1', now(), 'x')$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', 'authenticated（客服部）不能直接 update checkup_store_quarter', 'authenticated', 'vr-cs@2motor.tw',
    $q$update public.checkup_store_quarter set quarter = 4 where store_code = 'ZZ-C1'$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', 'authenticated（客服部）不能直接 delete checkups', 'authenticated', 'vr-cs@2motor.tw',
    $q$delete from public.checkups$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', 'anon 不能讀 checkups', 'anon', null, $q$select count(*) from public.checkups$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', 'anon 不能讀 checkup_store_quarter', 'anon', null, $q$select count(*) from public.checkup_store_quarter$q$, '%permission denied%');
  -- 兩張新表：網頁角色（客服部、主管、店長、無角色、anon）直接 select 一律被擋；任何寫入權限也都沒有
  perform pg_temp.vr_deny('1 授權', '店長直接 select checkups 被擋（scheduled_by／note／assessment_id 不外洩）', 'authenticated', 'vr-sm@2motor.tw', $q$select scheduled_by, note, assessment_id from public.checkups$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', '主管直接 select checkups 被擋', 'authenticated', 'vr-hq@2motor.tw', $q$select scheduled_by from public.checkups$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', '客服部直接 select checkups 被擋（一律走函式）', 'authenticated', 'vr-cs@2motor.tw', $q$select count(*) from public.checkups$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', '店長直接 select checkup_store_quarter 被擋（updated_by 不外洩）', 'authenticated', 'vr-sm@2motor.tw', $q$select store_code, updated_by from public.checkup_store_quarter$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', '主管直接 select checkup_store_quarter 被擋', 'authenticated', 'vr-hq@2motor.tw', $q$select updated_by from public.checkup_store_quarter$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', '客服部直接 select checkup_store_quarter 被擋', 'authenticated', 'vr-cs@2motor.tw', $q$select count(*) from public.checkup_store_quarter$q$, '%permission denied%');
  perform pg_temp.vr_eq('1 授權', '兩張新表：authenticated／anon 的 select、insert、update、delete、truncate、references、trigger 權限全部沒有', 'false',
    pg_temp.vr_q1($q$select coalesce(bool_or(has_table_privilege(r, t, p)), false)::text
      from unnest(array['authenticated','anon']) r, unnest(array['public.checkups','public.checkup_store_quarter']) t,
           unnest(array['select','insert','update','delete','truncate','references','trigger']) p$q$));
  perform pg_temp.vr_deny('1 授權', '店長不能直接 insert checkup_store_quarter', 'authenticated', 'vr-sm@2motor.tw', $q$insert into public.checkup_store_quarter (store_code, quarter) values ('ZZ-C5', 1)$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', '主管不能直接 update checkups', 'authenticated', 'vr-hq@2motor.tw', $q$update public.checkups set note = 'x'$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 授權', 'authenticated 不能呼叫內部函式 checkup_seed_assert', 'authenticated', 'vr-cs@2motor.tw', $q$select public.checkup_seed_assert(array['x'])$q$, '%permission denied%');
  -- check 約束
  perform pg_temp.vr_eq('1 約束', '健檢成績單身分只能是正式（新人被擋）', 'true',
    (pg_temp.vr_owner($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind, checkup_year, checkup_quarter)
        values ('MI-9701', 'x', 'ZZ-C1', 'vr-raw@2motor.tw', 'draft', '新人', '自動', 'checkup', 2040, 1)$q$) like 'ERROR: %assessments_checkup_formal%')::text);
  perform pg_temp.vr_eq('1 約束', 'kind=exam 不能帶健檢年度', 'true',
    (pg_temp.vr_owner($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind, checkup_year, checkup_quarter)
        values ('MI-9701', 'x', 'ZZ-C1', 'vr-raw@2motor.tw', 'draft', '正式', '自動', 'exam', 2040, 1)$q$) like 'ERROR: %assessments_kind_fields%')::text);
  perform pg_temp.vr_eq('1 約束', 'kind=checkup 必須有年度與季次', 'true',
    (pg_temp.vr_owner($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind)
        values ('MI-9701', 'x', 'ZZ-C1', 'vr-raw@2motor.tw', 'draft', '正式', '自動', 'checkup')$q$) like 'ERROR: %assessments_kind_fields%')::text);
  perform pg_temp.vr_eq('1 約束', 'kind=checkup 季次必須 1～4', 'true',
    (pg_temp.vr_owner($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind, checkup_year, checkup_quarter)
        values ('MI-9701', 'x', 'ZZ-C1', 'vr-raw@2motor.tw', 'draft', '正式', '自動', 'checkup', 2040, 5)$q$) like 'ERROR: %assessments_kind_fields%')::text);
  perform pg_temp.vr_eq('1 約束', 'kind 只能是 exam／checkup', 'true',
    (pg_temp.vr_owner($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind)
        values ('MI-9701', 'x', 'ZZ-C1', 'vr-raw@2motor.tw', 'draft', '正式', '自動', 'other')$q$) like 'ERROR: %assessments_kind_%')::text);
exception when others then
  perform pg_temp.vr_rec('區段 1','結構測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：門市季次種子
-- ============================================================
do $$
declare
  v_exp text;
begin
  perform set_config('request.jwt.claims', '', true);
  select string_agg(v.c || v.q, ',' order by v.c) into v_exp
  from (values ('中和', 1), ('新莊', 1), ('樹林', 1), ('桃園中壢', 2), ('新竹', 2), ('花蓮', 2),
               ('旗艦', 3), ('南台中', 3), ('太平', 3), ('台南', 4), ('高雄', 4)) as v(c, q);
  perform pg_temp.vr_eq('2 季次種子', '11 家門市都有季次（若客服部已改過季次，這三項失敗屬預期，請在改季次之前驗證）', '11',
    pg_temp.vr_q1($q$select count(*)::text from public.checkup_store_quarter where store_code in ('中和','新莊','樹林','桃園中壢','新竹','花蓮','旗艦','南台中','太平','台南','高雄')$q$));
  perform pg_temp.vr_eq('2 季次種子', '各季門市數 Q1/Q2/Q3/Q4 ＝ 3/3/3/2', '3/3/3/2',
    pg_temp.vr_q1($q$select count(*) filter (where quarter=1)::text || '/' || count(*) filter (where quarter=2)::text || '/' || count(*) filter (where quarter=3)::text || '/' || count(*) filter (where quarter=4)::text
      from public.checkup_store_quarter where store_code in ('中和','新莊','樹林','桃園中壢','新竹','花蓮','旗艦','南台中','太平','台南','高雄')$q$));
  perform pg_temp.vr_eq('2 季次種子', '每家門市的季次與老闆指定一致（Q1 中和新莊樹林；Q2 桃園中壢新竹花蓮；Q3 旗艦南台中太平；Q4 台南高雄）', v_exp,
    pg_temp.vr_q1($q$select string_agg(store_code || quarter, ',' order by store_code) from public.checkup_store_quarter where store_code in ('中和','新莊','樹林','桃園中壢','新竹','花蓮','旗艦','南台中','太平','台南','高雄')$q$));
  perform pg_temp.vr_eq('2 季次種子', '總公司不在季次表內', '0',
    pg_temp.vr_q1($q$select count(*)::text from public.checkup_store_quarter where store_code in ('總公司', 'HQ')$q$));
  -- 種子前置檢查：門市對不到時整份回復（用同一支 checkup_seed_assert，schema 開頭就是呼叫它）
  perform pg_temp.vr_eq('2 季次種子', '11 家門市名稱都對得到 stores（schema 能執行的前提）', 'OK',
    pg_temp.vr_owner($q$select public.checkup_seed_assert(array['中和','新莊','樹林','桃園中壢','新竹','花蓮','旗艦','南台中','太平','台南','高雄'])$q$));
  perform pg_temp.vr_eq('2 季次種子', '少一家門市（以不存在的名稱代替）：丟中文例外，列出對不到的名稱並提示確認門市資料', 'true',
    (pg_temp.vr_owner($q$select public.checkup_seed_assert(array['中和','ZZ不存在店甲','高雄','ZZ不存在店乙'])$q$)
      like 'ERROR: 健檢季次種子：以下門市在 stores 表找不到：ZZ不存在店乙、ZZ不存在店甲。請先到人員名冊／門市資料確認門市名稱後再執行%')::text);
exception when others then
  perform pg_temp.vr_rec('區段 2','季次種子測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：checkup_quarters_list／checkup_quarter_set
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.vr_eq('3 季次表', '客服部：ZZ-C1 → 季次 1、應健檢人數 6（9701、9705、9706、9707、9713、9714；考核期／離職／不納入不算）', '1/6',
    pg_temp.vr_cs($q$select quarter::text || '/' || headcount::text from public.checkup_quarters_list() where store_code = 'ZZ-C1'$q$));
  perform pg_temp.vr_eq('3 季次表', '客服部：ZZ-C2 → 3 人（不含 passed_on 限制）', '2/3',
    pg_temp.vr_cs($q$select quarter::text || '/' || headcount::text from public.checkup_quarters_list() where store_code = 'ZZ-C2'$q$));
  perform pg_temp.vr_eq('3 季次表', '客服部：看得到全部門市（含 11 家真實門市與 4 家假門市）', 'true',
    pg_temp.vr_cs($q$select (count(*) >= 15)::text from public.checkup_quarters_list()$q$));
  perform pg_temp.vr_eq('3 季次表', '客服部：回傳門市名稱', 'ZZ健檢門市1',
    pg_temp.vr_cs($q$select store_name from public.checkup_quarters_list() where store_code = 'ZZ-C1'$q$));
  perform pg_temp.vr_eq('3 季次表', '總公司主管：看全部門市', 'true',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select (count(*) >= 15)::text from public.checkup_quarters_list()$q$, true));
  perform pg_temp.vr_eq('3 季次表', '店長：只看到自己門市（1 列）', 'ZZ-C1/1',
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', $q$select string_agg(store_code, ',') || '/' || count(*)::text from public.checkup_quarters_list()$q$, true));
  perform pg_temp.vr_eq('3 季次表', '店長：另一位店長只看到自己門市', 'ZZ-C2/1',
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', $q$select string_agg(store_code, ',') || '/' || count(*)::text from public.checkup_quarters_list()$q$, true));
  perform pg_temp.vr_eq('3 季次表', 'updated_by：客服部看得到、主管與店長看不到（不洩漏信箱）', 'seed/(null)/(null)',
    pg_temp.vr_cs($q$select updated_by from public.checkup_quarters_list() where store_code = 'ZZ-C1'$q$) || '/' ||
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select updated_by from public.checkup_quarters_list() where store_code = 'ZZ-C1'$q$, true) || '/' ||
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', $q$select updated_by from public.checkup_quarters_list() where store_code = 'ZZ-C1'$q$, true));
  perform pg_temp.vr_deny('3 季次表', '沒有角色的登入者不能看季次表', 'authenticated', 'vr-none@2motor.tw', 'select count(*) from public.checkup_quarters_list()', '%沒有權限%');
  perform pg_temp.vr_deny('3 季次表', 'anon 不能呼叫 checkup_quarters_list', 'anon', null, 'select count(*) from public.checkup_quarters_list()', '%permission denied%');

  -- checkup_quarter_set
  perform pg_temp.vr_csok('3 改季次', '客服部把 ZZ-C4 改成 Q1', $q$select public.checkup_quarter_set('ZZ-C4', 1)$q$);
  perform pg_temp.vr_eq('3 改季次', '改後季次＝1、updated_by＝客服部信箱', '1/vr-cs@2motor.tw',
    (select quarter::text || '/' || updated_by from public.checkup_store_quarter where store_code = 'ZZ-C4'));
  perform pg_temp.vr_csok('3 改季次', '客服部改回 Q4（門市代碼前後空白會被去掉）', $q$select public.checkup_quarter_set(' ZZ-C4 ', 4)$q$);
  perform pg_temp.vr_eq('3 改季次', '改回後季次＝4', '4', (select quarter::text from public.checkup_store_quarter where store_code = 'ZZ-C4'));
  perform pg_temp.vr_csdeny('3 改季次', '季次 0 被擋', $q$select public.checkup_quarter_set('ZZ-C4', 0)$q$, '%季次必須是 1 到 4%');
  perform pg_temp.vr_csdeny('3 改季次', '季次 5 被擋', $q$select public.checkup_quarter_set('ZZ-C4', 5)$q$, '%季次必須是 1 到 4%');
  perform pg_temp.vr_csdeny('3 改季次', '季次 null 被擋', $q$select public.checkup_quarter_set('ZZ-C4', null)$q$, '%季次必須是 1 到 4%');
  perform pg_temp.vr_csdeny('3 改季次', '不在季次表的門市（ZZ-C5）被擋', $q$select public.checkup_quarter_set('ZZ-C5', 1)$q$, '%不在健檢季次表內%');
  perform pg_temp.vr_csdeny('3 改季次', '不存在的門市被擋', $q$select public.checkup_quarter_set('ZZ-NONE', 1)$q$, '%不在健檢季次表內%');
  perform pg_temp.vr_csdeny('3 改季次', 'null 門市被擋', $q$select public.checkup_quarter_set(null, 1)$q$, '%不在健檢季次表內%');
  perform pg_temp.vr_deny('3 改季次', '總公司主管不能改季次', 'authenticated', 'vr-hq@2motor.tw', $q$select public.checkup_quarter_set('ZZ-C4', 1)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('3 改季次', '店長不能改季次', 'authenticated', 'vr-sm@2motor.tw', $q$select public.checkup_quarter_set('ZZ-C1', 2)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('3 改季次', '沒有角色不能改季次', 'authenticated', 'vr-none@2motor.tw', $q$select public.checkup_quarter_set('ZZ-C1', 2)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('3 改季次', 'anon 不能改季次', 'anon', null, $q$select public.checkup_quarter_set('ZZ-C1', 2)$q$, '%permission denied%');
  perform pg_temp.vr_eq('3 改季次', '被擋的呼叫沒有改到任何季次', '1/2/3/4',
    (select string_agg(quarter::text, '/' order by store_code) from public.checkup_store_quarter where store_code like 'ZZ-C%'));
exception when others then
  perform pg_temp.vr_rec('區段 3','季次表測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：名單規則（checkup_roster）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.vr_eq('4 名單', '2031 Q1 客服部：通過日早於季初才入名單；考核期、離職、不納入者不入（9701、9705、9713、9714）', 'MI-9701,MI-9705,MI-9713,MI-9714',
    pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 1));
  perform pg_temp.vr_eq('4 名單', '通過日剛好等於季初（9706）不入名單、通過日在季中（9707）不入', 'false/false',
    (pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 1) like '%9706%')::text || '/' || (pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 1) like '%9707%')::text);
  perform pg_temp.vr_eq('4 名單', '2031 Q2：通過日 3/31（9709）入、4/1（9710）不入', 'MI-9708,MI-9709', pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 2));
  perform pg_temp.vr_eq('4 名單', '2031 Q3 只有 ZZ-C3 的人（季次依門市而不是人）', 'MI-9711', pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 3));
  perform pg_temp.vr_eq('4 名單', '2031 Q4', 'MI-9712', pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 4));
  perform pg_temp.vr_eq('4 名單', '下一年度 2032 Q1：9706（通過日 2031-01-01）、9707 輪到了，名單依年度＋季次的第一天判斷', 'MI-9701,MI-9705,MI-9706,MI-9707,MI-9713,MI-9714',
    pg_temp.ck_ros('vr-cs@2motor.tw', 2032, 1));
  perform pg_temp.vr_eq('4 名單', '總公司主管：與客服部看到的名單相同', 'MI-9701,MI-9705,MI-9713,MI-9714', pg_temp.ck_ros('vr-hq@2motor.tw', 2031, 1));
  perform pg_temp.vr_eq('4 名單', '店長（ZZ-C1）看 Q1：自己門市的人', 'MI-9701,MI-9705,MI-9713,MI-9714', pg_temp.ck_ros('vr-sm@2motor.tw', 2031, 1));
  perform pg_temp.vr_eq('4 名單', '店長（ZZ-C1）看 Q2：看不到別間門市（空）', '(空)', pg_temp.ck_ros('vr-sm@2motor.tw', 2031, 2));
  perform pg_temp.vr_eq('4 名單', '店長（ZZ-C2）看 Q2：只有自己門市', 'MI-9708,MI-9709', pg_temp.ck_ros('vr-sm2@2motor.tw', 2031, 2));
  perform pg_temp.vr_eq('4 名單', '名單欄位：新名單的人狀態＝待排定、is_first＝true、無排定、無成績單', '待排定/true/(null)/(null)/(null)/(null)/(null)',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'status') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'is_first') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'scheduled_at') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'checkup_id') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'assessment_id') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'score') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'verdict'));
  perform pg_temp.vr_eq('4 名單', '名單欄位：顯示名稱、門市代碼與名稱、到職日', '假員9701/ZZ-C1/ZZ健檢門市1/' || (pg_temp.p1_today() - 400)::text,
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'display_name') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'store_code') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'store_name') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'hire_date'));
  perform pg_temp.vr_eq('4 名單', '回傳欄位順序與型別', 'TABLE(employee_id text, display_name text, store_code text, store_name text, hire_date date, is_first boolean, status text, scheduled_at timestamp with time zone, checkup_id uuid, assessment_id uuid, score numeric, verdict text, assessment_status text)',
    pg_temp.vr_q1($q$select pg_get_function_result('public.checkup_roster(int,int)'::regprocedure)$q$));
  perform pg_temp.vr_eq('4 名單', 'checkup_quarters_list 回傳欄位', 'TABLE(store_code text, store_name text, quarter integer, headcount integer, updated_at timestamp with time zone, updated_by text)',
    pg_temp.vr_q1($q$select pg_get_function_result('public.checkup_quarters_list()'::regprocedure)$q$));
  perform pg_temp.vr_deny('4 名單', '年度 1999 被擋', 'authenticated', 'vr-cs@2motor.tw', 'select count(*) from public.checkup_roster(1999, 1)', '%年度不正確%');
  perform pg_temp.vr_deny('4 名單', '年度 null 被擋', 'authenticated', 'vr-cs@2motor.tw', 'select count(*) from public.checkup_roster(null, 1)', '%年度不正確%');
  perform pg_temp.vr_deny('4 名單', '季次 0 被擋', 'authenticated', 'vr-cs@2motor.tw', 'select count(*) from public.checkup_roster(2031, 0)', '%季次必須是 1 到 4%');
  perform pg_temp.vr_deny('4 名單', '季次 5 被擋', 'authenticated', 'vr-cs@2motor.tw', 'select count(*) from public.checkup_roster(2031, 5)', '%季次必須是 1 到 4%');
  perform pg_temp.vr_deny('4 名單', '沒有角色不能看名單', 'authenticated', 'vr-none@2motor.tw', 'select count(*) from public.checkup_roster(2031, 1)', '%沒有權限%');
  perform pg_temp.vr_deny('4 名單', 'anon 不能呼叫 checkup_roster', 'anon', null, 'select count(*) from public.checkup_roster(2031, 1)', '%permission denied%');
exception when others then
  perform pg_temp.vr_rec('區段 4','名單測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：排定／取消排定
-- ============================================================
do $$
declare
  v_id text;
  v_id1 text;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.ck_emp('MI-9725', 'ZZ-C5');

  v_id := pg_temp.ck_sched('MI-9713', 2031, 1, E'  備註一  ');
  perform pg_temp.vr_eq('5 排定', '客服部排定 9713（2031 Q1）：回傳 checkups.id（uuid）', 'true', (v_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')::text);
  perform pg_temp.vr_set('chk_9713', v_id);
  perform pg_temp.vr_eq('5 排定', '排定列內容：門市快照／年度／季次／備註（去頭尾空白）／排定人', 'ZZ-C1/2031/1/備註一/vr-cs@2motor.tw',
    (select store_code || '/' || year || '/' || quarter || '/' || note || '/' || scheduled_by from public.checkups where id = v_id::uuid));
  perform pg_temp.vr_eq('5 排定', '名單狀態變「已排定」、有排定時間與 checkup_id、尚無成績單', '已排定/true/' || v_id || '/(null)/(null)',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9713', 'status') || '/' ||
    (pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9713', 'scheduled_at') <> '(null)')::text || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9713', 'checkup_id') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9713', 'assessment_id') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9713', 'score'));
  perform pg_temp.vr_eq('5 排定', '主管與店長看到的狀態同樣是「已排定」', '已排定/已排定',
    pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9713', 'status') || '/' || pg_temp.ck_col('vr-sm@2motor.tw', 2031, 1, 'MI-9713', 'status'));
  perform pg_temp.vr_eq('5 排定', '店長看不到別間門市已排定的人', '(null)', pg_temp.ck_col('vr-sm2@2motor.tw', 2031, 1, 'MI-9713', 'status'));

  v_id1 := pg_temp.ck_sched('MI-9701', 2031, 1);
  perform pg_temp.vr_set('chk_9701', v_id1);
  perform pg_temp.vr_eq('5 排定', '排定 9701（備註可省略 → null）', 'true/(null)',
    (v_id1 ~ '^[0-9a-f-]{36}$')::text || '/' || coalesce((select note from public.checkups where id = v_id1::uuid), '(null)'));

  perform pg_temp.vr_eq('5 排定', '同一人同一年重複排定：擋（已排定）', 'true',
    (pg_temp.ck_sched('MI-9713', 2031, 1) like 'ERROR: 這位人員 2031 年已排定健檢（第 1 季）%')::text);
  perform pg_temp.vr_eq('5 排定', '同一人同一年改排別的季也擋（每人每年 1 次）', 'true',
    (pg_temp.ck_sched('MI-9713', 2031, 3) like 'ERROR: 這位人員 2031 年已排定健檢（第 1 季）%')::text);
  perform pg_temp.vr_eq('5 排定', '考核期的人不在名單', 'true', (pg_temp.ck_sched('MI-9702', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '離職的人不在名單', 'true', (pg_temp.ck_sched('MI-9703', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '不納入考核的人不在名單', 'true', (pg_temp.ck_sched('MI-9704', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '通過日剛好季初（9706）不在名單', 'true', (pg_temp.ck_sched('MI-9706', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '通過日在季中（9707）不在名單', 'true', (pg_temp.ck_sched('MI-9707', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '門市屬於 Q2 的人（9708）排成 Q1：擋', 'true', (pg_temp.ck_sched('MI-9708', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '門市屬於 Q1 的人（9705）排成 Q2：擋', 'true', (pg_temp.ck_sched('MI-9705', 2031, 2) like 'ERROR: 這位人員不在 2031 年第 2 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '不在任何季次的門市（ZZ-C5）的人：擋', 'true', (pg_temp.ck_sched('MI-9725', 2031, 1) like 'ERROR: 這位人員不在 2031 年第 1 季的健檢名單內%')::text);
  perform pg_temp.vr_eq('5 排定', '通過日 3/31（9709）排 Q2：可以', 'true', (pg_temp.ck_sched('MI-9709', 2031, 2) ~ '^[0-9a-f-]{36}$')::text);
  perform pg_temp.vr_eq('5 排定', '通過日 4/1（9710）排 Q2：擋', 'true', (pg_temp.ck_sched('MI-9710', 2031, 2) like 'ERROR: 這位人員不在 2031 年第 2 季的健檢名單內%')::text);
  perform pg_temp.vr_csdeny('5 排定', '找不到員工', $q$select public.checkup_schedule('MI-0000X', 2031, 1, now(), null)$q$, '%找不到員工%');
  perform pg_temp.vr_csdeny('5 排定', '沒指定時間被擋', $q$select public.checkup_schedule('MI-9705', 2031, 1, null, null)$q$, '%請指定健檢日期與時間%');
  perform pg_temp.vr_csdeny('5 排定', '備註超過 500 字被擋', format($q$select public.checkup_schedule('MI-9705', 2031, 1, now(), %L)$q$, repeat('字', 501)), '%備註最多 500 字%');
  perform pg_temp.vr_csdeny('5 排定', '年度 1999 被擋', $q$select public.checkup_schedule('MI-9705', 1999, 1, now(), null)$q$, '%年度不正確%');
  perform pg_temp.vr_csdeny('5 排定', '季次 0 被擋', $q$select public.checkup_schedule('MI-9705', 2031, 0, now(), null)$q$, '%季次必須是 1 到 4%');
  perform pg_temp.vr_eq('5 排定', '被擋的排定都沒有留下排定列', '0',
    (select count(*)::text from public.checkups where employee_id in ('MI-9702','MI-9703','MI-9704','MI-9706','MI-9707','MI-9708','MI-9705','MI-9725','MI-9710')));
  perform pg_temp.vr_deny('5 排定', '總公司主管不能排定', 'authenticated', 'vr-hq@2motor.tw', $q$select public.checkup_schedule('MI-9705', 2031, 1, now(), null)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('5 排定', '店長不能排定', 'authenticated', 'vr-sm@2motor.tw', $q$select public.checkup_schedule('MI-9705', 2031, 1, now(), null)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('5 排定', '沒有角色不能排定', 'authenticated', 'vr-none@2motor.tw', $q$select public.checkup_schedule('MI-9705', 2031, 1, now(), null)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('5 排定', 'anon 不能排定', 'anon', null, $q$select public.checkup_schedule('MI-9705', 2031, 1, now(), null)$q$, '%permission denied%');

  -- 改季次「從下一次起算」：已排定的留在原季，沒排定的跟著新季次走
  perform pg_temp.vr_csok('5 改季次後', '客服部把 ZZ-C1 改成 Q3', $q$select public.checkup_quarter_set('ZZ-C1', 3)$q$);
  perform pg_temp.vr_eq('5 改季次後', 'Q1 名單只剩已排定的人（9701、9713 仍在原季）', 'MI-9701,MI-9713', pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 1));
  perform pg_temp.vr_eq('5 改季次後', 'Q3 名單：ZZ-C1 沒排定的人（9705、9706、9707、9714）跟著新季次加入；已排定者（9701、9713）不重複出現', 'MI-9705,MI-9706,MI-9707,MI-9711,MI-9714',
    pg_temp.ck_ros('vr-cs@2motor.tw', 2031, 3));
  perform pg_temp.vr_csok('5 改季次後', '改回 Q1', $q$select public.checkup_quarter_set('ZZ-C1', 1)$q$);

  -- 取消排定
  perform pg_temp.vr_csok('5 取消排定', '客服部取消 9713 的排定', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9713')));
  perform pg_temp.vr_eq('5 取消排定', '取消後：排定列消失、回到「待排定」', '0/待排定',
    (select count(*)::text from public.checkups where id = pg_temp.vr_get('chk_9713')::uuid) || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9713', 'status'));
  perform pg_temp.vr_csdeny('5 取消排定', '同一筆再取消：找不到', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9713')), '%找不到這筆健檢排定%');
  perform pg_temp.vr_csdeny('5 取消排定', '亂給 uuid：找不到', $q$select public.checkup_unschedule('00000000-0000-0000-0000-000000000000'::uuid)$q$, '%找不到這筆健檢排定%');
  perform pg_temp.vr_csdeny('5 取消排定', 'null：找不到', $q$select public.checkup_unschedule(null)$q$, '%找不到這筆健檢排定%');
  perform pg_temp.vr_deny('5 取消排定', '總公司主管不能取消排定', 'authenticated', 'vr-hq@2motor.tw', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9701')), '%沒有權限%');
  perform pg_temp.vr_deny('5 取消排定', '店長不能取消排定', 'authenticated', 'vr-sm@2motor.tw', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9701')), '%沒有權限%');
  perform pg_temp.vr_deny('5 取消排定', '沒有角色不能取消排定', 'authenticated', 'vr-none@2motor.tw', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9701')), '%沒有權限%');
  perform pg_temp.vr_deny('5 取消排定', 'anon 不能取消排定', 'anon', null, format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9701')), '%permission denied%');
  perform pg_temp.vr_eq('5 取消排定', '被擋的取消沒有動到 9701 的排定', '1', (select count(*)::text from public.checkups where id = pg_temp.vr_get('chk_9701')::uuid));
exception when others then
  perform pg_temp.vr_rec('區段 5','排定測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：開始健檢（checkup_begin）與草稿
-- ============================================================
do $$
declare
  v_a text;
  v_a2 text;
  v_e1 text;
  v_e2 text;
  v_x text;
  v_y text;
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.vr_eq('6 開始健檢', '沒排定的人：擋（9705 尚未排定）', 'true', (pg_temp.ck_begin('MI-9705', 2031, 1) like 'ERROR: 這位人員 2031 年尚未排定健檢，請先排定')::text);
  perform pg_temp.vr_eq('6 開始健檢', '季次與排定不符：擋', 'ERROR: 這位人員 2031 年排定的是第 1 季，不是第 2 季', pg_temp.ck_begin('MI-9701', 2031, 2));
  perform pg_temp.vr_eq('6 開始健檢', '找不到員工', 'true', (pg_temp.ck_begin('MI-0000X', 2031, 1) like 'ERROR: 找不到員工%')::text);
  perform pg_temp.vr_eq('6 開始健檢', '年度不正確', 'ERROR: 年度不正確', pg_temp.ck_begin('MI-9701', 1999, 1));
  perform pg_temp.vr_eq('6 開始健檢', '季次不正確', 'ERROR: 季次必須是 1 到 4', pg_temp.ck_begin('MI-9701', 2031, 0));

  v_a := pg_temp.ck_begin('MI-9701', 2031, 1);
  perform pg_temp.vr_eq('6 開始健檢', '已排定者開始健檢：回傳成績單 id', 'true', (v_a ~ '^[0-9a-f-]{36}$')::text);
  perform pg_temp.vr_set('aid_chk_9701', v_a);
  perform pg_temp.vr_eq('6 開始健檢', '草稿內容：kind／年度／季次／狀態／身分／來源／考官／名稱／門市', 'checkup/2031/1/draft/正式/自動/vr-cs@2motor.tw/假員9701/ZZ-C1',
    (select kind || '/' || checkup_year || '/' || checkup_quarter || '/' || status || '/' || tenure || '/' || tenure_source || '/' || examiner_email || '/' || employee_label || '/' || store_code
       from public.assessments where id = v_a::uuid));
  perform pg_temp.vr_eq('6 開始健檢', 'checkups.assessment_id 已連到這張草稿', 'true',
    (select (assessment_id = v_a::uuid)::text from public.checkups where id = pg_temp.vr_get('chk_9701')::uuid));
  perform pg_temp.vr_eq('6 開始健檢', '再按一次開始：回傳同一張草稿（可接續）', v_a, pg_temp.ck_begin('MI-9701', 2031, 1));
  perform pg_temp.vr_eq('6 開始健檢', '同員工同年只有一張健檢草稿', '1',
    (select count(*)::text from public.assessments where employee_id = 'MI-9701' and kind = 'checkup'));
  perform pg_temp.vr_eq('6 開始健檢', '另一位客服部不能接手別人的健檢草稿', 'ERROR: 這場健檢已由其他客服部同仁開始，請由該同仁繼續，或請他先放棄草稿', pg_temp.ck_begin('MI-9701', 2031, 1, 'vr-cs2@2motor.tw'));
  perform pg_temp.vr_eq('6 開始健檢', '名單：客服部看到「已排定」＋草稿 id＋assessment_status=draft', '已排定/' || v_a || '/draft',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'status') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'assessment_id') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'assessment_status'));
  perform pg_temp.vr_eq('6 開始健檢', '名單：主管看不到草稿（assessment_id、assessment_status 為空，狀態仍「已排定」）', '已排定/(null)/(null)',
    pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'status') || '/' || pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'assessment_id') || '/' || pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'assessment_status'));
  perform pg_temp.vr_eq('6 開始健檢', '名單：店長看不到草稿', '已排定/(null)/(null)',
    pg_temp.ck_col('vr-sm@2motor.tw', 2031, 1, 'MI-9701', 'status') || '/' || pg_temp.ck_col('vr-sm@2motor.tw', 2031, 1, 'MI-9701', 'assessment_id') || '/' || pg_temp.ck_col('vr-sm@2motor.tw', 2031, 1, 'MI-9701', 'assessment_status'));
  perform pg_temp.vr_csdeny('6 開始健檢', '已開始（有草稿）不能取消排定', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9701')), '%這場健檢已經開始%請先放棄草稿%');

  -- 一般考核草稿與健檢草稿並存、互不干擾（assess_start 的草稿索引只管 exam）
  v_e1 := pg_temp.vr_cs($q$select public.assess_start('MI-9701', null)::text$q$);
  perform pg_temp.vr_eq('6 並存草稿', '同考官同員工：健檢草稿存在時仍可開一般考核（新草稿，不是健檢那張）', 'true/exam',
    (v_e1 ~ '^[0-9a-f-]{36}$' and v_e1 <> v_a)::text || '/' || (select kind from public.assessments where id = v_e1::uuid));
  perform pg_temp.vr_eq('6 並存草稿', '再開一次一般考核：回傳同一張考核草稿（既有「同考官同員工一張草稿」行為不變）', v_e1,
    pg_temp.vr_cs($q$select public.assess_start('MI-9701', null)::text$q$));
  perform pg_temp.vr_eq('6 並存草稿', '健檢草稿沒被動到：checkups 仍連著原草稿', 'true',
    (select (assessment_id = v_a::uuid)::text from public.checkups where id = pg_temp.vr_get('chk_9701')::uuid));
  perform pg_temp.vr_csok('6 並存草稿', '放棄一般考核草稿（既有 assess_abandon）', format($q$select public.assess_abandon(%L::uuid)$q$, v_e1));
  perform pg_temp.vr_eq('6 並存草稿', '放棄後健檢草稿還在', 'draft', (select status from public.assessments where id = v_a::uuid));
  -- 兩位考官各自的一般考核草稿（既有行為不變）
  v_x := pg_temp.vr_cs($q$select public.assess_start('MI-9725', null)::text$q$);
  v_y := pg_temp.vr_as('authenticated', 'vr-cs2@2motor.tw', $q$select public.assess_start('MI-9725', null)::text$q$, true);
  perform pg_temp.vr_eq('6 並存草稿', '不同考官對同一員工各有自己的考核草稿；同考官再開回傳自己那張', 'true/true',
    (v_x <> v_y)::text || '/' || (pg_temp.vr_cs($q$select public.assess_start('MI-9725', null)::text$q$) = v_x)::text);

  -- 放棄健檢草稿：排定仍在、assessment_id 變空、可重新開始
  perform pg_temp.vr_set('chk_9705', pg_temp.ck_sched('MI-9705', 2031, 1));
  v_a2 := pg_temp.ck_begin('MI-9705', 2031, 1);
  perform pg_temp.vr_csok('6 放棄', '放棄 9705 的健檢草稿（既有 assess_abandon）', format($q$select public.assess_abandon(%L::uuid)$q$, v_a2));
  perform pg_temp.vr_eq('6 放棄', '放棄後：排定列還在、assessment_id 變空、狀態仍是已排定', '1/(null)/已排定',
    (select count(*)::text from public.checkups where id = pg_temp.vr_get('chk_9705')::uuid) || '/' ||
    coalesce((select assessment_id::text from public.checkups where id = pg_temp.vr_get('chk_9705')::uuid), '(null)') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'status'));
  perform pg_temp.vr_eq('6 放棄', '放棄後可重新開始（新的草稿 id）', 'true', (pg_temp.ck_begin('MI-9705', 2031, 1) <> v_a2)::text);
  perform pg_temp.vr_set('aid_chk_9705', (select assessment_id::text from public.checkups where id = pg_temp.vr_get('chk_9705')::uuid));

  -- 開始時人員已離職：擋
  insert into public.checkups (employee_id, year, quarter, store_code, scheduled_at, scheduled_by)
  values ('MI-9703', 2031, 1, 'ZZ-C1', now(), 'vr-raw@2motor.tw');
  perform pg_temp.vr_eq('6 開始健檢', '排定後離職的人：名單仍顯示（已排定），但不能開始健檢', '已排定/true',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9703', 'status') || '/' || (pg_temp.ck_begin('MI-9703', 2031, 1) like 'ERROR: 該員工不在考核名單%')::text);
  delete from public.checkups where employee_id = 'MI-9703';

  perform pg_temp.vr_deny('6 開始健檢', '總公司主管不能開始健檢', 'authenticated', 'vr-hq@2motor.tw', $q$select public.checkup_begin('MI-9701', 2031, 1)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('6 開始健檢', '店長不能開始健檢', 'authenticated', 'vr-sm@2motor.tw', $q$select public.checkup_begin('MI-9701', 2031, 1)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('6 開始健檢', '沒有角色不能開始健檢', 'authenticated', 'vr-none@2motor.tw', $q$select public.checkup_begin('MI-9701', 2031, 1)$q$, '%沒有權限%');
  perform pg_temp.vr_deny('6 開始健檢', 'anon 不能開始健檢', 'anon', null, $q$select public.checkup_begin('MI-9701', 2031, 1)$q$, '%permission denied%');
exception when others then
  perform pg_temp.vr_rec('區段 6','開始健檢測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：健檢送出——只記錄，不動 employees、待開通、改善單、待考回報、抽查回考核期；85 分線
-- ============================================================
do $$
declare
  c_top jsonb := jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  c_849 jsonb := jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','優','待加強'),
      pg_temp.p1_all('優'),
      pg_temp.p1_lv('不適用','不適用','優','優','優','優','不及格'));
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
  v_a uuid;
  v_fp text;
  v_fx text;
  v_new uuid;
begin
  perform set_config('request.jwt.claims', '', true);

  -- 9701：全優 100 分。先放一筆店長的待考回報（待處理），確認送出後它不會被標成已完成
  insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
  values ('新人', 'MI-9701', 'x', 'ZZ-C1', 'vr-sm@2motor.tw', '店長', array[pg_temp.p1_today()], true);
  v_a := pg_temp.vr_get('aid_chk_9701')::uuid;
  v_fp := pg_temp.ck_empfp('MI-9701');
  v_fx := pg_temp.ck_sidefx();
  perform pg_temp.vr_eq('7 送出', '9701 評完 3 個核心題組', 'OK', pg_temp.ck_rate(v_a, c_top));
  perform pg_temp.vr_eq('7 送出', '9701 健檢送出：100.0/優秀/85/3/正式（身分一律正式，85 線）', '100.0/優秀/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('7 送出', '送出後員工那一列完全沒變（period_status、passed_on、probation_since、updated_at 都不動）', v_fp, pg_temp.ck_empfp('MI-9701'));
  perform pg_temp.vr_eq('7 送出', '送出後：待開通、改善單、待考回報（含店長那筆待處理仍是待處理）、抽查回考核期全部沒變', v_fx, pg_temp.ck_sidefx());
  perform pg_temp.vr_eq('7 送出', '店長的待考回報仍是「待處理」、沒連到成績單', '待處理/(null)',
    (select status || '/' || coalesce(assessment_id::text, '(null)') from public.exam_requests where employee_id = 'MI-9701'));
  perform pg_temp.vr_eq('7 送出', '成績單紀錄：已送出／kind／身分／合格線', 'submitted/checkup/正式/85',
    (select status || '/' || kind || '/' || tenure || '/' || pass_line from public.assessments where id = v_a));
  perform pg_temp.vr_eq('7 送出', '名單：狀態已完成、分數、判定、assessment_status', '已完成/100.0/優秀/submitted',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'status') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'score') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'verdict') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'assessment_status'));
  perform pg_temp.vr_eq('7 送出', '名單：主管與店長也看得到已完成的成績', '已完成/100.0/優秀/submitted/' || v_a::text,
    pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'status') || '/' || pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'score') || '/' ||
    pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'verdict') || '/' || pg_temp.ck_col('vr-hq@2motor.tw', 2031, 1, 'MI-9701', 'assessment_status') || '/' ||
    pg_temp.ck_col('vr-sm@2motor.tw', 2031, 1, 'MI-9701', 'assessment_id'));
  perform pg_temp.vr_csdeny('7 送出', '已完成的健檢不能取消排定', format($q$select public.checkup_unschedule(%L::uuid)$q$, pg_temp.vr_get('chk_9701')), '%已完成的健檢不能取消排定%');
  perform pg_temp.vr_eq('7 送出', '已完成的健檢不能再開始', 'ERROR: 這位人員 2031 年的健檢已完成，不能再開始', pg_temp.ck_begin('MI-9701', 2031, 1));
  perform pg_temp.vr_eq('7 送出', '已完成的人不能重複排定', 'true', (pg_temp.ck_sched('MI-9701', 2031, 1) like 'ERROR: 這位人員 2031 年已排定健檢%')::text);
  perform pg_temp.vr_eq('7 送出', '已完成的健檢送不能再送出一次', 'ERROR: 只有草稿可以送出', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('7 首次健檢', '次年（2032 Q1）9701 再入名單，is_first＝false（有更早的已送出健檢）；9705 還沒做過＝true', 'false/true',
    pg_temp.ck_col('vr-cs@2motor.tw', 2032, 1, 'MI-9701', 'is_first') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2032, 1, 'MI-9705', 'is_first'));
  perform pg_temp.vr_eq('7 首次健檢', '當年已完成（2031 Q1）的名單列，is_first 仍是 true（沒有更早的）', 'true', pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9701', 'is_first'));

  -- 9705：84.9 分——不過（需複訓），只記錄；不開改善單
  v_a := pg_temp.vr_get('aid_chk_9705')::uuid;
  v_fp := pg_temp.ck_empfp('MI-9705');
  v_fx := pg_temp.ck_sidefx();
  perform pg_temp.vr_eq('7 送出', '9705 評分（84.9 組合）', 'OK', pg_temp.ck_rate(v_a, c_849));
  perform pg_temp.vr_eq('7 送出', '84.9 → 需複訓、合格線 85（沿用正式判定函式）', '84.9/需複訓/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('7 送出', '健檢沒過只記錄：員工不變', v_fp, pg_temp.ck_empfp('MI-9705'));
  perform pg_temp.vr_eq('7 送出', '健檢沒過只記錄：不開改善單、沒有待開通、其他副作用都沒有', v_fx, pg_temp.ck_sidefx());
  perform pg_temp.vr_eq('7 送出', '9705 沒有改善單', '0',
    (select count(*)::text from public.improvement_tickets t where t.employee_id = 'MI-9705'));
  perform pg_temp.vr_eq('7 送出', '名單：不及格的健檢仍是「已完成」（只記錄）＋判定', '已完成/84.9/需複訓',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'status') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'score') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'verdict'));

  -- 作廢後：回到已排定，可再開始（新草稿），作廢的不佔「每年一張」
  perform pg_temp.vr_csok('7 作廢', '客服部作廢 9705 的健檢成績單（既有 assess_void）', format($q$select public.assess_void(%L::uuid, '測試作廢')$q$, v_a));
  perform pg_temp.vr_eq('7 作廢', '作廢後名單：已排定、成績單欄位清空', '已排定/(null)/(null)/(null)/(null)',
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'status') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'assessment_id') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'score') || '/' || pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'verdict') || '/' ||
    pg_temp.ck_col('vr-cs@2motor.tw', 2031, 1, 'MI-9705', 'assessment_status'));
  perform pg_temp.vr_eq('7 作廢', '作廢後 is_first 回到 true（已作廢的不算更早的健檢）', 'true', pg_temp.ck_col('vr-cs@2motor.tw', 2032, 1, 'MI-9705', 'is_first'));
  v_new := pg_temp.ck_begin('MI-9705', 2031, 1)::uuid;
  perform pg_temp.vr_eq('7 作廢', '作廢後可再開始：新草稿（不是被作廢那張）、checkups 連到新草稿', 'true/true',
    (v_new <> v_a)::text || '/' || (select (assessment_id = v_new)::text from public.checkups where id = pg_temp.vr_get('chk_9705')::uuid));
  perform pg_temp.vr_eq('7 作廢', '同一人同年現在有 1 張被作廢＋1 張草稿', '1/1',
    (select count(*) filter (where status = 'voided')::text || '/' || count(*) filter (where status = 'draft')::text from public.assessments where employee_id = 'MI-9705' and kind = 'checkup'));
  perform pg_temp.vr_csok('7 作廢', '放棄新草稿（收尾）', format($q$select public.assess_abandon(%L::uuid)$q$, v_new));

  -- 9713：probation_since 有值但已上線的異常資料；85.0 剛好過線——健檢仍不動 employees、不動抽查回考核期
  perform pg_temp.vr_set('chk_9713b', pg_temp.ck_sched('MI-9713', 2031, 1));
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9713', 'x', 'ZZ-C1', '{}'::uuid[], pg_temp.p1_today(), '待執行');
  v_a := pg_temp.ck_begin('MI-9713', 2031, 1)::uuid;
  v_fp := pg_temp.ck_empfp('MI-9713');
  v_fx := pg_temp.ck_sidefx();
  perform pg_temp.vr_eq('7 送出', '9713 評分（85.0 組合）', 'OK', pg_temp.ck_rate(v_a, c_850));
  perform pg_temp.vr_eq('7 送出', '85.0 剛好 → 及格（85 線含 85）', '85.0/及格/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('7 送出', '員工有 probation_since 也不動：員工列不變', v_fp, pg_temp.ck_empfp('MI-9713'));
  perform pg_temp.vr_eq('7 送出', '抽查回考核期仍是「待執行」、沒有待開通', v_fx, pg_temp.ck_sidefx());
  perform pg_temp.vr_eq('7 送出', '9713 狀態：已上線／probation_since 仍在／passed_on 空／待開通 0', '已上線/有/-/0', pg_temp.p1_st('MI-9713') || '/' || pg_temp.p1_act('MI-9713'));
  perform pg_temp.vr_eq('7 送出', '全部健檢成績單都沒有觸發改善單、待開通、待考回報連結', '0/0/0',
    (select count(*)::text from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where a.kind = 'checkup') || '/' ||
    (select count(*)::text from public.reply_activations r join public.assessments a on a.id = r.assessment_id where a.kind = 'checkup') || '/' ||
    (select count(*)::text from public.exam_requests r join public.assessments a on a.id = r.assessment_id where a.kind = 'checkup'));
exception when others then
  perform pg_temp.vr_rec('區段 7','健檢送出測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- 區段 7B：保險——即使健檢草稿的「來源」被異常改成考核期，送出仍只記錄（assess_submit 以 kind 把關，不只靠資料約束）
do $$
declare
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
  v_a uuid;
  v_fp text;
  v_fx text;
begin
  perform set_config('request.jwt.claims', '', true);
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9726', 'x', 'ZZ-C5', '{}'::uuid[], pg_temp.p1_today(), '待執行');
  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
                                  kind, checkup_year, checkup_quarter)
  values ('MI-9726', 'x', 'ZZ-C5', 'vr-cs@2motor.tw', 'draft', '正式', '考核期', 'checkup', 2034, 1)
  returning id into v_a;
  v_fp := pg_temp.ck_empfp('MI-9726');
  v_fx := pg_temp.ck_sidefx();
  perform pg_temp.vr_eq('7B 保險', '異常草稿（健檢＋來源考核期）評分', 'OK', pg_temp.ck_rate(v_a, c_850));
  perform pg_temp.vr_eq('7B 保險', '送出 85.0：只記錄成績單', '85.0/及格/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('7B 保險', '員工列不變（仍是考核期、probation_since 還在）', v_fp, pg_temp.ck_empfp('MI-9726'));
  perform pg_temp.vr_eq('7B 保險', '沒有待開通、抽查回考核期仍待執行、其他副作用都沒有', v_fx, pg_temp.ck_sidefx());
  perform pg_temp.vr_eq('7B 保險', '狀態：考核期／有／空／待開通 0', '考核期/有/-/0', pg_temp.p1_st('MI-9726') || '/' || pg_temp.p1_act('MI-9726'));
exception when others then
  perform pg_temp.vr_rec('區段 7B','保險測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 8：每人每年一張（含草稿、作廢後可再建）
-- ============================================================
do $$
declare
  v_id uuid;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.vr_eq('8 每年一張', '9701 今年已有未作廢的已送出健檢：再造一張（任何狀態）被唯一索引擋下', 'true/true',
    (pg_temp.vr_owner($q$select pg_temp.ck_mkchk('MI-9701', 'draft', 2031)$q$) like 'ERROR: %assessments_one_checkup_per_year%')::text || '/' ||
    (pg_temp.vr_owner($q$select pg_temp.ck_mkchk('MI-9701', 'submitted', 2031)$q$) like 'ERROR: %assessments_one_checkup_per_year%')::text);
  perform pg_temp.vr_eq('8 每年一張', '不同年度不受影響（9701 的 2033 可建）', 'OK', pg_temp.vr_owner($q$select pg_temp.ck_mkchk('MI-9701', 'draft', 2033)$q$));
  perform pg_temp.vr_eq('8 每年一張', '9714 先建 2033 草稿 OK、同年第二張草稿被擋', 'OK/true',
    pg_temp.vr_owner($q$select pg_temp.ck_mkchk('MI-9714', 'draft', 2033)$q$) || '/' ||
    (pg_temp.vr_owner($q$select pg_temp.ck_mkchk('MI-9714', 'draft', 2033)$q$) like 'ERROR: %assessments_one_checkup_per_year%')::text);
  update public.assessments
     set status = 'voided', total_score = 1, submitted_at = now(), voided_at = now(), voided_by = 'x', void_reason = '測試'
   where employee_id = 'MI-9714' and kind = 'checkup' and checkup_year = 2033;
  perform pg_temp.vr_eq('8 每年一張', '把那張作廢後，同年可以再建一張', 'OK', pg_temp.vr_owner($q$select pg_temp.ck_mkchk('MI-9714', 'draft', 2033)$q$));
  perform pg_temp.vr_eq('8 每年一張', '一般考核不受年度唯一限制（同員工可有多張 exam）', 'OK',
    pg_temp.vr_owner($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
      values ('MI-9722', 'x', 'ZZ-C5', 'vr-raw1@2motor.tw', 'draft', '正式', '自動'), ('MI-9722', 'x', 'ZZ-C5', 'vr-raw2@2motor.tw', 'draft', '正式', '自動')$q$));
exception when others then
  perform pg_temp.vr_rec('區段 8','每年一張測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 9：一般考核（kind='exam'）回歸——行為與第一期驗證的期望結果相同
-- ============================================================
do $$
declare
  c_top jsonb := jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  c_good jsonb := jsonb_build_array(pg_temp.p1_all('良'), pg_temp.p1_all('良'), pg_temp.p1_all('良'));
  c_849 jsonb := jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','優','待加強'),
      pg_temp.p1_all('優'),
      pg_temp.p1_lv('不適用','不適用','優','優','優','優','不及格'));
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
  v_today date := pg_temp.p1_today();
  v_a uuid;
  v_t uuid;
  v_ck uuid;
  v_ex2 uuid;
begin
  perform set_config('request.jwt.claims', '', true);

  -- R1 考核期新人通過（70 線）：已上線、待開通、待考回報自動完成
  insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
  values ('新人', 'MI-9721', 'x', 'ZZ-C5', 'vr-cs@2motor.tw', '客服部', array[v_today], true);
  v_a := pg_temp.p1_open('MI-9721');
  perform pg_temp.vr_eq('9 考試回歸', '考核期新人：assess_start 身分「新人／自動」、kind＝exam', '新人/自動/exam',
    (select tenure || '/' || tenure_source || '/' || kind from public.assessments where id = v_a));
  perform pg_temp.vr_eq('9 考試回歸', '評分', 'OK', pg_temp.p1_rate3(v_a, c_top -> 0, c_top -> 1, c_top -> 2));
  perform pg_temp.vr_eq('9 考試回歸', '考核期新人 100 分：100.0/優秀/70/3/新人（與第一期相同）', '100.0/優秀/70/3/新人', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('9 考試回歸', '通過 → 已上線、無 probation_since、passed_on＝今天、待開通 1 筆', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9721') || '/' || pg_temp.p1_act('MI-9721'));
  perform pg_temp.vr_eq('9 考試回歸', '店長的待考回報自動完成並連到成績單（觸發器對 exam 照常運作）', '已完成/true',
    (select status || '/' || (assessment_id = v_a)::text from public.exam_requests where employee_id = 'MI-9721'));

  -- R2 正式員工不及格 → 自動開改善單
  v_a := pg_temp.p1_open('MI-9722');
  perform pg_temp.vr_eq('9 考試回歸', '評分', 'OK', pg_temp.p1_rate3(v_a, c_good -> 0, c_good -> 1, c_good -> 2));
  perform pg_temp.vr_eq('9 考試回歸', '正式 70 分：70.0/不及格/85/3/正式', '70.0/不及格/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('9 考試回歸', '不及格自動開改善單：1 張、open、期限 14 天（觸發器對 exam 照常運作）', '1/open/true',
    (select count(*)::text || '/' || min(t.status) || '/' || bool_and(t.due_date = v_today + 14)::text
       from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where a.employee_id = 'MI-9722' and a.kind = 'exam'));
  perform pg_temp.vr_eq('9 考試回歸', '不及格員工狀態不變（已上線／無／空／0）', '已上線/無/-/0', pg_temp.p1_st('MI-9722') || '/' || pg_temp.p1_act('MI-9722'));

  -- R3 回考核期 85.0 通過
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9723', 'x', 'ZZ-C5', '{}'::uuid[], v_today, '待執行');
  v_a := pg_temp.p1_open('MI-9723');
  perform pg_temp.vr_eq('9 考試回歸', '回考核期：身分「正式／考核期」', '正式/考核期',
    (select tenure || '/' || tenure_source from public.assessments where id = v_a));
  perform pg_temp.vr_eq('9 考試回歸', '評分', 'OK', pg_temp.p1_rate3(v_a, c_850 -> 0, c_850 -> 1, c_850 -> 2));
  perform pg_temp.vr_eq('9 考試回歸', '回考核期 85.0（剛好）：85.0/及格/85/3/正式（與第一期相同）', '85.0/及格/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('9 考試回歸', '通過 → 清除 probation_since、已上線、passed_on、待開通 1 筆', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9723') || '/' || pg_temp.p1_act('MI-9723'));
  perform pg_temp.vr_eq('9 考試回歸', 'spot_probations 改「已通過」並記成績單', '已通過/true',
    (select p.status || '/' || (p.passed_assessment_id = v_a)::text from public.spot_probations p where p.employee_id = 'MI-9723'));

  -- R4 回考核期 84.9 不通過
  v_a := pg_temp.p1_open('MI-9724');
  perform pg_temp.vr_eq('9 考試回歸', '評分', 'OK', pg_temp.p1_rate3(v_a, c_849 -> 0, c_849 -> 1, c_849 -> 2));
  perform pg_temp.vr_eq('9 考試回歸', '回考核期 84.9：84.9/需複訓/85/3/正式', '84.9/需複訓/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('9 考試回歸', '84.9 不通過：什麼都不動（考核期／有／空／0）', '考核期/有/-/0', pg_temp.p1_st('MI-9724') || '/' || pg_temp.p1_act('MI-9724'));

  -- R5 改善單：健檢成績單不能當複檢成績單；一般考核可以
  v_a := pg_temp.p1_open('MI-9714');
  perform pg_temp.vr_eq('9 複檢', '9714 先考一場一般考核（70 分不及格）', 'OK', pg_temp.p1_rate3(v_a, c_good -> 0, c_good -> 1, c_good -> 2));
  perform pg_temp.vr_eq('9 複檢', '送出 → 開改善單', '70.0/不及格/85/3/正式', pg_temp.p1_submit(v_a));
  select t.id into v_t from public.improvement_tickets t where t.employee_id = 'MI-9714';
  perform pg_temp.vr_eq('9 複檢', '9714 有 1 張待改善的改善單', '1/open', (select count(*)::text || '/' || min(status) from public.improvement_tickets where employee_id = 'MI-9714'));
  perform pg_temp.vr_eq('9 複檢', '9714 的健檢排定、開始、評分、送出（全優）', 'true',
    (pg_temp.ck_sched('MI-9714', 2031, 1) ~ '^[0-9a-f-]{36}$')::text);
  v_ck := pg_temp.ck_begin('MI-9714', 2031, 1)::uuid;
  perform pg_temp.vr_eq('9 複檢', '評分', 'OK', pg_temp.ck_rate(v_ck, c_top));
  perform pg_temp.vr_eq('9 複檢', '健檢送出', '100.0/優秀/85/3/正式', pg_temp.p1_submit(v_ck));
  perform pg_temp.vr_eq('9 複檢', '健檢送出沒有動到這張改善單（仍是 1 張 open）', '1/open', (select count(*)::text || '/' || min(status) from public.improvement_tickets where employee_id = 'MI-9714'));
  update public.improvement_tickets set created_at = created_at - interval '2 hours' where id = v_t;
  perform pg_temp.vr_csdeny('9 複檢', '用健檢成績單當複檢結案：擋', format($q$select public.improve_close(%L::uuid, %L::uuid, null)$q$, v_t, v_ck), '%健檢成績單不能當作複檢成績單%');
  perform pg_temp.vr_eq('9 複檢', '被擋後改善單仍是 open', 'open', (select status from public.improvement_tickets where id = v_t));
  v_ex2 := pg_temp.p1_open('MI-9714');
  perform pg_temp.vr_eq('9 複檢', '再考一場一般考核（全優）', 'OK', pg_temp.p1_rate3(v_ex2, c_top -> 0, c_top -> 1, c_top -> 2));
  perform pg_temp.vr_eq('9 複檢', '送出', '100.0/優秀/85/3/正式', pg_temp.p1_submit(v_ex2));
  update public.improvement_tickets set created_at = created_at - interval '2 hours' where id = v_t;
  perform pg_temp.vr_csok('9 複檢', '用一般考核成績單結案：成功（既有行為不變）', format($q$select public.improve_close(%L::uuid, %L::uuid, null)$q$, v_t, v_ex2));
  perform pg_temp.vr_eq('9 複檢', '結案後狀態與連到的成績單', 'closed/true', (select status || '/' || (closed_by_assessment_id = v_ex2)::text from public.improvement_tickets where id = v_t));

  -- R6 弱項建議取題依據排除健檢
  perform pg_temp.vr_eq('9 弱項建議', '9714 共有 3 張已送出成績單（2 張一般考核＋1 張健檢）', '3/2/1',
    (select count(*)::text || '/' || count(*) filter (where kind = 'exam')::text || '/' || count(*) filter (where kind = 'checkup')::text from public.assessments where employee_id = 'MI-9714' and status = 'submitted'));
  perform pg_temp.vr_eq('9 弱項建議', 'assess_weak_profile 只看一般考核：n＝2（健檢不算）', '2', pg_temp.vr_cs($q$select (public.assess_weak_profile('MI-9714') ->> 'n')$q$));
  perform pg_temp.vr_eq('9 弱項建議', '只有健檢成績單的人（9701）：n＝0', '0', pg_temp.vr_cs($q$select (public.assess_weak_profile('MI-9701') ->> 'n')$q$));

  -- R7 檢視：kind 可區分、純顯示類看得到健檢
  perform pg_temp.vr_eq('9 檢視', 'assessment_summaries：健檢成績單帶 kind／年度／季次', 'checkup/2031/1',
    pg_temp.vr_cs(format($q$select kind || '/' || checkup_year || '/' || checkup_quarter from public.assessment_summaries where id = %L::uuid$q$, pg_temp.vr_get('aid_chk_9701'))));
  perform pg_temp.vr_eq('9 檢視', 'assessment_summaries：一般考核 kind＝exam、年度空', 'exam/-',
    pg_temp.vr_cs($q$select kind || '/' || coalesce(checkup_year::text, '-') from public.assessment_summaries where employee_id = 'MI-9722' and status = 'submitted' limit 1$q$));
  perform pg_temp.vr_eq('9 檢視', 'analytics_dim_rates：健檢列看得到（7 個面向×3 題組＝21 列），可用 assessment_id 對 assessment_summaries.kind 區分', 'checkup/21',
    pg_temp.vr_cs(format($q$select min(s.kind) || '/' || count(*)::text from public.analytics_dim_rates r join public.assessment_summaries s on s.id = r.assessment_id where r.assessment_id = %L::uuid$q$, pg_temp.vr_get('aid_chk_9701'))));
  perform pg_temp.vr_eq('9 檢視', 'analytics_dim_rates：一般考核列對到 kind＝exam', 'exam',
    pg_temp.vr_cs($q$select min(s.kind) from public.analytics_dim_rates r join public.assessment_summaries s on s.id = r.assessment_id where r.employee_id = 'MI-9722'$q$));
  perform pg_temp.vr_eq('9 檢視', '主管看得到已送出的健檢成績單', '1',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select count(*)::text from public.assessment_summaries where employee_id = 'MI-9701' and kind = 'checkup'$q$, true));
  perform pg_temp.vr_eq('9 檢視', '店長（本店）看得到、別店店長看不到', '1/0',
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', $q$select count(*)::text from public.assessment_summaries where employee_id = 'MI-9701' and kind = 'checkup'$q$, true) || '/' ||
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', $q$select count(*)::text from public.assessment_summaries where employee_id = 'MI-9701' and kind = 'checkup'$q$, true));
  perform pg_temp.vr_eq('9 檢視', '店長看不到本店的健檢草稿（RLS 照舊：草稿只有客服部）', '0',
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', $q$select count(*)::text from public.assessment_summaries where kind = 'checkup' and status = 'draft'$q$, true));
exception when others then
  perform pg_temp.vr_rec('區段 9','一般考核回歸測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 11：收尾比對（本腳本沒有改到任何函式、沒動到真實題庫）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.vr_eq('11 收尾', '所有 public 函式的定義在腳本前後相同', pg_temp.vr_get('fn_md5'), pg_temp.p1_fnmd5());
  perform pg_temp.vr_eq('11 收尾', '真實題目筆數沒變', pg_temp.vr_get('real_questions'),
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_eq('11 收尾', '真實題目的已抽記錄 drawn 沒變（若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_drawn'),
    (select count(*)::text from public.drawn where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_eq('11 收尾', '真實分類的 category_last 沒變', pg_temp.vr_get('real_last'),
    (select count(*)::text from public.category_last where category not like 'ZZ%'));
exception when others then
  perform pg_temp.vr_rec('區段 11','收尾比對意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 結果：先把結果表做成預備陳述式（rollback 不會讓它消失），再 rollback，最後 execute
-- ============================================================
do $$
declare
  v_total int;
  v_ok int;
  v_rows text;
  v_fail text;
  v_first text;
begin
  select count(*), count(*) filter (where pass) into v_total, v_ok from pg_temp.vr;
  select string_agg('#' || f.n, '、' order by f.n) into v_fail
  from (select n from pg_temp.vr where not pass order by n limit 20) f;
  -- 第一個失敗：序號、測項、實際（含錯誤訊息）
  select '第一個失敗（序號 ' || f.n || '）：' || f.grp || '｜' || f.name || '｜實際：' || left(f.actual, 300)
    into v_first
  from (select * from pg_temp.vr where not pass order by n limit 1) f;
  select string_agg(
           format('(%s, %L, %L, %L, %L)',
                  n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vr;

  begin
    execute 'deallocate ck_vr_out';
  exception when others then
    null;
  end;

  execute 'prepare ck_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_first is not null then '；' || v_first else '' end
                           || case when v_fail is not null then '；全部未通過序號：' || v_fail else '' end) || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  begin
    execute 'deallocate ck_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare ck_vr_out as select '
          || quote_literal('結果表輸出失敗（資料仍會 rollback）：' || sqlerrm) || '::text as "訊息"';
end
$$;

-- 備援：rollback 前先顯示一次（若畫面出現兩張一樣的表，看最後一張即可）
select n as "序號", grp || '｜' || name as "測項", expected as "預期", actual as "實際",
       case when pass then '通過' else '失敗' end as "通過"
from pg_temp.vr
order by n;

rollback;

-- rollback 已執行：上面所有假資料都不存在了。最後一個結果就是驗證結果表。
execute ck_vr_out;
