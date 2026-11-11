-- ============================================================
-- 業務考核系統：成績單完整版（店長／主管看題目名稱與面向備註）驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行（必須先執行過 grade3_schema.sql 與 fullreport_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-fcs／vr-fhq／vr-fsm1／vr-fsm2@2motor.tw）／假成績單，
--   跑完所有驗證，把結果存成預備陳述式 fullreport_vr_out（rollback 不會讓它消失），rollback 後 execute 它，
--   所以最後一個結果就是「序號／測項／預期／實際／通過」表。第一列「總結」顯示 N/M 項通過，「通過」欄全是「通過」才算成功。
-- 假門市代碼 ZZ-F1／ZZ-F2、假員工編號 MI-9861～MI-9864、假信箱 vr-fcs／vr-fhq／vr-fsm1／vr-fsm2／vr-fnobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regprocedure('public.fullreport_items(uuid[])') is null then
    raise exception '請先執行 fullreport_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_item_secrets'
                   and column_name = 'dim_notes') then
    raise exception '請先執行 grade3_schema.sql';
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

-- 直接寫入一張成績單（以資料庫擁有者身分；考官信箱用容易辨認的假信箱，之後檢查它不會出現在回傳裡）
create or replace function pg_temp.vr_asm(p_emp text, p_store text, p_status text)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
  values
    (p_emp, '假考生' || right(p_emp, 4), p_store, 'vr-fexaminer@2motor.tw', 'draft', '正式', '自動')
  returning id into v_id;
  if p_status = 'submitted' or p_status = 'voided' then
    update public.assessments
       set status = 'submitted', total_score = 88, verdict = '及格', pass_line = 85,
           weakest_dims = '{主動引導}', submitted_at = now()
     where id = v_id;
  end if;
  if p_status = 'voided' then
    update public.assessments
       set status = 'voided', voided_at = now(), voided_by = 'vr-fcs@2motor.tw', void_reason = '假作廢'
     where id = v_id;
  end if;
  return v_id;
end $$;

-- 直接寫入一個題組與它的機密列（題目名稱、步驟與考點、面向備註）
create or replace function pg_temp.vr_it(p_asm uuid, p_seq int, p_title text, p_dim_notes jsonb)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.assessment_items (assessment_id, seq, category, code, levels, note)
  values (p_asm, p_seq, 'ZZ分類' || p_seq, 'ZF' || p_seq, '{}'::jsonb, '題組備註' || p_seq)
  returning id into v_id;
  insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps, dim_notes)
  values (v_id, -9600 - p_seq, false, p_title, '[{"action":"a","point":"機密考點ZF"}]'::jsonb, p_dim_notes);
  return v_id;
end $$;

-- ============================================================
-- 建立假資料
--   A1 已送出 ZZ-F1（2 題：第 1 題有面向備註，第 2 題是舊單式沒有面向備註）
--   A2 已送出 ZZ-F2（1 題）
--   A3 草稿   ZZ-F1（1 題）
--   A4 已作廢 ZZ-F1（1 題）
-- ============================================================
do $$
declare
  a1 uuid; a2 uuid; a3 uuid; a4 uuid;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-F1', 'ZZ測試門市庚'), ('ZZ-F2', 'ZZ測試門市辛');
  insert into public.employees (id, nickname, store_code, job_title, status, include_in_assessment) values
    ('MI-9861', '假考生9861', 'ZZ-F1', '業務', '在職', true),
    ('MI-9862', '假考生9862', 'ZZ-F2', '業務', '在職', true),
    ('MI-9863', '假考生9863', 'ZZ-F1', '業務', '在職', true),
    ('MI-9864', '假考生9864', 'ZZ-F1', '業務', '在職', true);
  insert into public.app_users (email, role, store_code) values
    ('vr-fcs@2motor.tw',  'cs_admin',      null),
    ('vr-fhq@2motor.tw',  'hq_viewer',     null),
    ('vr-fsm1@2motor.tw', 'store_manager', 'ZZ-F1'),
    ('vr-fsm2@2motor.tw', 'store_manager', 'ZZ-F2');
  -- vr-fnobody@2motor.tw 刻意不建立帳號（有登入但沒帳號）

  a1 := pg_temp.vr_asm('MI-9861', 'ZZ-F1', 'submitted');
  a2 := pg_temp.vr_asm('MI-9862', 'ZZ-F2', 'submitted');
  a3 := pg_temp.vr_asm('MI-9863', 'ZZ-F1', 'draft');
  a4 := pg_temp.vr_asm('MI-9864', 'ZZ-F1', 'voided');
  perform pg_temp.vr_set('a1', a1::text); perform pg_temp.vr_set('a2', a2::text);
  perform pg_temp.vr_set('a3', a3::text); perform pg_temp.vr_set('a4', a4::text);
  perform pg_temp.vr_it(a1, 1, '題目名稱F1甲', '{"問題掌握":"面向備註F1甲"}'::jsonb);
  perform pg_temp.vr_it(a1, 2, '題目名稱F1乙', '{}'::jsonb);
  perform pg_temp.vr_it(a2, 1, '題目名稱F2', '{"問題掌握":"面向備註F2"}'::jsonb);
  perform pg_temp.vr_it(a3, 1, '題目名稱草稿', '{"問題掌握":"面向備註草稿"}'::jsonb);
  perform pg_temp.vr_it(a4, 1, '題目名稱作廢', '{"問題掌握":"面向備註作廢"}'::jsonb);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 測項
-- ============================================================
do $$
declare
  cs  text := 'vr-fcs@2motor.tw';
  hq  text := 'vr-fhq@2motor.tw';
  sm1 text := 'vr-fsm1@2motor.tw';
  sm2 text := 'vr-fsm2@2motor.tw';
  nob text := 'vr-fnobody@2motor.tw';
  a1 text := pg_temp.vr_get('a1'); a2 text := pg_temp.vr_get('a2');
  a3 text := pg_temp.vr_get('a3'); a4 text := pg_temp.vr_get('a4');
  all_ids text;
  v_cnt text := $q$select count(*) from public.fullreport_items(array[%s]::uuid[])$q$;
  v_titles text := $q$select string_agg(title, '、' order by title) from public.fullreport_items(array[%s]::uuid[])$q$;
  v_r text;
begin
  all_ids := format('%L,%L,%L,%L', a1, a2, a3, a4);

  -- 1 客服部
  perform pg_temp.vr_eq('1 客服部','客服部查四張（含草稿、作廢）共 5 題','5', pg_temp.vr_as('authenticated', cs, format(v_cnt, all_ids), true));
  perform pg_temp.vr_eq('1 客服部','客服部讀得到草稿題目名稱','題目名稱草稿', pg_temp.vr_as('authenticated', cs, format(v_titles, format('%L', a3)), true));
  -- 2 總公司主管
  perform pg_temp.vr_eq('2 主管','主管查四張只回已送出（A1 兩題＋A2 一題）','3', pg_temp.vr_as('authenticated', hq, format(v_cnt, all_ids), true));
  perform pg_temp.vr_eq('2 主管','主管讀得到各門市已送出的題目名稱','題目名稱F1乙、題目名稱F1甲、題目名稱F2', pg_temp.vr_as('authenticated', hq, format(v_titles, all_ids), true));
  perform pg_temp.vr_eq('2 主管','主管讀不到草稿','0', pg_temp.vr_as('authenticated', hq, format(v_cnt, format('%L', a3)), true));
  perform pg_temp.vr_eq('2 主管','主管讀不到已作廢','0', pg_temp.vr_as('authenticated', hq, format(v_cnt, format('%L', a4)), true));
  perform pg_temp.vr_eq('2 主管','主管讀得到面向備註','面向備註F1甲',
    pg_temp.vr_as('authenticated', hq, format($q$select dim_notes ->> '問題掌握' from public.fullreport_items(array[%L]::uuid[]) where title = '題目名稱F1甲'$q$, a1), true));
  -- 3 本店店長
  perform pg_temp.vr_eq('3 本店店長','店長 F1 查四張只回自己門市已送出（A1 兩題）','2', pg_temp.vr_as('authenticated', sm1, format(v_cnt, all_ids), true));
  perform pg_temp.vr_eq('3 本店店長','店長 F1 讀得到自己門市題目名稱','題目名稱F1乙、題目名稱F1甲', pg_temp.vr_as('authenticated', sm1, format(v_titles, format('%L', a1)), true));
  perform pg_temp.vr_eq('3 本店店長','店長 F1 讀得到自己門市面向備註','面向備註F1甲',
    pg_temp.vr_as('authenticated', sm1, format($q$select dim_notes ->> '問題掌握' from public.fullreport_items(array[%L]::uuid[]) where title = '題目名稱F1甲'$q$, a1), true));
  perform pg_temp.vr_eq('3 本店店長','舊單式（沒有面向備註）回傳空物件、不報錯','{}',
    pg_temp.vr_as('authenticated', sm1, format($q$select dim_notes::text from public.fullreport_items(array[%L]::uuid[]) where title = '題目名稱F1乙'$q$, a1), true));
  perform pg_temp.vr_eq('3 本店店長','店長 F1 讀不到自己門市的草稿','0', pg_temp.vr_as('authenticated', sm1, format(v_cnt, format('%L', a3)), true));
  perform pg_temp.vr_eq('3 本店店長','店長 F1 讀不到自己門市的已作廢','0', pg_temp.vr_as('authenticated', sm1, format(v_cnt, format('%L', a4)), true));
  -- 4 他店店長
  perform pg_temp.vr_eq('4 他店店長','店長 F2 讀不到 F1 的成績單（回空，不報錯）','0', pg_temp.vr_as('authenticated', sm2, format(v_cnt, format('%L', a1)), true));
  perform pg_temp.vr_eq('4 他店店長','店長 F1 讀不到 F2 的成績單','0', pg_temp.vr_as('authenticated', sm1, format(v_cnt, format('%L', a2)), true));
  perform pg_temp.vr_eq('4 他店店長','店長 F2 查四張只回自己門市（A2 一題）','1', pg_temp.vr_as('authenticated', sm2, format(v_cnt, all_ids), true));
  perform pg_temp.vr_eq('4 他店店長','店長 F2 的結果不含 F1 的任何題目名稱或面向備註','0',
    pg_temp.vr_as('authenticated', sm2, format($q$select count(*) from public.fullreport_items(array[%s]::uuid[]) t where t.title like '%%F1%%' or t.dim_notes::text like '%%F1%%'$q$, all_ids), true));
  -- 5 無帳號與 anon
  perform pg_temp.vr_deny('5 被擋','有登入但沒有帳號被擋','authenticated', nob, format('select * from public.fullreport_items(array[%L]::uuid[])', a1), '%沒有權限%');
  perform pg_temp.vr_deny('5 被擋','沒有登入資訊（JWT 為空）的 authenticated 被擋','authenticated', null, format('select * from public.fullreport_items(array[%L]::uuid[])', a1), '%沒有權限%');
  perform pg_temp.vr_deny('5 被擋','anon 被擋（沒有執行權）','anon', null, format('select * from public.fullreport_items(array[%L]::uuid[])', a1), '%permission denied%');
  perform pg_temp.vr_deny('5 被擋','anon 即使帶了別人的 email 也被擋','anon', sm1, format('select * from public.fullreport_items(array[%L]::uuid[])', a1), '%permission denied%');
  perform pg_temp.vr_eq('5 被擋','anon 沒有函式執行權','false', pg_temp.vr_q1($q$select has_function_privilege('anon', 'public.fullreport_items(uuid[])', 'execute')::text$q$));
  perform pg_temp.vr_eq('5 被擋','authenticated 有函式執行權','true', pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.fullreport_items(uuid[])', 'execute')::text$q$));
  -- 6 回傳內容不含信箱與步驟考點
  perform pg_temp.vr_eq('6 欄位','回傳欄位只有 assessment_id、dim_notes、item_id、title（不含信箱）','assessment_id,dim_notes,item_id,title',
    pg_temp.vr_q1($q$select string_agg(a, ',' order by a) from (select unnest(proargnames) a from pg_proc where oid = 'public.fullreport_items(uuid[])'::regprocedure) x where a <> 'p_assessment_ids'$q$));
  perform pg_temp.vr_eq('6 欄位','回傳欄位名稱不含 email 或 examiner','0',
    pg_temp.vr_q1($q$select count(*) from (select unnest(proargnames) a from pg_proc where oid = 'public.fullreport_items(uuid[])'::regprocedure) x where a ilike '%mail%' or a ilike '%examiner%'$q$));
  foreach v_r in array array[cs, hq, sm1] loop
    perform pg_temp.vr_eq('6 欄位','整列轉文字後不含考官信箱（' || split_part(v_r, '@', 1) || '）','0',
      pg_temp.vr_as('authenticated', v_r, format($q$select count(*) from public.fullreport_items(array[%s]::uuid[]) t where to_jsonb(t)::text like '%%vr-fexaminer%%' or to_jsonb(t)::text like '%%@%%'$q$, all_ids), true));
    perform pg_temp.vr_eq('6 欄位','整列轉文字後不含步驟與考點（' || split_part(v_r, '@', 1) || '）','0',
      pg_temp.vr_as('authenticated', v_r, format($q$select count(*) from public.fullreport_items(array[%s]::uuid[]) t where to_jsonb(t)::text like '%%機密考點%%'$q$, all_ids), true));
  end loop;
  -- 7 機密表本身仍然沒開放
  perform pg_temp.vr_eq('7 機密表','主管直接讀機密表 0 列','0', pg_temp.vr_as('authenticated', hq, 'select count(*) from public.assessment_item_secrets', true));
  perform pg_temp.vr_eq('7 機密表','店長直接讀機密表 0 列','0', pg_temp.vr_as('authenticated', sm1, 'select count(*) from public.assessment_item_secrets', true));
  perform pg_temp.vr_eq('7 機密表','店長直接讀機密表 dim_notes 0 列','0', pg_temp.vr_as('authenticated', sm1, 'select count(*) from public.assessment_item_secrets where dim_notes <> ''{}''::jsonb', true));
  perform pg_temp.vr_eq('7 機密表','客服部直接讀機密表仍可（5 列）','5', pg_temp.vr_as('authenticated', cs, 'select count(*) from public.assessment_item_secrets where title like ''題目名稱%''', true));
  perform pg_temp.vr_deny('7 機密表','anon 直接讀機密表被擋','anon', null, 'select count(*) from public.assessment_item_secrets', '%permission denied%');
  perform pg_temp.vr_eq('7 機密表','機密表授權沒被放寬：anon 無 select','false', pg_temp.vr_q1($q$select has_table_privilege('anon', 'public.assessment_item_secrets', 'select')::text$q$));
  perform pg_temp.vr_eq('7 機密表','機密表 policy 仍只有一條且限客服部','1',
    pg_temp.vr_q1($q$select count(*) from pg_policies where schemaname = 'public' and tablename = 'assessment_item_secrets' and qual like '%cs_admin%'$q$));
  perform pg_temp.vr_eq('7 機密表','機密表沒有其他 policy','1',
    pg_temp.vr_q1($q$select count(*) from pg_policies where schemaname = 'public' and tablename = 'assessment_item_secrets'$q$));
  -- 8 函式屬性與邊界
  perform pg_temp.vr_eq('8 函式','是 security definer 且固定 search_path','true',
    pg_temp.vr_q1($q$select (prosecdef and exists (select 1 from unnest(proconfig) c where c like 'search_path=%'))::text from pg_proc where oid = 'public.fullreport_items(uuid[])'::regprocedure$q$));
  perform pg_temp.vr_eq('8 函式','傳 null 回 0 列（不報錯）','0', pg_temp.vr_as('authenticated', cs, 'select count(*) from public.fullreport_items(null)', true));
  perform pg_temp.vr_eq('8 函式','傳空陣列回 0 列','0', pg_temp.vr_as('authenticated', cs, 'select count(*) from public.fullreport_items(array[]::uuid[])', true));
  perform pg_temp.vr_eq('8 函式','不存在的 id 回 0 列','0', pg_temp.vr_as('authenticated', hq, 'select count(*) from public.fullreport_items(array[gen_random_uuid()])', true));
  perform pg_temp.vr_deny('8 函式','一次查超過 50 張被擋','authenticated', cs,
    'select * from public.fullreport_items((select array_agg(gen_random_uuid()) from generate_series(1, 51)))', '%最多查 50%');
  perform pg_temp.vr_eq('8 函式','剛好 50 張可以','0', pg_temp.vr_as('authenticated', cs, 'select count(*) from public.fullreport_items((select array_agg(gen_random_uuid()) from generate_series(1, 50)))', true));
  perform pg_temp.vr_eq('8 函式','函式不改資料：機密表假資料列數不變（5）','5', pg_temp.vr_q1($q$select count(*) from public.assessment_item_secrets where title like '題目名稱%'$q$));
exception when others then
  perform pg_temp.vr_rec('測項','測項意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 結果：先把結果表做成預備陳述式（rollback 不會讓它消失），再 rollback，最後 execute
-- ============================================================
do $$
declare
  v_total int;
  v_ok int;
  v_fail text;
  v_rows text;
begin
  select count(*), count(*) filter (where pass),
         string_agg(n::text, '、' order by n) filter (where not pass)
    into v_total, v_ok, v_fail from pg_temp.vr;
  select string_agg(
           format('(%s, %L, %L, %L, %L)',
                  n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vr;

  begin
    execute 'deallocate fullreport_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare fullreport_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_fail is not null then '；未通過序號：' || v_fail else '' end) || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate fullreport_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare fullreport_vr_out as select '
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
execute fullreport_vr_out;
