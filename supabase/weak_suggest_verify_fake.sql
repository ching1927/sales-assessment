-- ============================================================
-- 業務考核系統：弱項建議題組（weak_suggest）驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 weak_suggest_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw，符合 accounts 網域檢查）／假題庫，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。
--   「抽選器 drawn／category_last」只動 ZZ 開頭的假分類；真實題庫的筆數在結尾比對，確認沒被動到。
-- 怎麼看結果：
--   * 因為 SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     腳本在 rollback 之前把結果表存成「預備陳述式 weak_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過（有失敗時後面附「；未通過：#序號…」，最多列 20 個）；
--     「通過」欄全是「通過」才算驗證成功。預期看到「N/N 項通過」。
-- 假門市代碼 ZZ-W1、假員工編號 MI-9821～MI-9850、假信箱 vr-cs／vr-cs2／vr-hq／vr-sm@2motor.tw、
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
  if to_regclass('public.question_dims') is null
     or to_regprocedure('public.bank_set_dims(bigint, text[])') is null
     or to_regprocedure('public.assess_weak_profile(text)') is null
     or to_regprocedure('public.assess_suggest_pool(text)') is null
     or to_regprocedure('public.assess_pick(uuid, bigint[])') is null then
    raise exception '請先執行 weak_suggest_schema.sql';
  end if;
  if to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_draw(uuid, text[])') is null
     or not exists (select 1 from pg_proc p   -- url_patch.sql 之後簽名多一個參數，所以只看名稱
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'assess_save_item')
     or to_regprocedure('public.assess_submit(uuid)') is null
     or to_regprocedure('public.assess_abandon(uuid)') is null
     or to_regprocedure('public.bank_delete_question(bigint)') is null
     or to_regprocedure('public.bank_reset(text)') is null then
    raise exception '請先執行 assess_schema.sql 與 bank_schema.sql';
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

-- 以擁有者身分造一題假題組，回傳 id，並記在 vr_ctx（key = 'q_' || code）
create or replace function pg_temp.vr_mkq(p_cat text, p_code text)
returns bigint language plpgsql as $$
declare
  v_id bigint;
begin
  insert into public.questions (category, code, title, steps)
  values (p_cat, p_code, '假題組' || p_code,
          '[{"action":"動作","point":"考點"}]'::jsonb)
  returning id into v_id;
  perform pg_temp.vr_set('q_' || p_code, v_id::text);
  return v_id;
end $$;

-- 取假題組 id（vr_mkq 時記下的）
create or replace function pg_temp.vr_qid(p_code text)
returns bigint language sql as $$
  select pg_temp.vr_get('q_' || p_code)::bigint;
$$;

-- 題組目前的面向標記（依存放順序以 + 連接；沒有標記回 '(none)'）
create or replace function pg_temp.vr_d(p_q bigint)
returns text language sql as $$
  select coalesce((select array_to_string(d.dims, '+') from public.question_dims d where d.question_id = p_q), '(none)');
$$;

-- 以擁有者身分直接造一張成績單（status = submitted／voided／draft）與它的題組。
--   p_items：jsonb 陣列，每個元素是一個題組的七面向評分（可只放部分面向）
--   p_qids：可選，每個題組對應的題庫題號（寫進機密表，給「考過」判斷用）
--   p_examiner：可選，沒給就隨機一個（同考官同員工只能有一張草稿）
-- 分類名稱用 'ZZ報' || 序號（只是標籤，不需要存在於題庫）。
create or replace function pg_temp.vr_mkrep(p_emp text, p_status text, p_ts timestamptz, p_items jsonb,
                                            p_qids bigint[] default null, p_examiner text default null)
returns uuid language plpgsql as $$
declare
  v_id uuid;
  v_item uuid;
  v_ex text := coalesce(p_examiner,
                 'vr-ex-' || substr(md5(random()::text || clock_timestamp()::text), 1, 10) || '@2motor.tw');
  i int;
begin
  if p_status = 'submitted' then
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure,
                                    tenure_source, total_score, verdict, pass_line, submitted_at)
    values (p_emp, 'x', 'ZZ-W1', v_ex, 'submitted', '正式', '自動', 80, '及格', 85, p_ts)
    returning id into v_id;
  elsif p_status = 'voided' then
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure,
                                    tenure_source, total_score, verdict, pass_line, submitted_at,
                                    voided_at, voided_by, void_reason)
    values (p_emp, 'x', 'ZZ-W1', v_ex, 'voided', '正式', '自動', 80, '及格', 85, p_ts,
            p_ts, 'x', '測試作廢')
    returning id into v_id;
  else
    insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure,
                                    tenure_source)
    values (p_emp, 'x', 'ZZ-W1', v_ex, 'draft', '正式', '自動')
    returning id into v_id;
  end if;

  for i in 1 .. jsonb_array_length(p_items) loop
    insert into public.assessment_items (assessment_id, seq, category, code, levels)
    values (v_id, i, 'ZZ報' || i, null, p_items -> (i - 1))
    returning id into v_item;
    if p_qids is not null and p_qids[i] is not null then
      insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps)
      values (v_item, p_qids[i], false, 'x', '[]'::jsonb);
    end if;
  end loop;
  return v_id;
end $$;

-- 抽題結果的「寫入後指紋」：這場考核的題組＋機密（題號、was_drawn_before、名稱、步驟）、
-- 該分類目前的 drawn 題號、該分類的 category_last。用來比對 assess_draw 與 assess_pick 寫入是否一致。
create or replace function pg_temp.vr_sig(p_a uuid, p_cat text, p_ret text)
returns text language sql as $$
  select p_ret || '#'
    || coalesce((select string_agg(i.seq::text || ':' || i.category || ':' || coalesce(i.code, '-') || ':'
                                   || s.question_id::text || ':' || s.was_drawn_before::text || ':'
                                   || coalesce(s.title, '-') || ':' || s.steps::text, ',' order by i.seq)
                   from public.assessment_items i
                   join public.assessment_item_secrets s on s.item_id = i.id
                  where i.assessment_id = p_a), '(none)') || '#'
    || coalesce((select string_agg(d.question_id::text, ',' order by d.question_id)
                   from public.drawn d
                   join public.questions q on q.id = d.question_id
                  where q.category = p_cat), '(none)') || '#'
    || coalesce((select l.question_id::text from public.category_last l where l.category = p_cat), '(none)');
$$;

-- ============================================================
-- 建立假資料與基準（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  -- 記下既有物件的基準（本檔不該動到任何既有函式）；新增的四個函式不算
  perform pg_temp.vr_set('fn_md5',
    (select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid))
       from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
        and p.proname not in ('bank_set_dims', 'assess_weak_profile', 'assess_suggest_pool', 'assess_pick')));
  perform pg_temp.vr_set('real_questions',
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_set('real_drawn',
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_set('real_last',
    (select count(*)::text from public.category_last where category not like 'ZZ%'));

  insert into public.stores (code, name) values ('ZZ-W1', 'ZZ測試門市W');

  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
  select 'MI-' || n, '假考生' || n, 'ZZ-W1', '業務', date '2020-01-01', '在職', true
  from generate_series(9821, 9850) as g(n);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs@2motor.tw',  'cs_admin',      null),
    ('vr-cs2@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm@2motor.tw',  'store_manager', 'ZZ-W1');
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：權限與資料表保護
--   角色（客服部／總公司主管／店長／未開通／沒登入者／anon）× 四個新函式；
--   question_dims 的 select 與直接寫入；函式授權、security definer、RLS
-- ============================================================
do $$
declare
  f record;
  w record;
  v_pq bigint;
  v_draft uuid;
  v_sig text;
begin
  perform set_config('request.jwt.claims', '', true);

  v_pq := pg_temp.vr_mkq('ZZ權限', 'PM1');
  -- 預先放一筆標記（擁有者身分），之後被拒的 bank_set_dims 若真的寫入就會改成「問題掌握」
  insert into public.question_dims (question_id, dims, updated_by) values (v_pq, array['主動引導'], 'seed');
  v_draft := pg_temp.vr_mkrep('MI-9841', 'draft', null, '[]'::jsonb, null, 'vr-cs@2motor.tw');

  for f in
    select * from (values
      ('bank_set_dims',      format($q$select public.bank_set_dims(%s, array['問題掌握'])$q$, v_pq)),
      ('assess_weak_profile', $q$select public.assess_weak_profile('MI-9841')::text$q$),
      ('assess_suggest_pool', $q$select count(*)::text from public.assess_suggest_pool('MI-9841')$q$),
      ('assess_pick',        format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_draft, v_pq))
    ) as t(fn, stmt)
  loop
    for w in
      select * from (values
        ('總公司主管', 'authenticated', 'vr-hq@2motor.tw',   '%沒有權限%'),
        ('店長',       'authenticated', 'vr-sm@2motor.tw',   '%沒有權限%'),
        ('未開通帳號', 'authenticated', 'vr-none@2motor.tw', '%沒有權限%'),
        ('沒有登入者（authenticated 但 JWT 空）', 'authenticated', null::text, '%沒有權限%'),
        ('anon',       'anon',          null::text,          '%permission denied%')
      ) as r(label, rol, email, pat)
    loop
      perform pg_temp.vr_deny('1 權限', w.label || ' 呼叫 ' || f.fn, w.rol, w.email, f.stmt, w.pat);
    end loop;
  end loop;

  -- 被拒絕之後，資料必須完全沒被動到
  perform pg_temp.vr_eq('1 權限', '被拒後：題組標記仍是原來的「主動引導」（沒被改）', '主動引導', pg_temp.vr_d(v_pq));
  perform pg_temp.vr_eq('1 權限', '被拒後：草稿裡沒有被塞進題組、題庫該題沒被標成已抽', '0/0',
    pg_temp.vr_q1(format($q$select (select count(*) from public.assessment_items where assessment_id = %L::uuid)::text
                                   || '/' || (select count(*) from public.drawn where question_id = %s)::text$q$,
                         v_draft, v_pq)));

  -- question_dims 的 select：只有客服部看得到
  v_sig := format('select count(*)::text from public.question_dims where question_id = %s', v_pq);
  perform pg_temp.vr_eq('1 權限', 'question_dims：客服部讀得到標記（1 筆）', '1',
    pg_temp.vr_as('authenticated', 'vr-cs@2motor.tw', v_sig, true));
  perform pg_temp.vr_eq('1 權限', 'question_dims：總公司主管讀不到（0 筆）', '0',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', v_sig, true));
  perform pg_temp.vr_eq('1 權限', 'question_dims：店長讀不到（0 筆）', '0',
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', v_sig, true));
  perform pg_temp.vr_eq('1 權限', 'question_dims：未開通帳號讀不到（0 筆）', '0',
    pg_temp.vr_as('authenticated', 'vr-none@2motor.tw', v_sig, true));
  perform pg_temp.vr_eq('1 權限', 'question_dims：沒有登入者（JWT 空）讀不到（0 筆）', '0',
    pg_temp.vr_as('authenticated', null, v_sig, true));
  perform pg_temp.vr_deny('1 權限', 'question_dims：anon 讀取被拒', 'anon', null, v_sig, '%permission denied%');

  -- 直接寫入一律被拒（含客服部）
  perform pg_temp.vr_csdeny('1 權限', 'question_dims：客服部直接 insert 被拒',
    format($q$insert into public.question_dims (question_id, dims) values (%s, array['問題掌握'])$q$, v_pq),
    '%permission denied%');
  perform pg_temp.vr_csdeny('1 權限', 'question_dims：客服部直接 update 被拒',
    $q$update public.question_dims set dims = array['問題掌握']$q$, '%permission denied%');
  perform pg_temp.vr_csdeny('1 權限', 'question_dims：客服部直接 delete 被拒',
    'delete from public.question_dims', '%permission denied%');
  perform pg_temp.vr_csdeny('1 權限', 'question_dims：客服部直接 truncate 被拒',
    'truncate public.question_dims', '%permission denied%');
  perform pg_temp.vr_deny('1 權限', 'question_dims：總公司主管直接 update 被拒', 'authenticated', 'vr-hq@2motor.tw',
    $q$update public.question_dims set dims = array['問題掌握']$q$, '%permission denied%');
  perform pg_temp.vr_deny('1 權限', 'question_dims：店長直接 insert 被拒', 'authenticated', 'vr-sm@2motor.tw',
    format($q$insert into public.question_dims (question_id, dims) values (%s, array['問題掌握'])$q$, v_pq),
    '%permission denied%');
  perform pg_temp.vr_eq('1 權限', '直接寫入被拒後：標記仍是原來的「主動引導」', '主動引導', pg_temp.vr_d(v_pq));

  -- 授權：anon 不能執行、authenticated 可以執行
  for f in
    select * from (values
      ('public.bank_set_dims(bigint, text[])'),
      ('public.assess_weak_profile(text)'),
      ('public.assess_suggest_pool(text)'),
      ('public.assess_pick(uuid, bigint[])')
    ) as t(sig)
  loop
    perform pg_temp.vr_eq('1 權限', f.sig || '：anon 沒有 execute 權限', 'false',
      has_function_privilege('anon', f.sig, 'execute')::text);
    perform pg_temp.vr_eq('1 權限', f.sig || '：authenticated 有 execute 權限', 'true',
      has_function_privilege('authenticated', f.sig, 'execute')::text);
  end loop;

  perform pg_temp.vr_eq('1 權限', '四個函式都是 security definer 且固定 search_path（含 pg_temp）', '4',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
                      where p.pronamespace = 'public'::regnamespace
                        and p.proname in ('bank_set_dims', 'assess_weak_profile', 'assess_suggest_pool', 'assess_pick')
                        and p.prosecdef
                        and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp%')$q$));
  perform pg_temp.vr_eq('1 權限', 'question_dims 已開 RLS', 'true',
    pg_temp.vr_q1($q$select relrowsecurity::text from pg_class where oid = 'public.question_dims'::regclass$q$));
  perform pg_temp.vr_eq('1 權限', 'question_dims 資料表權限：authenticated 只有 select，anon 什麼都沒有',
    'select=true,insert=false,update=false,delete=false,truncate=false,anon_select=false',
    pg_temp.vr_q1($q$select 'select=' || has_table_privilege('authenticated', 'public.question_dims', 'select')::text
                          || ',insert=' || has_table_privilege('authenticated', 'public.question_dims', 'insert')::text
                          || ',update=' || has_table_privilege('authenticated', 'public.question_dims', 'update')::text
                          || ',delete=' || has_table_privilege('authenticated', 'public.question_dims', 'delete')::text
                          || ',truncate=' || has_table_privilege('authenticated', 'public.question_dims', 'truncate')::text
                          || ',anon_select=' || has_table_privilege('anon', 'public.question_dims', 'select')::text$q$));
exception when others then
  perform pg_temp.vr_rec('區段 1','權限測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：bank_set_dims（驗證、覆蓋、刪除、連帶刪除、資料表層的保護）
-- ============================================================
do $$
declare
  q1 bigint; q2 bigint; q3 bigint;
  v_none bigint;
  v_set text := $q$select public.bank_set_dims(%s, %s)$q$;
begin
  perform set_config('request.jwt.claims', '', true);

  q1 := pg_temp.vr_mkq('ZZ標A', 'D1');
  q2 := pg_temp.vr_mkq('ZZ標A', 'D2');
  q3 := pg_temp.vr_mkq('ZZ標B', 'D3');
  v_none := (select coalesce(max(id), 0) + 100000 from public.questions);

  -- 成功：新增
  perform pg_temp.vr_csok('2 設定面向', '設定 1 個面向', format(v_set, q1, $q$array['問題掌握']$q$));
  perform pg_temp.vr_eq('2 設定面向', '設定 1 個面向：標記為「問題掌握」', '問題掌握', pg_temp.vr_d(q1));

  -- 成功：3 個（邊界），傳入順序亂，存入依固定順序
  perform pg_temp.vr_csok('2 設定面向', '設定 3 個面向（上限）', format(v_set, q1, $q$array['風險意識','資訊正確性','問題掌握']$q$));
  perform pg_temp.vr_eq('2 設定面向', '設定 3 個面向：依固定順序存成「資訊正確性＋問題掌握＋風險意識」', '資訊正確性+問題掌握+風險意識',
    pg_temp.vr_d(q1));

  -- 重複設定：覆蓋，不是疊加，也不會多出第二列
  perform pg_temp.vr_csok('2 設定面向', '重複設定（覆蓋成 2 個）', format(v_set, q1, $q$array['主動引導','預設訊息運用']$q$));
  perform pg_temp.vr_eq('2 設定面向', '重複設定：以最後一次為準（預設訊息運用＋主動引導）', '預設訊息運用+主動引導', pg_temp.vr_d(q1));
  perform pg_temp.vr_eq('2 設定面向', '重複設定：同一題仍只有 1 列', '1',
    pg_temp.vr_q1(format('select count(*)::text from public.question_dims where question_id = %s', q1)));
  perform pg_temp.vr_eq('2 設定面向', 'updated_by 記下設定者的信箱', 'vr-cs@2motor.tw',
    pg_temp.vr_q1(format('select updated_by from public.question_dims where question_id = %s', q1)));

  -- 其他題組的標記不受影響
  perform pg_temp.vr_csok('2 設定面向', '另一題設定「風險意識」', format(v_set, q3, $q$array['風險意識']$q$));

  -- 驗證：被拒
  perform pg_temp.vr_csdeny('2 驗證', '超過 3 個被拒', format(v_set, q1, $q$array['資訊正確性','預設訊息運用','問題掌握','主動引導']$q$),
    '%最多只能選 3 個%');
  perform pg_temp.vr_csdeny('2 驗證', '非法面向「語氣與禮貌」被拒（只能勾 5 個）', format(v_set, q1, $q$array['語氣與禮貌']$q$),
    '%面向不正確%語氣與禮貌%');
  perform pg_temp.vr_csdeny('2 驗證', '非法面向「文字品質」被拒', format(v_set, q1, $q$array['文字品質']$q$),
    '%面向不正確%文字品質%');
  perform pg_temp.vr_csdeny('2 驗證', '亂寫的面向被拒', format(v_set, q1, $q$array['亂寫']$q$), '%面向不正確%亂寫%');
  perform pg_temp.vr_csdeny('2 驗證', '合法面向混一個非法面向被拒', format(v_set, q1, $q$array['問題掌握','文字品質']$q$),
    '%面向不正確%');
  perform pg_temp.vr_csdeny('2 驗證', '重複的面向被拒', format(v_set, q1, $q$array['問題掌握','問題掌握']$q$), '%面向不可重複%');
  perform pg_temp.vr_csdeny('2 驗證', '含 null 元素被拒', format(v_set, q1, $q$array['問題掌握', null]::text[]$q$), '%面向不可有空值%');
  perform pg_temp.vr_csdeny('2 驗證', '面向整個是 null 被拒', format(v_set, q1, 'null::text[]'), '%面向不可為 null%');
  perform pg_temp.vr_csdeny('2 驗證', '二維陣列被拒', format(v_set, q1, $q$array[['問題掌握','主動引導']]::text[]$q$), '%一維%');
  perform pg_temp.vr_csdeny('2 驗證', '題組不存在被拒', format(v_set, v_none, $q$array['問題掌握']$q$), '%找不到題組%');
  perform pg_temp.vr_csdeny('2 驗證', '題組不存在（空陣列也一樣）被拒', format(v_set, v_none, $q$array[]::text[]$q$), '%找不到題組%');
  perform pg_temp.vr_csdeny('2 驗證', '題組編號 null 被拒', format(v_set, 'null::bigint', $q$array['問題掌握']$q$), '%題組編號不可空白%');
  perform pg_temp.vr_eq('2 驗證', '全部被拒之後：標記沒被動到（預設訊息運用＋主動引導）', '預設訊息運用+主動引導', pg_temp.vr_d(q1));
  perform pg_temp.vr_eq('2 驗證', '全部被拒之後：另一題標記仍是「風險意識」、沒標的題仍是未標記', '風險意識/(none)',
    pg_temp.vr_d(q3) || '/' || pg_temp.vr_d(q2));

  -- 空陣列＝刪除標記
  perform pg_temp.vr_csok('2 刪除標記', '空陣列清除標記', format(v_set, q1, $q$array[]::text[]$q$));
  perform pg_temp.vr_eq('2 刪除標記', '空陣列之後：該題回到未標記', '(none)', pg_temp.vr_d(q1));
  perform pg_temp.vr_csok('2 刪除標記', '對本來就沒標記的題傳空陣列：不報錯', format(v_set, q2, $q$array[]::text[]$q$));
  perform pg_temp.vr_eq('2 刪除標記', '清除一題不影響別題（另一題仍是「風險意識」）', '風險意識', pg_temp.vr_d(q3));

  -- 連帶刪除：刪題組（用既有的 bank_delete_question），標記跟著消失
  perform pg_temp.vr_csok('2 連帶刪除', '客服部刪除題組（既有 bank_delete_question）',
    format('select public.bank_delete_question(%s)', q3));
  perform pg_temp.vr_eq('2 連帶刪除', '題組刪除後：標記一併刪除（cascade）', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.question_dims where question_id = %s', q3)));

  -- 資料表層的保護（即使繞過函式，以擁有者身分也寫不進不合法內容）
  perform pg_temp.vr_eq('2 資料表約束', '擁有者直接 insert：重複面向被約束擋下', 'ERROR: 約束',
    case when pg_temp.vr_owner(format($q$insert into public.question_dims (question_id, dims) values (%s, array['問題掌握','問題掌握'])$q$, q2))
              like '%violates check constraint%question_dims_dims_valid%' then 'ERROR: 約束' else 'other' end);
  perform pg_temp.vr_eq('2 資料表約束', '擁有者直接 insert：4 個面向被約束擋下', 'ERROR: 約束',
    case when pg_temp.vr_owner(format($q$insert into public.question_dims (question_id, dims) values (%s, array['資訊正確性','預設訊息運用','問題掌握','主動引導'])$q$, q2))
              like '%violates check constraint%question_dims_dims_valid%' then 'ERROR: 約束' else 'other' end);
  perform pg_temp.vr_eq('2 資料表約束', '擁有者直接 insert：非法面向被約束擋下', 'ERROR: 約束',
    case when pg_temp.vr_owner(format($q$insert into public.question_dims (question_id, dims) values (%s, array['文字品質'])$q$, q2))
              like '%violates check constraint%question_dims_dims_valid%' then 'ERROR: 約束' else 'other' end);
  perform pg_temp.vr_eq('2 資料表約束', '擁有者直接 insert：空陣列被約束擋下', 'ERROR: 約束',
    case when pg_temp.vr_owner(format($q$insert into public.question_dims (question_id, dims) values (%s, array[]::text[])$q$, q2))
              like '%violates check constraint%question_dims_dims_valid%' then 'ERROR: 約束' else 'other' end);
  perform pg_temp.vr_eq('2 資料表約束', '擁有者直接 insert：不存在的題組被外鍵擋下', 'ERROR: 外鍵',
    case when pg_temp.vr_owner(format($q$insert into public.question_dims (question_id, dims) values (%s, array['問題掌握'])$q$, v_none))
              like '%violates foreign key constraint%' then 'ERROR: 外鍵' else 'other' end);
exception when others then
  perform pg_temp.vr_rec('區段 2','bank_set_dims 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：assess_weak_profile（得分率與弱項）
--   成績單一律以擁有者身分直接寫入（可指定 submitted_at、作廢、草稿），
--   再用客服部身分呼叫函式，把結果攤成「面向:百分比」字串比對。
-- ============================================================
do $$
declare
  -- 把 weak_profile 的某一段攤成「面向:pct,面向:pct」（p_key = rates／weak／always_low）
  v_list text := $q$select coalesce(string_agg((t.w ->> 'dim') || ':' || coalesce(t.w ->> 'pct', 'null'), ',' order by t.ord), '')
                      from jsonb_array_elements(public.assess_weak_profile(%L) -> %L) with ordinality as t(w, ord)$q$;
  v_n text := $q$select (public.assess_weak_profile(%L) ->> 'n')$q$;
  v_nulls text := '資訊正確性:null,預設訊息運用:null,問題掌握:null,主動引導:null,風險意識:null,語氣與禮貌:null,文字品質:null';
  v_id uuid;
begin
  perform set_config('request.jwt.claims', '', true);

  -- ===== 無成績單（MI-9821）=====
  perform pg_temp.vr_eq('3 弱項', '無成績單：n = 0', '0', pg_temp.vr_cs(format(v_n, 'MI-9821')));
  perform pg_temp.vr_eq('3 弱項', '無成績單：rates 七個面向固定順序、pct 全是 null', v_nulls,
    pg_temp.vr_cs(format(v_list, 'MI-9821', 'rates')));
  perform pg_temp.vr_eq('3 弱項', '無成績單：weak 是空陣列', '', pg_temp.vr_cs(format(v_list, 'MI-9821', 'weak')));
  perform pg_temp.vr_eq('3 弱項', '無成績單：always_low 是空陣列', '', pg_temp.vr_cs(format(v_list, 'MI-9821', 'always_low')));
  perform pg_temp.vr_eq('3 弱項', '回傳是 jsonb 物件，只有 n、rates、weak、always_low 四個鍵',
    'n,rates,weak,always_low',
    pg_temp.vr_cs($q$select string_agg(k, ',' order by case k when 'n' then 1 when 'rates' then 2 when 'weak' then 3 else 4 end)
                       from jsonb_object_keys(public.assess_weak_profile('MI-9821')) as k$q$));
  perform pg_temp.vr_eq('3 弱項', 'rates 每一項都是 {dim, pct} 兩個鍵', '7',
    pg_temp.vr_cs($q$select count(*)::text from jsonb_array_elements(public.assess_weak_profile('MI-9821') -> 'rates') e
                      where (select count(*) from jsonb_object_keys(e)) = 2 and e ? 'dim' and e ? 'pct'$q$));
  perform pg_temp.vr_csdeny('3 弱項', '員工不存在被拒', $q$select public.assess_weak_profile('MI-0000')::text$q$, '%找不到員工%');

  -- 只有作廢與草稿（MI-9829）：視同沒有成績單
  perform pg_temp.vr_mkrep('MI-9829', 'voided', now() - interval '2 days', '[{"資訊正確性":"優"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9829', 'draft', null, '[{"資訊正確性":"優"}]'::jsonb);
  perform pg_temp.vr_eq('3 弱項', '只有作廢與草稿：n = 0', '0', pg_temp.vr_cs(format(v_n, 'MI-9829')));
  perform pg_temp.vr_eq('3 弱項', '只有作廢與草稿：weak 是空陣列', '', pg_temp.vr_cs(format(v_list, 'MI-9829', 'weak')));

  -- ===== 1 張成績單（MI-9822）：不適用與未評不計入；weak 取 5 個面向最低的 2 個 =====
  perform pg_temp.vr_mkrep('MI-9822', 'submitted', now() - interval '1 day', jsonb_build_array(
    '{"資訊正確性":"優","預設訊息運用":"良","問題掌握":"待加強","主動引導":"不及格","風險意識":"優","語氣與禮貌":"優","文字品質":"優"}'::jsonb,
    '{"資訊正確性":"良","預設訊息運用":"不適用","問題掌握":"良","主動引導":"待加強","風險意識":"不適用"}'::jsonb));
  perform pg_temp.vr_eq('3 弱項', '1 張成績單：n = 1', '1', pg_temp.vr_cs(format(v_n, 'MI-9822')));
  perform pg_temp.vr_eq('3 弱項', '1 張成績單：各面向以題組平均（不適用、未評不計入；優100良70待加強40不及格0）',
    '資訊正確性:85,預設訊息運用:70,問題掌握:55,主動引導:20,風險意識:100,語氣與禮貌:100,文字品質:100',
    pg_temp.vr_cs(format(v_list, 'MI-9822', 'rates')));
  perform pg_temp.vr_eq('3 弱項', '1 張成績單：weak 是最低的 2 個，由低到高', '主動引導:20,問題掌握:55',
    pg_temp.vr_cs(format(v_list, 'MI-9822', 'weak')));
  perform pg_temp.vr_eq('3 弱項', '1 張成績單：語氣、文字品質都很高 → always_low 空', '',
    pg_temp.vr_cs(format(v_list, 'MI-9822', 'always_low')));

  -- ===== 5 張已送出＋1 張更新的作廢＋1 張更新的草稿（MI-9823）：只取最近 3 張已送出 =====
  -- 故意不照時間順序寫入：最新的先寫、最舊的後寫，證明排序依 submitted_at 而不是寫入順序
  perform pg_temp.vr_mkrep('MI-9823', 'submitted', now() - interval '1 day',  '[{"資訊正確性":"待加強"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9823', 'submitted', now() - interval '5 days', '[{"資訊正確性":"不及格"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9823', 'submitted', now() - interval '3 days', '[{"資訊正確性":"良"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9823', 'submitted', now() - interval '4 days', '[{"資訊正確性":"不及格"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9823', 'submitted', now() - interval '2 days', '[{"資訊正確性":"優"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9823', 'voided',    now() - interval '12 hours', '[{"資訊正確性":"優"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9823', 'draft',     null, '[{"資訊正確性":"優"}]'::jsonb);
  perform pg_temp.vr_eq('3 弱項', '3 張以上：n 最多 3', '3', pg_temp.vr_cs(format(v_n, 'MI-9823')));
  perform pg_temp.vr_eq('3 弱項', '3 張以上：只取最近 3 張已送出（待加強、優、良＝70；含舊的 2 張不及格會變 42，含作廢會變 80）',
    '資訊正確性:70,預設訊息運用:null,問題掌握:null,主動引導:null,風險意識:null,語氣與禮貌:null,文字品質:null',
    pg_temp.vr_cs(format(v_list, 'MI-9823', 'rates')));
  perform pg_temp.vr_eq('3 弱項', '3 張以上：weak 只有有資料的 1 個（不足 2 個就取有的）', '資訊正確性:70',
    pg_temp.vr_cs(format(v_list, 'MI-9823', 'weak')));

  -- ===== 1 張已送出＋作廢＋草稿（MI-9824）：作廢與草稿不計 =====
  perform pg_temp.vr_mkrep('MI-9824', 'submitted', now() - interval '2 days', '[{"資訊正確性":"良"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9824', 'voided',    now() - interval '1 day',
                           '[{"資訊正確性":"優","問題掌握":"不及格"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9824', 'draft',     null, '[{"問題掌握":"不及格"}]'::jsonb);
  perform pg_temp.vr_eq('3 弱項', '作廢與草稿不計：n = 1', '1', pg_temp.vr_cs(format(v_n, 'MI-9824')));
  perform pg_temp.vr_eq('3 弱項', '作廢與草稿不計：資訊正確性 70（含作廢會變 85）、問題掌握仍是 null',
    '資訊正確性:70,預設訊息運用:null,問題掌握:null,主動引導:null,風險意識:null,語氣與禮貌:null,文字品質:null',
    pg_temp.vr_cs(format(v_list, 'MI-9824', 'rates')));

  -- ===== 以題組為單位平均（MI-9825）：A 張 3 題都優、B 張 1 題不及格 → 75（若先算每張平均再平均會是 50）=====
  perform pg_temp.vr_mkrep('MI-9825', 'submitted', now() - interval '2 days',
    '[{"資訊正確性":"優"},{"資訊正確性":"優"},{"資訊正確性":"優"}]'::jsonb);
  perform pg_temp.vr_mkrep('MI-9825', 'submitted', now() - interval '1 day', '[{"資訊正確性":"不及格"}]'::jsonb);
  perform pg_temp.vr_eq('3 弱項', '以題組為單位平均：(100×3＋0)÷4 = 75', '資訊正確性:75',
    pg_temp.vr_cs(format(v_list, 'MI-9825', 'weak')));

  -- ===== 語氣與禮貌、文字品質不進 weak（MI-9826）=====
  perform pg_temp.vr_mkrep('MI-9826', 'submitted', now() - interval '1 day',
    '[{"資訊正確性":"優","預設訊息運用":"優","問題掌握":"良","主動引導":"良","風險意識":"優","語氣與禮貌":"待加強","文字品質":"不及格"}]'::jsonb);
  perform pg_temp.vr_eq('3 弱項', '語氣 40、文字 0 是全部最低，但 weak 只從 5 個面向取（並列依固定順序）', '問題掌握:70,主動引導:70',
    pg_temp.vr_cs(format(v_list, 'MI-9826', 'weak')));
  perform pg_temp.vr_eq('3 弱項', '語氣與文字品質偏低 → 進 always_low（依固定順序）', '語氣與禮貌:40,文字品質:0',
    pg_temp.vr_cs(format(v_list, 'MI-9826', 'always_low')));

  -- ===== 邊界（MI-9827）：文字品質剛好 70 不算低；語氣 900÷13＝69.23 算低 =====
  -- 平均值是 10 的倍數除以題組數，要剛好 69.9 需要 100 題以上，做不出來；
  -- 這裡用 13 題做出 69.23（6 優、2 良、4 待加強、1 不及格）當「剛好低於 70」，用兩題（優、待加強）做出剛好 70。
  perform pg_temp.vr_mkrep('MI-9827', 'submitted', now() - interval '1 day',
    (select jsonb_agg(
              case when t.n = 1 then jsonb_build_object('語氣與禮貌', t.lv, '文字品質', '優')
                   when t.n = 2 then jsonb_build_object('語氣與禮貌', t.lv, '文字品質', '待加強')
                   else jsonb_build_object('語氣與禮貌', t.lv) end
              order by t.n)
       from unnest(array['優','優','優','優','優','優','良','良','待加強','待加強','待加強','待加強','不及格'])
            with ordinality as t(lv, n)));
  perform pg_temp.vr_eq('3 弱項', '邊界：語氣 69.23 < 70 進 always_low（輸出四捨五入到小數 1 位）；文字品質剛好 70 不進',
    '語氣與禮貌:69.2', pg_temp.vr_cs(format(v_list, 'MI-9827', 'always_low')));
  perform pg_temp.vr_eq('3 弱項', '邊界：文字品質剛好 70（優 100、待加強 40 平均）', '文字品質:70',
    pg_temp.vr_cs($q$select (t.w ->> 'dim') || ':' || (t.w ->> 'pct')
                       from jsonb_array_elements(public.assess_weak_profile('MI-9827') -> 'rates') as t(w)
                      where t.w ->> 'dim' = '文字品質'$q$));
  perform pg_temp.vr_eq('3 弱項', '邊界：5 個面向都沒資料 → weak 空陣列（語氣、文字品質不補位）', '',
    pg_temp.vr_cs(format(v_list, 'MI-9827', 'weak')));
exception when others then
  perform pg_temp.vr_rec('區段 3','assess_weak_profile 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：assess_suggest_pool（整個題庫、標記、考過、本輪已抽）
-- ============================================================
do $$
declare
  p1 bigint; p2 bigint; p3 bigint; p4 bigint;
  v_str text := $q$select string_agg(p.title || ':' || array_to_string(p.dims, '+') || ':'
                                     || case when p.taken_before then 'Y' else 'N' end || ':'
                                     || case when p.drawn_this_round then 'Y' else 'N' end, ',' order by p.n)
                     from public.assess_suggest_pool(%L)
                          with ordinality as p(question_id, category, title, dims, taken_before, drawn_this_round, n)
                    where p.category like 'ZZ池%%'$q$;
begin
  perform set_config('request.jwt.claims', '', true);

  -- 分類第一次出現順序＝甲、乙；同分類依 id
  p1 := pg_temp.vr_mkq('ZZ池甲', 'P1');
  p2 := pg_temp.vr_mkq('ZZ池甲', 'P2');
  p3 := pg_temp.vr_mkq('ZZ池乙', 'P3');
  p4 := pg_temp.vr_mkq('ZZ池乙', 'P4');
  insert into public.question_dims (question_id, dims, updated_by) values
    (p1, array['問題掌握', '主動引導'], 'seed'),
    (p3, array['風險意識'], 'seed');
  insert into public.drawn (question_id) values (p2);

  -- MI-9828：已送出的成績單考過 P1、已作廢的考過 P3、草稿裡有 P2（草稿不算考過）
  perform pg_temp.vr_mkrep('MI-9828', 'submitted', now() - interval '3 days', '[{}]'::jsonb, array[p1]);
  perform pg_temp.vr_mkrep('MI-9828', 'voided',    now() - interval '2 days', '[{}]'::jsonb, array[p3]);
  perform pg_temp.vr_mkrep('MI-9828', 'draft',     null,                      '[{}]'::jsonb, array[p2]);

  perform pg_temp.vr_eq('4 建議題庫', '回傳欄位與型別（規格指定的 6 欄）',
    'TABLE(question_id bigint, category text, title text, dims text[], taken_before boolean, drawn_this_round boolean)',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_suggest_pool(text)'::regprocedure)$q$));

  perform pg_temp.vr_eq('4 建議題庫', '題組、標記（未標記＝空）、考過（已送出與已作廢算、草稿不算）、本輪已抽、排序',
    '假題組P1:問題掌握+主動引導:Y:N,假題組P2::N:Y,假題組P3:風險意識:Y:N,假題組P4::N:N',
    pg_temp.vr_cs(format(v_str, 'MI-9828')));

  perform pg_temp.vr_eq('4 建議題庫', '回傳整個題庫（筆數與題庫總題數相同，含真實題目）',
    pg_temp.vr_q1('select count(*)::text from public.questions'),
    pg_temp.vr_cs($q$select count(*)::text from public.assess_suggest_pool('MI-9828')$q$));

  perform pg_temp.vr_eq('4 建議題庫', 'dims 永遠不是 null（未標記為空陣列）', '0',
    pg_temp.vr_cs($q$select count(*)::text from public.assess_suggest_pool('MI-9828') p where p.dims is null$q$));

  perform pg_temp.vr_eq('4 建議題庫', '另一位沒考過任何題的考生（MI-9830）：假題全部 taken_before = N', 'N,N,N,N',
    pg_temp.vr_cs($q$select string_agg(case when p.taken_before then 'Y' else 'N' end, ',' order by p.question_id)
                       from public.assess_suggest_pool('MI-9830') p where p.category like 'ZZ池%'$q$));

  -- 洗牌（既有 bank_reset）後 drawn_this_round 跟著變
  perform pg_temp.vr_csok('4 建議題庫', '客服部洗牌「ZZ池甲」（既有 bank_reset）', $q$select public.bank_reset('ZZ池甲')$q$);
  perform pg_temp.vr_eq('4 建議題庫', '洗牌後：P2 的 drawn_this_round 變 N，其餘照舊',
    '假題組P1:問題掌握+主動引導:Y:N,假題組P2::N:N,假題組P3:風險意識:Y:N,假題組P4::N:N',
    pg_temp.vr_cs(format(v_str, 'MI-9828')));

  perform pg_temp.vr_csdeny('4 建議題庫', '員工不存在被拒', $q$select count(*) from public.assess_suggest_pool('MI-0000')$q$, '%找不到員工%');
exception when others then
  perform pg_temp.vr_rec('區段 4','assess_suggest_pool 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：assess_pick（寫入語意與 assess_draw 一致、各種被拒情況、與 assess_draw 混用）
-- ============================================================
do $$
declare
  qa1 bigint; qa2 bigint; qa3 bigint; qb1 bigint; qb2 bigint; qc1 bigint; qd1 bigint; qd2 bigint;
  v_str text := $q$select string_agg(r.category || ':' || r.code || ':' || r.repeated::text || ':' || r.new_round::text, ',' order by r.n)
                     from public.assess_pick(%L::uuid, array[%s]::bigint[])
                          with ordinality as r(item_id, category, code, title, steps, repeated, new_round, n)$q$;
  v_items text := $q$select string_agg(i.seq::text || ':' || i.category || ':' || i.code, ',' order by i.seq)
                       from public.assessment_items i where i.assessment_id = %L::uuid$q$;
  v_sec text := $q$select string_agg(s.question_id::text || ':' || s.was_drawn_before::text || ':' || s.title, ',' order by i.seq)
                     from public.assessment_items i
                     join public.assessment_item_secrets s on s.item_id = i.id
                    where i.assessment_id = %L::uuid$q$;
  v_drawn text := $q$select coalesce(string_agg(d.question_id::text, ',' order by d.question_id), '(none)')
                       from public.drawn d join public.questions q on q.id = d.question_id
                      where q.category = %L$q$;
  v_d1 uuid; v_d1b uuid; v_d2 uuid; v_d3 uuid; v_d4 uuid; v_d5 uuid; v_sub uuid; v_void uuid;
  v_s1 text; v_s2 text; v_ret text;
  v_pa uuid; v_pb uuid;
  i int;
  v_emp_draw text; v_emp_pick text;
begin
  perform set_config('request.jwt.claims', '', true);

  qa1 := pg_temp.vr_mkq('ZZ選A', 'A1');
  qa2 := pg_temp.vr_mkq('ZZ選A', 'A2');
  qa3 := pg_temp.vr_mkq('ZZ選A', 'A3');
  qb1 := pg_temp.vr_mkq('ZZ選B', 'B1');
  qb2 := pg_temp.vr_mkq('ZZ選B', 'B2');
  qc1 := pg_temp.vr_mkq('ZZ選C', 'C1');
  qd1 := pg_temp.vr_mkq('ZZ選D', 'D1');
  qd2 := pg_temp.vr_mkq('ZZ選D', 'D2');

  -- 草稿：全部經真正的 assess_start 建立
  v_d1  := pg_temp.vr_cs($q$select public.assess_start('MI-9831')::text$q$)::uuid;                                   -- 客服部 1 的主草稿
  v_d1b := pg_temp.vr_as('authenticated', 'vr-cs2@2motor.tw', $q$select public.assess_start('MI-9831')::text$q$, true)::uuid;  -- 客服部 2 對同一人的草稿
  v_d2  := pg_temp.vr_cs($q$select public.assess_start('MI-9839')::text$q$)::uuid;
  v_d3  := pg_temp.vr_cs($q$select public.assess_start('MI-9840')::text$q$)::uuid;
  v_d4  := pg_temp.vr_cs($q$select public.assess_start('MI-9842')::text$q$)::uuid;
  v_d5  := pg_temp.vr_cs($q$select public.assess_start('MI-9845')::text$q$)::uuid;

  -- ---------- 回傳型別、鎖 ----------
  perform pg_temp.vr_eq('5 選題', '回傳欄位與 assess_draw 完全相同',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_draw(uuid, text[])'::regprocedure)$q$),
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_pick(uuid, bigint[])'::regprocedure)$q$));
  perform pg_temp.vr_eq('5 選題', '回傳欄位正是規格指定的 7 欄',
    'TABLE(item_id uuid, category text, code text, title text, steps jsonb, repeated boolean, new_round boolean)',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_pick(uuid, bigint[])'::regprocedure)$q$));
  perform pg_temp.vr_eq('5 選題', 'assess_pick 與 assess_draw 取同一把鎖（hashtext(''exam_draw_questions'')）', 'true/true',
    pg_temp.vr_q1($q$select (position('pg_advisory_xact_lock(hashtext(''exam_draw_questions''))'
                                      in pg_get_functiondef('public.assess_pick(uuid, bigint[])'::regprocedure)) > 0)::text
                            || '/' || (position('pg_advisory_xact_lock(hashtext(''exam_draw_questions''))'
                                      in pg_get_functiondef('public.assess_draw(uuid, text[])'::regprocedure)) > 0)::text$q$));

  -- ---------- 主流程：MI-9831 選 A1、B1 ----------
  perform pg_temp.vr_eq('5 選題', '成功：回傳 2 列（分類、代號、repeated、new_round，依傳入順序）',
    'ZZ選A:A1:false:false,ZZ選B:B1:false:false',
    pg_temp.vr_cs(format(v_str, v_d1, qa1 || ',' || qb1)));
  perform pg_temp.vr_eq('5 選題', '成功：assessment_items 依序 seq 1、2', '1:ZZ選A:A1,2:ZZ選B:B1',
    pg_temp.vr_q1(format(v_items, v_d1)));
  perform pg_temp.vr_eq('5 選題', '成功：機密表記下題號、was_drawn_before、名稱',
    format('%s:false:假題組A1,%s:false:假題組B1', qa1, qb1),
    pg_temp.vr_q1(format(v_sec, v_d1)));
  perform pg_temp.vr_eq('5 選題', '成功：機密表存下題庫當時的步驟（考官操作與考點）', 'true',
    pg_temp.vr_q1(format($q$select bool_and(s.steps = '[{"action":"動作","point":"考點"}]'::jsonb)::text
                              from public.assessment_items i join public.assessment_item_secrets s on s.item_id = i.id
                             where i.assessment_id = %L::uuid$q$, v_d1)));
  perform pg_temp.vr_eq('5 選題', '成功：選到的題寫入 drawn（沒選的 A2、A3、B2 不在）',
    format('%s,%s', qa1, qb1),
    pg_temp.vr_q1(format($q$select string_agg(question_id::text, ',' order by question_id) from public.drawn
                             where question_id in (%s,%s,%s,%s,%s)$q$, qa1, qa2, qa3, qb1, qb2)));
  perform pg_temp.vr_eq('5 選題', '成功：category_last 更新為選到的題', format('ZZ選A:%s,ZZ選B:%s', qa1, qb1),
    pg_temp.vr_q1($q$select string_agg(category || ':' || question_id::text, ',' order by category)
                       from public.category_last where category in ('ZZ選A', 'ZZ選B')$q$));

  -- ---------- 沒有「全部抽完」的分類：選到已抽過的題 → was_drawn_before = true、不開新一輪；另一分類剛好抽滿也不開新一輪 ----------
  perform pg_temp.vr_eq('5 選題', '再選 A1（已在 drawn）與 B2：沒有開新一輪、repeated 皆 false',
    'ZZ選A:A1:false:false,ZZ選B:B2:false:false',
    pg_temp.vr_cs(format(v_str, v_d2, qa1 || ',' || qb2)));
  perform pg_temp.vr_eq('5 選題', '再選 A1：was_drawn_before 為 true（它本來就在 drawn），B2 為 false',
    format('%s:true:假題組A1,%s:false:假題組B2', qa1, qb2),
    pg_temp.vr_q1(format(v_sec, v_d2)));
  perform pg_temp.vr_eq('5 選題', '此時 B 分類已全部抽過（B1、B2 都在 drawn）', format('%s,%s', qb1, qb2),
    pg_temp.vr_q1(format(v_drawn, 'ZZ選B')));

  -- 分類已全部抽過 → 再選其中一題：先清該分類 drawn 開新一輪
  perform pg_temp.vr_eq('5 選題', '分類已全部抽過再選 B1：new_round = true',
    'ZZ選B:B1:false:true',
    pg_temp.vr_cs(format(v_str, v_d3, qb1::text)));
  perform pg_temp.vr_eq('5 選題', '開新一輪後：B 分類 drawn 只剩剛選的 B1', qb1::text, pg_temp.vr_q1(format(v_drawn, 'ZZ選B')));
  perform pg_temp.vr_eq('5 選題', '開新一輪後：was_drawn_before 為 false（清完之後才判斷）', format('%s:false:假題組B1', qb1),
    pg_temp.vr_q1(format(v_sec, v_d3)));
  perform pg_temp.vr_eq('5 選題', '開新一輪不影響別的分類：A 分類 drawn 仍是 A1', qa1::text, pg_temp.vr_q1(format(v_drawn, 'ZZ選A')));

  -- ---------- repeated：以前考過（已送出、已作廢都算，草稿不算） ----------
  perform pg_temp.vr_mkrep('MI-9842', 'submitted', now() - interval '3 days', '[{}]'::jsonb, array[qd2]);
  perform pg_temp.vr_mkrep('MI-9842', 'voided',    now() - interval '2 days', '[{}]'::jsonb, array[qa3]);
  perform pg_temp.vr_eq('5 選題', 'repeated：考過的 D2（已送出）與 A3（已作廢）皆為 true',
    'ZZ選D:D2:true:false,ZZ選A:A3:true:false',
    pg_temp.vr_cs(format(v_str, v_d4, qd2 || ',' || qa3)));

  -- ---------- 與 assess_draw 的寫入一致：同一題、同樣起始狀態，各跑一次，比對寫入後指紋 ----------
  -- 情境 1：C 分類只有 C1，完全沒抽過；情境 2：C1 已在 drawn（會開新一輪）；情境 3：考生以前考過 C1。
  for i in 1 .. 3 loop
    if i = 3 then
      perform pg_temp.vr_mkrep('MI-9837', 'submitted', now() - interval '3 days', '[{}]'::jsonb, array[qc1]);
      perform pg_temp.vr_mkrep('MI-9838', 'submitted', now() - interval '3 days', '[{}]'::jsonb, array[qc1]);
    end if;
    v_emp_draw := case i when 1 then 'MI-9833' when 2 then 'MI-9835' else 'MI-9837' end;
    v_emp_pick := case i when 1 then 'MI-9834' when 2 then 'MI-9836' else 'MI-9838' end;
    v_pa := pg_temp.vr_cs(format($q$select public.assess_start(%L)::text$q$, v_emp_draw))::uuid;
    v_pb := pg_temp.vr_cs(format($q$select public.assess_start(%L)::text$q$, v_emp_pick))::uuid;

    -- assess_draw
    delete from public.drawn where question_id = qc1;
    delete from public.category_last where category = 'ZZ選C';
    if i = 2 then insert into public.drawn (question_id) values (qc1); end if;
    v_ret := pg_temp.vr_cs(format($q$select string_agg(r.repeated::text || '/' || r.new_round::text, ',')
                                       from public.assess_draw(%L::uuid, array['ZZ選C']) r$q$, v_pa));
    v_s1 := pg_temp.vr_sig(v_pa, 'ZZ選C', v_ret);

    -- assess_pick
    delete from public.drawn where question_id = qc1;
    delete from public.category_last where category = 'ZZ選C';
    if i = 2 then insert into public.drawn (question_id) values (qc1); end if;
    v_ret := pg_temp.vr_cs(format($q$select string_agg(r.repeated::text || '/' || r.new_round::text, ',')
                                       from public.assess_pick(%L::uuid, array[%s]::bigint[]) r$q$, v_pb, qc1));
    v_s2 := pg_temp.vr_sig(v_pb, 'ZZ選C', v_ret);

    perform pg_temp.vr_eq('5 與抽題一致', '情境 ' || i || '：assess_pick 與 assess_draw 寫入後指紋相同（題組、機密、drawn、category_last、回傳旗標）',
      v_s1, v_s2);
    perform pg_temp.vr_rec('5 與抽題一致', '情境 ' || i || '：兩邊都成功執行（不是兩個錯誤訊息剛好相同）', '無 ERROR',
      v_s1 || ' ／ ' || v_s2, v_s1 not like '%ERROR%' and v_s2 not like '%ERROR%');
    perform pg_temp.vr_eq('5 與抽題一致', '情境 ' || i || '：repeated／new_round 符合預期',
      case i when 1 then 'false/false' when 2 then 'false/true' else 'true/false' end,
      split_part(v_s2, '#', 1));
  end loop;

  -- ---------- 與 assess_draw 混用：先 pick、再 draw、再 pick ----------
  perform pg_temp.vr_eq('5 混用', 'pick 之後同一張草稿可以接著 assess_draw 抽別的分類（D）', 'ZZ選D',
    pg_temp.vr_cs(format($q$select string_agg(r.category, ',') from public.assess_draw(%L::uuid, array['ZZ選D']) r$q$, v_d1)));
  perform pg_temp.vr_eq('5 混用', 'draw 之後 seq 接在 pick 後面（A、B、D → 第 3 題）', '3',
    pg_temp.vr_q1(format('select max(seq)::text from public.assessment_items where assessment_id = %L::uuid', v_d1)));
  perform pg_temp.vr_csdeny('5 混用', 'assess_draw 對 pick 過的分類（A）仍被擋（每個分類最多一個題組）',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['ZZ選A'])$q$, v_d1), '%已抽過%');
  delete from public.drawn where question_id = qc1;
  delete from public.category_last where category = 'ZZ選C';
  perform pg_temp.vr_eq('5 混用', 'draw 之後再 pick（C1）：成功', 'ZZ選C:C1:false:false',
    pg_temp.vr_cs(format(v_str, v_d1, qc1::text)));
  perform pg_temp.vr_eq('5 混用', '混用後四題依序：A、B、D、C（seq 1～4）', 'ZZ選A,ZZ選B,ZZ選D,ZZ選C',
    pg_temp.vr_q1(format($q$select string_agg(i.category, ',' order by i.seq)
                              from public.assessment_items i where i.assessment_id = %L::uuid$q$, v_d1)));

  -- ---------- 被拒 ----------
  -- 別人的草稿
  perform pg_temp.vr_csdeny('5 被拒', '只能對自己的草稿：對另一位客服部的草稿被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_d1b, qa2), '%只有建立者本人%');
  perform pg_temp.vr_eq('5 被拒', '被拒後：別人的草稿沒被塞進題組', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.assessment_items where assessment_id = %L::uuid', v_d1b)));
  -- 已送出、已作廢
  v_sub  := pg_temp.vr_mkrep('MI-9846', 'submitted', now() - interval '1 day', '[{}]'::jsonb, null, 'vr-cs@2motor.tw');
  v_void := pg_temp.vr_mkrep('MI-9847', 'voided',    now() - interval '1 day', '[{}]'::jsonb, null, 'vr-cs@2motor.tw');
  perform pg_temp.vr_csdeny('5 被拒', '已送出的考核被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_sub, qa2), '%只有草稿%');
  perform pg_temp.vr_csdeny('5 被拒', '已作廢的考核被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_void, qa2), '%只有草稿%');
  perform pg_temp.vr_csdeny('5 被拒', '考核不存在被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, '00000000-0000-0000-0000-000000000000', qa2),
    '%找不到考核%');

  -- 題組清單不合規（都對乾淨的草稿 v_d5 操作）
  perform pg_temp.vr_csdeny('5 被拒', '題組不存在被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_d5,
           (select coalesce(max(id), 0) + 100000 from public.questions)),
    '%題組不存在%');
  perform pg_temp.vr_csdeny('5 被拒', '一批裡有一題不存在：整批被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s, %s]::bigint[])$q$, v_d5, qa2,
           (select coalesce(max(id), 0) + 100000 from public.questions)),
    '%題組不存在%');
  perform pg_temp.vr_eq('5 被拒', '整批被拒後：沒有寫入任何題組，A2 也沒被標成已抽（交易整批回復）', '0/0',
    pg_temp.vr_q1(format($q$select (select count(*) from public.assessment_items where assessment_id = %L::uuid)::text
                                   || '/' || (select count(*) from public.drawn where question_id = %s)::text$q$, v_d5, qa2)));
  perform pg_temp.vr_csdeny('5 被拒', '題組編號重複被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s, %s]::bigint[])$q$, v_d5, qa2, qa2), '%題組不可重複選取%');
  perform pg_temp.vr_csdeny('5 被拒', '空陣列被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[]::bigint[])$q$, v_d5), '%請至少選一個題組%');
  perform pg_temp.vr_csdeny('5 被拒', 'null 陣列被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, null::bigint[])$q$, v_d5), '%請至少選一個題組%');
  perform pg_temp.vr_csdeny('5 被拒', '陣列含 null 被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s, null]::bigint[])$q$, v_d5, qa2), '%題組編號不可空白%');
  perform pg_temp.vr_csdeny('5 被拒', '一批裡有兩題同分類（A2、A3）被拒（上限：每個分類最多一個題組）',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s, %s]::bigint[])$q$, v_d5, qa2, qa3), '%分類不可重複%');
  -- 這場考核已經有的題組／分類（v_d1 內已有 A1）
  perform pg_temp.vr_csdeny('5 被拒', '選這場已經有的題組（A1）被拒',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_d1, qa1), '%已在這場考核內%');
  perform pg_temp.vr_csdeny('5 被拒', '選這場已有分類的另一題（A2；A 分類已有 A1）被拒（每個分類最多一個題組）',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_d1, qa2), '%已抽過%最多一個題組%');
  perform pg_temp.vr_eq('5 被拒', '全部被拒之後：乾淨草稿仍是 0 題，A2 仍不在 drawn', '0/0',
    pg_temp.vr_q1(format($q$select (select count(*) from public.assessment_items where assessment_id = %L::uuid)::text
                                   || '/' || (select count(*) from public.drawn where question_id = %s)::text$q$, v_d5, qa2)));

  -- ---------- 選題後走完整流程：評分、送出，再看建議題庫與弱項 ----------
  declare
    qfa bigint; qfb bigint; v_d6 uuid; v_it record; v_cnt text;
  begin
    qfa := pg_temp.vr_mkq('ZZ流A', 'FA1');
    qfb := pg_temp.vr_mkq('ZZ流B', 'FB1');
    v_d6 := pg_temp.vr_cs($q$select public.assess_start('MI-9844')::text$q$)::uuid;
    perform pg_temp.vr_eq('5 完整流程', '選 FA1、FB1',
      'ZZ流A:FA1:false:false,ZZ流B:FB1:false:false',
      pg_temp.vr_cs(format(v_str, v_d6, qfa || ',' || qfb)));
    for v_it in select it.id, it.seq from public.assessment_items it where it.assessment_id = v_d6 order by it.seq loop
      perform pg_temp.vr_csok('5 完整流程', '第 ' || v_it.seq || ' 題暫存評分（assess_save_item 對 pick 出來的題組正常）',
        format($q$select public.assess_save_item(%L::uuid, %L::jsonb, null)$q$, v_it.id,
               case v_it.seq
                 when 1 then '{"資訊正確性":"優","預設訊息運用":"優","問題掌握":"優","主動引導":"不及格","風險意識":"優","語氣與禮貌":"優","文字品質":"優"}'
                 else        '{"資訊正確性":"優","預設訊息運用":"優","問題掌握":"待加強","主動引導":"優","風險意識":"優","語氣與禮貌":"優","文字品質":"優"}'
               end));
    end loop;
    v_cnt := pg_temp.vr_cs(format($q$select item_count::text from public.assess_submit(%L::uuid)$q$, v_d6));
    perform pg_temp.vr_eq('5 完整流程', 'assess_submit 送出：2 個題組', '2', v_cnt);
    perform pg_temp.vr_eq('5 完整流程', '送出後建議題庫：FA1、FB1 對 MI-9844 的 taken_before 皆為 Y', 'Y,Y',
      pg_temp.vr_cs($q$select string_agg(case when p.taken_before then 'Y' else 'N' end, ',' order by p.question_id)
                         from public.assess_suggest_pool('MI-9844') p where p.title in ('假題組FA1', '假題組FB1')$q$));
    perform pg_temp.vr_eq('5 完整流程', '送出後弱項：n = 1', '1',
      pg_temp.vr_cs($q$select (public.assess_weak_profile('MI-9844') ->> 'n')$q$));
    perform pg_temp.vr_eq('5 完整流程', '送出後弱項：主動引導 50、問題掌握 70 最低', '主動引導:50,問題掌握:70',
      pg_temp.vr_cs($q$select string_agg((t.w ->> 'dim') || ':' || (t.w ->> 'pct'), ',' order by t.ord)
                         from jsonb_array_elements(public.assess_weak_profile('MI-9844') -> 'weak') with ordinality as t(w, ord)$q$));
  end;

  -- ---------- 既有 assess_draw 行為不變：跑一次既有流程 ----------
  declare
    qe1 bigint; qe2 bigint; qe3 bigint; qf1 bigint; v_d7 uuid;
  begin
    qe1 := pg_temp.vr_mkq('ZZ抽E', 'E1');
    qe2 := pg_temp.vr_mkq('ZZ抽E', 'E2');
    qe3 := pg_temp.vr_mkq('ZZ抽E', 'E3');
    qf1 := pg_temp.vr_mkq('ZZ抽F', 'F1');
    -- 考生以前考過 E1、E2 → 抽 E 應避開，只剩 E3
    perform pg_temp.vr_mkrep('MI-9843', 'submitted', now() - interval '3 days', '[{},{}]'::jsonb, array[qe1, qe2]);
    v_d7 := pg_temp.vr_cs($q$select public.assess_start('MI-9843')::text$q$)::uuid;
    perform pg_temp.vr_eq('5 既有抽題', 'assess_draw 照舊：避開考過的題（E1、E2），抽 E3 與 F1，repeated／new_round 皆 false',
      'ZZ抽E:E3:false:false,ZZ抽F:F1:false:false',
      pg_temp.vr_cs(format($q$select string_agg(r.category || ':' || r.code || ':' || r.repeated::text || ':' || r.new_round::text, ',' order by r.n)
                               from public.assess_draw(%L::uuid, array['ZZ抽E','ZZ抽F'])
                                    with ordinality as r(item_id, category, code, title, steps, repeated, new_round, n)$q$, v_d7)));
    perform pg_temp.vr_eq('5 既有抽題', 'assess_draw 照舊：題組與機密寫入（seq、題號、was_drawn_before）',
      format('%s:false:假題組E3,%s:false:假題組F1', qe3, qf1), pg_temp.vr_q1(format(v_sec, v_d7)));
    perform pg_temp.vr_eq('5 既有抽題', 'assess_draw 照舊：drawn 只多了 E3、F1', format('%s,%s', qe3, qf1),
      pg_temp.vr_q1(format($q$select string_agg(question_id::text, ',' order by question_id) from public.drawn
                               where question_id in (%s, %s, %s, %s)$q$, qe1, qe2, qe3, qf1)));
    perform pg_temp.vr_eq('5 既有抽題', 'assess_draw 照舊：category_last 更新', format('ZZ抽E:%s,ZZ抽F:%s', qe3, qf1),
      pg_temp.vr_q1($q$select string_agg(l.category || ':' || l.question_id::text, ',' order by l.category)
                         from public.category_last l where l.category in ('ZZ抽E', 'ZZ抽F')$q$));
    perform pg_temp.vr_csok('5 既有抽題', 'assess_abandon 照舊：放棄草稿', format($q$select public.assess_abandon(%L::uuid)::text$q$, v_d7));
    perform pg_temp.vr_eq('5 既有抽題', 'assess_abandon 照舊：本來不在 drawn 的 E3、F1 回到題池、草稿消失', '0/0',
      pg_temp.vr_q1(format($q$select (select count(*) from public.drawn where question_id in (%s, %s))::text
                                     || '/' || (select count(*) from public.assessments where id = %L::uuid)::text$q$,
                           qe3, qf1, v_d7)));
  end;
exception when others then
  perform pg_temp.vr_rec('區段 5','assess_pick 測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：既有資料與函式沒有被改動
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.vr_eq('6 既有未改動', '既有函式（四個新函式以外）的定義沒變', pg_temp.vr_get('fn_md5'),
    (select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid))
       from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
        and p.proname not in ('bank_set_dims', 'assess_weak_profile', 'assess_suggest_pool', 'assess_pick')));
  perform pg_temp.vr_eq('6 既有未改動', 'assess_draw 簽名沒變', 'p_assessment_id uuid, p_cats text[]',
    pg_temp.vr_q1($q$select pg_get_function_arguments('public.assess_draw(uuid, text[])'::regprocedure)$q$));
  perform pg_temp.vr_eq('6 既有未改動', '真實題目筆數沒變', pg_temp.vr_get('real_questions'),
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_eq('6 既有未改動', '真實題目的已抽記錄 drawn 沒變（若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_drawn'),
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_eq('6 既有未改動', '真實分類的 category_last 沒變（若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_last'),
    (select count(*)::text from public.category_last where category not like 'ZZ%'));
exception when others then
  perform pg_temp.vr_rec('區段 6','既有未改動比對意外中斷','無例外', sqlerrm, false);
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
begin
  select count(*), count(*) filter (where pass) into v_total, v_ok from pg_temp.vr;
  -- 未通過的序號（最多列 20 個），免得在上百列裡找失敗項
  select string_agg('#' || f.n, '、' order by f.n) into v_fail
  from (select n from pg_temp.vr where not pass order by n limit 20) f;
  select string_agg(
           format('(%s, %L, %L, %L, %L)',
                  n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vr;

  begin
    execute 'deallocate weak_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare weak_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_fail is not null then '；未通過：' || v_fail else '' end) || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate weak_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare weak_vr_out as select '
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
execute weak_vr_out;
