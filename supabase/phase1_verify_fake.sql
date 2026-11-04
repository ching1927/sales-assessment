-- ============================================================
-- 業務考核系統：第一期（考核期、固定 3 題組、弱項追加題、待開通）驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 phase1_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw，符合 accounts 網域檢查）／假題庫，
--   用 set_config('request.jwt.claims', …) ＋ set local role 模擬各角色登入，真的呼叫
--   assess_start／assess_draw／assess_save_item／assess_draft_weak／assess_add_extra／assess_submit／assess_void／
--   assess_abandon／assess_core_categories／activation_mark_done／exam_req_*／spot_register 等函式，
--   把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
--   開頭會在交易內把 app_settings.exam_core_categories 暫時改成假分類、並把「遷移完成記號」拿掉重跑一次遷移
--   （都在交易內，rollback 後老闆的設定與記號原樣保留）。
-- 怎麼看結果：
--   * 因為 SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     腳本在 rollback 之前把結果表存成「預備陳述式 p1_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；有失敗時會附上「第一個失敗」的序號、測項與實際錯誤訊息
--     （以及全部未通過序號，最多列 20 個）。「通過」欄全是「通過」才算驗證成功。預期看到「N/N 項通過」。
-- 假門市代碼 ZZ-P1／ZZ-P2、假員工編號 MI-9501～MI-9699、假信箱 vr-cs／vr-cs2／vr-hq／vr-sm／vr-sm2@2motor.tw、
--   假分類一律以 ZZ 開頭；若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 注意：假題庫的 questions.id 會用掉幾個流水號（序號不會因 rollback 倒退），無害。
-- 第一次執行請選在沒人抽題的時段（腳本執行期間有人抽題，結尾的「真實題庫筆數沒變」比對可能誤報）。
-- 全程都用 begin…rollback 包住；請不要在中途自己手動下 commit。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯停下（rollback 後無影響），不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.reply_activations') is null
     or to_regprocedure('public.assess_core_categories()') is null
     or to_regprocedure('public.assess_draft_weak(uuid)') is null
     or to_regprocedure('public.assess_add_extra(uuid, bigint[])') is null
     or to_regprocedure('public.activation_mark_done(uuid)') is null
     or to_regprocedure('public.phase1_migrate_period_status()') is null then
    raise exception '請先執行 phase1_schema.sql';
  end if;
  if to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_draw(uuid, text[])') is null
     or to_regprocedure('public.assess_submit(uuid)') is null
     or to_regprocedure('public.assess_pick(uuid, bigint[])') is null
     or to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is null
     or to_regprocedure('public.spot_register(text, date, text, jsonb, text, text)') is null
     or to_regprocedure('public.exam_req_create(text, text, date[], boolean, text, uuid)') is null then
    raise exception '請先執行既有的 assess／spotcheck／url_patch／weak_suggest／exam_request 各 schema';
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

-- ============================================================
-- 建立假資料與基準（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
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
  perform pg_temp.vr_set('marker_before',
    coalesce((select s.value from public.app_settings s where s.key = 'phase1_migrated_on'), '(none)'));
  perform pg_temp.vr_set('core_setting_before',
    coalesce((select s.value from public.app_settings s where s.key = 'exam_core_categories'), '(none)'));

  insert into public.stores (code, name) values ('ZZ-P1', 'ZZ測試門市P1'), ('ZZ-P2', 'ZZ測試門市P2');

  insert into public.app_users (email, role, store_code) values
    ('vr-cs@2motor.tw',  'cs_admin',      null),
    ('vr-cs2@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm@2motor.tw',  'store_manager', 'ZZ-P1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-P2');

  -- 假題庫：核心三類各 6 題、追加專用類 6 題
  for c in 1 .. 3 loop
    for k in 1 .. 6 loop
      insert into public.questions (category, code, title, steps)
      values ('ZZ核' || c, 'K' || c || k, '假題組K' || c || k, '[{"action":"動作","point":"考點"}]'::jsonb);
    end loop;
  end loop;
  for k in 1 .. 6 loop
    insert into public.questions (category, code, title, steps)
    values ('ZZ追', 'E' || k, '假題組E' || k, '[{"action":"動作","point":"考點"}]'::jsonb);
  end loop;
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：結構、授權、RLS
-- ============================================================
do $$
declare
  f record;
  w record;
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.p1_emp('MI-9500', 'ZZ-P1', 20, '已上線');
  perform pg_temp.vr_eq('1 結構', 'employees.period_status：text、not null、預設已上線', 'text/NO/''已上線''::text',
    pg_temp.vr_q1($q$select data_type || '/' || is_nullable || '/' || column_default from information_schema.columns
                      where table_schema='public' and table_name='employees' and column_name='period_status'$q$));
  perform pg_temp.vr_eq('1 結構', 'employees.passed_on：date、可空', 'date/YES',
    pg_temp.vr_q1($q$select data_type || '/' || is_nullable from information_schema.columns
                      where table_schema='public' and table_name='employees' and column_name='passed_on'$q$));
  perform pg_temp.vr_eq('1 結構', 'assessment_items.is_extra：boolean、not null、預設 false', 'boolean/NO/false',
    pg_temp.vr_q1($q$select data_type || '/' || is_nullable || '/' || column_default from information_schema.columns
                      where table_schema='public' and table_name='assessment_items' and column_name='is_extra'$q$));
  perform pg_temp.vr_eq('1 結構', 'assessments.extra_started_at：timestamptz、可空', 'timestamp with time zone/YES',
    pg_temp.vr_q1($q$select data_type || '/' || is_nullable from information_schema.columns
                      where table_schema='public' and table_name='assessments' and column_name='extra_started_at'$q$));
  perform pg_temp.vr_eq('1 結構', 'period_status 只收「考核期／已上線」（寫入別的值被擋）', 'ERROR: new row for relation "employees" violates check constraint "employees_period_status_check"',
    pg_temp.vr_owner($q$update public.employees set period_status = '亂寫' where id = 'MI-9500'$q$));
  perform pg_temp.vr_eq('1 結構', 'assessment_items 不再有 (assessment_id, category) 唯一約束（只剩 assessment_id＋seq 那一個）', '1',
    pg_temp.vr_q1($q$select count(*)::text from pg_constraint where conrelid = 'public.assessment_items'::regclass and contype = 'u'$q$));
  perform pg_temp.vr_eq('1 結構', '核心題組分類唯一改成部分唯一索引（where not is_extra）', 'true',
    pg_temp.vr_q1($q$select (indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%(assessment_id, category)%' and indexdef like '%WHERE (NOT is_extra)%')::text
                      from pg_indexes where schemaname='public' and indexname='assessment_items_one_core_per_category'$q$));
  perform pg_temp.vr_eq('1 結構', 'reply_activations 已開 RLS', 'true',
    pg_temp.vr_q1($q$select relrowsecurity::text from pg_class where oid = 'public.reply_activations'::regclass$q$));
  perform pg_temp.vr_eq('1 結構', 'reply_activations：同一張成績單唯一的部分唯一索引存在', '1',
    pg_temp.vr_q1($q$select count(*)::text from pg_indexes where schemaname='public' and indexname='reply_activations_one_per_assessment' and indexdef like 'CREATE UNIQUE INDEX%'$q$));
  perform pg_temp.vr_eq('1 結構', 'employees_with_tenure 帶出 tenure_group／probation_since／period_status／passed_on', '4',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns where table_schema='public' and table_name='employees_with_tenure'
                      and column_name in ('tenure_group','probation_since','period_status','passed_on')$q$));
  perform pg_temp.vr_eq('1 結構', '三個檢視都是 security_invoker', '3',
    pg_temp.vr_q1($q$select count(*)::text from pg_class c where c.relnamespace = 'public'::regnamespace
                      and c.relname in ('employees_with_tenure','assessment_summaries','analytics_dim_rates')
                      and exists (select 1 from unnest(c.reloptions) o where o = 'security_invoker=true')$q$));
  perform pg_temp.vr_eq('1 結構', '三個檢視：anon 無權限、authenticated 可 select', 'anon=false,auth=true x3',
    pg_temp.vr_q1($q$select 'anon=' || bool_or(has_table_privilege('anon', c.oid, 'select'))::text
                          || ',auth=' || bool_and(has_table_privilege('authenticated', c.oid, 'select'))::text || ' x' || count(*)
                     from pg_class c where c.relnamespace = 'public'::regnamespace
                      and c.relname in ('employees_with_tenure','assessment_summaries','analytics_dim_rates')$q$));
  perform pg_temp.vr_eq('1 結構', 'assessment_summaries 原 19 欄不變（第 19 欄是 item_count；之後的健檢追加欄位不算）', '19/item_count',
    pg_temp.vr_q1($q$select count(*)::text || '/' || (array_agg(column_name::text order by ordinal_position))[count(*)]
                     from information_schema.columns where table_schema='public' and table_name='assessment_summaries' and ordinal_position <= 19$q$));
  perform pg_temp.vr_eq('1 結構', 'analytics_dim_rates 欄位清單沒變（8 欄）', '8',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns where table_schema='public' and table_name='analytics_dim_rates'$q$));
  perform pg_temp.vr_eq('1 結構', 'app_settings 有 exam_core_categories 與遷移記號', 'true/true',
    pg_temp.vr_q1($q$select (exists (select 1 from public.app_settings where key='exam_core_categories'))::text || '/'
                          || (exists (select 1 from public.app_settings where key='phase1_migrated_on'))::text$q$));

  -- 函式授權與屬性
  for f in
    select * from (values
      ('public.assess_core_categories()'), ('public.assess_draft_weak(uuid)'), ('public.assess_add_extra(uuid, bigint[])'),
      ('public.activation_mark_done(uuid)'), ('public.assess_start(text, text)'), ('public.assess_submit(uuid)'),
      ('public.assess_weak_profile(text)'), ('public.exam_req_candidates(text)'),
      ('public.exam_req_create(text, text, date[], boolean, text, uuid)'), ('public.exam_req_badge()')
    ) as t(sig)
  loop
    perform pg_temp.vr_eq('1 結構', f.sig || '：anon 不能執行、authenticated 可以', 'false/true',
      has_function_privilege('anon', f.sig, 'execute')::text || '/' || has_function_privilege('authenticated', f.sig, 'execute')::text);
    perform pg_temp.vr_eq('1 結構', f.sig || '：security definer 且固定 search_path（含 pg_temp）', 'true',
      (select (p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp%'))::text
         from pg_proc p where p.oid = f.sig::regprocedure));
  end loop;
  perform pg_temp.vr_eq('1 結構', '遷移用內部函式：anon、authenticated 都不能執行', 'false/false',
    has_function_privilege('anon', 'public.phase1_migrate_period_status()', 'execute')::text || '/'
    || has_function_privilege('authenticated', 'public.phase1_migrate_period_status()', 'execute')::text);

  perform pg_temp.vr_eq('1 結構', 'reply_activations 資料表權限：authenticated 只有 select，anon 全無',
    'select=true,insert=false,update=false,delete=false,truncate=false,anon_select=false',
    pg_temp.vr_q1($q$select 'select=' || has_table_privilege('authenticated', 'public.reply_activations', 'select')::text
                          || ',insert=' || has_table_privilege('authenticated', 'public.reply_activations', 'insert')::text
                          || ',update=' || has_table_privilege('authenticated', 'public.reply_activations', 'update')::text
                          || ',delete=' || has_table_privilege('authenticated', 'public.reply_activations', 'delete')::text
                          || ',truncate=' || has_table_privilege('authenticated', 'public.reply_activations', 'truncate')::text
                          || ',anon_select=' || has_table_privilege('anon', 'public.reply_activations', 'select')::text$q$));

  -- 四個新函式 × 各角色
  for f in
    select * from (values
      ('assess_core_categories', $q$select array_to_string(public.assess_core_categories(), ',')$q$),
      ('assess_draft_weak',      $q$select public.assess_draft_weak('00000000-0000-0000-0000-000000000000'::uuid)::text$q$),
      ('assess_add_extra',       $q$select count(*)::text from public.assess_add_extra('00000000-0000-0000-0000-000000000000'::uuid, array[1]::bigint[])$q$),
      ('activation_mark_done',   $q$select public.activation_mark_done('00000000-0000-0000-0000-000000000000'::uuid)::text$q$)
    ) as t(fn, stmt)
  loop
    for w in
      select * from (values
        ('總公司主管', 'authenticated', 'vr-hq@2motor.tw',   '%沒有權限%'),
        ('店長',       'authenticated', 'vr-sm@2motor.tw',   '%沒有權限%'),
        ('未開通帳號', 'authenticated', 'vr-none@2motor.tw', '%沒有權限%'),
        ('沒有登入者（JWT 空）', 'authenticated', null::text, '%沒有權限%'),
        ('anon',       'anon',          null::text,          '%permission denied%')
      ) as r(label, rol, email, pat)
    loop
      perform pg_temp.vr_deny('1 權限', w.label || ' 呼叫 ' || f.fn, w.rol, w.email, f.stmt, w.pat);
    end loop;
  end loop;
exception when others then
  perform pg_temp.vr_rec('區段 1','結構／權限測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：既有資料遷移（各種員工狀態分到哪一邊、重跑不改回）
--   先建一批「各種狀態」的假員工（全部先放已上線），拿掉遷移記號後呼叫遷移函式，檢查分類。
-- ============================================================
do $$
declare
  v_a uuid;
  v_n int;
  v_h text;
  v_st text;
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.p1_emp('MI-9501', 'ZZ-P1', 20,  '已上線');                 -- 新人、沒考過
  perform pg_temp.p1_emp('MI-9502', 'ZZ-P1', 40,  '已上線');                 -- 新人、及格
  perform pg_temp.p1_emp('MI-9503', 'ZZ-P1', 40,  '已上線');                 -- 新人、優秀
  perform pg_temp.p1_emp('MI-9504', 'ZZ-P1', 40,  '已上線');                 -- 新人、需複訓
  perform pg_temp.p1_emp('MI-9505', 'ZZ-P1', 40,  '已上線');                 -- 新人、不及格
  perform pg_temp.p1_emp('MI-9506', 'ZZ-P1', 40,  '已上線');                 -- 新人、只有作廢的及格
  perform pg_temp.p1_emp('MI-9507', 'ZZ-P1', 40,  '已上線');                 -- 新人、只有草稿
  perform pg_temp.p1_emp('MI-9508', 'ZZ-P1', 20,  '已上線', null, true, '離職'); -- 新人但離職
  perform pg_temp.p1_emp('MI-9509', 'ZZ-P1', 20,  '已上線', null, false);    -- 新人但不納入考核
  perform pg_temp.p1_emp('MI-9510', 'ZZ-P1', 200, '已上線');                 -- 正式
  perform pg_temp.p1_emp('MI-9511', 'ZZ-P1', null, '已上線');                -- 未填到職日
  perform pg_temp.p1_emp('MI-9512', 'ZZ-P1', 90,  '已上線');                 -- 剛好 90 天（仍算新人）
  perform pg_temp.p1_emp('MI-9513', 'ZZ-P1', 91,  '已上線');                 -- 91 天（正式）
  perform pg_temp.p1_emp('MI-9514', 'ZZ-P1', 200, '已上線', 3);              -- 回考核期（probation_since 有值）
  perform pg_temp.p1_emp('MI-9515', 'ZZ-P1', 200, '已上線', 3, true, '離職'); -- 離職但 probation_since 有值
  perform pg_temp.p1_emp('MI-9516', 'ZZ-P1', 200, '已上線', 3, false);       -- 不納入但 probation_since 有值
  perform pg_temp.p1_emp('MI-9517', 'ZZ-P1', 20,  '已上線');                 -- 新人、先不及格後及格
  perform pg_temp.p1_emp('MI-9518', 'ZZ-P1', 20,  '已上線', 3);              -- 新人且 probation_since 有值、也有及格成績單

  perform pg_temp.p1_mkrep('MI-9502', 'submitted', '及格',   '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9503', 'submitted', '優秀',   '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9504', 'submitted', '需複訓', '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9505', 'submitted', '不及格', '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9506', 'voided',    '及格',   '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9507', 'draft',     null,     '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9517', 'submitted', '不及格', '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9517', 'submitted', '及格',   '[]'::jsonb, null, '新人');
  perform pg_temp.p1_mkrep('MI-9518', 'submitted', '及格',   '[]'::jsonb, null, '新人');

  perform pg_temp.vr_eq('2 遷移', '（前提）遷移完成記號在（schema 已經跑過遷移）', 'true',
    (pg_temp.vr_get('marker_before') <> '(none)')::text);

  -- 拿掉記號（交易內，rollback 後還原）→ 重新遷移
  delete from public.app_settings where key = 'phase1_migrated_on';
  select public.phase1_migrate_period_status() into v_n;
  perform pg_temp.vr_eq('2 遷移', '遷移函式回傳筆數 >= 假資料中應轉考核期的 10 人', 'true', (v_n >= 10)::text);
  perform pg_temp.vr_eq('2 遷移', '遷移後寫入記號', 'true',
    (exists (select 1 from public.app_settings where key = 'phase1_migrated_on'))::text);

  perform pg_temp.vr_eq('2 遷移', '新人、沒考過 → 考核期', '考核期', (select period_status from public.employees where id='MI-9501'));
  perform pg_temp.vr_eq('2 遷移', '新人、有及格成績單 → 已上線', '已上線', (select period_status from public.employees where id='MI-9502'));
  perform pg_temp.vr_eq('2 遷移', '新人、有優秀成績單 → 已上線', '已上線', (select period_status from public.employees where id='MI-9503'));
  perform pg_temp.vr_eq('2 遷移', '新人、只有需複訓 → 考核期', '考核期', (select period_status from public.employees where id='MI-9504'));
  perform pg_temp.vr_eq('2 遷移', '新人、只有不及格 → 考核期', '考核期', (select period_status from public.employees where id='MI-9505'));
  perform pg_temp.vr_eq('2 遷移', '新人、只有作廢的及格 → 考核期（作廢不算）', '考核期', (select period_status from public.employees where id='MI-9506'));
  perform pg_temp.vr_eq('2 遷移', '新人、只有草稿 → 考核期', '考核期', (select period_status from public.employees where id='MI-9507'));
  perform pg_temp.vr_eq('2 遷移', '新人但離職 → 已上線', '已上線', (select period_status from public.employees where id='MI-9508'));
  perform pg_temp.vr_eq('2 遷移', '新人但不納入考核 → 已上線', '已上線', (select period_status from public.employees where id='MI-9509'));
  perform pg_temp.vr_eq('2 遷移', '正式員工 → 已上線', '已上線', (select period_status from public.employees where id='MI-9510'));
  perform pg_temp.vr_eq('2 遷移', '未填到職日 → 已上線', '已上線', (select period_status from public.employees where id='MI-9511'));
  perform pg_temp.vr_eq('2 遷移', '到職剛好 90 天 → 考核期', '考核期', (select period_status from public.employees where id='MI-9512'));
  perform pg_temp.vr_eq('2 遷移', '到職 91 天 → 已上線', '已上線', (select period_status from public.employees where id='MI-9513'));
  perform pg_temp.vr_eq('2 遷移', 'probation_since 有值（正式員工）→ 考核期', '考核期', (select period_status from public.employees where id='MI-9514'));
  perform pg_temp.vr_eq('2 遷移', 'probation_since 有值但離職 → 一律考核期', '考核期', (select period_status from public.employees where id='MI-9515'));
  perform pg_temp.vr_eq('2 遷移', 'probation_since 有值但不納入 → 一律考核期', '考核期', (select period_status from public.employees where id='MI-9516'));
  perform pg_temp.vr_eq('2 遷移', '先不及格後及格（有及格）→ 已上線', '已上線', (select period_status from public.employees where id='MI-9517'));
  perform pg_temp.vr_eq('2 遷移', 'probation_since 有值且有及格成績單 → 一律考核期', '考核期', (select period_status from public.employees where id='MI-9518'));
  perform pg_temp.vr_eq('2 遷移', '遷移只動 period_status：passed_on 全空、probation_since 沒被改（有 4 人原本就有）', '0/4',
    (select count(*) filter (where passed_on is not null)::text || '/' || count(*) filter (where probation_since is not null)::text
       from public.employees where id between 'MI-9501' and 'MI-9518'));

  -- 重跑：有記號就整段略過。模擬客服部手動調整後重跑，不得被改回去
  update public.employees set period_status = '已上線' where id = 'MI-9501';   -- 客服部手動轉已上線
  update public.employees set period_status = '考核期' where id = 'MI-9510';   -- 客服部手動轉考核期
  select md5(string_agg(e.id || e.period_status, ',' order by e.id)) into v_h from public.employees e;
  select public.phase1_migrate_period_status() into v_n;
  perform pg_temp.vr_eq('2 遷移', '重跑（有記號）：回傳 0', '0', v_n::text);
  perform pg_temp.vr_eq('2 遷移', '重跑（有記號）：所有人的 period_status 一個都沒變', 'true',
    ((select md5(string_agg(e.id || e.period_status, ',' order by e.id)) from public.employees e) = v_h)::text);
  perform pg_temp.vr_eq('2 遷移', '重跑後：手動轉已上線的 9501 沒被改回考核期', '已上線', (select period_status from public.employees where id='MI-9501'));
  perform pg_temp.vr_eq('2 遷移', '重跑後：手動轉考核期的 9510 沒被改回已上線', '考核期', (select period_status from public.employees where id='MI-9510'));
  -- 對照：拿掉記號才會重新判斷（證明保護來自記號）
  delete from public.app_settings where key = 'phase1_migrated_on';
  perform public.phase1_migrate_period_status();
  perform pg_temp.vr_eq('2 遷移', '（對照）沒有記號時重新判斷：9501 又回到考核期', '考核期', (select period_status from public.employees where id='MI-9501'));

  -- 職稱超過 20 字的保護：暫時拿掉 NOT VALID 約束造一個長職稱的新人，遷移要用中文訊息停下
  alter table public.employees drop constraint if exists accounts_employees_job_title_len;
  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
  values ('MI-9519', '假員9519', 'ZZ-P1', repeat('長', 21), pg_temp.p1_today() - 5, '在職', true);
  delete from public.app_settings where key = 'phase1_migrated_on';
  perform pg_temp.vr_eq('2 遷移', '職稱超過 20 字的待轉人員：遷移用中文訊息停下（不寫記號）', 'ERROR: 這些人員的職稱超過 20 字，無法更新考核期狀態，請先到人員名冊縮短職稱再重跑：MI-9519',
    pg_temp.vr_owner('select public.phase1_migrate_period_status()'));
  perform pg_temp.vr_eq('2 遷移', '被擋後沒有寫記號', 'false',
    (exists (select 1 from public.app_settings where key = 'phase1_migrated_on'))::text);
  delete from public.employees where id = 'MI-9519';
  -- 還原約束（NOT VALID，與 accounts_schema.sql 相同；rollback 本來也會還原）
  alter table public.employees add constraint accounts_employees_job_title_len check (char_length(job_title) <= 20) not valid;
  perform public.phase1_migrate_period_status();   -- 重新寫記號
exception when others then
  perform pg_temp.vr_rec('區段 2','遷移測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：assess_core_categories
-- ============================================================
do $$
declare
  v_old text;
begin
  perform set_config('request.jwt.claims', '', true);
  v_old := pg_temp.vr_get('core_setting_before');

  -- 以客服部身分
  update public.app_settings set value = '基礎,進階,綜合' where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '預設三類：基礎,進階,綜合', '基礎,進階,綜合',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  update public.app_settings set value = ' 基礎 , 進階，綜合 ,基礎,, 進階 ' where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '去空白、全形逗號、去空項、去重（保留第一次出現順序）', '基礎,進階,綜合',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  update public.app_settings set value = '綜合,基礎,新分類,基礎' where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '日後新增分類只改設定：順序照設定、可超過三類', '綜合,基礎,新分類',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  update public.app_settings set value = '' where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '設定為空字串 → 預設三類', '基礎,進階,綜合',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  update public.app_settings set value = ' , ，, ' where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '設定只有逗號與空白 → 預設三類', '基礎,進階,綜合',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  update public.app_settings set value = null where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '設定值為 null → 預設三類', '基礎,進階,綜合',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  delete from public.app_settings where key = 'exam_core_categories';
  perform pg_temp.vr_eq('3 核心分類', '沒有這列設定 → 預設三類', '基礎,進階,綜合',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
  perform pg_temp.vr_eq('3 核心分類', '回傳型別是 text[]', 'text[]',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_core_categories()'::regprocedure)$q$));

  -- 之後的測試用假分類
  insert into public.app_settings (key, value) values ('exam_core_categories', 'ZZ核1,ZZ核2,ZZ核3')
  on conflict (key) do update set value = excluded.value;
  perform pg_temp.vr_eq('3 核心分類', '改成假分類後：ZZ核1,ZZ核2,ZZ核3', 'ZZ核1,ZZ核2,ZZ核3',
    pg_temp.vr_cs($q$select array_to_string(public.assess_core_categories(), ',')$q$));
exception when others then
  perform pg_temp.vr_rec('區段 3','核心分類測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：assess_start（考核期新人／回考核期／已上線／未填到職日）
-- ============================================================
do $$
declare
  v_a text;
  v_a2 text;
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.p1_emp('MI-9531', 'ZZ-P1', 20,   '考核期');          -- 考核期新人
  perform pg_temp.p1_emp('MI-9532', 'ZZ-P1', 400,  '考核期');          -- 考核期、到職很久
  perform pg_temp.p1_emp('MI-9533', 'ZZ-P1', null, '考核期');          -- 考核期、未填到職日
  perform pg_temp.p1_emp('MI-9534', 'ZZ-P1', 400,  '考核期', 3);       -- 回考核期（遷移後狀態）
  perform pg_temp.p1_emp('MI-9535', 'ZZ-P1', 20,   '已上線');          -- 已上線、到職 20 天
  perform pg_temp.p1_emp('MI-9536', 'ZZ-P1', 400,  '已上線');          -- 已上線、正式
  perform pg_temp.p1_emp('MI-9537', 'ZZ-P1', null, '已上線');          -- 已上線、未填到職日
  perform pg_temp.p1_emp('MI-9538', 'ZZ-P1', 400,  '已上線', 3);       -- 回考核期（抽查後、period_status 仍已上線）
  perform pg_temp.p1_emp('MI-9539', 'ZZ-P1', 20,   '考核期', null, false);   -- 不納入
  perform pg_temp.p1_emp('MI-9540', 'ZZ-P1', 20,   '考核期', null, true, '離職');

  -- 考核期新人
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9531', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '考核期新人（到職 20 天）：身分新人、來源自動', '新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_eq('4 開始考核', '考核期新人：到職日快照有存', 'true',
    pg_temp.vr_q1(format($q$select (hire_date_snapshot = (select hire_date from public.employees where id='MI-9531'))::text from public.assessments where id = %L::uuid$q$, v_a)));
  v_a2 := pg_temp.vr_cs($q$select public.assess_start('MI-9531', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '同考官同員工已有草稿：回傳既有那張', v_a, v_a2);
  perform pg_temp.vr_eq('4 開始考核', '考核期新人：同考官只有一張草稿', '1',
    pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id='MI-9531' and status='draft'$q$));
  -- 到職很久的考核期人員（不管到職多久，沒通過就一直是考核期）
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9532', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '考核期、到職 400 天：仍是新人（合格線 70）／自動', '新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  -- 未填到職日的考核期人員不需手動指定；傳 override 也被忽略
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9533', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '考核期、未填到職日：不需指定，直接新人／自動', '新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_eq('4 開始考核', '考核期新人：傳入 override「正式」被忽略', '新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$,
      pg_temp.vr_as('authenticated','vr-cs2@2motor.tw', $q$select public.assess_start('MI-9531', '正式')::text$q$, true))));
  -- 回考核期（probation_since 有值）：維持既有（正式、考核期、85）
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9534', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '回考核期（period_status 考核期）：正式／考核期', '正式/考核期',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9538', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '回考核期（period_status 仍已上線）：正式／考核期', '正式/考核期',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  -- 已上線：既有判斷
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9535', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '已上線、到職 20 天：既有判斷＝新人／自動', '新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9536', null)::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '已上線、到職 400 天：既有判斷＝正式／自動', '正式/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_csdeny('4 開始考核', '已上線、未填到職日：仍需手動指定（沒給被拒）',
    $q$select public.assess_start('MI-9537', null)::text$q$, '%到職日空白，請手動指定%');
  perform pg_temp.vr_csdeny('4 開始考核', '已上線、未填到職日：指定值不是新人／正式被拒',
    $q$select public.assess_start('MI-9537', '亂寫')::text$q$, '%到職日空白，請手動指定%');
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9537', '新人')::text$q$);
  perform pg_temp.vr_eq('4 開始考核', '已上線、未填到職日、指定新人：新人／手動指定', '新人/手動指定',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  -- 既有的檢查
  perform pg_temp.vr_csdeny('4 開始考核', '找不到員工', $q$select public.assess_start('MI-9599', null)::text$q$, '%找不到員工%');
  perform pg_temp.vr_csdeny('4 開始考核', '不納入考核者被拒（即使是考核期）', $q$select public.assess_start('MI-9539', null)::text$q$, '%不在考核名單%');
  perform pg_temp.vr_csdeny('4 開始考核', '離職者被拒', $q$select public.assess_start('MI-9540', null)::text$q$, '%不在考核名單%');
  perform pg_temp.vr_deny('4 開始考核', '總公司主管不能開始考核', 'authenticated', 'vr-hq@2motor.tw', $q$select public.assess_start('MI-9531', null)::text$q$, '%沒有權限%');
  perform pg_temp.vr_deny('4 開始考核', '店長不能開始考核', 'authenticated', 'vr-sm@2motor.tw', $q$select public.assess_start('MI-9531', null)::text$q$, '%沒有權限%');
  perform pg_temp.vr_deny('4 開始考核', 'anon 不能開始考核', 'anon', null, $q$select public.assess_start('MI-9531', null)::text$q$, '%permission denied%');
exception when others then
  perform pg_temp.vr_rec('區段 4','assess_start 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- 小工具：把 [{dim,pct}] 轉成「dim:pct,dim:pct」（保留順序；空陣列回 '(空)'）
create or replace function pg_temp.p1_jl(j jsonb)
returns text language sql as $$
  select coalesce((select string_agg((e.v ->> 'dim') || ':' || coalesce(e.v ->> 'pct', 'null'), ',' order by e.n)
                     from jsonb_array_elements(j) with ordinality as e(v, n)), '(空)');
$$;

-- ============================================================
-- 區段 5：固定 3 題組抽題、同一場分類唯一限制（只對核心題組有效）
-- ============================================================
do $$
declare
  v_a uuid;
  v_b uuid;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9541', 'ZZ-P1', 400, '已上線');
  perform pg_temp.p1_emp('MI-9542', 'ZZ-P1', 400, '已上線');

  v_a := pg_temp.p1_open('MI-9541');
  perform pg_temp.vr_eq('5 固定題組', '用核心分類清單一次抽 3 題：核心 3 題、追加 0 題', '3/0', pg_temp.p1_cnt(v_a));
  perform pg_temp.vr_eq('5 固定題組', '三題的分類就是 ZZ核1、ZZ核2、ZZ核3（依序）', 'ZZ核1,ZZ核2,ZZ核3',
    pg_temp.vr_q1(format($q$select string_agg(category, ',' order by seq) from public.assessment_items where assessment_id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_eq('5 固定題組', '三題都不是追加題、各有機密列', 'false/3',
    pg_temp.vr_q1(format($q$select bool_or(i.is_extra)::text || '/' || count(sx.item_id)::text
                            from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id = i.id
                            where i.assessment_id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_csdeny('5 固定題組', '同一場再抽同一分類被拒（既有訊息不變）',
    format($q$select count(*)::text from public.assess_draw(%L::uuid, array['ZZ核1'])$q$, v_a),
    '%這場考核已抽過其中的分類，每個分類最多一個題組%');
  perform pg_temp.vr_eq('5 固定題組', '擁有者直接再寫一筆同分類的核心題組 → 唯一限制擋下', 'ERROR: duplicate key value violates unique constraint "assessment_items_one_core_per_category"',
    pg_temp.vr_owner(format($q$insert into public.assessment_items (assessment_id, seq, category, code) values (%L::uuid, 9, 'ZZ核1', 'x')$q$, v_a)));
  perform pg_temp.vr_eq('5 固定題組', '同分類的追加題（is_extra）可以寫入', 'OK',
    pg_temp.vr_owner(format($q$insert into public.assessment_items (assessment_id, seq, category, code, is_extra) values (%L::uuid, 9, 'ZZ核1', 'x', true)$q$, v_a)));
  perform pg_temp.vr_eq('5 固定題組', '同一場可再有第二個同分類追加題', 'OK',
    pg_temp.vr_owner(format($q$insert into public.assessment_items (assessment_id, seq, category, code, is_extra) values (%L::uuid, 10, 'ZZ核1', 'x', true)$q$, v_a)));
  perform pg_temp.vr_eq('5 固定題組', '把第 1 個核心題組改成追加（is_extra 改 true）後，同分類可再補一個核心', 'OK',
    pg_temp.vr_owner(format($q$update public.assessment_items set is_extra = true where assessment_id = %L::uuid and seq = 1$q$, v_a)));
  perform pg_temp.vr_eq('5 固定題組', '（備料）補上同分類的新核心題組', 'OK',
    pg_temp.vr_owner(format($q$insert into public.assessment_items (assessment_id, seq, category, code) values (%L::uuid, 11, 'ZZ核1', 'x')$q$, v_a)));
  perform pg_temp.vr_eq('5 固定題組', '再把那個追加題改回核心會撞到同分類核心 → 被擋', 'ERROR: duplicate key value violates unique constraint "assessment_items_one_core_per_category"',
    pg_temp.vr_owner(format($q$update public.assessment_items set is_extra = false where assessment_id = %L::uuid and seq = 1$q$, v_a)));
  -- 另一個考生：直接用 assess_draw 抽，也不受影響
  v_b := pg_temp.p1_open('MI-9542');
  perform pg_temp.vr_eq('5 固定題組', '另一位考生一樣抽到核心 3 題', '3/0', pg_temp.p1_cnt(v_b));
exception when others then
  perform pg_temp.vr_rec('區段 5','固定題組測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：assess_draft_weak
-- ============================================================
do $$
declare
  i int;
  v_a uuid;
  v_s1 text;
  v_lowx jsonb := pg_temp.p1_all('不及格');
  s1 jsonb := '[]'::jsonb;
begin
  perform set_config('request.jwt.claims', '', true);
  for i in 51 .. 60 loop
    perform pg_temp.p1_emp('MI-95' || i, 'ZZ-P1', 400, '已上線');
  end loop;

  -- S1：問題掌握 60、主動引導 70、預設訊息運用 80；語氣與禮貌 40（偏低）；文字品質 70（不算偏低）
  s1 := jsonb_build_array(
    pg_temp.p1_lv('優','優','待加強','良','優','待加強','良'),
    pg_temp.p1_lv('優','良','良','良','優','待加強','良'),
    pg_temp.p1_lv('優','良','良','良','優','待加強','良'));
  v_a := pg_temp.p1_mkrep('MI-9551', 'draft', null, s1, null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S1：weak 只取 5 面向中最低的 2 個（問題掌握 60、主動引導 70；預設訊息運用 80 排第三不取）', '問題掌握:60,主動引導:70',
    pg_temp.p1_jl((v_s1::jsonb) -> 'weak'));
  perform pg_temp.vr_eq('6 弱項', 'S1：always_low 只有語氣與禮貌 40（文字品質 70 不算偏低）', '語氣與禮貌:40',
    pg_temp.p1_jl((v_s1::jsonb) -> 'always_low'));
  perform pg_temp.vr_eq('6 弱項', 'S1：rates 七個面向、固定順序', '7/資訊正確性/文字品質',
    (jsonb_array_length((v_s1::jsonb) -> 'rates'))::text || '/' || ((v_s1::jsonb) -> 'rates' -> 0 ->> 'dim') || '/' || ((v_s1::jsonb) -> 'rates' -> 6 ->> 'dim'));
  perform pg_temp.vr_eq('6 弱項', 'S1：rates 數值（資訊 100、預設 80、問題 60、主動 70、風險 100、語氣 40、文字 70）',
    '資訊正確性:100,預設訊息運用:80,問題掌握:60,主動引導:70,風險意識:100,語氣與禮貌:40,文字品質:70',
    pg_temp.p1_jl((v_s1::jsonb) -> 'rates'));
  perform pg_temp.vr_eq('6 弱項', 'S1：回傳只有 rates／weak／always_low 三個鍵', 'always_low,rates,weak',
    (select string_agg(k, ',' order by k) from jsonb_object_keys(v_s1::jsonb) k));
  perform pg_temp.vr_eq('6 弱項', '分析是唯讀：呼叫後成績單仍是草稿、題組沒被改', 'draft/3/0',
    pg_temp.vr_q1(format($q$select a.status || '/' || (select count(*) from public.assessment_items i where i.assessment_id = a.id and not i.is_extra)::text
                            || '/' || (select count(*) from public.assessment_items i where i.assessment_id = a.id and i.is_extra)::text
                            from public.assessments a where a.id = %L::uuid$q$, v_a)));

  -- S2：全優 → 沒有弱項
  v_a := pg_temp.p1_mkrep('MI-9552', 'draft', null, jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優')), null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S2：全部 100 → weak、always_low 都是空', '(空)/(空)',
    pg_temp.p1_jl((v_s1::jsonb) -> 'weak') || '/' || pg_temp.p1_jl((v_s1::jsonb) -> 'always_low'));

  -- S3：資訊正確性 優、良、不適用 → 平均剛好 85 → 不算弱項
  v_a := pg_temp.p1_mkrep('MI-9553', 'draft', null, jsonb_build_array(
      pg_temp.p1_all('優'), pg_temp.p1_lv('良','優','優','優','優','優','優'), pg_temp.p1_lv('不適用','優','優','優','優','優','優')),
      null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S3：資訊正確性剛好 85 → rates 是 85、weak 為空（剛好 85 不算弱項）', '85/(空)',
    (select (e.v ->> 'pct') from jsonb_array_elements((v_s1::jsonb) -> 'rates') e(v) where e.v ->> 'dim' = '資訊正確性')
    || '/' || pg_temp.p1_jl((v_s1::jsonb) -> 'weak'));

  -- S4：只有一個面向低於 85 → weak 只有一個
  v_a := pg_temp.p1_mkrep('MI-9554', 'draft', null, jsonb_build_array(
      pg_temp.p1_all('優'), pg_temp.p1_lv('良','優','優','優','優','優','優'), pg_temp.p1_lv('良','優','優','優','優','優','優')),
      null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S4：只有資訊正確性 80 低於 85 → weak 只有一個', '資訊正確性:80', pg_temp.p1_jl((v_s1::jsonb) -> 'weak'));

  -- S5：全部良（70）→ 五個可標記面向都 70，只取固定順序的前兩個；語氣與文字剛好 70 不算偏低
  v_a := pg_temp.p1_mkrep('MI-9555', 'draft', null, jsonb_build_array(pg_temp.p1_all('良'), pg_temp.p1_all('良'), pg_temp.p1_all('良')), null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S5：五個面向並列 70 → 依面向固定順序取資訊正確性、預設訊息運用', '資訊正確性:70,預設訊息運用:70', pg_temp.p1_jl((v_s1::jsonb) -> 'weak'));
  perform pg_temp.vr_eq('6 弱項', 'S5：語氣與禮貌、文字品質剛好 70 → always_low 為空', '(空)', pg_temp.p1_jl((v_s1::jsonb) -> 'always_low'));

  -- S6：語氣、文字很低 → 只進 always_low，不進 weak；風險意識 13.3（四捨五入到小數 1 位）
  v_a := pg_temp.p1_mkrep('MI-9556', 'draft', null, jsonb_build_array(
      pg_temp.p1_lv('優','優','優','優','待加強','不及格','待加強'),
      pg_temp.p1_lv('優','優','優','優','不及格','不及格','待加強'),
      pg_temp.p1_lv('優','優','優','優','不及格','不及格','待加強')),
      null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S6：語氣 0、文字 40 → always_low（固定順序）；weak 只有風險意識 13.3', '語氣與禮貌:0,文字品質:40/風險意識:13.3',
    pg_temp.p1_jl((v_s1::jsonb) -> 'always_low') || '/' || pg_temp.p1_jl((v_s1::jsonb) -> 'weak'));

  -- S7：追加題不計入（追加題再低、沒評完都不影響）
  v_a := pg_temp.p1_mkrep('MI-9557', 'draft', null, s1,
      jsonb_build_array(v_lowx, v_lowx, '{}'::jsonb), '正式', 'vr-cs@2motor.tw');
  perform pg_temp.vr_eq('6 弱項', 'S7：有 3 個追加題（2 個全不及格、1 個沒評）→ 核心 3、追加 3', '3/3', pg_temp.p1_cnt(v_a));
  perform pg_temp.vr_eq('6 弱項', 'S7：追加題不計入，結果與 S1（同核心題組）完全相同', 'true',
    (pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a))::jsonb
       = pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text',
           (select a.id from public.assessments a where a.employee_id = 'MI-9551')))::jsonb)::text);

  -- S8：某面向所有題組都不適用 → rates 為 null、不進 weak
  v_a := pg_temp.p1_mkrep('MI-9558', 'draft', null, jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','優','優','優','優'), pg_temp.p1_lv('不適用','不適用','優','優','優','優','優'), pg_temp.p1_lv('不適用','不適用','優','優','優','優','優')),
      null, '正式', 'vr-cs@2motor.tw');
  v_s1 := pg_temp.vr_cs(format('select public.assess_draft_weak(%L::uuid)::text', v_a));
  perform pg_temp.vr_eq('6 弱項', 'S8：資訊正確性全部不適用 → rates 為 null、weak 為空', 'null/(空)',
    (select coalesce(e.v ->> 'pct', 'null') from jsonb_array_elements((v_s1::jsonb) -> 'rates') e(v) where e.v ->> 'dim' = '資訊正確性')
    || '/' || pg_temp.p1_jl((v_s1::jsonb) -> 'weak'));

  -- 拒絕條件
  v_a := pg_temp.p1_mkrep('MI-9559', 'draft', null, jsonb_build_array(pg_temp.p1_all('優'), '{"資訊正確性":"優"}'::jsonb, pg_temp.p1_all('優')), null, '正式', 'vr-cs@2motor.tw');
  perform pg_temp.vr_csdeny('6 弱項', '核心題組有一題只評一部分 → 拒絕（未評完）',
    format('select public.assess_draft_weak(%L::uuid)::text', v_a), '%第 2 題組尚未評完%');
  v_a := pg_temp.p1_mkrep('MI-9560', 'draft', null, jsonb_build_array(pg_temp.p1_all('優'), '{}'::jsonb, pg_temp.p1_all('優')), null, '正式', 'vr-cs@2motor.tw');
  perform pg_temp.vr_csdeny('6 弱項', '核心題組有一題完全沒評 → 拒絕',
    format('select public.assess_draft_weak(%L::uuid)::text', v_a), '%第 2 題組尚未評完%');
  perform pg_temp.p1_emp('MI-9549', 'ZZ-P1', 400, '已上線');
  v_a := pg_temp.p1_mkrep('MI-9549', 'draft', null, '[]'::jsonb, null, '正式', 'vr-cs@2motor.tw');
  perform pg_temp.vr_csdeny('6 弱項', '沒有任何核心題組 → 拒絕', format('select public.assess_draft_weak(%L::uuid)::text', v_a), '%還沒有核心題組%');
  perform pg_temp.vr_deny('6 弱項', '別位客服部的草稿 → 拒絕', 'authenticated', 'vr-cs2@2motor.tw',
    format('select public.assess_draft_weak(%L::uuid)::text', (select a.id from public.assessments a where a.employee_id = 'MI-9551')),
    '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_csdeny('6 弱項', '已送出的成績單 → 拒絕',
    format('select public.assess_draft_weak(%L::uuid)::text', pg_temp.p1_mkrep('MI-9552', 'submitted', '及格', jsonb_build_array(pg_temp.p1_all('優')))),
    '%只有草稿可以分析弱項%');
  perform pg_temp.vr_csdeny('6 弱項', '找不到考核', $q$select public.assess_draft_weak('00000000-0000-0000-0000-000000000000'::uuid)::text$q$, '%找不到考核%');
  perform pg_temp.vr_csdeny('6 弱項', 'null 的考核 id', $q$select public.assess_draft_weak(null)::text$q$, '%找不到考核%');
exception when others then
  perform pg_temp.vr_rec('區段 6','assess_draft_weak 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：assess_add_extra
-- ============================================================
do $$
declare
  i int;
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_d uuid;
  v_e uuid;
  e1 bigint; e2 bigint; e3 bigint; e4 bigint; e5 bigint;
  v_core_q bigint;
  v_r text;
  v_q bigint;
  v_core_free bigint;
begin
  perform set_config('request.jwt.claims', '', true);
  for i in 61 .. 66 loop
    perform pg_temp.p1_emp('MI-95' || i, 'ZZ-P1', 400, '已上線');
  end loop;

  v_a := pg_temp.p1_open('MI-9561');
  e1 := pg_temp.p1_freeq(v_a, 'ZZ追', 1); e2 := pg_temp.p1_freeq(v_a, 'ZZ追', 2); e3 := pg_temp.p1_freeq(v_a, 'ZZ追', 3);
  e4 := pg_temp.p1_freeq(v_a, 'ZZ追', 4); e5 := pg_temp.p1_freeq(v_a, 'ZZ追', 5);

  -- 核心還沒評完
  perform pg_temp.vr_eq('7 追加題', '核心題組都沒評 → 拒絕', 'ERROR: 核心題組尚未評完，不能追加弱項題（第 1 題組：七個面向必須全部有值）',
    pg_temp.p1_extra(v_a, array[e1]));
  perform pg_temp.p1_rate(v_a, 1, pg_temp.p1_all('優'));
  perform pg_temp.vr_eq('7 追加題', '只評完第 1 題 → 仍拒絕', 'ERROR: 核心題組尚未評完，不能追加弱項題（第 2 題組：七個面向必須全部有值）',
    pg_temp.p1_extra(v_a, array[e1]));
  perform pg_temp.vr_eq('7 追加題', '拒絕後沒有寫入任何追加題、extra_started_at 仍是空', '3/0/null',
    pg_temp.p1_cnt(v_a) || '/' || coalesce((select a.extra_started_at::text from public.assessments a where a.id = v_a), 'null'));
  perform pg_temp.p1_rate(v_a, 2, pg_temp.p1_all('優'));
  perform pg_temp.p1_rate(v_a, 3, pg_temp.p1_lv('優','優','待加強','良','優','優','優'));

  -- 沒有核心題組
  v_b := pg_temp.vr_cs($q$select public.assess_start('MI-9562', null)::text$q$)::uuid;
  perform pg_temp.vr_eq('7 追加題', '只有 assess_start、還沒抽核心題組 → 拒絕', 'ERROR: 這場考核還沒有核心題組，不能追加弱項題',
    pg_temp.p1_extra(v_b, array[e1]));

  -- 權限與身分
  perform pg_temp.vr_eq('7 追加題', '別位客服部的草稿 → 拒絕', 'ERROR: 只有建立者本人可以操作這張考核', pg_temp.p1_extra(v_a, array[e1], 'vr-cs2@2motor.tw'));
  perform pg_temp.vr_eq('7 追加題', '已送出的成績單 → 拒絕', 'ERROR: 只有草稿可以追加題組',
    pg_temp.p1_extra(pg_temp.p1_mkrep('MI-9562', 'submitted', '及格', jsonb_build_array(pg_temp.p1_all('優'))), array[e1]));
  perform pg_temp.vr_eq('7 追加題', '找不到考核', 'ERROR: 找不到考核', pg_temp.p1_extra('00000000-0000-0000-0000-000000000000'::uuid, array[e1]));

  -- 參數驗證
  perform pg_temp.vr_eq('7 追加題', 'null 陣列', 'ERROR: 請至少選一個題組', pg_temp.vr_cs(format($q$select count(*)::text from public.assess_add_extra(%L::uuid, null)$q$, v_a)));
  perform pg_temp.vr_eq('7 追加題', '空陣列', 'ERROR: 請至少選一個題組', pg_temp.p1_extra(v_a, array[]::bigint[]));
  perform pg_temp.vr_eq('7 追加題', '陣列含 null', 'ERROR: 題組編號不可空白', pg_temp.vr_cs(format($q$select count(*)::text from public.assess_add_extra(%L::uuid, array[%s, null]::bigint[])$q$, v_a, e1)));
  perform pg_temp.vr_eq('7 追加題', '題組重複', 'ERROR: 題組不可重複選取', pg_temp.p1_extra(v_a, array[e1, e1]));
  perform pg_temp.vr_eq('7 追加題', '一次 5 題 → 一次最多 4 題', 'ERROR: 一次最多追加 4 題（目前 5 題）', pg_temp.p1_extra(v_a, array[e1, e2, e3, e4, e5]));
  perform pg_temp.vr_eq('7 追加題', '題組不存在', 'ERROR: 題組不存在：999999999', pg_temp.p1_extra(v_a, array[e1, 999999999]));
  select sx.question_id into v_core_q from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id = i.id
   where i.assessment_id = v_a and i.seq = 1;
  perform pg_temp.vr_eq('7 追加題', '追加的題組已經是這場的核心題組 → 拒絕', 'ERROR: 這個題組已在這場考核內，不可重複選取', pg_temp.p1_extra(v_a, array[e1, v_core_q]));
  perform pg_temp.vr_eq('7 追加題', '所有被拒的呼叫都沒有留下任何東西（整批回復）', '3/0/null/false',
    pg_temp.p1_cnt(v_a) || '/' || coalesce((select a.extra_started_at::text from public.assessments a where a.id = v_a), 'null')
    || '/' || (exists (select 1 from public.drawn d where d.question_id in (e1, e2, e3, e4, e5)))::text);

  -- 成功：一題，檢查回傳欄位與寫入
  v_r := pg_temp.vr_cs(format($q$select r.category || '/' || r.repeated::text || '/' || r.new_round::text || '/' || (r.item_id is not null)::text
                                  from public.assess_add_extra(%L::uuid, array[%s]::bigint[]) r$q$, v_a, e1));
  perform pg_temp.vr_eq('7 追加題', '追加 1 題：分類 ZZ追、repeated＝false、new_round＝false、有 item_id', 'ZZ追/false/false/true', v_r);
  perform pg_temp.vr_eq('7 追加題', '回傳欄位與 assess_draw 完全相同', 'true',
    (pg_get_function_result('public.assess_add_extra(uuid, bigint[])'::regprocedure) = pg_get_function_result('public.assess_draw(uuid, text[])'::regprocedure))::text);
  perform pg_temp.vr_eq('7 追加題', '寫入：核心 3、追加 1；追加題 seq＝4、is_extra＝true、有機密列（題號、was_drawn_before＝false）', '3/1/4/true/e1/false',
    pg_temp.vr_q1(format($q$select pg_temp.p1_cnt(%L::uuid) || '/' || i.seq::text || '/' || i.is_extra::text || '/'
                              || case when sx.question_id = %s then 'e1' else 'other' end || '/' || sx.was_drawn_before::text
                            from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id = i.id
                            where i.assessment_id = %L::uuid and i.is_extra$q$, v_a, e1, v_a)));
  perform pg_temp.vr_eq('7 追加題', 'extra_started_at 第一次追加就寫入', 'true',
    (select (a.extra_started_at is not null)::text from public.assessments a where a.id = v_a));
  perform pg_temp.vr_eq('7 追加題', 'drawn 有這題、category_last（ZZ追）＝這題', 'true/true',
    (exists (select 1 from public.drawn d where d.question_id = e1))::text || '/'
    || (exists (select 1 from public.category_last l where l.category = 'ZZ追' and l.question_id = e1))::text);

  -- extra_started_at 只寫第一次：改成哨兵值再追加，不得被覆蓋
  update public.assessments set extra_started_at = timestamptz '2020-01-01 00:00:00+00' where id = v_a;
  perform pg_temp.vr_eq('7 追加題', '第二次追加 2 題（同分類 ZZ追，追加題可同分類、前一題追加題還沒評也可繼續追加）', '2', pg_temp.p1_extra(v_a, array[e2, e3]));
  perform pg_temp.vr_eq('7 追加題', 'extra_started_at 只寫第一次（哨兵值沒被覆蓋）', 'true',
    (select (a.extra_started_at = timestamptz '2020-01-01 00:00:00+00')::text from public.assessments a where a.id = v_a));
  perform pg_temp.vr_eq('7 追加題', '同一次呼叫的兩題都更新 drawn；category_last 是該次最後一題', 'true/true',
    (exists (select 1 from public.drawn d where d.question_id = e2) and exists (select 1 from public.drawn d where d.question_id = e3))::text || '/'
    || (exists (select 1 from public.category_last l where l.category = 'ZZ追' and l.question_id = e3))::text);
  -- 與核心題組同分類
  v_core_free := pg_temp.p1_freeq(v_a, 'ZZ核1', 1);
  perform pg_temp.vr_eq('7 追加題', '追加與核心題組同分類（ZZ核1）的題 → 成功（不受每分類一題限制）', '1', pg_temp.p1_extra(v_a, array[v_core_free]));
  perform pg_temp.vr_eq('7 追加題', '現在核心 3、追加 4', '3/4', pg_temp.p1_cnt(v_a));
  perform pg_temp.vr_eq('7 追加題', '整場追加題已滿 4 題，再追加 1 題 → 拒絕', 'ERROR: 整場追加題最多 4 題（已追加 4 題，這次要再追加 1 題）', pg_temp.p1_extra(v_a, array[e4]));
  perform pg_temp.vr_eq('7 追加題', '追加題可以用 assess_save_item 評分', 'OK',
    pg_temp.p1_rate(v_a, 4, pg_temp.p1_all('良')));
  perform pg_temp.vr_eq('7 追加題', '追加題 seq 連續（4、5、6、7）', '4,5,6,7',
    pg_temp.vr_q1(format($q$select string_agg(seq::text, ',' order by seq) from public.assessment_items where assessment_id = %L::uuid and is_extra$q$, v_a)));

  -- 整場上限：3 + 2 → 拒絕、3 + 1 → 成功
  v_c := pg_temp.p1_open('MI-9563');
  perform pg_temp.p1_rate3(v_c, pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  e1 := pg_temp.p1_freeq(v_c, 'ZZ追', 1); e2 := pg_temp.p1_freeq(v_c, 'ZZ追', 2); e3 := pg_temp.p1_freeq(v_c, 'ZZ追', 3);
  e4 := pg_temp.p1_freeq(v_c, 'ZZ追', 4); e5 := pg_temp.p1_freeq(v_c, 'ZZ追', 5);
  perform pg_temp.vr_eq('7 追加題', '一次追加 3 題成功', '3', pg_temp.p1_extra(v_c, array[e1, e2, e3]));
  perform pg_temp.vr_eq('7 追加題', '已有 3 題再追加 2 題 → 整場超過 4 題被拒', 'ERROR: 整場追加題最多 4 題（已追加 3 題，這次要再追加 2 題）', pg_temp.p1_extra(v_c, array[e4, e5]));
  perform pg_temp.vr_eq('7 追加題', '被拒後仍是 3 題追加', '3/3', pg_temp.p1_cnt(v_c));
  perform pg_temp.vr_eq('7 追加題', '再追加 1 題 → 剛好 4 題成功', '1', pg_temp.p1_extra(v_c, array[e4]));
  perform pg_temp.vr_eq('7 追加題', '一次追加剛好 4 題（新的一場）成功', '4',
    pg_temp.p1_extra((select x from (select pg_temp.p1_open('MI-9564') as x) y where pg_temp.p1_rate3(x, pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優')) = 'OK'),
                     array(select q.id from public.questions q where q.category = 'ZZ追' order by q.id limit 4)));

  -- repeated：該考生以前考過的題
  v_q := (select q.id from public.questions q where q.category = 'ZZ追' order by q.id offset 5 limit 1);
  v_d := pg_temp.p1_mkrep('MI-9565', 'submitted', '及格', jsonb_build_array(pg_temp.p1_all('優')));
  insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps)
  select i.id, v_q, false, 'x', '[]'::jsonb from public.assessment_items i where i.assessment_id = v_d;
  v_e := pg_temp.p1_open('MI-9565');
  perform pg_temp.p1_rate3(v_e, pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  perform pg_temp.vr_eq('7 追加題', '考生以前考過的題 → repeated＝true', 'true',
    pg_temp.vr_cs(format($q$select r.repeated::text from public.assess_add_extra(%L::uuid, array[%s]::bigint[]) r$q$, v_e, v_q)));

  -- new_round：該分類全部都在 drawn 內時先開新一輪
  insert into public.drawn (question_id) select q.id from public.questions q where q.category = 'ZZ追' on conflict do nothing;
  v_q := (select q.id from public.questions q where q.category = 'ZZ追' order by q.id offset 1 limit 1);
  perform pg_temp.vr_eq('7 追加題', '該分類全部已抽過 → new_round＝true', 'true',
    pg_temp.vr_cs(format($q$select r.new_round::text from public.assess_add_extra(%L::uuid, array[%s]::bigint[]) r$q$,
      (select x from (select pg_temp.p1_open('MI-9566') as x) y where pg_temp.p1_rate3(x, pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優')) = 'OK'), v_q)));
  perform pg_temp.vr_eq('7 追加題', '開新一輪後：該分類的 drawn 清掉舊的、只留這一題', '1',
    (select count(*) from public.drawn d join public.questions q on q.id = d.question_id where q.category = 'ZZ追')::text);

  -- 放棄考核（既有 assess_abandon）：追加題一併刪除，was_drawn_before＝false 的回到題池
  perform pg_temp.vr_set('abandon_qs', (select string_agg(sx.question_id::text, ',') from public.assessment_items i
                         join public.assessment_item_secrets sx on sx.item_id = i.id
                         where i.assessment_id = v_c and sx.was_drawn_before = false));
  perform pg_temp.vr_eq('7 追加題', '（備料）v_c 有 7 筆題組（核心 3＋追加 4）', '3/4', pg_temp.p1_cnt(v_c));
  perform pg_temp.vr_ok('7 追加題', 'assess_abandon 放棄含追加題的草稿', 'vr-cs@2motor.tw', format($q$select public.assess_abandon(%L::uuid)$q$, v_c));
  perform pg_temp.vr_eq('7 追加題', '放棄後：題組全部刪除', '0/0', pg_temp.p1_cnt(v_c));
  perform pg_temp.vr_eq('7 追加題', '放棄後：was_drawn_before＝false 的題（含追加題）都從 drawn 移除', 'false',
    (exists (select 1 from public.drawn d where d.question_id = any(string_to_array(pg_temp.vr_get('abandon_qs'), ',')::bigint[])))::text);

exception when others then
  perform pg_temp.vr_rec('區段 7','assess_add_extra 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- 小工具：整場流程（開考核、抽核心題組、評核心、追加題、評追加題、送出）。
-- p_core＝三個核心題組的 levels（jsonb 陣列）；p_extras＝追加題 levels（jsonb 陣列，可 null）；
-- p_submit＝false 時停在評完、不送出。送出結果記在 vr_ctx（'res_' || 員工編號），成績單 id 記在 'aid_' || 員工編號。
create or replace function pg_temp.p1_full(p_emp text, p_core jsonb, p_extras jsonb default null, p_submit boolean default true)
returns uuid language plpgsql as $$
declare
  v_a uuid;
  r text;
  i int;
  n int := coalesce(jsonb_array_length(p_extras), 0);
  ids bigint[];
begin
  v_a := pg_temp.p1_open(p_emp);
  r := pg_temp.p1_rate3(v_a, p_core -> 0, p_core -> 1, p_core -> 2);
  if r <> 'OK' then raise exception '評核心失敗：%', r; end if;
  if n > 0 then
    select array_agg(x.id order by x.k) into ids
    from (select k, pg_temp.p1_freeq(v_a, 'ZZ追', k) as id from generate_series(1, n) k) x;
    r := pg_temp.p1_extra(v_a, ids);
    if r like 'ERROR%' then raise exception '追加失敗：%', r; end if;
    for i in 1 .. n loop
      r := pg_temp.p1_rate(v_a, 3 + i, p_extras -> (i - 1));
      if r <> 'OK' then raise exception '評追加題失敗：%', r; end if;
    end loop;
  end if;
  perform pg_temp.vr_set('aid_' || p_emp, v_a::text);
  if p_submit then
    perform pg_temp.vr_set('res_' || p_emp, pg_temp.p1_submit(v_a));
  end if;
  return v_a;
end $$;

-- ============================================================
-- 區段 8：assess_submit（追加題不算分、考核期通過轉已上線＋待開通）
-- ============================================================
do $$
declare
  i int;
  v_a uuid;
  v_ex_low jsonb := jsonb_build_array(pg_temp.p1_all('不及格'), pg_temp.p1_all('不及格'));
  v_ex_hi jsonb := jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  c_mix jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','待加強','良','優','待加強','良'),
      pg_temp.p1_lv('優','良','良','良','優','待加強','良'),
      pg_temp.p1_lv('良','良','不及格','優','良','優','待加強'));
  c_all_good jsonb := jsonb_build_array(pg_temp.p1_all('良'), pg_temp.p1_all('良'), pg_temp.p1_all('良'));
  c_all_top jsonb := jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  -- 三題組平均四捨五入＝69.9（70、85、54.6）與 84.9（70、100、84.6）
  c_699 jsonb := jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','優','待加強'),
      pg_temp.p1_lv('不適用','優','優','優','優','待加強','待加強'),
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','待加強','不及格'));
  c_849 jsonb := jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','優','待加強'),
      pg_temp.p1_all('優'),
      pg_temp.p1_lv('不適用','不適用','優','優','優','優','不及格'));
  -- 剛好 85.0：問題掌握、主動引導、語氣、文字為良，其餘優
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
  v_oracle text;
  v_exp text;
  v_weak_a text;
  v_weak_b text;
  v_tk1 text;
  v_tk2 text;
  v_pid uuid;
  v_r text;
begin
  perform set_config('request.jwt.claims', '', true);
  for i in 71 .. 78 loop
    perform pg_temp.p1_emp('MI-95' || i, 'ZZ-P1', 400, '已上線');
  end loop;

  -- A：沒有追加題的正式員工（基準）。預期值用既有純計算函式算（assess_score_session／assess_verdict）
  select ss.total_score::text into v_oracle from public.assess_score_session(c_mix) ss;
  select v_oracle || '/' || vd.verdict || '/' || vd.pass_line::text || '/3/正式' into v_exp from public.assess_verdict(v_oracle::numeric, '正式') vd;
  perform pg_temp.p1_full('MI-9571', c_mix);
  perform pg_temp.vr_eq('8 送出', 'A 沒有追加題：總分／判定／合格線／題組數／身分與既有計算一致', v_exp, pg_temp.vr_get('res_MI-9571'));
  v_weak_a := (select array_to_string(a.weakest_dims, ',') from public.assessments a where a.employee_id = 'MI-9571');
  perform pg_temp.vr_eq('8 送出', 'A 最弱面向與 assess_score_session 一致', (select array_to_string(ss.weakest_dims, ',') from public.assess_score_session(c_mix) ss), v_weak_a);

  -- B：同樣的核心題組，另加 2 個全不及格的追加題 → 結果必須與 A 完全相同
  perform pg_temp.p1_full('MI-9572', c_mix, v_ex_low);
  perform pg_temp.vr_eq('8 送出', 'B 追加 2 題（全不及格）：總分／判定／題組數與 A 完全相同', v_exp, pg_temp.vr_get('res_MI-9572'));
  v_weak_b := (select array_to_string(a.weakest_dims, ',') from public.assessments a where a.employee_id = 'MI-9572');
  perform pg_temp.vr_eq('8 送出', 'B weakest_dims（成績單）與 A 相同（只看核心）', v_weak_a, v_weak_b);
  perform pg_temp.vr_eq('8 送出', 'B 成績單上的 total_score／verdict 與回傳一致', v_oracle || '/' || split_part(v_exp, '/', 2),
    (select a.total_score::text || '/' || a.verdict from public.assessments a where a.employee_id = 'MI-9572'));
  perform pg_temp.vr_eq('8 送出', 'B 追加題仍寫入各自的 item_score（0.0），核心題組的 item_score 都有值', '2/3',
    pg_temp.vr_q1($q$select (select count(*) from public.assessment_items i join public.assessments a on a.id = i.assessment_id
                              where a.employee_id = 'MI-9572' and i.is_extra and i.item_score = 0)::text
                          || '/' || (select count(*) from public.assessment_items i join public.assessments a on a.id = i.assessment_id
                              where a.employee_id = 'MI-9572' and not i.is_extra and i.item_score is not null)::text$q$));
  perform pg_temp.vr_eq('8 送出', 'B 成績單列表檢視 item_count 只算核心題組（3），實際題組列有 5', '3/5',
    pg_temp.vr_cs($q$select s.item_count::text || '/' || (select count(*) from public.assessment_items i where i.assessment_id = s.id)::text
                     from public.assessment_summaries s where s.employee_id = 'MI-9572'$q$));

  -- C：核心全優、追加題全不及格 → 仍是 100／優秀；追加題全優、核心全良 → 70／不及格（不被追加題拉高）
  perform pg_temp.p1_full('MI-9573', c_all_top, v_ex_low);
  perform pg_temp.vr_eq('8 送出', 'C 核心全優＋追加全不及格：100.0/優秀/85/3/正式', '100.0/優秀/85/3/正式', pg_temp.vr_get('res_MI-9573'));
  perform pg_temp.vr_eq('8 送出', 'C 最弱面向（全部並列）七個都在，不受追加題影響', '資訊正確性,預設訊息運用,問題掌握,主動引導,風險意識,語氣與禮貌,文字品質',
    (select array_to_string(a.weakest_dims, ',') from public.assessments a where a.employee_id = 'MI-9573'));
  perform pg_temp.p1_full('MI-9574', c_all_good, v_ex_hi);
  perform pg_temp.vr_eq('8 送出', 'D 核心全良＋追加全優：70.0/不及格/85/3/正式（正式 70 分為不及格；追加題沒把它拉高）', '70.0/不及格/85/3/正式', pg_temp.vr_get('res_MI-9574'));
  perform pg_temp.p1_full('MI-9575', c_all_good);
  perform pg_temp.vr_eq('8 送出', 'D 對照：同樣核心、沒有追加題，結果相同', pg_temp.vr_get('res_MI-9574'), pg_temp.vr_get('res_MI-9575'));
  -- 改善單：判定不及格 → 開一張，目標面向只看核心
  v_tk1 := (select array_to_string(t.target_dims, ',') || '/' || t.status || '/' || (t.due_date = pg_temp.p1_today() + 14)::text
              from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where a.employee_id = 'MI-9574');
  v_tk2 := (select array_to_string(t.target_dims, ',') || '/' || t.status || '/' || (t.due_date = pg_temp.p1_today() + 14)::text
              from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where a.employee_id = 'MI-9575');
  perform pg_temp.vr_eq('8 送出', '不及格自動開改善單（既有觸發器）：有追加題與沒追加題開出的改善單內容相同', 'true',
    (v_tk1 is not null and v_tk1 = v_tk2)::text);
  perform pg_temp.vr_eq('8 送出', '改善單：目標面向＝核心最弱面向（全部七個）、待改善、14 天內', '資訊正確性,預設訊息運用,問題掌握,主動引導,風險意識,語氣與禮貌,文字品質/open/true', v_tk1);
  -- 作廢不及格成績單 → 改善單自動取消（既有行為）
  perform pg_temp.vr_ok('8 送出', '客服部作廢 D 的成績單（既有 assess_void）', 'vr-cs@2motor.tw',
    format($q$select public.assess_void(%L::uuid, '測試作廢')$q$, pg_temp.vr_get('aid_MI-9574')));
  perform pg_temp.vr_eq('8 送出', '作廢後改善單自動取消（既有觸發器）', 'cancelled',
    (select t.status from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where a.employee_id = 'MI-9574'));

  -- E：追加題未評完不能送出
  v_a := pg_temp.p1_full('MI-9576', c_all_top, null, false);
  perform pg_temp.vr_eq('8 送出', 'E（備料）加 1 題追加題先不評', '1', pg_temp.p1_extra(v_a, array[pg_temp.p1_freeq(v_a, 'ZZ追', 1)]));
  perform pg_temp.vr_eq('8 送出', 'E 追加題未評完 → 不能送出', 'ERROR: 第 4 題組評分不完整或不正確：七個面向必須全部有值', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('8 送出', 'E 被拒後仍是草稿', 'draft', (select a.status from public.assessments a where a.id = v_a));
  perform pg_temp.p1_rate(v_a, 4, pg_temp.p1_all('優'));
  perform pg_temp.vr_eq('8 送出', 'E 評完追加題後可以送出（題組數仍是 3）', '100.0/優秀/85/3/正式', pg_temp.p1_submit(v_a));
  -- F：核心沒評完仍擋；只有追加題沒有核心也擋
  v_a := pg_temp.p1_open('MI-9577');
  perform pg_temp.vr_eq('8 送出', 'F 核心題組沒評 → 不能送出（既有行為）', 'ERROR: 第 1 題組評分不完整或不正確：七個面向必須全部有值', pg_temp.p1_submit(v_a));
  v_a := pg_temp.p1_mkrep('MI-9578', 'draft', null, '[]'::jsonb, jsonb_build_array(pg_temp.p1_all('優')), '正式', 'vr-cs@2motor.tw');
  perform pg_temp.vr_eq('8 送出', 'G 只有追加題、沒有核心題組 → 不能送出', 'ERROR: 至少要有 1 個題組', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('8 送出', 'G 被拒後仍是草稿、員工狀態沒動', 'draft/已上線/無/-', (select a.status from public.assessments a where a.id = v_a) || '/' || pg_temp.p1_st('MI-9578'));

  -- 既有檢查
  v_a := pg_temp.p1_mkrep('MI-9577', 'submitted', '及格', jsonb_build_array(pg_temp.p1_all('優')));
  perform pg_temp.vr_eq('8 送出', '已送出的再送出 → 拒絕', 'ERROR: 只有草稿可以送出', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('8 送出', '找不到考核', 'ERROR: 找不到考核', pg_temp.p1_submit('00000000-0000-0000-0000-000000000000'::uuid));
exception when others then
  perform pg_temp.vr_rec('區段 8A','assess_submit 測試意外中斷','無例外', sqlerrm, false);
end
$$;

do $$
declare
  v_a uuid;
  v_b uuid;
  c_all_good jsonb := jsonb_build_array(pg_temp.p1_all('良'), pg_temp.p1_all('良'), pg_temp.p1_all('良'));
  c_all_top jsonb := jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  v_ex_low jsonb := jsonb_build_array(pg_temp.p1_all('不及格'), pg_temp.p1_all('不及格'));
  v_ex_hi jsonb := jsonb_build_array(pg_temp.p1_all('優'), pg_temp.p1_all('優'));
  c_699 jsonb := jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','優','待加強'),
      pg_temp.p1_lv('不適用','優','優','優','優','待加強','待加強'),
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','待加強','不及格'));
  c_849 jsonb := jsonb_build_array(
      pg_temp.p1_lv('不適用','不適用','優','良','待加強','優','待加強'),
      pg_temp.p1_all('優'),
      pg_temp.p1_lv('不適用','不適用','優','優','優','優','不及格'));
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
  v_today date := pg_temp.p1_today();
  v_pid uuid;
  v_req uuid;
begin
  perform set_config('request.jwt.claims', '', true);

  -- ===== 新人（考核期）通過／未通過 =====
  perform pg_temp.p1_emp('MI-9581', 'ZZ-P1', 20,  '考核期');
  perform pg_temp.p1_emp('MI-9582', 'ZZ-P1', 20,  '考核期');
  perform pg_temp.p1_emp('MI-9583', 'ZZ-P1', 400, '考核期');
  perform pg_temp.p1_emp('MI-9584', 'ZZ-P1', 20,  '已上線');
  perform pg_temp.p1_emp('MI-9585', 'ZZ-P1', 20,  '考核期');
  perform pg_temp.p1_emp('MI-9586', 'ZZ-P1', 20,  '考核期');
  perform pg_temp.p1_emp('MI-9587', 'ZZ-P1', null, '考核期');
  perform pg_temp.p1_emp('MI-9588', 'ZZ-P1', 20,  '考核期');

  perform pg_temp.p1_full('MI-9581', c_all_good);
  perform pg_temp.vr_eq('8 考核期', '新人 70.0（剛好合格線）：70.0/及格/70/3/新人', '70.0/及格/70/3/新人', pg_temp.vr_get('res_MI-9581'));
  perform pg_temp.vr_eq('8 考核期', '通過 → 已上線、無 probation_since、passed_on＝台北今天', '已上線/無/' || v_today::text, pg_temp.p1_st('MI-9581'));
  perform pg_temp.vr_eq('8 考核期', '通過 → 新增 1 筆待開通', '1', pg_temp.p1_act('MI-9581'));
  perform pg_temp.vr_eq('8 考核期', '待開通內容：待開通、通過日、門市、名稱、成績單 id、未填開通資料', '待開通/' || v_today::text || '/ZZ-P1/假員9581/true/true',
    (select r.status || '/' || r.passed_on::text || '/' || r.store_code || '/' || r.employee_label || '/'
            || (r.assessment_id = pg_temp.vr_get('aid_MI-9581')::uuid)::text || '/' || (r.done_on is null and r.done_by is null)::text
       from public.reply_activations r where r.employee_id = 'MI-9581'));
  perform pg_temp.vr_eq('8 考核期', '成績單身分：新人／自動', '新人/自動',
    (select a.tenure || '/' || a.tenure_source from public.assessments a where a.id = pg_temp.vr_get('aid_MI-9581')::uuid));

  -- 69.9 不轉；補考通過才轉
  perform pg_temp.p1_full('MI-9582', c_699);
  perform pg_temp.vr_eq('8 考核期', '新人 69.9：69.9/需複訓/70/3/新人', '69.9/需複訓/70/3/新人', pg_temp.vr_get('res_MI-9582'));
  perform pg_temp.vr_eq('8 考核期', '69.9 不轉：仍是考核期、沒有 passed_on、沒有待開通', '考核期/無/-/0', pg_temp.p1_st('MI-9582') || '/' || pg_temp.p1_act('MI-9582'));
  perform pg_temp.p1_full('MI-9582', c_all_good);
  perform pg_temp.vr_eq('8 考核期', '補考 70.0 通過：轉已上線＋待開通', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9582') || '/' || pg_temp.p1_act('MI-9582'));

  -- 到職很久的考核期、100 分通過
  perform pg_temp.p1_full('MI-9583', c_all_top);
  perform pg_temp.vr_eq('8 考核期', '到職 400 天的考核期人員（身分新人）100 分通過：已上線＋待開通', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9583') || '/' || pg_temp.p1_act('MI-9583'));
  -- 已上線的新人標籤者：通過不新增待開通
  perform pg_temp.p1_full('MI-9584', c_all_top);
  perform pg_temp.vr_eq('8 考核期', '已上線（到職 20 天）通過：不動狀態、沒有 passed_on、不新增待開通', '已上線/無/-/0', pg_temp.p1_st('MI-9584') || '/' || pg_temp.p1_act('MI-9584'));
  -- 追加題不影響通過與否
  perform pg_temp.p1_full('MI-9585', c_all_good, v_ex_low);
  perform pg_temp.vr_eq('8 考核期', '核心 70.0＋追加題全不及格：仍通過（追加題不拉低）', '70.0/及格/70/3/新人', pg_temp.vr_get('res_MI-9585'));
  perform pg_temp.vr_eq('8 考核期', '同上：轉已上線＋待開通', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9585') || '/' || pg_temp.p1_act('MI-9585'));
  perform pg_temp.p1_full('MI-9586', c_699, v_ex_hi);
  perform pg_temp.vr_eq('8 考核期', '核心 69.9＋追加題全優：仍不通過（追加題不拉高）', '69.9/需複訓/70/3/新人', pg_temp.vr_get('res_MI-9586'));
  perform pg_temp.vr_eq('8 考核期', '同上：仍是考核期、沒有待開通', '考核期/無/-/0', pg_temp.p1_st('MI-9586') || '/' || pg_temp.p1_act('MI-9586'));

  -- 不重複新增待開通：同一張成績單已有一筆時送出不報錯也不多一筆
  perform pg_temp.p1_emp('MI-9589', 'ZZ-P1', 20, '考核期');
  v_a := pg_temp.p1_full('MI-9589', c_all_good, null, false);
  insert into public.reply_activations (employee_id, employee_label, store_code, assessment_id, passed_on, status)
  values ('MI-9589', '假員9589', 'ZZ-P1', v_a, v_today, '待開通');
  perform pg_temp.vr_eq('8 考核期', '成績單已有待開通時送出：照常成功', '70.0/及格/70/3/新人', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('8 考核期', '同一張成績單不重複新增待開通（仍只有 1 筆）', '1', pg_temp.p1_act('MI-9589'));
  perform pg_temp.vr_eq('8 考核期', '資料庫層：同一張成績單直接再寫第 2 筆待開通被唯一索引擋下', 'ERROR: duplicate key value violates unique constraint "reply_activations_one_per_assessment"',
    pg_temp.vr_owner(format($q$insert into public.reply_activations (employee_id, employee_label, store_code, assessment_id, passed_on) values ('MI-9589','x','ZZ-P1',%L::uuid, current_date)$q$, v_a)));

  -- 作廢成績單不倒回
  perform pg_temp.vr_ok('8 考核期', '作廢 9581 通過的成績單', 'vr-cs@2motor.tw', format($q$select public.assess_void(%L::uuid, '測試作廢')$q$, pg_temp.vr_get('aid_MI-9581')));
  perform pg_temp.vr_eq('8 考核期', '作廢後：員工仍是已上線、待開通仍在（不倒回）', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9581') || '/' || pg_temp.p1_act('MI-9581'));

  -- 既有的自動完成觸發器：未結案待考回報在送出時完成
  perform pg_temp.vr_eq('8 考核期', '（備料）客服部替 9588 報新人（考核期）', 'true',
    (pg_temp.vr_cs(format($q$select public.exam_req_create('新人', 'MI-9588', array[%L::date], true, '測試')::text$q$, (v_today + 1)::text)) not like 'ERROR%')::text);
  perform pg_temp.p1_full('MI-9588', c_all_good);
  perform pg_temp.vr_eq('8 考核期', '送出後該員工的待考回報自動完成（既有 exam_req_auto_complete 觸發器）', '已完成',
    (select r.status from public.exam_requests r where r.employee_id = 'MI-9588' and r.kind = '新人'));

  -- ===== 回考核期通過／未通過 =====
  perform pg_temp.p1_emp('MI-9591', 'ZZ-P1', 400, '考核期', 3);
  perform pg_temp.p1_emp('MI-9592', 'ZZ-P1', 400, '考核期', 3);
  perform pg_temp.p1_emp('MI-9593', 'ZZ-P1', 400, '考核期', 3);
  perform pg_temp.p1_emp('MI-9594', 'ZZ-P1', 400, '已上線', 3);
  perform pg_temp.p1_emp('MI-9595', 'ZZ-P1', 400, '考核期', 3);
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  select e.id, e.nickname, 'ZZ-P1', '{}'::uuid[], v_today, '待執行'
  from public.employees e where e.id in ('MI-9591', 'MI-9592');

  perform pg_temp.p1_full('MI-9591', c_850);
  perform pg_temp.vr_eq('8 回考核期', '回考核期 85.0（剛好）：85.0/及格/85/3/正式', '85.0/及格/85/3/正式', pg_temp.vr_get('res_MI-9591'));
  perform pg_temp.vr_eq('8 回考核期', '成績單身分：正式／考核期', '正式/考核期',
    (select a.tenure || '/' || a.tenure_source from public.assessments a where a.id = pg_temp.vr_get('aid_MI-9591')::uuid));
  perform pg_temp.vr_eq('8 回考核期', '通過 → 清除 probation_since（既有）、已上線、passed_on、待開通 1 筆', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9591') || '/' || pg_temp.p1_act('MI-9591'));
  perform pg_temp.vr_eq('8 回考核期', '既有行為不變：spot_probations 改「已通過」並記成績單', '已通過/true',
    (select p.status || '/' || (p.passed_assessment_id = pg_temp.vr_get('aid_MI-9591')::uuid)::text from public.spot_probations p where p.employee_id = 'MI-9591'));

  perform pg_temp.p1_full('MI-9592', c_all_good);
  perform pg_temp.vr_eq('8 回考核期', '回考核期 70 分（<85）：70.0/不及格/85/3/正式', '70.0/不及格/85/3/正式', pg_temp.vr_get('res_MI-9592'));
  perform pg_temp.vr_eq('8 回考核期', '<85 什麼都不動：仍在考核期、probation_since 還在、沒有待開通', '考核期/有/-/0', pg_temp.p1_st('MI-9592') || '/' || pg_temp.p1_act('MI-9592'));
  perform pg_temp.vr_eq('8 回考核期', '<85：spot_probations 仍是待執行', '待執行', (select p.status from public.spot_probations p where p.employee_id = 'MI-9592'));
  perform pg_temp.p1_full('MI-9593', c_849);
  perform pg_temp.vr_eq('8 回考核期', '回考核期 84.9：84.9/需複訓/85/3/正式', '84.9/需複訓/85/3/正式', pg_temp.vr_get('res_MI-9593'));
  perform pg_temp.vr_eq('8 回考核期', '84.9 不通過：什麼都不動', '考核期/有/-/0', pg_temp.p1_st('MI-9593') || '/' || pg_temp.p1_act('MI-9593'));

  perform pg_temp.p1_full('MI-9594', c_all_top);
  perform pg_temp.vr_eq('8 回考核期', '回考核期（period_status 仍已上線）100 分通過：已上線、清 probation_since、passed_on、待開通', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9594') || '/' || pg_temp.p1_act('MI-9594'));
  perform pg_temp.p1_full('MI-9595', c_850, v_ex_low);
  perform pg_temp.vr_eq('8 回考核期', '核心 85.0＋追加題全不及格：仍通過', '85.0/及格/85/3/正式', pg_temp.vr_get('res_MI-9595'));
  perform pg_temp.vr_eq('8 回考核期', '同上：已上線＋待開通', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9595') || '/' || pg_temp.p1_act('MI-9595'));

  -- 不是客服部／不是建立者
  perform pg_temp.p1_emp('MI-9596', 'ZZ-P1', 400, '已上線');
  v_b := pg_temp.p1_full('MI-9596', c_all_top, null, false);
  perform pg_temp.vr_eq('8 送出', '別位客服部不能送出別人的草稿', 'ERROR: 只有建立者本人可以操作這張考核', pg_temp.p1_submit(v_b, 'vr-cs2@2motor.tw'));
  perform pg_temp.vr_eq('8 送出', '總公司主管不能送出', 'true',
    (pg_temp.p1_submit(v_b, 'vr-hq@2motor.tw') like 'ERROR: %沒有權限%')::text);
  perform pg_temp.vr_eq('8 送出', '店長不能送出', 'true',
    (pg_temp.p1_submit(v_b, 'vr-sm@2motor.tw') like 'ERROR: %沒有權限%')::text);
exception when others then
  perform pg_temp.vr_rec('區段 8B','考核期通過測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 9：所有分析檢視與函式排除追加題（用有追加題的資料比對前後數值）
-- ============================================================
create or replace function pg_temp.p1_snap(p_a uuid, p_email text default 'vr-cs@2motor.tw')
returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_email,
    format($q$select (select count(*)::text || '/' || coalesce(sum(level_pct), 0)::text from public.analytics_dim_rates where assessment_id = %L::uuid)
                     || '|' || coalesce((select item_count::text from public.assessment_summaries where id = %L::uuid), '看不到')$q$, p_a, p_a), true);
$$;

do $$
declare
  v_a uuid;
  v_before text;
  v_after text;
  v_wb text;
  v_wa text;
  v_lowx jsonb := pg_temp.p1_all('不及格');
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9601', 'ZZ-P1', 400, '已上線');

  v_a := pg_temp.p1_mkrep('MI-9601', 'submitted', '及格', jsonb_build_array(
      pg_temp.p1_lv('優','優','待加強','良','優','待加強','良'),
      pg_temp.p1_lv('優','良','良','良','優','待加強','良'),
      pg_temp.p1_lv('優','良','良','良','優','待加強','良')));
  v_before := pg_temp.p1_snap(v_a);
  v_wb := pg_temp.vr_cs($q$select public.assess_weak_profile('MI-9601')::text$q$);
  perform pg_temp.vr_eq('9 排除追加題', '（基準）沒有追加題：analytics 21 列（3 題組×7 面向）、summaries item_count＝3', '21/' || (select sum(public.assess_level_pct(i.levels ->> d.dim))::int from public.assessment_items i cross join unnest(public.assess_dim_order()) d(dim) where i.assessment_id = v_a)::text || '|3', v_before);

  -- 同一張成績單加入 2 個極端的追加題
  insert into public.assessment_items (assessment_id, seq, category, code, levels, is_extra)
  values (v_a, 4, 'ZZ報x', null, v_lowx, true), (v_a, 5, 'ZZ報y', null, v_lowx, true);
  v_after := pg_temp.p1_snap(v_a);
  v_wa := pg_temp.vr_cs($q$select public.assess_weak_profile('MI-9601')::text$q$);
  perform pg_temp.vr_eq('9 排除追加題', 'analytics_dim_rates：加入追加題後列數與等級總和完全不變', v_before, v_after);
  perform pg_temp.vr_eq('9 排除追加題', 'assessment_summaries.item_count：加入追加題後仍是 3', '3', split_part(v_after, '|', 2));
  perform pg_temp.vr_eq('9 排除追加題', 'assess_weak_profile：加入追加題後結果完全不變', v_wb, v_wa);
  perform pg_temp.vr_eq('9 排除追加題', 'assess_weak_profile 仍有正確的核心數字（n＝1、問題掌握 60）', '1/60',
    ((v_wa::jsonb) ->> 'n') || '/' || (select e.v ->> 'pct' from jsonb_array_elements((v_wa::jsonb) -> 'rates') e(v) where e.v ->> 'dim' = '問題掌握'));
  -- 其他角色看到的也一樣（RLS 之外，檢視同樣排除）
  perform pg_temp.vr_eq('9 排除追加題', '總公司主管看 analytics／summaries 一樣排除追加題', v_before, pg_temp.p1_snap(v_a, 'vr-hq@2motor.tw'));
  perform pg_temp.vr_eq('9 排除追加題', '本店店長看到的一樣', v_before, pg_temp.p1_snap(v_a, 'vr-sm@2motor.tw'));
  perform pg_temp.vr_eq('9 排除追加題', '他店店長看不到（analytics 0 列、summaries 看不到）', '0/0|看不到', pg_temp.p1_snap(v_a, 'vr-sm2@2motor.tw'));
  -- 對照組：把追加題改成核心後數字會變（證明上面的比對有鑑別力）
  update public.assessment_items set is_extra = false where assessment_id = v_a and seq in (4, 5);
  perform pg_temp.vr_eq('9 排除追加題', '（對照）若追加題算核心：item_count 變 5、analytics 變 35 列、weak_profile 改變', 'true',
    (split_part(pg_temp.p1_snap(v_a), '|', 2) = '5'
     and pg_temp.p1_snap(v_a) like '35/%'
     and pg_temp.vr_cs($q$select public.assess_weak_profile('MI-9601')::text$q$) <> v_wb)::text);
  update public.assessment_items set is_extra = true where assessment_id = v_a and seq in (4, 5);

  -- 成績單 weakest_dims／判定也不被追加題影響：見區段 8（B、C、D 對照）
exception when others then
  perform pg_temp.vr_rec('區段 9','排除追加題測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 10：待開通（activation_mark_done、reply_activations 的 RLS）
-- ============================================================
do $$
declare
  v_ra1 uuid; v_ra2 uuid; v_ra3 uuid;
  v_sql text := $q$select count(*)::text from public.reply_activations where employee_id in ('MI-9611','MI-9612')$q$;
  v_today date := pg_temp.p1_today();
  v_aid uuid;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9611', 'ZZ-P1', 20, '已上線');
  perform pg_temp.p1_emp('MI-9612', 'ZZ-P2', 20, '已上線');
  insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9611', '假員9611', 'ZZ-P1', v_today) returning id into v_ra1;
  insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9612', '假員9612', 'ZZ-P2', v_today) returning id into v_ra2;
  insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9611', '假員9611', 'ZZ-P1', v_today) returning id into v_ra3;

  -- RLS（看得到哪些）
  perform pg_temp.vr_eq('10 待開通 RLS', '客服部看全部（3 筆）', '3', pg_temp.vr_cs(v_sql));
  perform pg_temp.vr_eq('10 待開通 RLS', '總公司主管看全部（3 筆）', '3', pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', v_sql, true));
  perform pg_temp.vr_eq('10 待開通 RLS', '店長（ZZ-P1）只看本店（2 筆）', '2', pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', v_sql, true));
  perform pg_temp.vr_eq('10 待開通 RLS', '他店店長（ZZ-P2）只看自己店（1 筆）', '1', pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', v_sql, true));
  perform pg_temp.vr_eq('10 待開通 RLS', '未開通帳號看不到（0 筆）', '0', pg_temp.vr_as('authenticated', 'vr-none@2motor.tw', v_sql, true));
  perform pg_temp.vr_eq('10 待開通 RLS', '沒有登入者（JWT 空）看不到（0 筆）', '0', pg_temp.vr_as('authenticated', null, v_sql, true));
  perform pg_temp.vr_deny('10 待開通 RLS', 'anon 讀取被拒', 'anon', null, v_sql, '%permission denied%');
  -- 直接寫入全部被拒
  perform pg_temp.vr_csdeny('10 待開通 RLS', '客服部直接 insert 被拒',
    $q$insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9611','x','ZZ-P1', current_date)$q$, '%permission denied%');
  perform pg_temp.vr_csdeny('10 待開通 RLS', '客服部直接 update 被拒', $q$update public.reply_activations set status = '已開通'$q$, '%permission denied%');
  perform pg_temp.vr_csdeny('10 待開通 RLS', '客服部直接 delete 被拒', 'delete from public.reply_activations', '%permission denied%');
  perform pg_temp.vr_csdeny('10 待開通 RLS', '客服部直接 truncate 被拒', 'truncate public.reply_activations', '%permission denied%');
  perform pg_temp.vr_deny('10 待開通 RLS', '店長直接 update 被拒', 'authenticated', 'vr-sm@2motor.tw', $q$update public.reply_activations set status = '已開通'$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 待開通 RLS', '總公司主管直接 delete 被拒', 'authenticated', 'vr-hq@2motor.tw', 'delete from public.reply_activations', '%permission denied%');
  perform pg_temp.vr_deny('10 待開通 RLS', 'anon 直接 insert 被拒', 'anon', null,
    $q$insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9611','x','ZZ-P1', current_date)$q$, '%permission denied%');
  perform pg_temp.vr_eq('10 待開通 RLS', '被拒後三筆資料都還是待開通', '3',
    pg_temp.vr_q1($q$select count(*)::text from public.reply_activations where employee_id in ('MI-9611','MI-9612') and status = '待開通'$q$));

  -- activation_mark_done
  perform pg_temp.vr_deny('10 標記已開通', '店長不能標記（即使是自己店的）', 'authenticated', 'vr-sm@2motor.tw', format($q$select public.activation_mark_done(%L::uuid)::text$q$, v_ra1), '%沒有權限%');
  perform pg_temp.vr_deny('10 標記已開通', '總公司主管不能標記', 'authenticated', 'vr-hq@2motor.tw', format($q$select public.activation_mark_done(%L::uuid)::text$q$, v_ra1), '%沒有權限%');
  perform pg_temp.vr_eq('10 標記已開通', '被拒後仍是待開通', '待開通', (select status from public.reply_activations where id = v_ra1));
  perform pg_temp.vr_csdeny('10 標記已開通', '找不到紀錄', $q$select public.activation_mark_done('00000000-0000-0000-0000-000000000000'::uuid)::text$q$, '%找不到待開通紀錄%');
  perform pg_temp.vr_csdeny('10 標記已開通', 'null id', $q$select public.activation_mark_done(null)::text$q$, '%找不到待開通紀錄%');
  perform pg_temp.vr_csok('10 標記已開通', '客服部標記已開通', format($q$select public.activation_mark_done(%L::uuid)$q$, v_ra1));
  perform pg_temp.vr_eq('10 標記已開通', '標記後：已開通、done_on＝台北今天、done_by＝操作者信箱', '已開通/' || v_today::text || '/vr-cs@2motor.tw',
    (select status || '/' || done_on::text || '/' || done_by from public.reply_activations where id = v_ra1));
  perform pg_temp.vr_deny('10 標記已開通', '已開通者不可重複標記（另一位客服部也一樣）', 'authenticated', 'vr-cs2@2motor.tw',
    format($q$select public.activation_mark_done(%L::uuid)::text$q$, v_ra1), '%已經是「已開通」，不可重複標記%');
  perform pg_temp.vr_eq('10 標記已開通', '重複標記被拒後，done_by 沒被改成第二個人', 'vr-cs@2motor.tw', (select done_by from public.reply_activations where id = v_ra1));
  perform pg_temp.vr_ok('10 標記已開通', '另一位客服部標記另一筆', 'vr-cs2@2motor.tw', format($q$select public.activation_mark_done(%L::uuid)$q$, v_ra3));
  perform pg_temp.vr_eq('10 標記已開通', '另一筆的 done_by 是第二位客服部', 'vr-cs2@2motor.tw', (select done_by from public.reply_activations where id = v_ra3));
  perform pg_temp.vr_eq('10 標記已開通', '沒標記的那筆仍是待開通、沒有開通資料', '待開通/true', (select status || '/' || (done_on is null and done_by is null)::text from public.reply_activations where id = v_ra2));
  perform pg_temp.vr_eq('10 標記已開通', '資料庫層：已開通必須有日期與人（只改狀態被 check 擋下）', 'ERROR: new row for relation "reply_activations" violates check constraint "reply_activations_status_fields"',
    pg_temp.vr_owner(format($q$update public.reply_activations set status = '已開通' where id = %L::uuid$q$, v_ra2)));
  perform pg_temp.vr_eq('10 標記已開通', '資料庫層：status 只能是待開通／已開通', 'true',
    (pg_temp.vr_owner(format($q$update public.reply_activations set status = '亂寫' where id = %L::uuid$q$, v_ra2)) like 'ERROR:%')::text);
exception when others then
  perform pg_temp.vr_rec('區段 10','待開通測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 11：待考回報資格（新規則：新人＝考核期且無 probation_since）
-- ============================================================
do $$
declare
  v_today date := pg_temp.p1_today();
  v_d text := (pg_temp.p1_today() + 2)::text;
  v_lst text := $q$select coalesce(string_agg(employee_id, ',' order by employee_id), '(空)') from public.exam_req_candidates(%L) where employee_id between 'MI-9621' and 'MI-9630'$q$;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9621', 'ZZ-P1', 400,  '考核期');            -- 考核期、到職超過 90 天
  perform pg_temp.p1_emp('MI-9622', 'ZZ-P1', 20,   '已上線');            -- 已上線、到職 20 天（新人標籤）
  perform pg_temp.p1_emp('MI-9623', 'ZZ-P1', 400,  '考核期', 3);         -- 回考核期
  perform pg_temp.p1_emp('MI-9624', 'ZZ-P1', 400,  '已上線', 3);         -- 回考核期（period_status 已上線）
  perform pg_temp.p1_emp('MI-9625', 'ZZ-P1', 20,   '考核期', null, true, '離職');
  perform pg_temp.p1_emp('MI-9626', 'ZZ-P1', 20,   '考核期', null, false);
  perform pg_temp.p1_emp('MI-9627', 'ZZ-P1', null, '考核期');            -- 考核期、未填到職日
  perform pg_temp.p1_emp('MI-9628', 'ZZ-P1', 400,  '已上線');            -- 正式、已上線
  perform pg_temp.p1_emp('MI-9629', 'ZZ-P2', 20,   '考核期');            -- 他店考核期新人
  perform pg_temp.p1_emp('MI-9630', 'ZZ-P1', 90,   '考核期');            -- 剛好 90 天、考核期

  perform pg_temp.vr_eq('11 待考回報', '新人候選（客服部）：考核期且無 probation_since（含到職超過 90 天、未填到職日），已上線者不列', 'MI-9621,MI-9627,MI-9629,MI-9630',
    pg_temp.vr_cs(format(v_lst, '新人')));
  perform pg_temp.vr_eq('11 待考回報', '新人候選（店長 ZZ-P1）：只列自己門市', 'MI-9621,MI-9627,MI-9630',
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', format(v_lst, '新人'), true));
  perform pg_temp.vr_eq('11 待考回報', '新人候選（店長 ZZ-P2）：只列自己門市', 'MI-9629',
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', format(v_lst, '新人'), true));
  perform pg_temp.vr_eq('11 待考回報', '回考核期候選：有 probation_since 者（不論 period_status）', 'MI-9623,MI-9624',
    pg_temp.vr_cs(format(v_lst, '回考核期')));
  perform pg_temp.vr_eq('11 待考回報', '已上線的新人標籤者（9622）不在新人候選、也不在回考核期候選', '(空)/(空)',
    pg_temp.vr_cs($q$select coalesce((select string_agg(employee_id, ',') from public.exam_req_candidates('新人') where employee_id = 'MI-9622'), '(空)')
                     || '/' || coalesce((select string_agg(employee_id, ',') from public.exam_req_candidates('回考核期') where employee_id = 'MI-9622'), '(空)')$q$));

  -- 新增
  perform pg_temp.vr_eq('11 待考回報', '考核期超過 90 天（9621）仍可報新人', 'true',
    (pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', format($q$select public.exam_req_create('新人', 'MI-9621', array[%L::date], true, '測試')::text$q$, v_d), true) not like 'ERROR%')::text);
  perform pg_temp.vr_eq('11 待考回報', '考核期未填到職日（9627）可報新人（客服部代報）', 'true',
    (pg_temp.vr_cs(format($q$select public.exam_req_create('新人', 'MI-9627', array[%L::date], true, '測試')::text$q$, v_d)) not like 'ERROR%')::text);
  perform pg_temp.vr_csdeny('11 待考回報', '已上線的新人標籤者（9622，到職 20 天）不可報新人',
    format($q$select public.exam_req_create('新人', 'MI-9622', array[%L::date], true, null)::text$q$, v_d), '%不是新人%');
  perform pg_temp.vr_csdeny('11 待考回報', '回考核期者（9623）不能以新人回報（既有訊息）',
    format($q$select public.exam_req_create('新人', 'MI-9623', array[%L::date], true, null)::text$q$, v_d), '%只能以「回考核期」回報%');
  perform pg_temp.vr_csdeny('11 待考回報', '已上線＋probation_since（9624）不能以新人回報',
    format($q$select public.exam_req_create('新人', 'MI-9624', array[%L::date], true, null)::text$q$, v_d), '%只能以「回考核期」回報%');
  perform pg_temp.vr_csdeny('11 待考回報', '正式已上線（9628）不能報新人', format($q$select public.exam_req_create('新人', 'MI-9628', array[%L::date], true, null)::text$q$, v_d), '%不是新人%');
  perform pg_temp.vr_csdeny('11 待考回報', '離職者不能報（既有訊息）', format($q$select public.exam_req_create('新人', 'MI-9625', array[%L::date], true, null)::text$q$, v_d), '%已離職%');
  perform pg_temp.vr_csdeny('11 待考回報', '未納入考核者不能報（既有訊息）', format($q$select public.exam_req_create('新人', 'MI-9626', array[%L::date], true, null)::text$q$, v_d), '%未納入考核%');
  perform pg_temp.vr_deny('11 待考回報', '店長（ZZ-P1）報他店的考核期新人（9629）→ 通用訊息', 'authenticated', 'vr-sm@2motor.tw',
    format($q$select public.exam_req_create('新人', 'MI-9629', array[%L::date], true, null)::text$q$, v_d), '%找不到這位人員或沒有權限%');
  perform pg_temp.vr_csdeny('11 待考回報', '重複報同一人新人（9621）→ 既有的防重複訊息', format($q$select public.exam_req_create('新人', 'MI-9621', array[%L::date], true, null)::text$q$, v_d), '%已有一筆「新人」回報在處理中%');
  perform pg_temp.vr_eq('11 待考回報', '已報的 9621、9627 不再出現在新人候選', 'MI-9629,MI-9630', pg_temp.vr_cs(format(v_lst, '新人')));
  perform pg_temp.vr_eq('11 待考回報', '回考核期：有 probation_since 者（9624，period_status 已上線）可報', 'true',
    (pg_temp.vr_cs(format($q$select public.exam_req_create('回考核期', 'MI-9624', array[%L::date], null, '測試')::text$q$, v_d)) not like 'ERROR%')::text);
  perform pg_temp.vr_eq('11 待考回報', '回考核期：考核期＋probation_since（9623）可報', 'true',
    (pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', format($q$select public.exam_req_create('回考核期', 'MI-9623', array[%L::date], null, '測試')::text$q$, v_d), true) not like 'ERROR%')::text);
  perform pg_temp.vr_csdeny('11 待考回報', '回考核期：沒有 probation_since（9628）不能報（既有訊息）', format($q$select public.exam_req_create('回考核期', 'MI-9628', array[%L::date], null, null)::text$q$, v_d), '%目前不在考核期%');
  perform pg_temp.vr_csdeny('11 待考回報', '回考核期：考核期新人沒有 probation_since（9630）不能報回考核期', format($q$select public.exam_req_create('回考核期', 'MI-9630', array[%L::date], null, null)::text$q$, v_d), '%目前不在考核期%');
  perform pg_temp.vr_eq('11 待考回報', '候選與建立的回報資料：9621 的回報是新人、影片 true、待處理', '新人/true/待處理',
    (select r.kind || '/' || r.video_done::text || '/' || r.status from public.exam_requests r where r.employee_id = 'MI-9621'));
exception when others then
  perform pg_temp.vr_rec('區段 11','待考回報資格測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 12：exam_req_badge（客服部含待開通）
-- ============================================================
do $$
declare
  v_cs0 int; v_sm0 int; v_cs int;
  v_ra uuid;
  v_today date := pg_temp.p1_today();
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9631', 'ZZ-P1', 20, '已上線');
  perform pg_temp.p1_emp('MI-9632', 'ZZ-P1', 20, '考核期');

  v_cs0 := pg_temp.vr_cs('select public.exam_req_badge()::text')::int;
  perform pg_temp.vr_eq('12 紅點', '客服部紅點＝待處理回報數＋待開通數', ((select count(*) from public.exam_requests where status = '待處理') + (select count(*) from public.reply_activations where status = '待開通'))::text, v_cs0::text);
  v_sm0 := pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', 'select public.exam_req_badge()::text', true)::int;
  perform pg_temp.vr_eq('12 紅點', '店長紅點＝本店未看過的回覆數（不含待開通）', (select count(*) from public.exam_requests where store_code = 'ZZ-P1' and mgr_seen = false)::text, v_sm0::text);

  insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9631', 'x', 'ZZ-P1', v_today);
  insert into public.reply_activations (employee_id, employee_label, store_code, passed_on) values ('MI-9631', 'x', 'ZZ-P1', v_today) returning id into v_ra;
  perform pg_temp.vr_eq('12 紅點', '新增 2 筆待開通 → 客服部紅點 +2', (v_cs0 + 2)::text, pg_temp.vr_cs('select public.exam_req_badge()::text'));
  perform pg_temp.vr_eq('12 紅點', '待開通不影響店長紅點', v_sm0::text, pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', 'select public.exam_req_badge()::text', true));
  perform pg_temp.vr_csok('12 紅點', '標記其中一筆已開通', format($q$select public.activation_mark_done(%L::uuid)$q$, v_ra));
  perform pg_temp.vr_eq('12 紅點', '標記已開通後 → 客服部紅點 −1', (v_cs0 + 1)::text, pg_temp.vr_cs('select public.exam_req_badge()::text'));
  perform pg_temp.vr_eq('12 紅點', '新增 1 筆待處理回報 → 客服部紅點再 +1（回報與待開通合計）', 'true',
    (pg_temp.vr_cs(format($q$select public.exam_req_create('新人', 'MI-9632', array[%L::date], true, null)::text$q$, (v_today + 1)::text)) not like 'ERROR%')::text);
  perform pg_temp.vr_eq('12 紅點', '合計＝v0＋1（待開通）＋1（待處理）', (v_cs0 + 2)::text, pg_temp.vr_cs('select public.exam_req_badge()::text'));
  perform pg_temp.vr_eq('12 紅點', '總公司主管紅點仍是 0', '0', pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', 'select public.exam_req_badge()::text', true));
  perform pg_temp.vr_deny('12 紅點', '未開通帳號：沒有權限', 'authenticated', 'vr-none@2motor.tw', 'select public.exam_req_badge()::text', '%沒有權限%');
  perform pg_temp.vr_deny('12 紅點', 'anon：被拒', 'anon', null, 'select public.exam_req_badge()::text', '%permission denied%');
exception when others then
  perform pg_temp.vr_rec('區段 12','紅點測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 13：既有功能關鍵路徑（本期不該改變的行為）
-- ============================================================
do $$
declare
  v_a uuid;
  v_p uuid;
  v_q bigint;
  v_r text;
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9641', 'ZZ-P1', 400, '已上線');
  perform pg_temp.p1_emp('MI-9642', 'ZZ-P1', 400, '考核期', 3);
  perform pg_temp.p1_emp('MI-9643', 'ZZ-P1', 400, '已上線');

  -- 抽查登記（既有 spot_register）：不改 period_status
  v_r := pg_temp.vr_cs(format($q$select (public.spot_register('MI-9641', %L::date, 'https://line.example/chat/1', %L::jsonb, '適當', null) ->> 'total_score')$q$,
    pg_temp.p1_today()::text, pg_temp.p1_all('優')::text));
  perform pg_temp.vr_eq('13 既有功能', 'spot_register（既有）：全優登記成功、總分 100.0', '100.0', v_r);
  perform pg_temp.vr_eq('13 既有功能', 'spot_register 沒觸發回考核期時不碰 period_status／probation_since', '已上線/無/-', pg_temp.p1_st('MI-9641'));
  v_r := pg_temp.vr_cs(format($q$select (public.spot_register('MI-9641', %L::date, 'https://line.example/chat/2', %L::jsonb, '不適當', '測試') ->> 'yellow_id') is not null$q$,
    pg_temp.p1_today()::text, pg_temp.p1_all('待加強')::text));
  perform pg_temp.vr_eq('13 既有功能', 'spot_register（既有）：不適當開黃單', 'true', v_r);

  -- 取消回考核期（spot_cancel_probation）：清 probation_since，並把 period_status 設回已上線（老闆 2026-11-03 決定）
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9642', '假員9642', 'ZZ-P1', '{}'::uuid[], pg_temp.p1_today(), '待執行') returning id into v_p;
  perform pg_temp.vr_csok('13 既有功能', 'spot_cancel_probation（既有）可取消', format($q$select public.spot_cancel_probation(%L::uuid, '誤判')$q$, v_p));
  perform pg_temp.vr_eq('13 既有功能', '取消回考核期：probation_since 清除、period_status 設回已上線（老闆決定：誤判復原）', '已上線/無/-', pg_temp.p1_st('MI-9642'));

  -- assess_pick（弱項建議題組，既有）
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9643', null)::text$q$)::uuid;
  v_q := (select q.id from public.questions q where q.category = 'ZZ追' order by q.id limit 1);
  perform pg_temp.vr_eq('13 既有功能', 'assess_pick（既有）：指定題組寫入成核心題組', '1/0',
    pg_temp.vr_cs(format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_a, v_q)) || '/' || (select count(*) from public.assessment_items where assessment_id = v_a and is_extra)::text);
  perform pg_temp.vr_csdeny('13 既有功能', 'assess_pick（既有）：同分類第二題仍被拒', format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_a, (select q.id from public.questions q where q.category = 'ZZ追' order by q.id offset 1 limit 1)), '%這場考核已抽過其中的分類%');
  -- assess_candidates（既有）
  perform pg_temp.vr_eq('13 既有功能', 'assess_candidates（既有）：列得到納入考核者', '1', pg_temp.vr_cs($q$select count(*)::text from public.assess_candidates() where id = 'MI-9531'$q$));
  -- assess_abandon 既有：沒追加題的草稿
  perform pg_temp.vr_csok('13 既有功能', 'assess_abandon（既有）：放棄草稿', format($q$select public.assess_abandon(%L::uuid)$q$, v_a));
  perform pg_temp.vr_eq('13 既有功能', '放棄後草稿與題組都消失', '0',
    (select count(*) from public.assessments where id = v_a)::text);
exception when others then
  perform pg_temp.vr_rec('區段 13','既有功能測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 13B：抽查拉回考核期／取消回考核期與 period_status 的串接（老闆 2026-11-03 決定）
--   * spot_register 觸發回考核期時，period_status 同步設為考核期（單一事實）
--   * spot_cancel_probation 取消時，period_status 設回已上線；已通過的不可取消
-- ============================================================
-- 讓某人「本季已有 1 張舊紅單」後，連登記 5 次不適當 → 第 5 次開第 2 張紅單 → 觸發回考核期。回傳最後一次登記的 jsonb（文字）
create or replace function pg_temp.p1_pull(p_emp text)
returns text language plpgsql as $$
declare
  i int;
  v_r text;
begin
  insert into public.spot_tickets (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on, created_at)
  select '紅', e.id, e.nickname, e.store_code, '{}'::uuid[], '舊紅單', pg_temp.p1_today(), now() - interval '2 days'
  from public.employees e where e.id = p_emp;
  for i in 1 .. 5 loop
    v_r := pg_temp.vr_cs(format($q$select public.spot_register(%L, %L::date, %L, %L::jsonb, '不適當', '測試')::text$q$,
             p_emp, pg_temp.p1_today()::text, 'https://line.example/chat/' || p_emp || '-' || i, pg_temp.p1_all('待加強')::text));
    if v_r like 'ERROR%' then raise exception '登記失敗：%', v_r; end if;
  end loop;
  return v_r;
end $$;

do $$
declare
  v_r text;
  v_pid uuid;
  v_a text;
  v_today date := pg_temp.p1_today();
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.p1_emp('MI-9651', 'ZZ-P1', 400, '已上線');
  perform pg_temp.p1_emp('MI-9652', 'ZZ-P1', 400, '已上線');
  perform pg_temp.p1_emp('MI-9653', 'ZZ-P1', 400, '已上線');

  -- ===== 拉回考核期 =====
  v_r := pg_temp.p1_pull('MI-9651');
  perform pg_temp.vr_eq('13B 抽查串接', 'spot_register 第 5 張黃單：自動開紅單並觸發回考核期（probation_id 不為空）', 'true',
    ((v_r::jsonb ->> 'probation_id') is not null)::text);
  perform pg_temp.vr_eq('13B 抽查串接', '拉回後：period_status 同步設為考核期、probation_since 有值', '考核期/有/-', pg_temp.p1_st('MI-9651'));
  perform pg_temp.vr_eq('13B 抽查串接', '拉回後 probation_since＝台北今天（既有行為不變）', 'true',
    (select (e.probation_since = v_today)::text from public.employees e where e.id = 'MI-9651'));
  perform pg_temp.vr_eq('13B 抽查串接', '拉回前（登記第 1～4 次）不影響 period_status：只有觸發的那一位被改，其他人沒動', '已上線/已上線',
    (select e.period_status from public.employees e where e.id = 'MI-9652') || '/' || (select e.period_status from public.employees e where e.id = 'MI-9653'));
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9651', null)::text$q$);
  perform pg_temp.vr_eq('13B 抽查串接', '拉回後 assess_start 仍走既有回考核期判斷：正式／考核期', '正式/考核期',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_csok('13B 抽查串接', '（備料）放棄這張草稿，改走完整流程', format($q$select public.assess_abandon(%L::uuid)$q$, v_a));
  perform pg_temp.p1_full('MI-9651', c_850);
  perform pg_temp.vr_eq('13B 抽查串接', '拉回後考核 85.0 通過：85.0/及格/85/3/正式', '85.0/及格/85/3/正式', pg_temp.vr_get('res_MI-9651'));
  perform pg_temp.vr_eq('13B 抽查串接', '通過後：恢復已上線、清 probation_since、passed_on、新增待開通', '已上線/無/' || v_today::text || '/1',
    pg_temp.p1_st('MI-9651') || '/' || pg_temp.p1_act('MI-9651'));
  perform pg_temp.vr_eq('13B 抽查串接', '通過後 spot_probations 為已通過', '已通過',
    (select p.status from public.spot_probations p where p.employee_id = 'MI-9651'));
  perform pg_temp.vr_eq('13B 抽查串接', '通過後不再列入回考核期候選名單', 'true',
    (pg_temp.vr_cs(format($q$select count(*)::text from public.exam_req_candidates('回考核期') where employee_id = 'MI-9651'$q$)) = '0')::text);

  -- ===== 取消回考核期 =====
  v_r := pg_temp.p1_pull('MI-9652');
  v_pid := (v_r::jsonb ->> 'probation_id')::uuid;
  perform pg_temp.vr_eq('13B 抽查串接', '（備料）9652 被拉回考核期', '考核期/有/-', pg_temp.p1_st('MI-9652'));
  perform pg_temp.vr_eq('13B 抽查串接', '（備料）拉回期間 9652 在回考核期候選名單、不在新人候選名單', '1/0',
    pg_temp.vr_cs($q$select (select count(*) from public.exam_req_candidates('回考核期') where employee_id = 'MI-9652')::text
                         || '/' || (select count(*) from public.exam_req_candidates('新人') where employee_id = 'MI-9652')::text$q$));
  perform pg_temp.vr_csok('13B 抽查串接', '客服部取消回考核期（誤判復原）', format($q$select public.spot_cancel_probation(%L::uuid, '誤判')$q$, v_pid));
  perform pg_temp.vr_eq('13B 抽查串接', '取消後：已上線、probation_since 清除、沒有 passed_on、沒有待開通', '已上線/無/-/0', pg_temp.p1_st('MI-9652') || '/' || pg_temp.p1_act('MI-9652'));
  perform pg_temp.vr_eq('13B 抽查串接', '取消後：回考核期紀錄為已取消（既有行為）', '已取消', (select p.status from public.spot_probations p where p.id = v_pid));
  perform pg_temp.vr_eq('13B 抽查串接', '取消後標籤依 period_status 為「已上線」（不是考核期）、新人／回考核期候選都不列', '0/0',
    pg_temp.vr_cs($q$select (select count(*) from public.exam_req_candidates('回考核期') where employee_id = 'MI-9652')::text
                         || '/' || (select count(*) from public.exam_req_candidates('新人') where employee_id = 'MI-9652')::text$q$));
  v_a := pg_temp.vr_cs($q$select public.assess_start('MI-9652', null)::text$q$);
  perform pg_temp.vr_eq('13B 抽查串接', '取消後 assess_start 走原本的正式判斷（到職 400 天）：正式／自動', '正式/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_csdeny('13B 抽查串接', '已取消的不可重複取消（既有）', format($q$select public.spot_cancel_probation(%L::uuid, '再取消')$q$, v_pid), '%這筆回考核期已經取消%');

  -- 已通過的不可取消（既有規則不變），且員工狀態不被動到
  perform pg_temp.p1_emp('MI-9654', 'ZZ-P1', 400, '已上線');
  v_r := pg_temp.p1_pull('MI-9654');
  v_pid := (v_r::jsonb ->> 'probation_id')::uuid;
  update public.spot_probations set status = '已通過' where id = v_pid;
  perform pg_temp.vr_csdeny('13B 抽查串接', '已通過的回考核期不可取消（既有規則）', format($q$select public.spot_cancel_probation(%L::uuid, '想取消')$q$, v_pid), '%已通過的回考核期不可取消%');
  perform pg_temp.vr_eq('13B 抽查串接', '被拒後員工狀態不變（仍考核期、probation_since 還在）', '考核期/有/-', pg_temp.p1_st('MI-9654'));
  -- 權限不變
  perform pg_temp.vr_deny('13B 抽查串接', '店長不能取消回考核期', 'authenticated', 'vr-sm@2motor.tw', format($q$select public.spot_cancel_probation(%L::uuid, 'x')$q$, v_pid), '%沒有權限%');
  perform pg_temp.vr_eq('13B 抽查串接', 'spot_register／spot_cancel_probation：anon 不能執行、authenticated 可以', 'false/true/false/true',
    has_function_privilege('anon', 'public.spot_register(text, date, text, jsonb, text, text)', 'execute')::text || '/'
    || has_function_privilege('authenticated', 'public.spot_register(text, date, text, jsonb, text, text)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.spot_cancel_probation(uuid, text)', 'execute')::text || '/'
    || has_function_privilege('authenticated', 'public.spot_cancel_probation(uuid, text)', 'execute')::text);
exception when others then
  perform pg_temp.vr_rec('區段 13B','抽查串接測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 13C：（審查建議）assess_submit 回考核期通過加守門、抽查資格排除考核期的人
-- ============================================================
do $$
declare
  v_today date := pg_temp.p1_today();
  v_r text;
  v_pid uuid;
  v_a uuid;
  v_b uuid;
  v_ra int;
  c_850 jsonb := jsonb_build_array(
      pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'), pg_temp.p1_lv('優','優','良','良','優','良','良'));
begin
  perform set_config('request.jwt.claims', '', true);

  -- ===== 守門 (a)：草稿存在期間取消回考核期，之後草稿 >= 85 送出 → 不新增待開通、passed_on 不變 =====
  perform pg_temp.p1_emp('MI-9661', 'ZZ-P1', 400, '已上線');
  v_r := pg_temp.p1_pull('MI-9661');
  v_pid := (v_r::jsonb ->> 'probation_id')::uuid;
  perform pg_temp.vr_eq('13C 守門', '（備料）9661 被拉回考核期', '考核期/有/-', pg_temp.p1_st('MI-9661'));
  v_a := pg_temp.p1_full('MI-9661', c_850, null, false);
  perform pg_temp.vr_eq('13C 守門', '（備料）草稿是回考核期身分（正式／考核期）', '正式/考核期',
    (select a.tenure || '/' || a.tenure_source from public.assessments a where a.id = v_a));
  perform pg_temp.vr_csok('13C 守門', '草稿存在期間客服部取消回考核期', format($q$select public.spot_cancel_probation(%L::uuid, '誤判')$q$, v_pid));
  perform pg_temp.vr_eq('13C 守門', '取消後：已上線、無 probation_since', '已上線/無/-', pg_temp.p1_st('MI-9661'));
  perform pg_temp.vr_eq('13C 守門', '取消後草稿 85.0 仍可正常送出（成績單照常產生）', '85.0/及格/85/3/正式', pg_temp.p1_submit(v_a));
  perform pg_temp.vr_eq('13C 守門', '送出後：不新增待開通、passed_on 不變（仍空）、仍是已上線', '已上線/無/-/0', pg_temp.p1_st('MI-9661') || '/' || pg_temp.p1_act('MI-9661'));
  perform pg_temp.vr_eq('13C 守門', '成績單狀態是已送出', 'submitted', (select a.status from public.assessments a where a.id = v_a));
  perform pg_temp.vr_eq('13C 守門', '已取消的回考核期紀錄不會被改成已通過', '已取消', (select p.status from public.spot_probations p where p.id = v_pid));

  -- ===== 守門 (b)：兩張回考核期草稿先後 >= 85 送出 → 只新增一筆待開通 =====
  perform pg_temp.p1_emp('MI-9662', 'ZZ-P1', 400, '已上線');
  v_r := pg_temp.p1_pull('MI-9662');
  v_a := pg_temp.p1_open('MI-9662', null, 'vr-cs@2motor.tw');
  v_b := pg_temp.p1_open('MI-9662', null, 'vr-cs2@2motor.tw');
  perform pg_temp.vr_eq('13C 守門', '（備料）兩位考官各有一張回考核期草稿', '2/正式考核期正式考核期',
    (select count(*)::text || '/' || string_agg(a.tenure || a.tenure_source, '' order by a.examiner_email) from public.assessments a where a.employee_id = 'MI-9662' and a.status = 'draft'));
  perform pg_temp.p1_rate3(v_a, c_850 -> 0, c_850 -> 1, c_850 -> 2, 'vr-cs@2motor.tw');
  perform pg_temp.p1_rate3(v_b, c_850 -> 0, c_850 -> 1, c_850 -> 2, 'vr-cs2@2motor.tw');
  perform pg_temp.vr_eq('13C 守門', '第一張送出（85.0）：通過、轉已上線、新增 1 筆待開通', '85.0/及格/85/3/正式/已上線/無/' || v_today::text || '/1',
    pg_temp.p1_submit(v_a, 'vr-cs@2motor.tw') || '/' || pg_temp.p1_st('MI-9662') || '/' || pg_temp.p1_act('MI-9662'));
  perform pg_temp.vr_eq('13C 守門', '第二張送出（85.0）：成績單正常送出', '85.0/及格/85/3/正式', pg_temp.p1_submit(v_b, 'vr-cs2@2motor.tw'));
  perform pg_temp.vr_eq('13C 守門', '第二張送出後：待開通仍只有 1 筆、passed_on 沒被改、仍是已上線', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9662') || '/' || pg_temp.p1_act('MI-9662'));
  perform pg_temp.vr_eq('13C 守門', '待開通連的是第一張成績單', 'true',
    (select bool_and(r.assessment_id = v_a)::text from public.reply_activations r where r.employee_id = 'MI-9662'));
  perform pg_temp.vr_eq('13C 守門', '兩張成績單都是已送出', '2', (select count(*)::text from public.assessments a where a.employee_id = 'MI-9662' and a.status = 'submitted'));
  -- 新人分支原本就有守門：已上線者通過不新增（與區段 8 的 9584 同一規則，這裡再用「先過一次再送第二張」確認一致）
  perform pg_temp.p1_emp('MI-9663', 'ZZ-P1', 20, '考核期');
  v_a := pg_temp.p1_open('MI-9663', null, 'vr-cs@2motor.tw');
  v_b := pg_temp.p1_open('MI-9663', null, 'vr-cs2@2motor.tw');
  perform pg_temp.p1_rate3(v_a, pg_temp.p1_all('良'), pg_temp.p1_all('良'), pg_temp.p1_all('良'), 'vr-cs@2motor.tw');
  perform pg_temp.p1_rate3(v_b, pg_temp.p1_all('良'), pg_temp.p1_all('良'), pg_temp.p1_all('良'), 'vr-cs2@2motor.tw');
  perform pg_temp.p1_submit(v_a, 'vr-cs@2motor.tw');
  perform pg_temp.p1_submit(v_b, 'vr-cs2@2motor.tw');
  perform pg_temp.vr_eq('13C 守門', '新人兩張草稿先後 70 分送出：只新增 1 筆待開通、已上線', '已上線/無/' || v_today::text || '/1', pg_temp.p1_st('MI-9663') || '/' || pg_temp.p1_act('MI-9663'));

  -- ===== 抽查資格排除考核期的人 =====
  perform pg_temp.p1_emp('MI-9671', 'ZZ-P1', 400,  '考核期');            -- 到職超過 90 天、但仍是考核期
  perform pg_temp.p1_emp('MI-9672', 'ZZ-P1', null, '考核期');            -- 未填到職日的考核期
  perform pg_temp.p1_emp('MI-9673', 'ZZ-P1', 400,  '已上線');            -- 已上線正式
  perform pg_temp.p1_emp('MI-9674', 'ZZ-P1', null, '已上線');            -- 已上線、未填到職日（視為正式）
  perform pg_temp.p1_emp('MI-9675', 'ZZ-P1', 400,  '已上線', 3);         -- probation_since 有值（既有規則：不抽查）
  perform pg_temp.vr_eq('13C 抽查資格', 'spot_candidates：考核期的人（到職超過 90 天、未填到職日）不在名單', '(空)',
    pg_temp.vr_cs($q$select coalesce(string_agg(id, ',' order by id), '(空)') from public.spot_candidates() where id in ('MI-9671','MI-9672')$q$));
  perform pg_temp.vr_eq('13C 抽查資格', 'spot_candidates：已上線者行為不變（9673 正式、9674 未填到職日仍在名單；有 probation_since 的 9675 不在）', 'MI-9673,MI-9674',
    pg_temp.vr_cs($q$select coalesce(string_agg(id, ',' order by id), '(空)') from public.spot_candidates() where id in ('MI-9673','MI-9674','MI-9675')$q$));
  perform pg_temp.vr_csdeny('13C 抽查資格', 'spot_register：到職超過 90 天但仍是考核期的人被拒',
    format($q$select public.spot_register('MI-9671', %L::date, 'https://line.example/c/1', %L::jsonb, '適當', null)::text$q$, v_today::text, pg_temp.p1_all('優')::text),
    '%該員工目前在考核期，不能抽查%');
  perform pg_temp.vr_csdeny('13C 抽查資格', 'spot_register：未填到職日的考核期人員被拒',
    format($q$select public.spot_register('MI-9672', %L::date, 'https://line.example/c/2', %L::jsonb, '適當', null)::text$q$, v_today::text, pg_temp.p1_all('優')::text),
    '%該員工目前在考核期，不能抽查%');
  perform pg_temp.vr_eq('13C 抽查資格', '被拒後沒有留下抽查紀錄', '0',
    (select count(*)::text from public.spot_inspections where employee_id in ('MI-9671', 'MI-9672')));
  perform pg_temp.vr_eq('13C 抽查資格', 'spot_register：已上線正式員工行為不變（成功、總分 100.0）', '100.0',
    pg_temp.vr_cs(format($q$select (public.spot_register('MI-9673', %L::date, 'https://line.example/c/3', %L::jsonb, '適當', null) ->> 'total_score')$q$, v_today::text, pg_temp.p1_all('優')::text)));
  perform pg_temp.vr_eq('13C 抽查資格', 'spot_register：已上線、未填到職日（視為正式）行為不變', '100.0',
    pg_temp.vr_cs(format($q$select (public.spot_register('MI-9674', %L::date, 'https://line.example/c/4', %L::jsonb, '適當', null) ->> 'total_score')$q$, v_today::text, pg_temp.p1_all('優')::text)));
  perform pg_temp.vr_csdeny('13C 抽查資格', 'spot_register：有 probation_since 者仍被拒（既有規則不變）',
    format($q$select public.spot_register('MI-9675', %L::date, 'https://line.example/c/5', %L::jsonb, '適當', null)::text$q$, v_today::text, pg_temp.p1_all('優')::text),
    '%該員工目前在考核期，不能抽查%');
  perform pg_temp.vr_deny('13C 抽查資格', '店長不能呼叫 spot_candidates（既有權限不變）', 'authenticated', 'vr-sm@2motor.tw', 'select count(*)::text from public.spot_candidates()', '%沒有權限%');
exception when others then
  perform pg_temp.vr_rec('區段 13C','守門與抽查資格測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 14：收尾比對（本腳本沒有改到任何函式、沒動到真實題庫）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.vr_eq('14 收尾', '所有 public 函式的定義在腳本前後相同', pg_temp.vr_get('fn_md5'), pg_temp.p1_fnmd5());
  perform pg_temp.vr_eq('14 收尾', '真實題目筆數沒變', pg_temp.vr_get('real_questions'),
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_eq('14 收尾', '真實題目的已抽記錄 drawn 沒變（若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_drawn'),
    (select count(*)::text from public.drawn where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_eq('14 收尾', '真實分類的 category_last 沒變（若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_last'),
    (select count(*)::text from public.category_last where category not like 'ZZ%'));
exception when others then
  perform pg_temp.vr_rec('區段 14','收尾比對意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate p1_vr_out';
  exception when others then
    null;
  end;

  execute 'prepare p1_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_first is not null then '；' || v_first else '' end
                           || case when v_fail is not null then '；全部未通過序號：' || v_fail else '' end) || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  begin
    execute 'deallocate p1_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare p1_vr_out as select '
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
execute p1_vr_out;
