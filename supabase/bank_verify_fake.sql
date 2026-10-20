-- ============================================================
-- 業務考核系統：題庫管理（bank_*）驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 bank_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw，符合 accounts 網域檢查）／假題庫，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。
--   為了測「全部洗牌」，腳本會先把真實的 drawn、category_last 備份到暫存表，洗完再還原，
--   最後比對筆數；整份都在交易內，rollback 後真實題庫與已抽記錄原封不動（備份與還原只是讓筆數比對更乾淨）。
--   ⚠️ 第一次執行請選在沒人抽題的時段（腳本執行期間有人抽題，區段 10 的筆數比對可能誤報）。
--   「停用舊抽選器」那段（收回 anon 的 execute，再還原）也是在交易內執行，一併 rollback。
-- 怎麼看結果：
--   * 因為 SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     腳本在 rollback 之前把結果表存成「預備陳述式 bank_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- 假門市代碼 ZZ-K1、假員工編號 MI-9801、假信箱 vr-cs／vr-hq／vr-sm@2motor.tw、
--   假分類一律以 ZZ 開頭；若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 注意：假題庫的 questions.id 會用掉幾個流水號（序號不會因 rollback 倒退），無害。
--   列表測試只看 ZZ 開頭的分類，所以真實題庫存在也不影響結果。
-- 區段 9 的 revoke／grant 語句與 bank_retire_legacy.sql 相同；兩邊若要修改必須同步。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯停下（rollback 後無影響），不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regprocedure('public.bank_list_questions()') is null
     or to_regprocedure('public.bank_save_question(bigint, text, text, text, jsonb)') is null
     or to_regprocedure('public.bank_delete_question(bigint)') is null
     or to_regprocedure('public.bank_rename_category(text, text)') is null
     or to_regprocedure('public.bank_reset(text)') is null then
    raise exception '請先執行 bank_schema.sql';
  end if;
  if to_regprocedure('public.assess_categories()') is null
     or to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_draw(uuid, text[])') is null then
    raise exception '請先執行 assess_schema.sql';
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

-- 真實 drawn／category_last 的備份（測「全部洗牌」用，洗完會還原）
create temp table vr_bk_drawn as select question_id, drawn_at from public.drawn;
create temp table vr_bk_last as select category, question_id from public.category_last;

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

-- 客服部身分的捷徑
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

-- 以擁有者身分直接造一題假題組，回傳 id（steps 固定一個步驟）
create or replace function pg_temp.vr_mkq(p_cat text, p_code text)
returns bigint language plpgsql as $$
declare
  v_id bigint;
begin
  insert into public.questions (category, code, title, steps)
  values (p_cat, p_code, '假題組' || p_code,
          '[{"action":"動作","point":"考點"}]'::jsonb)
  returning id into v_id;
  return v_id;
end $$;

-- ============================================================
-- 建立假資料與基準（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  -- 先記下既有物件的基準，最後比對有沒有被動到（bank_ 函式不算）
  perform pg_temp.vr_set('fn_md5',
    (select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid))
       from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname not like 'bank\_%'));
  perform pg_temp.vr_set('col_md5',
    (select md5(string_agg(c.table_name || '.' || c.column_name || ':' || c.data_type || ':'
                           || coalesce(c.column_default, '') || ':' || c.is_nullable, ','
                           order by c.table_name, c.ordinal_position))
       from information_schema.columns c where c.table_schema = 'public'));
  perform pg_temp.vr_set('pol_md5',
    (select coalesce(md5(string_agg(schemaname || '.' || tablename || '.' || policyname || ':'
                                    || coalesce(qual, '') || ':' || coalesce(with_check, ''), ','
                                    order by schemaname, tablename, policyname)), '')
       from pg_policies where schemaname in ('public', 'storage')));
  perform pg_temp.vr_set('trg_cnt',
    (select count(*)::text from pg_trigger t
      where not t.tgisinternal and t.tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace)));
  perform pg_temp.vr_set('acl_md5',
    (select md5(string_agg(c.relname || ':' || coalesce(c.relacl::text, ''), ',' order by c.relname))
       from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'S')));
  perform pg_temp.vr_set('real_questions',
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_set('real_drawn',
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_set('real_last',
    (select count(*)::text from public.category_last where category not like 'ZZ%'));
  perform pg_temp.vr_set('secret_cnt', (select count(*)::text from public.app_secret));

  insert into public.stores (code, name) values ('ZZ-K1', 'ZZ測試門市K');

  insert into public.employees (id, nickname, store_code, job_title, status, include_in_assessment) values
    ('MI-9801', '假考生9801', 'ZZ-K1', '業務', '在職', true);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw', 'hq_viewer',     null),
    ('vr-sm@2motor.tw', 'store_manager', 'ZZ-K1');
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：權限（主管、店長、無帳號、沒登入者、anon 一律被拒；被拒後資料沒被動到）
-- ============================================================
do $$
declare
  f record;
  w record;
  q1 bigint; q2 bigint;
begin
  perform set_config('request.jwt.claims', '', true);

  q1 := pg_temp.vr_mkq('ZZ庫權', 'P1');
  q2 := pg_temp.vr_mkq('ZZ庫權', 'P2');
  insert into public.drawn (question_id) values (q1);
  insert into public.category_last (category, question_id) values ('ZZ庫權', q1);
  perform pg_temp.vr_set('perm_q', q1::text);

  for f in
    select * from (values
      ('bank_list_questions',   $q$select count(*)::text from public.bank_list_questions()$q$),
      ('bank_save_question',    $q$select public.bank_save_question(null, 'ZZ庫權', 'X1', 'ZZ越權', '[{"action":"a","point":"b"}]'::jsonb)::text$q$),
      ('bank_delete_question',  format($q$select public.bank_delete_question(%s)$q$, q1)),
      ('bank_rename_category',  $q$select public.bank_rename_category('ZZ庫權', 'ZZ庫被改')::text$q$),
      ('bank_reset',            $q$select public.bank_reset('ZZ庫權')$q$)
    ) as t(fn, stmt)
  loop
    for w in
      select * from (values
        ('總公司主管', 'authenticated', 'vr-hq@2motor.tw',   '%沒有權限%'),
        ('店長',       'authenticated', 'vr-sm@2motor.tw',   '%沒有權限%'),
        ('無帳號',     'authenticated', 'vr-none@2motor.tw', '%沒有權限%'),
        ('沒有登入者（authenticated 但 JWT 空）', 'authenticated', null::text, '%沒有權限%'),
        ('anon',       'anon',          null::text,          '%permission denied%')
      ) as r(label, rol, email, pat)
    loop
      perform pg_temp.vr_deny('1 權限', w.label || ' 呼叫 ' || f.fn, w.rol, w.email, f.stmt, w.pat);
    end loop;
  end loop;

  -- 被拒絕之後，資料必須完全沒被動到
  perform pg_temp.vr_eq('1 權限', '被拒後：沒有任何「ZZ越權」題組被新增', '0',
    pg_temp.vr_q1($q$select count(*)::text from public.questions where title = 'ZZ越權'$q$));
  perform pg_temp.vr_eq('1 權限', '被拒後：「ZZ庫權」分類仍是 2 題（沒被刪、沒被改名）', '2',
    pg_temp.vr_q1($q$select count(*)::text from public.questions where category = 'ZZ庫權'$q$));
  perform pg_temp.vr_eq('1 權限', '被拒後：已抽記錄與最近一題記錄仍在（沒被洗牌）', '1/1',
    pg_temp.vr_q1($q$select (select count(*) from public.drawn where question_id in
                              (select id from public.questions where category = 'ZZ庫權'))::text
                           || '/' || (select count(*) from public.category_last where category = 'ZZ庫權')::text$q$));
exception when others then
  perform pg_temp.vr_rec('區段 1','權限測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：列表（欄位、排序、drawn 旗標）
-- ============================================================
do $$
declare
  k1 bigint; l1 bigint; k2 bigint; l2 bigint; m1 bigint; k3 bigint;
begin
  perform set_config('request.jwt.claims', '', true);

  -- 故意交錯新增：分類第一次出現順序＝甲、乙、丙
  k1 := pg_temp.vr_mkq('ZZ序甲', 'K1');
  l1 := pg_temp.vr_mkq('ZZ序乙', 'L1');
  k2 := pg_temp.vr_mkq('ZZ序甲', 'K2');
  l2 := pg_temp.vr_mkq('ZZ序乙', 'L2');
  m1 := pg_temp.vr_mkq('ZZ序丙', 'M1');
  k3 := pg_temp.vr_mkq('ZZ序甲', 'K3');
  insert into public.drawn (question_id) values (k2), (l1);

  perform pg_temp.vr_eq('2 列表', '回傳欄位與型別（id、category、code、title、steps、drawn）',
    'TABLE(id bigint, category text, code text, title text, steps jsonb, drawn boolean)',
    pg_temp.vr_q1($q$select pg_get_function_result('public.bank_list_questions()'::regprocedure)$q$));

  perform pg_temp.vr_eq('2 列表', '客服部：依分類第一次出現順序、再依 id 排序，drawn 旗標正確',
    'K1:N,K2:Y,K3:N,L1:Y,L2:N,M1:N',
    pg_temp.vr_cs($q$
      select string_agg(t.code || ':' || case when t.drawn then 'Y' else 'N' end, ',' order by t.n)
      from public.bank_list_questions() with ordinality as t(id, category, code, title, steps, drawn, n)
      where t.category like 'ZZ序%'$q$));

  perform pg_temp.vr_eq('2 列表', '客服部：能讀到題組名稱與步驟（含考點）', '6',
    pg_temp.vr_cs($q$
      select count(*)::text from public.bank_list_questions() t
      where t.category like 'ZZ序%' and t.title like '假題組%'
        and t.steps = '[{"action":"動作","point":"考點"}]'::jsonb$q$));
exception when others then
  perform pg_temp.vr_rec('區段 2','列表測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：儲存（新增、編輯、改分類、各欄位驗證）
-- ============================================================
do $$
declare
  v_id text;
  v_idn bigint;
  r record;
  v_save text := $q$select public.bank_save_question(%s, %L, %L, %L, %L::jsonb)::text$q$;
begin
  perform set_config('request.jwt.claims', '', true);

  -- 新增：去空白、空白代號變 null、只保留 action／point、缺 point 補空字串
  v_id := pg_temp.vr_cs(format(v_save, 'null', '  ZZ存新  ', '   ', '  新題名  ',
    '[{"action":"  動作一  ","point":"  考點一  ","extra":"x"},{"action":"動作二"}]'));
  perform pg_temp.vr_rec('3 儲存', '新增：回傳新題組 id（數字）', '數字', v_id, v_id ~ '^[0-9]+$');
  v_idn := case when v_id ~ '^[0-9]+$' then v_id::bigint end;
  perform pg_temp.vr_eq('3 儲存', '新增：分類、代號、名稱已去空白（空白代號存成 null）', 'ZZ存新|(null)|新題名',
    pg_temp.vr_q1(format($q$select category || '|' || coalesce(code, '(null)') || '|' || title
                            from public.questions where id = %s$q$, v_idn)));
  perform pg_temp.vr_eq('3 儲存', '新增：steps 只保留 action、point 並去空白，缺的 point 補空字串', 'true',
    pg_temp.vr_q1(format($q$select (steps = '[{"action":"動作一","point":"考點一"},{"action":"動作二","point":""}]'::jsonb)::text
                            from public.questions where id = %s$q$, v_idn)));
  perform pg_temp.vr_eq('3 儲存', '新增：新題不在已抽記錄內', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.drawn where question_id = %s', v_idn)));

  -- 編輯（分類不變）：欄位更新、已抽記錄保留
  insert into public.drawn (question_id) values (v_idn);
  v_id := pg_temp.vr_cs(format(v_save, v_idn, 'ZZ存新', '  B2  ', '改名後',
    '[{"action":"新動作","point":"新考點"}]'));
  perform pg_temp.vr_eq('3 儲存', '編輯：回傳原 id', v_idn::text, v_id);
  perform pg_temp.vr_eq('3 儲存', '編輯：欄位已更新', 'ZZ存新|B2|改名後',
    pg_temp.vr_q1(format($q$select category || '|' || coalesce(code, '(null)') || '|' || title
                            from public.questions where id = %s$q$, v_idn)));
  perform pg_temp.vr_eq('3 儲存', '編輯（分類不變）：已抽記錄保留', '1',
    pg_temp.vr_q1(format('select count(*)::text from public.drawn where question_id = %s', v_idn)));

  -- 編輯（改分類）：已抽記錄被移除
  v_id := pg_temp.vr_cs(format(v_save, v_idn, 'ZZ存新2', 'B2', '改名後',
    '[{"action":"新動作","point":"新考點"}]'));
  perform pg_temp.vr_eq('3 儲存', '編輯（改分類）：回傳原 id', v_idn::text, v_id);
  perform pg_temp.vr_eq('3 儲存', '編輯（改分類）：分類已改', 'ZZ存新2',
    pg_temp.vr_q1(format('select category from public.questions where id = %s', v_idn)));
  perform pg_temp.vr_eq('3 儲存', '編輯（改分類）：已抽記錄被移除', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.drawn where question_id = %s', v_idn)));

  perform pg_temp.vr_csdeny('3 儲存', '編輯不存在的題目被拒',
    format(v_save, '999999999', 'ZZ庫拒', 'A', 'ZZ拒絕', '[{"action":"a","point":"b"}]'), '%找不到題目%');

  -- 邊界值：剛好上限可以存
  perform pg_temp.vr_csok('3 儲存', '名稱剛好 100 字、代號剛好 10 字可儲存',
    format(v_save, 'null', 'ZZ庫邊', 'ABCDEFGHIJ', repeat('題', 100), '[{"action":"a","point":"b"}]'));
  perform pg_temp.vr_csok('3 儲存', '剛好 30 個步驟可儲存',
    format(v_save, 'null', 'ZZ庫邊', 'S30',  '三十步',
      (select jsonb_agg(jsonb_build_object('action', '動作' || g, 'point', '考點'))::text from generate_series(1, 30) g)));
  perform pg_temp.vr_csok('3 儲存', 'action、point 剛好 500 字可儲存',
    format(v_save, 'null', 'ZZ庫邊', 'L500', '長步驟',
      json_build_array(json_build_object('action', repeat('甲', 500), 'point', repeat('乙', 500)))::text));
  perform pg_temp.vr_csok('3 儲存', 'point 為 null 可儲存（存成空字串）',
    format(v_save, 'null', 'ZZ庫邊', 'PN', '點為空', '[{"action":"a","point":null}]'));
  perform pg_temp.vr_eq('3 儲存', 'point 為 null：stored 為空字串', 'true',
    pg_temp.vr_q1($q$select (steps = '[{"action":"a","point":""}]'::jsonb)::text
                     from public.questions where code = 'PN' and category = 'ZZ庫邊'$q$));

  -- 各欄位驗證：全部必須被拒，訊息與舊函式一致
  for r in
    select * from (values
      ('分類空白',               '   ',            'A1',          '標',       '[{"action":"a","point":"b"}]', '%分類不可空白%'),
      ('分類 null',              null::text,       'A1',          '標',       '[{"action":"a","point":"b"}]', '%分類不可空白%'),
      ('題組名稱空白',           'ZZ庫拒',         'A1',          '   ',      '[{"action":"a","point":"b"}]', '%題組名稱不可空白%'),
      ('題組名稱 null',          'ZZ庫拒',         'A1',          null::text, '[{"action":"a","point":"b"}]', '%題組名稱不可空白%'),
      ('題組名稱 101 字',        'ZZ庫拒',         'A1',          repeat('題', 101), '[{"action":"a","point":"b"}]', '%題組名稱太長%'),
      ('代號 11 字',             'ZZ庫拒',         'ABCDEFGHIJK', 'ZZ拒絕',   '[{"action":"a","point":"b"}]', '%代號太長%'),
      ('步驟為 null',            'ZZ庫拒',         'A1',          'ZZ拒絕',   null::text,                      '%步驟格式不正確%'),
      ('步驟是物件不是清單',     'ZZ庫拒',         'A1',          'ZZ拒絕',   '{"action":"a"}',                '%步驟格式不正確%'),
      ('步驟是字串不是清單',     'ZZ庫拒',         'A1',          'ZZ拒絕',   '"abc"',                         '%步驟格式不正確%'),
      ('步驟 0 個',              'ZZ庫拒',         'A1',          'ZZ拒絕',   '[]',                            '%至少要有 1 個步驟%'),
      ('步驟 31 個',             'ZZ庫拒',         'A1',          'ZZ拒絕',
         (select jsonb_agg(jsonb_build_object('action', '動作' || g, 'point', '考點'))::text from generate_series(1, 31) g),
         '%步驟太多%'),
      ('步驟不是物件',           'ZZ庫拒',         'A1',          'ZZ拒絕',   '["abc"]',                       '%每個步驟都要有%'),
      ('步驟 action 空白',       'ZZ庫拒',         'A1',          'ZZ拒絕',   '[{"action":"   ","point":"b"}]', '%每個步驟都要有%'),
      ('步驟缺 action',          'ZZ庫拒',         'A1',          'ZZ拒絕',   '[{"point":"b"}]',               '%每個步驟都要有%'),
      ('步驟 action 不是文字',   'ZZ庫拒',         'A1',          'ZZ拒絕',   '[{"action":5,"point":"b"}]',    '%每個步驟都要有%'),
      ('步驟 point 不是文字',    'ZZ庫拒',         'A1',          'ZZ拒絕',   '[{"action":"a","point":5}]',    '%每個步驟都要有%'),
      ('第二個步驟 action 空白', 'ZZ庫拒',         'A1',          'ZZ拒絕',   '[{"action":"a"},{"action":""}]', '%每個步驟都要有%'),
      ('action 501 字',          'ZZ庫拒',         'A1',          'ZZ拒絕',
         json_build_array(json_build_object('action', repeat('甲', 501), 'point', 'b'))::text, '%步驟文字太長%'),
      ('point 501 字',           'ZZ庫拒',         'A1',          'ZZ拒絕',
         json_build_array(json_build_object('action', 'a', 'point', repeat('乙', 501)))::text, '%步驟文字太長%')
    ) as t(nm, cat, code, title, steps, pat)
  loop
    perform pg_temp.vr_csdeny('3 儲存', '被拒：' || r.nm,
      format($q$select public.bank_save_question(null, %L, %L, %L, %L::jsonb)$q$, r.cat, r.code, r.title, r.steps),
      r.pat);
  end loop;

  perform pg_temp.vr_eq('3 儲存', '被拒的儲存都沒有留下任何資料', '0',
    pg_temp.vr_q1($q$select count(*)::text from public.questions
                      where title = 'ZZ拒絕' or category = 'ZZ庫拒'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 3','儲存測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：刪除
-- ============================================================
do $$
declare
  d1 bigint; d2 bigint;
begin
  perform set_config('request.jwt.claims', '', true);

  d1 := pg_temp.vr_mkq('ZZ刪', 'D1');
  d2 := pg_temp.vr_mkq('ZZ刪', 'D2');
  insert into public.drawn (question_id) values (d1), (d2);

  perform pg_temp.vr_csok('4 刪除', '客服部刪除題組成功', format('select public.bank_delete_question(%s)', d1));
  perform pg_temp.vr_eq('4 刪除', '該題已不存在', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.questions where id = %s', d1)));
  perform pg_temp.vr_eq('4 刪除', '該題的已抽記錄一併清除', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.drawn where question_id = %s', d1)));
  perform pg_temp.vr_eq('4 刪除', '同分類其他題不受影響（題與其已抽記錄都在）', '1/1',
    pg_temp.vr_q1(format($q$select (select count(*) from public.questions where category = 'ZZ刪')::text
                                   || '/' || (select count(*) from public.drawn where question_id = %s)::text$q$, d2)));
  perform pg_temp.vr_csok('4 刪除', '刪除不存在的題不報錯（同舊函式）', 'select public.bank_delete_question(999999999)');
  perform pg_temp.vr_csok('4 刪除', '刪除 null 不報錯（同舊函式）', 'select public.bank_delete_question(null)');
exception when others then
  perform pg_temp.vr_rec('區段 4','刪除測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：分類改名與合併
-- ============================================================
do $$
declare
  a1 bigint; a2 bigint; b1 bigint; c1 bigint;
begin
  perform set_config('request.jwt.claims', '', true);

  a1 := pg_temp.vr_mkq('ZZ改甲', 'R1');
  a2 := pg_temp.vr_mkq('ZZ改甲', 'R2');
  b1 := pg_temp.vr_mkq('ZZ改乙', 'R3');
  c1 := pg_temp.vr_mkq('ZZ改丙', 'R4');
  insert into public.drawn (question_id) values (a1);
  insert into public.category_last (category, question_id) values ('ZZ改甲', a1), ('ZZ改乙', b1);

  -- 合併：甲 → 乙
  perform pg_temp.vr_eq('5 改名', '改名成已存在的分類＝合併：回傳受影響題數 2', '2',
    pg_temp.vr_cs($q$select public.bank_rename_category('ZZ改甲', 'ZZ改乙')::text$q$));
  perform pg_temp.vr_eq('5 改名', '合併後：乙有 3 題、甲 0 題', '3/0',
    pg_temp.vr_q1($q$select (select count(*) from public.questions where category = 'ZZ改乙')::text
                            || '/' || (select count(*) from public.questions where category = 'ZZ改甲')::text$q$));
  perform pg_temp.vr_eq('5 改名', '合併後：舊分類（甲）的最近一題記錄被刪、乙的保留', '0/1',
    pg_temp.vr_q1($q$select (select count(*) from public.category_last where category = 'ZZ改甲')::text
                            || '/' || (select count(*) from public.category_last where category = 'ZZ改乙')::text$q$));
  perform pg_temp.vr_eq('5 改名', '合併後：已抽記錄跟著題目保留', '1',
    pg_temp.vr_q1(format('select count(*)::text from public.drawn where question_id = %s', a1)));

  -- 一般改名，新名稱去空白
  perform pg_temp.vr_eq('5 改名', '一般改名（新名稱前後空白去除）：回傳 1', '1',
    pg_temp.vr_cs($q$select public.bank_rename_category('ZZ改丙', '  ZZ改丁  ')::text$q$));
  perform pg_temp.vr_eq('5 改名', '改名後題目在新分類（已去空白）', '1',
    pg_temp.vr_q1(format($q$select count(*)::text from public.questions where id = %s and category = 'ZZ改丁'$q$, c1)));

  -- 新舊相同：不動 category_last
  perform pg_temp.vr_eq('5 改名', '新舊名稱相同：回傳該分類題數 3', '3',
    pg_temp.vr_cs($q$select public.bank_rename_category('ZZ改乙', ' ZZ改乙 ')::text$q$));
  perform pg_temp.vr_eq('5 改名', '新舊名稱相同：最近一題記錄不動', '1',
    pg_temp.vr_q1($q$select count(*)::text from public.category_last where category = 'ZZ改乙'$q$));

  -- 舊分類不存在
  perform pg_temp.vr_eq('5 改名', '舊分類不存在：回傳 0（同舊函式）', '0',
    pg_temp.vr_cs($q$select public.bank_rename_category('ZZ不存在的分類', 'ZZ改戊')::text$q$));

  perform pg_temp.vr_csdeny('5 改名', '新名稱空白被拒', $q$select public.bank_rename_category('ZZ改乙', '   ')$q$, '%新分類名稱不可空白%');
  perform pg_temp.vr_csdeny('5 改名', '新名稱 null 被拒', $q$select public.bank_rename_category('ZZ改乙', null)$q$, '%新分類名稱不可空白%');
  perform pg_temp.vr_eq('5 改名', '被拒後：乙仍是 3 題', '3',
    pg_temp.vr_q1($q$select count(*)::text from public.questions where category = 'ZZ改乙'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 5','改名測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：洗牌（單一分類與全部）
-- 全部洗牌會清掉真實的 drawn／category_last，所以先備份、測完立刻還原（都在交易內）
-- ============================================================
do $$
declare
  a1 bigint; a2 bigint; b1 bigint; b2 bigint;
begin
  perform set_config('request.jwt.claims', '', true);

  a1 := pg_temp.vr_mkq('ZZ洗A', 'W1');
  a2 := pg_temp.vr_mkq('ZZ洗A', 'W2');
  b1 := pg_temp.vr_mkq('ZZ洗B', 'W3');
  b2 := pg_temp.vr_mkq('ZZ洗B', 'W4');
  insert into public.drawn (question_id) values (a1), (a2), (b1), (b2);
  insert into public.category_last (category, question_id) values ('ZZ洗A', a2), ('ZZ洗B', b2);

  -- 單一分類
  perform pg_temp.vr_csok('6 洗牌', '洗牌單一分類（ZZ洗A）成功', $q$select public.bank_reset('ZZ洗A')$q$);
  perform pg_temp.vr_eq('6 洗牌', '單一分類：A 的已抽記錄清空、B 的保留', '0/2',
    pg_temp.vr_q1($q$select (select count(*) from public.drawn d join public.questions q on q.id = d.question_id
                              where q.category = 'ZZ洗A')::text
                            || '/' || (select count(*) from public.drawn d join public.questions q on q.id = d.question_id
                              where q.category = 'ZZ洗B')::text$q$));
  perform pg_temp.vr_eq('6 洗牌', '單一分類：A 的最近一題記錄清除、B 的保留', '0/1',
    pg_temp.vr_q1($q$select (select count(*) from public.category_last where category = 'ZZ洗A')::text
                            || '/' || (select count(*) from public.category_last where category = 'ZZ洗B')::text$q$));
  perform pg_temp.vr_eq('6 洗牌', '單一分類：不動題庫本身', '4',
    pg_temp.vr_q1($q$select count(*)::text from public.questions where category in ('ZZ洗A', 'ZZ洗B')$q$));

  -- 全部分類
  perform pg_temp.vr_csok('6 洗牌', '全部洗牌（p_category = null）成功', 'select public.bank_reset(null)');
  perform pg_temp.vr_eq('6 洗牌', '全部洗牌：drawn 與 category_last 全清空', '0/0',
    pg_temp.vr_q1($q$select (select count(*) from public.drawn)::text
                            || '/' || (select count(*) from public.category_last)::text$q$));
  perform pg_temp.vr_eq('6 洗牌', '全部洗牌：不動題庫本身（B 仍 2 題）', '2',
    pg_temp.vr_q1($q$select count(*)::text from public.questions where category = 'ZZ洗B'$q$));

  -- 還原真實資料（交易內），以免後面的「真實資料沒變」比對失真
  insert into public.drawn (question_id, drawn_at)
  select b.question_id, b.drawn_at from vr_bk_drawn b
  where exists (select 1 from public.questions q where q.id = b.question_id);
  insert into public.category_last (category, question_id)
  select b.category, b.question_id from vr_bk_last b;
exception when others then
  perform pg_temp.vr_rec('區段 6','洗牌測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：抽題（assess_draw）與洗牌（bank_reset）的互動、共用同一把鎖
-- ============================================================
do $$
declare
  v_aid text;
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.vr_mkq('ZZ抽A', 'T1');
  perform pg_temp.vr_mkq('ZZ抽A', 'T2');
  perform pg_temp.vr_mkq('ZZ抽A', 'T3');

  v_aid := pg_temp.vr_cs($q$select public.assess_start('MI-9801', '正式')::text$q$);
  perform pg_temp.vr_rec('7 抽題互動', '建立假考核草稿（assess_start）', 'uuid', v_aid,
    v_aid ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  perform pg_temp.vr_csok('7 抽題互動', '抽一題（assess_draw）成功',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['ZZ抽A'])$q$, v_aid));
  perform pg_temp.vr_eq('7 抽題互動', '抽題後：assess_categories 顯示 ZZ抽A 剩 2 題', '3/2',
    pg_temp.vr_cs($q$select total::text || '/' || remaining::text from public.assess_categories() where category = 'ZZ抽A'$q$));
  perform pg_temp.vr_eq('7 抽題互動', '抽題後：bank_list_questions 顯示 ZZ抽A 恰有 1 題 drawn', '1',
    pg_temp.vr_cs($q$select count(*)::text from public.bank_list_questions() t
                      where t.category = 'ZZ抽A' and t.drawn$q$));

  perform pg_temp.vr_csok('7 抽題互動', 'bank_reset 洗牌 ZZ抽A 成功', $q$select public.bank_reset('ZZ抽A')$q$);
  perform pg_temp.vr_eq('7 抽題互動', '洗牌後：assess_categories 顯示 ZZ抽A 剩餘回復為 3', '3/3',
    pg_temp.vr_cs($q$select total::text || '/' || remaining::text from public.assess_categories() where category = 'ZZ抽A'$q$));
  perform pg_temp.vr_eq('7 抽題互動', '洗牌後：bank_list_questions 顯示 ZZ抽A 沒有 drawn', '0',
    pg_temp.vr_cs($q$select count(*)::text from public.bank_list_questions() t
                      where t.category = 'ZZ抽A' and t.drawn$q$));
  perform pg_temp.vr_eq('7 抽題互動', '洗牌後：ZZ抽A 的最近一題記錄也清除', '0',
    pg_temp.vr_q1($q$select count(*)::text from public.category_last where category = 'ZZ抽A'$q$));

  -- 共用同一把 advisory lock（讀函式內容確認；實際互斥只能靠兩個連線同時操作，腳本做不到）
  perform pg_temp.vr_eq('7 抽題互動', '四個會寫入的 bank_ 函式都取同一把鎖（與 assess_draw 相同；列表純讀取不取鎖）', '4/true',
    pg_temp.vr_q1($q$select (select count(*) from pg_proc p
                              where p.pronamespace = 'public'::regnamespace
                                and p.proname in ('bank_save_question', 'bank_delete_question',
                                                  'bank_rename_category', 'bank_reset')
                                and p.prosrc like '%pg_advisory_xact_lock(hashtext(''exam_draw_questions''))%')::text
                            || '/' ||
                            (select (p.prosrc like '%pg_advisory_xact_lock(hashtext(''exam_draw_questions''))%')::text
                               from pg_proc p where p.oid = 'public.assess_draw(uuid, text[])'::regprocedure)$q$));
exception when others then
  perform pg_temp.vr_rec('區段 7','抽題互動測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 8：直接讀寫三張題庫表被拒；函式設定（security definer、search_path、權限）
-- ============================================================
do $$
declare
  t record;
  w record;
  v_q bigint := pg_temp.vr_get('perm_q')::bigint;
begin
  perform set_config('request.jwt.claims', '', true);

  for t in
    select * from (values
      ('questions',     $q$select count(*)::text from public.questions$q$,
                        $q$insert into public.questions (category, code, title, steps) values ('ZZ直寫', 'X', 'x', '[]'::jsonb)$q$,
                        $q$update public.questions set title = title$q$,
                        $q$delete from public.questions where false$q$),
      ('drawn',         $q$select count(*)::text from public.drawn$q$,
                        format($q$insert into public.drawn (question_id) values (%s)$q$, v_q),
                        $q$update public.drawn set drawn_at = now()$q$,
                        $q$delete from public.drawn where false$q$),
      ('category_last', $q$select count(*)::text from public.category_last$q$,
                        format($q$insert into public.category_last (category, question_id) values ('ZZ直寫', %s)$q$, v_q),
                        $q$update public.category_last set category = category$q$,
                        $q$delete from public.category_last where false$q$)
    ) as x(tbl, s_sel, s_ins, s_upd, s_del)
  loop
    for w in
      select * from (values
        ('客服部（已登入）', 'authenticated', 'vr-cs@2motor.tw'),
        ('anon',             'anon',          null::text)
      ) as r(label, rol, email)
    loop
      perform pg_temp.vr_deny('8 直接讀寫', w.label || ' 不能讀 ' || t.tbl, w.rol, w.email, t.s_sel, '%permission denied%');
      perform pg_temp.vr_deny('8 直接讀寫', w.label || ' 不能新增 ' || t.tbl, w.rol, w.email, t.s_ins, '%permission denied%');
      perform pg_temp.vr_deny('8 直接讀寫', w.label || ' 不能修改 ' || t.tbl, w.rol, w.email, t.s_upd, '%permission denied%');
      perform pg_temp.vr_deny('8 直接讀寫', w.label || ' 不能刪除 ' || t.tbl, w.rol, w.email, t.s_del, '%permission denied%');
    end loop;
  end loop;

  perform pg_temp.vr_eq('8 直接讀寫', '三張表：anon／authenticated 都沒有任何直接權限', 'false',
    (select bool_or(has_table_privilege(rl, tb, p))::text
       from (values ('anon'), ('authenticated')) as a(rl),
            (values ('public.questions'), ('public.drawn'), ('public.category_last')) as b(tb),
            (values ('select'), ('insert'), ('update'), ('delete')) as c(p)));
  perform pg_temp.vr_eq('8 直接讀寫', '三張表仍開 RLS、且沒有任何 policy', 'true,true,true/0',
    (select (select string_agg(relrowsecurity::text, ',' order by relname) from pg_class
              where oid in ('public.questions'::regclass, 'public.drawn'::regclass, 'public.category_last'::regclass))
            || '/' ||
            (select count(*)::text from pg_policies
              where schemaname = 'public' and tablename in ('questions', 'drawn', 'category_last'))));

  -- 函式設定：security definer、固定 search_path
  perform pg_temp.vr_eq('8 函式設定', '6 個 bank_ 函式都是 security definer 且有固定 search_path', '6',
    (select count(*)::text from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('bank_assert_cs', 'bank_list_questions', 'bank_save_question',
                          'bank_delete_question', 'bank_rename_category', 'bank_reset')
        and p.prosecdef
        and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')));
  -- 權限：PUBLIC 沒有、anon 沒有；authenticated 只有 5 個對外函式
  perform pg_temp.vr_eq('8 函式設定', '6 個 bank_ 函式：PUBLIC 與 anon 都沒有 execute', '0',
    (select count(*)::text from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('bank_assert_cs', 'bank_list_questions', 'bank_save_question',
                          'bank_delete_question', 'bank_rename_category', 'bank_reset')
        and (has_function_privilege('anon', p.oid, 'execute')
             or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                         where a.grantee = 0 and a.privilege_type = 'EXECUTE'))));
  perform pg_temp.vr_eq('8 函式設定', '5 個對外函式 authenticated 可執行；內部 bank_assert_cs 不可', '5/false',
    (select (select count(*) from pg_proc p
              where p.pronamespace = 'public'::regnamespace
                and p.proname in ('bank_list_questions', 'bank_save_question', 'bank_delete_question',
                                  'bank_rename_category', 'bank_reset')
                and has_function_privilege('authenticated', p.oid, 'execute'))::text
            || '/' ||
            has_function_privilege('authenticated', 'public.bank_assert_cs()', 'execute')::text));
exception when others then
  perform pg_temp.vr_rec('區段 8','直接讀寫／函式設定測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 9：停用舊抽選器（語句與 bank_retire_legacy.sql 相同；在交易內執行，最後一起 rollback）
-- ============================================================
do $$
declare
  v_pat text := '(_pw_ok|_assert_pw|list_categories|draw_questions|admin_(login|list_questions|save_question|delete_question|rename_category|reset))';
  v_sig text[] := array[
    'public.list_categories(text)',
    'public.draw_questions(text, text[])',
    'public.admin_login(text)',
    'public.admin_list_questions(text)',
    'public.admin_save_question(text, bigint, text, text, text, jsonb)',
    'public.admin_delete_question(text, bigint)',
    'public.admin_rename_category(text, text, text)',
    'public.admin_reset(text, text)'];
  v_calls text[] := array[
    $q$select count(*) from public.list_categories('vr-not-the-password')$q$,
    $q$select count(*) from public.draw_questions('vr-not-the-password', array['ZZ'])$q$,
    $q$select public.admin_login('vr-not-the-password')$q$,
    $q$select count(*) from public.admin_list_questions('vr-not-the-password')$q$,
    $q$select public.admin_save_question('vr-not-the-password', null, 'ZZ', 'x', 'x', '[]'::jsonb)$q$,
    $q$select public.admin_delete_question('vr-not-the-password', 0)$q$,
    $q$select public.admin_rename_category('vr-not-the-password', 'ZZ', 'ZZ2')$q$,
    $q$select public.admin_reset('vr-not-the-password', 'ZZ')$q$];
  v_names text := '''_pw_ok'', ''_assert_pw'', ''list_categories'', ''draw_questions'', ''admin_login'', ''admin_list_questions'', ''admin_save_question'', ''admin_delete_question'', ''admin_rename_category'', ''admin_reset''';
  i int;
  s text;
  v_r text;
  v_n int;
  v_ok int;
begin
  perform set_config('request.jwt.claims', '', true);

  -- ===== 實證：新系統沒有任何地方呼叫舊的密碼函式 =====
  perform pg_temp.vr_eq('9 停用舊抽選器', '實證：舊 10 個以外的 public 函式（含全部 assess_*、bank_*）內容都沒有引用舊函式', '0',
    pg_temp.vr_q1(format($q$select count(*)::text from pg_proc p
                             where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
                               and p.proname not in (%s) and p.prosrc ~* %L$q$, v_names, v_pat)));
  perform pg_temp.vr_eq('9 停用舊抽選器', '實證：policy（含 storage）與 public 檢視都沒有引用舊函式', '0',
    pg_temp.vr_q1(format($q$select ((select count(*) from pg_policies where schemaname in ('public', 'storage')
                                       and (coalesce(qual, '') ~* %L or coalesce(with_check, '') ~* %L))
                                  + (select count(*) from pg_views where schemaname = 'public' and definition ~* %L))::text$q$,
                         v_pat, v_pat, v_pat)));
  select count(*) into v_n from unnest(v_sig) x where to_regprocedure(x) is not null;
  perform pg_temp.vr_eq('9 停用舊抽選器', '8 個舊函式都存在（執行停用前的前提）', '8', v_n::text);

  -- 起始狀態（資訊，不判斷對錯）
  select count(*) into v_n from unnest(v_sig) x where has_function_privilege('anon', x, 'execute');
  perform pg_temp.vr_rec('9 停用舊抽選器', '起始狀態（資訊）：8 個舊函式中有幾個開放 anon 執行', '8（舊抽選器還在運作）；0 代表已經停用過',
    v_n::text, true);

  -- ===== 上半段：停用（與 bank_retire_legacy.sql 的 revoke 相同） =====
  for i in 1 .. array_length(v_sig, 1) loop
    execute 'revoke execute on function ' || v_sig[i] || ' from anon';
  end loop;

  select count(*) into v_n from unnest(v_sig) x where has_function_privilege('anon', x, 'execute');
  perform pg_temp.vr_eq('9 停用舊抽選器', '停用後：8 個舊函式 anon 都沒有 execute 權限', '0', v_n::text);

  for i in 1 .. array_length(v_calls, 1) loop
    v_r := pg_temp.vr_as('anon', null, v_calls[i], false);
    perform pg_temp.vr_rec('9 停用舊抽選器', '停用後：anon 呼叫 ' || split_part(split_part(v_sig[i], '(', 1), '.', 2) || ' 被拒',
      '報錯，訊息含：permission denied', v_r, v_r like 'ERROR: permission denied%');
  end loop;

  -- assess_* 與 bank_* 仍可用（客服部）
  v_r := pg_temp.vr_cs('select count(*)::text from public.assess_categories()');
  perform pg_temp.vr_rec('9 停用舊抽選器', '停用後：assess_categories 客服部仍可用', '數字', v_r, v_r ~ '^[0-9]+$');
  v_r := pg_temp.vr_cs('select count(*)::text from public.assess_candidates()');
  perform pg_temp.vr_rec('9 停用舊抽選器', '停用後：assess_candidates 客服部仍可用', '數字', v_r, v_r ~ '^[0-9]+$');
  v_r := pg_temp.vr_cs('select count(*)::text from public.bank_list_questions()');
  perform pg_temp.vr_rec('9 停用舊抽選器', '停用後：bank_list_questions 客服部仍可用', '數字', v_r, v_r ~ '^[0-9]+$');
  v_r := pg_temp.vr_cs($q$select public.bank_save_question(null, 'ZZ庫停用', 'Z1', '停用後新增', '[{"action":"a","point":"b"}]'::jsonb)::text$q$);
  perform pg_temp.vr_rec('9 停用舊抽選器', '停用後：bank_save_question 客服部仍可新增', '數字', v_r, v_r ~ '^[0-9]+$');
  v_r := pg_temp.vr_cs($q$select public.bank_reset('ZZ庫停用')$q$, false);
  perform pg_temp.vr_eq('9 停用舊抽選器', '停用後：bank_reset 客服部仍可用', 'OK', v_r);

  -- 不刪函式、不動 app_secret 與題庫資料
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname in ('_pw_ok', '_assert_pw', 'list_categories', 'draw_questions',
         'admin_login', 'admin_list_questions', 'admin_save_question', 'admin_delete_question', 'admin_rename_category', 'admin_reset');
  perform pg_temp.vr_eq('9 停用舊抽選器', '停用後：舊 10 個函式都還在（沒刪）', '10', v_n::text);
  perform pg_temp.vr_eq('9 停用舊抽選器', '停用後：app_secret 筆數沒變', pg_temp.vr_get('secret_cnt'),
    (select count(*)::text from public.app_secret));
  perform pg_temp.vr_eq('9 停用舊抽選器', '停用後：真實題目筆數沒變', pg_temp.vr_get('real_questions'),
    (select count(*)::text from public.questions where category not like 'ZZ%'));

  -- ===== 下半段：還原（與 bank_retire_legacy.sql 註解內的 grant 相同） =====
  for i in 1 .. array_length(v_sig, 1) loop
    execute 'grant execute on function ' || v_sig[i] || ' to anon';
  end loop;

  select count(*) into v_n from unnest(v_sig) x where has_function_privilege('anon', x, 'execute');
  perform pg_temp.vr_eq('9 停用舊抽選器', '還原後：8 個舊函式 anon 都恢復 execute 權限', '8', v_n::text);

  -- 還原後不實際呼叫舊函式：它們密碼錯誤時會 pg_sleep(0.5)，在交易內會拖長時間；
  -- 權限是否恢復以上面的 has_function_privilege 為準（停用後的呼叫在 permission denied 時就被擋下，不會睡）
exception when others then
  perform pg_temp.vr_rec('區段 9','停用舊抽選器測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 10：既有資料表與函式沒有被改動（比對腳本開始時的基準）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  perform pg_temp.vr_eq('10 既有未改動', '既有（非 bank_）函式的定義沒變', pg_temp.vr_get('fn_md5'),
    (select md5(string_agg(pg_get_functiondef(p.oid), '' order by p.oid))
       from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname not like 'bank\_%'));
  perform pg_temp.vr_eq('10 既有未改動', 'public 所有資料表的欄位結構沒變', pg_temp.vr_get('col_md5'),
    (select md5(string_agg(c.table_name || '.' || c.column_name || ':' || c.data_type || ':'
                           || coalesce(c.column_default, '') || ':' || c.is_nullable, ','
                           order by c.table_name, c.ordinal_position))
       from information_schema.columns c where c.table_schema = 'public'));
  perform pg_temp.vr_eq('10 既有未改動', 'policy（public 與 storage）沒變', pg_temp.vr_get('pol_md5'),
    (select coalesce(md5(string_agg(schemaname || '.' || tablename || '.' || policyname || ':'
                                    || coalesce(qual, '') || ':' || coalesce(with_check, ''), ','
                                    order by schemaname, tablename, policyname)), '')
       from pg_policies where schemaname in ('public', 'storage')));
  perform pg_temp.vr_eq('10 既有未改動', '觸發器數量沒變', pg_temp.vr_get('trg_cnt'),
    (select count(*)::text from pg_trigger t
      where not t.tgisinternal and t.tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace)));
  perform pg_temp.vr_eq('10 既有未改動', 'public 資料表／檢視的權限沒變', pg_temp.vr_get('acl_md5'),
    (select md5(string_agg(c.relname || ':' || coalesce(c.relacl::text, ''), ',' order by c.relname))
       from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'm', 'S')));
  perform pg_temp.vr_eq('10 既有未改動', '真實題目筆數沒變', pg_temp.vr_get('real_questions'),
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_eq('10 既有未改動', '真實題目的已抽記錄 drawn 沒變（含全部洗牌後還原；若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_drawn'),
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_eq('10 既有未改動', '真實分類的 category_last 沒變（含全部洗牌後還原；若腳本執行期間有人抽題可能誤報，請在沒人抽題時重跑）', pg_temp.vr_get('real_last'),
    (select count(*)::text from public.category_last where category not like 'ZZ%'));
exception when others then
  perform pg_temp.vr_rec('區段 10','既有未改動比對意外中斷','無例外', sqlerrm, false);
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
begin
  select count(*), count(*) filter (where pass) into v_total, v_ok from pg_temp.vr;
  select string_agg(
           format('(%s, %L, %L, %L, %L)',
                  n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vr;

  begin
    execute 'deallocate bank_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare bank_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過') || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate bank_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare bank_vr_out as select '
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
execute bank_vr_out;
