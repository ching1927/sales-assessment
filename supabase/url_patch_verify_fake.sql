-- ============================================================
-- 業務考核系統：網址欄位修補（url_patch.sql）驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 spotcheck_schema.sql、notes_visible_schema.sql、url_patch.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw）／假題庫，用 set_config('request.jwt.claims', …)
--   ＋ set local role 模擬各角色登入，真的呼叫 assess_start／assess_draw／assess_save_item／spot_register，
--   結果記在暫存表，最後 rollback（假資料全部消失）。
-- 驗證內容：assessment_items.note_url 欄位與約束；assess_save_item 四參數新行為（存網址、空白變 null、壞格式被拒、
--   舊三參數與具名參數呼叫仍可用、沒有重載歧義、已送出／作廢後不可改、他人不可改、主管／店長可讀到）；
--   assess_verify_fake.sql 既有的 assess_save_item 呼叫寫法與錯誤情境；spot_register 的網址驗證（簡要，完整在 spotcheck_verify_fake.sql）。
-- 怎麼看結果：同 spotcheck_verify_fake.sql——最後一張表第一列「總結」顯示 N/M 項通過，「通過」欄全是「通過」才算成功；
--   結果存成預備陳述式 urlpatch_vr_out，rollback 後 execute；rollback 前也會先 select 一次當備援（出現兩張表看最後一張）。
-- 假門市 ZZ-U1／ZZ-U2、假員工 MI-9901～MI-9905、假信箱 vr-cs1／vr-cs2／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null or to_regclass('public.assessment_items') is null then
    raise exception '請先執行 assess_schema.sql';
  end if;
  if to_regclass('public.spot_inspections') is null then
    raise exception '請先執行 spotcheck_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_items' and column_name = 'note_url') then
    raise exception '請先執行 url_patch.sql';
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

-- 以資料庫擁有者身分執行一段 SQL：成功回 'OK'，失敗回 'ERROR: 訊息'（失敗的子交易自動回復）
create or replace function pg_temp.vr_own(p_sql text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

-- 擁有者身分的 SQL 預期報錯，訊息符合 like 樣式
create or replace function pg_temp.vr_ownerr(p_grp text, p_name text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare
  v_r text := pg_temp.vr_own(p_sql);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r,
                         v_r like 'ERROR: ' || p_pattern);
end $$;

-- 以指定資料庫角色（authenticated／anon）＋指定 email 執行一段 SQL。
-- p_scalar = true：SQL 必須回傳單一值，回傳該值的文字；false：只執行，成功回 'OK'。
-- 失敗回 'ERROR: 訊息'。p_email 為 null＝沒有登入者（JWT 為空）。
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

-- 一次測多個角色被拒：h＝總公司主管、s＝店長（vr-sm1）、n＝有登入但沒帳號、a＝未登入（anon）
create or replace function pg_temp.vr_denyset(p_grp text, p_label text, p_sql text, p_who text)
returns void language plpgsql as $$
begin
  if position('h' in p_who) > 0 then
    perform pg_temp.vr_deny(p_grp, p_label || '：總公司主管被拒', 'authenticated', 'vr-hq@2motor.tw', p_sql, '%沒有權限%');
  end if;
  if position('s' in p_who) > 0 then
    perform pg_temp.vr_deny(p_grp, p_label || '：店長被拒', 'authenticated', 'vr-sm1@2motor.tw', p_sql, '%沒有權限%');
  end if;
  if position('n' in p_who) > 0 then
    perform pg_temp.vr_deny(p_grp, p_label || '：有登入但未開通帳號被拒', 'authenticated', 'vr-nobody@2motor.tw', p_sql, '%沒有權限%');
  end if;
  if position('a' in p_who) > 0 then
    perform pg_temp.vr_deny(p_grp, p_label || '：未登入（anon）被拒', 'anon', null, p_sql, '%permission denied%');
  end if;
end $$;

-- 以某角色查一個值，與「擁有者身分」查的值比對（用來驗證各角色看得到的筆數）
create or replace function pg_temp.vr_cmp(p_grp text, p_name text, p_role text, p_email text, p_sql_role text, p_sql_owner text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_eq(p_grp, p_name, pg_temp.vr_q1(p_sql_owner), pg_temp.vr_as(p_role, p_email, p_sql_role, true));
end $$;

-- 組出七面向評分物件
create or replace function pg_temp.vr_mk(a text, b text, c text, d text, e text, f text, g text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('資訊正確性', a, '預設訊息運用', b, '問題掌握', c, '主動引導', d,
                            '風險意識', e, '語氣與禮貌', f, '文字品質', g);
$$;


create or replace function pg_temp.vr_today()
returns date language sql as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

create or replace function pg_temp.vr_has(j jsonb, k text)
returns text language sql as $$
  select case when j ->> k is null then '無' else '有' end;
$$;

-- 客服部開始一場考核並抽一個題組，回傳題組 id
create or replace function pg_temp.vr_item(p_emp text, p_email text)
returns uuid language plpgsql as $$
declare
  v_r text;
  v_aid uuid;
begin
  v_r := pg_temp.vr_as('authenticated', p_email,
           format($q$select public.assess_start(%L, '正式')::text$q$, p_emp), true);
  if v_r like 'ERROR%' then raise exception 'assess_start：%', v_r; end if;
  v_aid := v_r::uuid;
  perform pg_temp.vr_set('a_' || p_emp, v_aid::text);
  v_r := pg_temp.vr_as('authenticated', p_email,
           format($q$select item_id::text from public.assess_draw(%L::uuid, array['ZZ分類U'])$q$, v_aid), true);
  if v_r like 'ERROR%' then raise exception 'assess_draw：%', v_r; end if;
  return v_r::uuid;
end $$;

-- 以指定帳號呼叫 assess_save_item（四參數），回傳 'OK' 或 'ERROR: …'
create or replace function pg_temp.vr_save4(p_item text, p_email text, p_note text, p_url text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, %L, %L)$q$, p_item, p_note, p_url), false);
end $$;

create or replace function pg_temp.vr_nurl(p_item text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select note_url from public.assessment_items where id = %L::uuid', p_item));
end $$;

create or replace function pg_temp.vr_note(p_item text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select note from public.assessment_items where id = %L::uuid', p_item));
end $$;

-- 預期網址格式錯誤被拒（訊息完全一致），且網址、備註都沒被改
create or replace function pg_temp.vr_urlbad(p_name text, p_item text, p_url text)
returns void language plpgsql as $$
declare
  v_before text := pg_temp.vr_nurl(p_item) || '|' || pg_temp.vr_note(p_item);
  v_r text := pg_temp.vr_save4(p_item, 'vr-cs1@2motor.tw', '壞網址測試', p_url);
begin
  perform pg_temp.vr_rec('2 網址格式', p_name,
    '報錯「備註網址格式不正確…」且網址、備註不變', v_r || ' ／ 之後：' || pg_temp.vr_nurl(p_item) || '|' || pg_temp.vr_note(p_item),
    v_r = 'ERROR: 備註網址格式不正確（需 http 或 https 開頭，不可含空白，最長 500 字）'
    and (pg_temp.vr_nurl(p_item) || '|' || pg_temp.vr_note(p_item)) = v_before);
end $$;

-- 客服部登記一次抽查（適當、全優），自訂網址，回傳結果文字或 'ERROR: …'
create or replace function pg_temp.vr_regurl(p_emp text, p_url text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select public.spot_register(%L, %L::date, %L, %L::jsonb, '適當', null)::text$q$,
           p_emp, pg_temp.vr_today()::text, p_url,
           pg_temp.vr_mk('優','優','優','優','優','優','優')::text), true);
end $$;

-- ============================================================
-- 建立假資料（擁有者身分、沒有登入者）
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-U1', 'ZZ測試門市丙'), ('ZZ-U2', 'ZZ測試門市丁');

  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment) values
    ('MI-9901', '假員9901', 'ZZ-U1', '業務', null,          '在職', true),
    ('MI-9902', '假員9902', 'ZZ-U2', '業務', null,          '在職', true),
    ('MI-9903', '假員9903', 'ZZ-U1', '業務', v_today - 200, '在職', true),
    ('MI-9904', '假員9904', 'ZZ-U1', '業務', null,          '在職', true),
    ('MI-9905', '假員9905', 'ZZ-U1', '業務', null,          '在職', true);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-cs2@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-U1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-U2');

  insert into public.questions (category, code, title, steps) values
    ('ZZ分類U', 'U1', '假題組U1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類U', 'U2', '假題組U2', '[{"action":"動作1","point":"考點1"}]'::jsonb);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：結構（欄位、約束、函式簽名與權限）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('1 結構','assessment_items.note_url 欄位存在且是 text','text',
    pg_temp.vr_q1($q$select data_type from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_items' and column_name = 'note_url'$q$));
  perform pg_temp.vr_eq('1 結構','既有資料不受影響：建立題組前沒有任何 note_url 有值的題組','0',
    pg_temp.vr_q1($q$select count(*)::text from public.assessment_items where note_url is not null$q$));
  perform pg_temp.vr_eq('1 結構','note_url 有一條 check，內容含 500 與 http 格式','1/true/true',
    pg_temp.vr_q1($q$select count(*)::text || '/' || bool_and(pg_get_constraintdef(c.oid) like '%500%')::text
                            || '/' || bool_and(pg_get_constraintdef(c.oid) like '%https?%')::text
                     from pg_constraint c
                     where c.conrelid = 'public.assessment_items'::regclass and c.contype = 'c'
                       and pg_get_constraintdef(c.oid) like '%note_url%'$q$));
  perform pg_temp.vr_eq('1 結構','assess_save_item 只有一個版本（沒有三參數／四參數並存的重載）','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'assess_save_item'$q$));
  perform pg_temp.vr_eq('1 結構','舊的三參數簽名已不存在，四參數存在','(null)/有',
    pg_temp.vr_q1($q$select coalesce(to_regprocedure('public.assess_save_item(uuid, jsonb, text)')::text, '(null)') || '/'
                            || case when to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is not null then '有' else '無' end$q$));
  perform pg_temp.vr_eq('1 結構','第 4 個參數是 p_note_url，有預設值（共 4 個參數、1 個預設）','4/1/true',
    pg_temp.vr_q1($q$select p.pronargs::text || '/' || p.pronargdefaults::text || '/'
                            || (pg_get_function_arguments(p.oid) like '%p_note_url text DEFAULT NULL%')::text
                     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'assess_save_item'$q$));
  perform pg_temp.vr_eq('1 結構','assess_save_item 仍是 security definer 且固定 search_path；回傳 void','true/true/void',
    pg_temp.vr_q1($q$select p.prosecdef::text || '/'
                            || exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')::text || '/'
                            || p.prorettype::regtype::text
                     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'assess_save_item'$q$));
  perform pg_temp.vr_eq('1 結構','assess_save_item：authenticated 可執行、anon 不可','true/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.assess_save_item(uuid, jsonb, text, text)'::regprocedure, 'execute')::text
                            || '/' || has_function_privilege('anon', 'public.assess_save_item(uuid, jsonb, text, text)'::regprocedure, 'execute')::text$q$));
  perform pg_temp.vr_eq('1 結構','spot_register 仍只有一個版本、參數名稱仍是 p_message、欄位仍叫 message','1/true/1',
    pg_temp.vr_q1($q$select (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'spot_register')::text
                            || '/' || (select (pg_get_function_arguments(p.oid) like '%p_message text%')::text
                                       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'spot_register')
                            || '/' || (select count(*) from information_schema.columns
                                       where table_schema = 'public' and table_name = 'spot_inspections' and column_name = 'message')::text$q$));
exception when others then
  perform pg_temp.vr_rec('區段 1','結構檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：assess_save_item 新行為與 note_url 約束
-- ============================================================
do $$
declare
  cs1 text := 'vr-cs1@2motor.tw';
  i1 text;
begin
  i1 := pg_temp.vr_item('MI-9901', cs1)::text;
  perform pg_temp.vr_set('i1', i1);

  -- 舊寫法：三參數、具名參數呼叫仍可運作，沒有重載歧義
  perform pg_temp.vr_eq('2 舊寫法','三參數呼叫（位置參數）仍可運作','OK',
    pg_temp.vr_as('authenticated', cs1,
      format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"良","預設訊息運用":"優"}'::jsonb, '舊備註')$q$, i1), false));
  perform pg_temp.vr_eq('2 舊寫法','三參數呼叫：備註與評分照舊存入、網址為空','舊備註/良/(null)',
    pg_temp.vr_q1(format($q$select note || '/' || (levels ->> '資訊正確性') || '/' || coalesce(note_url, '(null)')
                            from public.assessment_items where id = %L::uuid$q$, i1)));
  perform pg_temp.vr_eq('2 舊寫法','備註傳 null（assess_verify_fake.sql 的寫法）仍可運作','OK',
    pg_temp.vr_as('authenticated', cs1,
      format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, null)$q$, i1), false));
  perform pg_temp.vr_eq('2 舊寫法','備註傳 null 後備註被清除（既有行為不變）','(null)', pg_temp.vr_note(i1));
  perform pg_temp.vr_eq('2 舊寫法','具名參數呼叫（網頁 RPC 的寫法 p_item_id／p_levels／p_note）仍可運作','OK',
    pg_temp.vr_as('authenticated', cs1,
      format($q$select public.assess_save_item(p_item_id => %L::uuid, p_levels => '{"資訊正確性":"優"}'::jsonb, p_note => '具名備註')$q$, i1), false));
  perform pg_temp.vr_eq('2 舊寫法','具名參數呼叫：備註存入','具名備註', pg_temp.vr_note(i1));

  -- 存網址
  perform pg_temp.vr_eq('2 存網址','四參數：呼叫成功','OK', pg_temp.vr_save4(i1, cs1, '新備註', 'https://line.me/R/ti/p/abc'));
  perform pg_temp.vr_eq('2 存網址','四參數：網址與備註都存入','https://line.me/R/ti/p/abc/新備註', pg_temp.vr_nurl(i1) || '/' || pg_temp.vr_note(i1));
  perform pg_temp.vr_eq('2 存網址','具名參數（含 p_note_url）可運作','OK',
    pg_temp.vr_as('authenticated', cs1,
      format($q$select public.assess_save_item(p_item_id => %L::uuid, p_levels => '{"資訊正確性":"優"}'::jsonb, p_note => 'n', p_note_url => 'https://line.me/named')$q$, i1), false));
  perform pg_temp.vr_eq('2 存網址','具名參數存入的網址','https://line.me/named', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', E'  \t https://line.me/trim \n ');
  perform pg_temp.vr_eq('2 存網址','網址前後有空白、換行：存去除後的值','https://line.me/trim', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', chr(12288) || 'https://line.me/full' || chr(12288));
  perform pg_temp.vr_eq('2 存網址','網址前後有全形空白：存去除後的值','https://line.me/full', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', 'HTTP://LINE.ME/UPPER');
  perform pg_temp.vr_eq('2 存網址','大寫 HTTP:// 通過（不分大小寫），原樣保存','HTTP://LINE.ME/UPPER', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', 'https://line.me/' || repeat('a', 484));
  perform pg_temp.vr_eq('2 存網址','剛好 500 字通過','500',
    pg_temp.vr_q1(format('select length(note_url)::text from public.assessment_items where id = %L::uuid', i1)));

  -- 空白視為 null
  perform pg_temp.vr_save4(i1, cs1, 'n', 'https://line.me/x');
  perform pg_temp.vr_eq('2 空白','先存一個網址','https://line.me/x', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_eq('2 空白','網址傳空字串：呼叫成功','OK', pg_temp.vr_save4(i1, cs1, 'n', ''));
  perform pg_temp.vr_eq('2 空白','網址傳空字串：視為 null（清除）','(null)', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', 'https://line.me/x');
  perform pg_temp.vr_save4(i1, cs1, 'n', '   ');
  perform pg_temp.vr_eq('2 空白','網址傳全空白：視為 null','(null)', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', 'https://line.me/x');
  perform pg_temp.vr_save4(i1, cs1, 'n', chr(12288) || E'\n');
  perform pg_temp.vr_eq('2 空白','網址傳全形空白＋換行：視為 null','(null)', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', 'https://line.me/x');
  perform pg_temp.vr_save4(i1, cs1, 'n', null);
  perform pg_temp.vr_eq('2 空白','網址傳 null：視為 null（整份取代，與備註一樣：沒傳＝清除）','(null)', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, 'n', 'https://line.me/x');
  perform pg_temp.vr_as('authenticated', cs1,
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, 'n')$q$, i1), false);
  perform pg_temp.vr_eq('2 空白','三參數呼叫（舊前端）會把網址清成 null（已知行為：前端存檔必須一併傳 p_note_url）','(null)', pg_temp.vr_nurl(i1));
  perform pg_temp.vr_save4(i1, cs1, '   ', null);
  perform pg_temp.vr_eq('2 空白','備註只有空白：照舊視為 null（既有行為不變）','(null)', pg_temp.vr_note(i1));

  -- 壞格式被拒（先存一個好網址，確認被拒後網址與備註都沒變）
  perform pg_temp.vr_save4(i1, cs1, '好備註', 'https://line.me/good');
  perform pg_temp.vr_urlbad('網址不是 http／https（ftp）被拒', i1, 'ftp://line.me/abc');
  perform pg_temp.vr_urlbad('網址沒有通訊協定被拒', i1, 'line.me/R/ti/p/abc');
  perform pg_temp.vr_urlbad('只有通訊協定沒有網址被拒', i1, 'https://');
  perform pg_temp.vr_urlbad('網址中間含空白被拒', i1, 'https://line.me/a b');
  perform pg_temp.vr_urlbad('網址中間含換行被拒', i1, E'https://line.me/a\nb');
  perform pg_temp.vr_urlbad('網址中間含 tab 被拒', i1, E'https://line.me/a\tb');
  perform pg_temp.vr_urlbad('網址 501 字被拒', i1, 'https://line.me/' || repeat('a', 485));
  perform pg_temp.vr_urlbad('網址以 javascript: 開頭被拒', i1, 'javascript:alert(1)');
  perform pg_temp.vr_eq('2 網址格式','被拒之後好網址與好備註都還在','https://line.me/good/好備註', pg_temp.vr_nurl(i1) || '/' || pg_temp.vr_note(i1));

  -- 錯誤優先順序：既有檢查優先於網址檢查
  perform pg_temp.vr_eq('2 優先順序','壞網址＋壞評分：先報評分錯誤（既有檢查優先）','true',
    (pg_temp.vr_as('authenticated', cs1,
       format($q$select public.assess_save_item(%L::uuid, '{"亂寫":"優"}'::jsonb, 'n', 'ftp://bad')$q$, i1), false)
       like 'ERROR: %未知的面向%')::text);
  perform pg_temp.vr_eq('2 優先順序','壞網址＋找不到題組：先報找不到題組','true',
    (pg_temp.vr_save4('00000000-0000-0000-0000-000000000000', cs1, 'n', 'ftp://bad') like 'ERROR: %找不到題組%')::text);
  perform pg_temp.vr_eq('2 優先順序','壞網址＋非本人：先報建立者本人（客服部 vr-cs2）','true',
    (pg_temp.vr_save4(i1, 'vr-cs2@2motor.tw', 'n', 'ftp://bad') like 'ERROR: %建立者本人%')::text);
exception when others then
  perform pg_temp.vr_rec('區段 2','存網址意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：note_url 資料表約束（擁有者直接寫入也要擋）、權限
-- ============================================================
do $$
declare
  i1 text := pg_temp.vr_get('i1');
  v_upd text := 'update public.assessment_items set note_url = %L where id = %L::uuid';
begin
  perform pg_temp.vr_ownerr('3 約束','約束：note_url 為 ftp:// 被擋', format(v_upd, 'ftp://x.com', i1), '%assessment_items_note_url_check%');
  perform pg_temp.vr_ownerr('3 約束','約束：note_url 含空白被擋', format(v_upd, 'https://x.com/a b', i1), '%assessment_items_note_url_check%');
  perform pg_temp.vr_ownerr('3 約束','約束：note_url 為空字串被擋（空白應由函式轉成 null）', format(v_upd, '', i1), '%assessment_items_note_url_check%');
  perform pg_temp.vr_ownerr('3 約束','約束：note_url 501 字被擋', format(v_upd, 'https://x.com/' || repeat('a', 487), i1), '%assessment_items_note_url_check%');
  perform pg_temp.vr_eq('3 約束','約束：note_url 為合法網址可以','OK', pg_temp.vr_own(format(v_upd, 'https://x.com/ok', i1)));
  perform pg_temp.vr_eq('3 約束','約束：note_url 為大寫 HTTPS 可以（不分大小寫）','OK', pg_temp.vr_own(format(v_upd, 'HTTPS://X.COM/OK', i1)));
  perform pg_temp.vr_eq('3 約束','約束：note_url 剛好 500 字可以','OK', pg_temp.vr_own(format(v_upd, 'https://x.com/' || repeat('a', 486), i1)));
  perform pg_temp.vr_eq('3 約束','約束：note_url 為 null 可以','OK', pg_temp.vr_own(format('update public.assessment_items set note_url = null where id = %L::uuid', i1)));

  perform pg_temp.vr_deny('3 權限','客服部也不能直接 update note_url（只能走函式）','authenticated','vr-cs1@2motor.tw',
    format($q$update public.assessment_items set note_url = 'https://x.com/direct' where id = %L::uuid$q$, i1), '%permission denied%');
  perform pg_temp.vr_deny('3 權限','未登入（anon）不能讀 assessment_items','anon', null,
    'select note_url from public.assessment_items', '%permission denied%');
exception when others then
  perform pg_temp.vr_rec('區段 3','約束意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：角色權限、已送出／作廢後不可改、可見性
-- ============================================================
do $$
declare
  cs1 text := 'vr-cs1@2motor.tw';
  i1 text := pg_temp.vr_get('i1');
  i2 text; i3 text; i4 text;
  v_ids text;
begin
  perform pg_temp.vr_denyset('4 權限','assess_save_item（四參數）',
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, 'n', 'https://line.me/x')$q$, i1), 'hsna');
  perform pg_temp.vr_eq('4 權限','另一位客服部（非建立者）不能改別人的草稿','true',
    (pg_temp.vr_save4(i1, 'vr-cs2@2motor.tw', 'n', 'https://line.me/x') like 'ERROR: %建立者本人%')::text);
  perform pg_temp.vr_eq('4 權限','被拒的呼叫沒有改到網址（仍是最後一次合法寫入前的值）','(null)', pg_temp.vr_nurl(i1));

  -- i2：9904（U1）已送出；i3：9902（U2）已送出；i4：9905（U1）已作廢；皆先存網址再改狀態
  i2 := pg_temp.vr_item('MI-9904', cs1)::text;
  i3 := pg_temp.vr_item('MI-9902', cs1)::text;
  i4 := pg_temp.vr_item('MI-9905', cs1)::text;
  perform pg_temp.vr_save4(i1, cs1, '草稿備註', 'https://line.me/draft');
  perform pg_temp.vr_save4(i2, cs1, '甲店備註', 'https://line.me/u1');
  perform pg_temp.vr_save4(i3, cs1, '乙店備註', 'https://line.me/u2');
  perform pg_temp.vr_save4(i4, cs1, '作廢備註', 'https://line.me/void');

  update public.assessments
     set status = 'submitted', total_score = 80, verdict = '及格', pass_line = 85, submitted_at = now()
   where id in (pg_temp.vr_get('a_MI-9904')::uuid, pg_temp.vr_get('a_MI-9902')::uuid);
  update public.assessments
     set status = 'voided', total_score = 80, verdict = '及格', pass_line = 85, submitted_at = now(),
         voided_at = now(), voided_by = cs1, void_reason = '假作廢'
   where id = pg_temp.vr_get('a_MI-9905')::uuid;

  perform pg_temp.vr_eq('4 已送出','已送出後客服部也不能改網址（沿用「只有草稿可以暫存評分」）','true',
    (pg_temp.vr_save4(i2, cs1, '想改', 'https://line.me/changed') like 'ERROR: %只有草稿%')::text);
  perform pg_temp.vr_eq('4 已送出','已送出後網址沒被改','https://line.me/u1', pg_temp.vr_nurl(i2));
  perform pg_temp.vr_eq('4 已送出','已送出後想清除網址也被拒、網址仍在','true/https://line.me/u1',
    (pg_temp.vr_save4(i2, cs1, '甲店備註', null) like 'ERROR: %只有草稿%')::text || '/' || pg_temp.vr_nurl(i2));
  perform pg_temp.vr_eq('4 已作廢','已作廢後不能改網址','true/https://line.me/void',
    (pg_temp.vr_save4(i4, cs1, '想改', 'https://line.me/changed') like 'ERROR: %只有草稿%')::text || '/' || pg_temp.vr_nurl(i4));
  perform pg_temp.vr_eq('4 已送出','已送出後壞網址：先報「只有草稿」（既有檢查優先）','true',
    (pg_temp.vr_save4(i2, cs1, 'n', 'ftp://bad') like 'ERROR: %只有草稿%')::text);

  -- 可見性：note_url 與備註相同——客服部全看；主管看已送出；店長看自己門市已送出；草稿與作廢只有客服部
  v_ids := format('%L, %L, %L, %L', i1, i2, i3, i4);
  perform pg_temp.vr_eq('4 可見性','客服部看得到全部 4 題的網址（草稿、已送出、作廢）','4',
    pg_temp.vr_as('authenticated', cs1,
      format('select count(*)::text from public.assessment_items where id in (%s) and note_url is not null', replace(v_ids, '''', '''')), true));
  perform pg_temp.vr_eq('4 可見性','總公司主管只看到已送出的 2 題網址（看不到草稿與作廢）','u1,u2',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw',
      format($q$select string_agg(replace(note_url, 'https://line.me/', ''), ',' order by note_url)
                from public.assessment_items where id in (%s)$q$, v_ids), true));
  perform pg_temp.vr_eq('4 可見性','店長（U1）只看到自己門市已送出的網址','u1',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw',
      format($q$select string_agg(replace(note_url, 'https://line.me/', ''), ',' order by note_url)
                from public.assessment_items where id in (%s)$q$, v_ids), true));
  perform pg_temp.vr_eq('4 可見性','店長（U2）只看到自己門市已送出的網址','u2',
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw',
      format($q$select string_agg(replace(note_url, 'https://line.me/', ''), ',' order by note_url)
                from public.assessment_items where id in (%s)$q$, v_ids), true));
  perform pg_temp.vr_eq('4 可見性','有登入但未開通帳號看不到任何題組（網址也看不到）','0',
    pg_temp.vr_as('authenticated', 'vr-nobody@2motor.tw',
      format('select count(*)::text from public.assessment_items where id in (%s)', v_ids), true));
  perform pg_temp.vr_eq('4 可見性','備註文字與網址一起可見（主管讀到已送出題組的備註與網址）','甲店備註/https://line.me/u1',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw',
      format($q$select note || '/' || note_url from public.assessment_items where id = %L::uuid$q$, i2), true));
exception when others then
  perform pg_temp.vr_rec('區段 4','權限與可見性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：assess_verify_fake.sql 既有的 assess_save_item 呼叫寫法與錯誤情境（用同樣寫法驗一次）
-- ============================================================
do $$
declare
  cs1 text := 'vr-cs1@2motor.tw';
  i1 text := pg_temp.vr_get('i1');
begin
  perform pg_temp.vr_eq('5 既有寫法','等級不正確（普通）：照舊報「等級不正確」','true',
    (pg_temp.vr_as('authenticated', cs1,
       format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"普通"}'::jsonb, null)$q$, i1), false)
       like 'ERROR: %等級不正確%')::text);
  perform pg_temp.vr_eq('5 既有寫法','不適用超過 2 個：照舊報錯','true',
    (pg_temp.vr_as('authenticated', cs1,
       format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"不適用","預設訊息運用":"不適用","問題掌握":"不適用"}'::jsonb, null)$q$, i1), false)
       like 'ERROR: %不適用最多 2%')::text);
  perform pg_temp.vr_eq('5 既有寫法','未知面向：照舊報錯','true',
    (pg_temp.vr_as('authenticated', cs1,
       format($q$select public.assess_save_item(%L::uuid, '{"亂寫":"優"}'::jsonb, null)$q$, i1), false)
       like 'ERROR: %未知的面向%')::text);
  perform pg_temp.vr_eq('5 既有寫法','非建立者（vr-cs2）三參數呼叫：照舊報「建立者本人」','true',
    (pg_temp.vr_as('authenticated', 'vr-cs2@2motor.tw',
       format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, null)$q$, i1), false)
       like 'ERROR: %建立者本人%')::text);
  perform pg_temp.vr_eq('5 既有寫法','暫存部分面向（位置參數三個）成功並存入','OK/良',
    pg_temp.vr_as('authenticated', cs1,
      format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"良","預設訊息運用":"優"}'::jsonb, '暫存備註')$q$, i1), false)
    || '/' || pg_temp.vr_q1(format($q$select levels ->> '資訊正確性' from public.assessment_items where id = %L::uuid$q$, i1)));
  perform pg_temp.vr_eq('5 既有寫法','暫存備註存入 assessment_items.note','暫存備註', pg_temp.vr_note(i1));
  perform pg_temp.vr_eq('5 既有寫法','assessment_items 欄位沒有多出名稱外洩機密的欄位（title／steps 不在其中）','0',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_items'
                       and column_name in ('title', 'steps', 'question_id')$q$));
exception when others then
  perform pg_temp.vr_rec('區段 5','既有寫法意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：spot_register 的網址驗證（簡要；完整斷言在 spotcheck_verify_fake.sql）
-- ============================================================
do $$
declare
  j jsonb;
  v_msg text := 'ERROR: 請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）';
begin
  perform pg_temp.vr_eq('6 抽查網址','網址為 null 被拒（訊息完全一致）', v_msg, pg_temp.vr_regurl('MI-9903', null));
  perform pg_temp.vr_eq('6 抽查網址','網址只有空白被拒', v_msg, pg_temp.vr_regurl('MI-9903', '   '));
  perform pg_temp.vr_eq('6 抽查網址','非 http 開頭被拒', v_msg, pg_temp.vr_regurl('MI-9903', 'ftp://line.me/x'));
  perform pg_temp.vr_eq('6 抽查網址','含空白被拒', v_msg, pg_temp.vr_regurl('MI-9903', 'https://line.me/a b'));
  perform pg_temp.vr_eq('6 抽查網址','501 字被拒', v_msg, pg_temp.vr_regurl('MI-9903', 'https://line.me/' || repeat('a', 485)));
  perform pg_temp.vr_eq('6 抽查網址','被拒的登記沒有留下抽查','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_inspections where employee_id = 'MI-9903'$q$));
  j := pg_temp.vr_regurl('MI-9903', '  HTTPS://LINE.ME/R/TI/P/ABC  ')::jsonb;
  perform pg_temp.vr_eq('6 抽查網址','大寫 HTTPS 且前後有空白：通過，存去空白後的值','HTTPS://LINE.ME/R/TI/P/ABC',
    pg_temp.vr_q1(format('select message from public.spot_inspections where id = %L::uuid', j ->> 'inspection_id')));
exception when others then
  perform pg_temp.vr_rec('區段 6','抽查網址意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate urlpatch_vr_out';
  exception when others then
    null;
  end;

  execute 'prepare urlpatch_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_ok = v_total then ''
                                   else '；未通過：' || (select string_agg(n::text, '、' order by n) from pg_temp.vr where not pass) end)
          || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  begin
    execute 'deallocate urlpatch_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare urlpatch_vr_out as select '
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
execute urlpatch_vr_out;
