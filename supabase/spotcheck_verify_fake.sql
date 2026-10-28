-- ============================================================
-- 業務考核系統：階段 4 抽查系統驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 spotcheck_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw）／假題庫，
--   用 set_config('request.jwt.claims', …) ＋ set local role 模擬各角色登入，真的呼叫 spot_* 與
--   assess_start／assess_draw／assess_save_item／assess_submit／assess_void，
--   把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
--   「跨月」「跨季」「紅單之後」這類需要過去時間的情境，以資料庫擁有者身分直接寫入舊日期的單據來模擬
--   （同一個交易內 now() 是固定值，不能靠等待）。
-- 怎麼看結果：
--   * SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     所以腳本在 rollback 之前把結果表存成「預備陳述式 spotcheck_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- 假門市代碼 ZZ-K1／ZZ-K2、假員工編號 MI-9801～MI-9822、假信箱 vr-cs1／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 並發保護（兩個連線同時登記同一個人）無法在單一連線的腳本內實測，
--   只以「函式內容含 for update 鎖定」做靜態確認，其餘見 README_spotcheck.md 的說明。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯停下（rollback 後無影響），不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null then
    raise exception '請先執行 assess_schema.sql';
  end if;
  if to_regclass('public.spot_inspections') is null
     or to_regclass('public.spot_tickets') is null
     or to_regclass('public.spot_probations') is null
     or to_regprocedure('public.spot_register(text, date, text, jsonb, text, text)') is null then
    raise exception '請先執行 spotcheck_schema.sql';
  end if;
  if to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is null then
    raise exception '請先執行 url_patch.sql（assess_save_item 需為四參數版本）';
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

-- 抽查用的等級：適當＝全優（100.0）；不適當＝64.0 分、最弱面向「問題掌握」
create or replace function pg_temp.vr_lv(p_verdict text)
returns jsonb language plpgsql as $$
begin
  if p_verdict = '適當' then
    return pg_temp.vr_mk('優','優','優','優','優','優','優');
  end if;
  return pg_temp.vr_mk('待加強','良','不及格','優','良','優','優');
end $$;

create or replace function pg_temp.vr_today()
returns date language sql as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

-- jsonb 回傳值的某個鍵有沒有值：有／無
create or replace function pg_temp.vr_has(j jsonb, k text)
returns text language sql as $$
  select case when j ->> k is null then '無' else '有' end;
$$;

-- 客服部登記一次抽查（今天），回傳 jsonb；失敗回 {"error": "..."}
create or replace function pg_temp.vr_reg(p_emp text, p_verdict text, p_reason text default null,
                                           p_email text default 'vr-cs1@2motor.tw')
returns jsonb language plpgsql as $$
declare
  v text;
begin
  v := pg_temp.vr_as('authenticated', p_email,
         format($q$select public.spot_register(%L, %L::date, 'https://line.me/R/ti/p/test-1', %L::jsonb, %L, %L)::text$q$,
                p_emp, pg_temp.vr_today()::text, pg_temp.vr_lv(p_verdict)::text, p_verdict, p_reason),
         true);
  if v like 'ERROR:%' then
    return jsonb_build_object('error', v);
  end if;
  return v::jsonb;
end $$;

-- 連續登記 n 次「不適當」，回傳最後一次的 jsonb
create or replace function pg_temp.vr_n(p_emp text, p_n int, p_reason text default '假原因')
returns jsonb language plpgsql as $$
declare
  j jsonb;
  i int;
begin
  for i in 1 .. p_n loop
    j := pg_temp.vr_reg(p_emp, '不適當', p_reason);
  end loop;
  return j;
end $$;

-- 自訂等級／判定／原因／日期的登記，回傳 spot_register 的結果文字或 'ERROR: …'（客服部身分）
create or replace function pg_temp.vr_rawreg(p_emp text, p_levels jsonb, p_verdict text, p_reason text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.spot_register(%L, %L::date, 'https://line.me/R/ti/p/test-1', %L::jsonb, %L, %L)::text$q$,
                  p_emp, pg_temp.vr_today()::text, p_levels::text, p_verdict, p_reason),
           true);
end $$;

-- 自訂「訊息抽檢-LINE聊天室網址」的登記（適當、全優），回傳結果文字或 'ERROR: …'
create or replace function pg_temp.vr_regurl(p_emp text, p_url text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.spot_register(%L, %L::date, %L, %L::jsonb, '適當', null)::text$q$,
                  p_emp, pg_temp.vr_today()::text, p_url, pg_temp.vr_lv('適當')::text),
           true);
end $$;

-- 網址不合格：預期被拒並回傳指定訊息（用 9814，最後確認沒有留下任何資料）
create or replace function pg_temp.vr_urlbad(p_name text, p_url text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_eq('3 網址', p_name, 'true',
    (pg_temp.vr_regurl('MI-9814', p_url)
       like 'ERROR: 請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）')::text);
end $$;

-- 某人某種單據的張數（預設只算有效）
create or replace function pg_temp.vr_tc(p_emp text, p_kind text, p_status text default '有效')
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format(
    'select count(*)::text from public.spot_tickets where employee_id = %L and kind = %L and status = %L',
    p_emp, p_kind, p_status));
end $$;

-- 客服部看到的人員抽查狀態：黃單數／紅單數／回考核期狀態
create or replace function pg_temp.vr_st(p_emp text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select yellow_month::text || '/' || red_quarter::text || '/' || coalesce(probation_status, '無')
              from public.spot_status() where employee_id = %L$q$, p_emp), true);
end $$;

-- 直接寫入一張舊的黃單（含它的抽查），以擁有者身分；模擬「過去的月份」
create or replace function pg_temp.vr_old_y(p_emp text, p_store text, p_issued date, p_created timestamptz)
returns uuid language plpgsql as $$
declare
  v_i uuid;
  v_t uuid;
  v_lv jsonb := pg_temp.vr_lv('不適當');
  s record;
begin
  select * into s from public.assess_score_item(v_lv);
  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels, total_score, dim_points,
     weakest_dims, verdict, reason, examiner_email, created_at)
  values
    (p_emp, '假員' || right(p_emp, 4), p_store, p_issued, '舊', v_lv, s.item_score, s.dim_points,
     s.weakest_dims, '不適當', '舊原因', 'vr-cs1@2motor.tw', p_created)
  returning id into v_i;
  insert into public.spot_tickets
    (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on, created_at)
  values
    ('黃', p_emp, '假員' || right(p_emp, 4), p_store, v_i, '舊原因', p_issued, p_created)
  returning id into v_t;
  return v_t;
end $$;

-- 直接寫入一張舊的紅單（來源黃單為空陣列），以擁有者身分
create or replace function pg_temp.vr_old_r(p_emp text, p_store text, p_issued date, p_created timestamptz)
returns uuid language plpgsql as $$
declare
  v_t uuid;
begin
  insert into public.spot_tickets
    (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on, created_at)
  values
    ('紅', p_emp, '假員' || right(p_emp, 4), p_store, '{}'::uuid[], '舊紅單', p_issued, p_created)
  returning id into v_t;
  return v_t;
end $$;

-- 真實考核流程：客服部 assess_start → assess_draw → assess_save_item，回傳考核 id；失敗丟例外
create or replace function pg_temp.vr_flow(p_emp text, p_override text, p_levels jsonb)
returns uuid language plpgsql as $$
declare
  v_r text;
  v_aid uuid;
  v_item uuid;
begin
  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.assess_start(%L, %L)::text$q$, p_emp, p_override), true);
  if v_r like 'ERROR%' then raise exception 'assess_start：%', v_r; end if;
  v_aid := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select item_id::text from public.assess_draw(%L::uuid, array['ZZ分類K'])$q$, v_aid), true);
  if v_r like 'ERROR%' then raise exception 'assess_draw：%', v_r; end if;
  v_item := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '假備註')$q$, v_item, p_levels::text), false);
  if v_r like 'ERROR%' then raise exception 'assess_save_item：%', v_r; end if;
  return v_aid;
end $$;

-- 送出考核，回傳「總分/判定/合格線」
create or replace function pg_temp.vr_submit(p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select total_score::text || '/' || verdict || '/' || pass_line::text
              from public.assess_submit(%L::uuid)$q$, p_aid), true);
end $$;

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- K1＝ZZ-K1（店長 vr-sm1）、K2＝ZZ-K2（店長 vr-sm2）
-- 9801 主情境（黃→紅→回考核期）  9802 未填到職日  9803 新人  9804 到職滿 90 天（仍是新人）
-- 9805 到職 91 天（正式）  9806 不納入考核  9807 離職  9808 考核期  9809 K2 正式
-- 9810 考核期通過  9811 跨月  9812 取消回考核期  9813 跨季  9814 作廢  9815 作廢後不倒回
-- 9816 考核期沒過  9817 一般正式（既有行為）  9818 新人（既有行為）  9819 未填到職日（既有行為）
-- 9820 新人且考核期  9821 未填到職日且考核期（已執行）  9822 K2 正式
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values
    ('ZZ-K1', 'ZZ測試門市甲'), ('ZZ-K2', 'ZZ測試門市乙');

  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, probation_since)
  values
    ('MI-9801', '假員9801', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9802', '假員9802', 'ZZ-K1', '業務', null,          '在職', true,  null),
    ('MI-9803', '假員9803', 'ZZ-K1', '業務', v_today - 30,  '在職', true,  null),
    ('MI-9804', '假員9804', 'ZZ-K1', '業務', v_today - 90,  '在職', true,  null),
    ('MI-9805', '假員9805', 'ZZ-K1', '業務', v_today - 91,  '在職', true,  null),
    ('MI-9806', '假員9806', 'ZZ-K1', '業務', v_today - 200, '在職', false, null),
    ('MI-9807', '假員9807', 'ZZ-K1', '業務', v_today - 200, '離職', true,  null),
    ('MI-9808', '假員9808', 'ZZ-K1', '業務', v_today - 200, '在職', true,  v_today),
    ('MI-9809', '假員9809', 'ZZ-K2', '業務', v_today - 200, '在職', true,  null),
    ('MI-9810', '假員9810', 'ZZ-K1', '業務', v_today - 300, '在職', true,  null),
    ('MI-9811', '假員9811', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9812', '假員9812', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9813', '假員9813', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9814', '假員9814', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9815', '假員9815', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9816', '假員9816', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9817', '假員9817', 'ZZ-K1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9818', '假員9818', 'ZZ-K1', '業務', v_today - 30,  '在職', true,  null),
    ('MI-9819', '假員9819', 'ZZ-K1', '業務', null,          '在職', true,  null),
    ('MI-9820', '假員9820', 'ZZ-K1', '業務', v_today - 30,  '在職', true,  null),
    ('MI-9821', '假員9821', 'ZZ-K1', '業務', null,          '在職', true,  null),
    ('MI-9822', '假員9822', 'ZZ-K2', '業務', v_today - 200, '在職', true,  null);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-K1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-K2');
  -- vr-nobody@2motor.tw 刻意不建立帳號（模擬有登入但未開通）
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 0：結構（欄位、約束、資料表、RLS、函式、權限、檢視）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('0 結構','employees.probation_since 欄位存在且是 date','date',
    pg_temp.vr_q1($q$select data_type from information_schema.columns
                     where table_schema = 'public' and table_name = 'employees' and column_name = 'probation_since'$q$));

  perform pg_temp.vr_eq('0 結構','assessments 管 tenure_source 的 check 只有 1 條，且允許「考核期」','1/1',
    pg_temp.vr_q1($q$select count(*)::text || '/' || count(*) filter (where pg_get_constraintdef(c.oid) like '%考核期%')
                     from pg_constraint c
                     where c.conrelid = 'public.assessments'::regclass and c.contype = 'c'
                       and pg_get_constraintdef(c.oid) like '%tenure_source%'$q$));

  perform pg_temp.vr_ownerr('0 結構','tenure_source 寫入不合法的值仍被拒絕',
    $q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
       values ('MI-9822', 'x', 'ZZ-K2', 'vr-zz@2motor.tw', 'draft', '正式', '亂來')$q$,
    '%assessments_tenure_source_check%');

  perform pg_temp.vr_eq('0 結構','tenure_source 寫入「考核期」可以','OK',
    pg_temp.vr_own($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
                      values ('MI-9822', 'x', 'ZZ-K2', 'vr-zz@2motor.tw', 'draft', '正式', '考核期')$q$));
  perform pg_temp.vr_own($q$delete from public.assessments where examiner_email = 'vr-zz@2motor.tw'$q$);

  perform pg_temp.vr_eq('0 結構','三張新表都存在且開了 RLS','3',
    pg_temp.vr_q1($q$select count(*)::text from pg_class c
                     where c.oid in ('public.spot_inspections'::regclass, 'public.spot_tickets'::regclass,
                                     'public.spot_probations'::regclass)
                       and c.relrowsecurity$q$));

  perform pg_temp.vr_eq('0 結構','七個對外函式都存在','7',
    pg_temp.vr_q1($q$select count(to_regprocedure(s))::text from unnest(array[
        'public.spot_candidates()',
        'public.spot_register(text, date, text, jsonb, text, text)',
        'public.spot_void_ticket(uuid, text)',
        'public.spot_coach(uuid, date, text)',
        'public.spot_mark_executed(uuid)',
        'public.spot_cancel_probation(uuid, text)',
        'public.spot_status()']) as s$q$));

  perform pg_temp.vr_eq('0 結構','七個 spot 函式＋assess_start＋assess_submit 都是 security definer 且固定 search_path','9',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.proname in ('spot_candidates','spot_register','spot_void_ticket','spot_coach',
                                         'spot_mark_executed','spot_cancel_probation','spot_status',
                                         'assess_start','assess_submit')
                       and p.prosecdef
                       and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')$q$));

  perform pg_temp.vr_eq('0 結構','authenticated 對七個對外函式都有 execute','7',
    pg_temp.vr_q1($q$select count(*)::text from unnest(array[
        'public.spot_candidates()',
        'public.spot_register(text, date, text, jsonb, text, text)',
        'public.spot_void_ticket(uuid, text)',
        'public.spot_coach(uuid, date, text)',
        'public.spot_mark_executed(uuid)',
        'public.spot_cancel_probation(uuid, text)',
        'public.spot_status()']) as s
      where has_function_privilege('authenticated', to_regprocedure(s), 'execute')$q$));

  perform pg_temp.vr_eq('0 結構','anon 對七個對外函式都沒有 execute','0',
    pg_temp.vr_q1($q$select count(*)::text from unnest(array[
        'public.spot_candidates()',
        'public.spot_register(text, date, text, jsonb, text, text)',
        'public.spot_void_ticket(uuid, text)',
        'public.spot_coach(uuid, date, text)',
        'public.spot_mark_executed(uuid)',
        'public.spot_cancel_probation(uuid, text)',
        'public.spot_status()']) as s
      where has_function_privilege('anon', to_regprocedure(s), 'execute')$q$));

  perform pg_temp.vr_eq('0 結構','內部小工具（次數計算）連 authenticated 都不能直接呼叫','0',
    pg_temp.vr_q1($q$select count(*)::text from unnest(array[
        'public.spot_month_yellow_ids(text, date)',
        'public.spot_quarter_red_ids(text, date)']) as s
      where has_function_privilege('authenticated', to_regprocedure(s), 'execute')
         or has_function_privilege('anon', to_regprocedure(s), 'execute')$q$));

  perform pg_temp.vr_eq('0 結構','authenticated 對三張新表只有 select（沒有 insert／update／delete／truncate）','3/0',
    pg_temp.vr_q1($q$select
        (select count(*) from unnest(array['public.spot_inspections','public.spot_tickets','public.spot_probations']) t
          where has_table_privilege('authenticated', t, 'select'))::text
        || '/' ||
        (select count(*) from unnest(array['public.spot_inspections','public.spot_tickets','public.spot_probations']) t,
                unnest(array['insert','update','delete','truncate']) p
          where has_table_privilege('authenticated', t, p))::text$q$));

  perform pg_temp.vr_eq('0 結構','anon 對三張新表沒有任何權限','0',
    pg_temp.vr_q1($q$select count(*)::text from unnest(array['public.spot_inspections','public.spot_tickets','public.spot_probations']) t,
                       unnest(array['select','insert','update','delete','truncate']) p
                     where has_table_privilege('anon', t, p)$q$));

  perform pg_temp.vr_eq('0 結構','employees_with_tenure 檢視帶出 probation_since，且仍有 tenure_group','2',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'employees_with_tenure'
                       and column_name in ('probation_since', 'tenure_group')$q$));

  perform pg_temp.vr_eq('0 結構','employees_with_tenure 仍是 security_invoker 檢視','true',
    pg_temp.vr_q1($q$select (c.reloptions::text like '%security_invoker=true%')::text
                     from pg_class c where c.oid = 'public.employees_with_tenure'::regclass$q$));

  perform pg_temp.vr_eq('0 結構','employees_with_tenure 筆數與 employees 相同（沒有多列少列）','true',
    pg_temp.vr_q1($q$select ((select count(*) from public.employees_with_tenure)
                           = (select count(*) from public.employees))::text$q$));

  perform pg_temp.vr_eq('0 結構','檢視 employees_with_tenure：假員工的新人／正式分類不變（9803 新人、9805 正式、9802 未填到職日）','新人/正式/未填到職日',
    pg_temp.vr_q1($q$select (select tenure_group from public.employees_with_tenure where id = 'MI-9803') || '/' ||
                            (select tenure_group from public.employees_with_tenure where id = 'MI-9805') || '/' ||
                            (select tenure_group from public.employees_with_tenure where id = 'MI-9802')$q$));

  perform pg_temp.vr_eq('0 結構','既有 assess 函式與成績單檢視都還在','6/true',
    pg_temp.vr_q1($q$select (select count(to_regprocedure(s)) from unnest(array[
        'public.assess_void(uuid, text)', 'public.assess_draw(uuid, text[])',
        'public.assess_save_item(uuid, jsonb, text, text)', 'public.assess_abandon(uuid)',
        'public.assess_candidates()', 'public.assess_categories()']) as s)::text
        || '/' || (to_regclass('public.assessment_summaries') is not null)::text$q$));
exception when others then
  perform pg_temp.vr_rec('區段 0','結構檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：角色權限（函式層）——客服部／主管／店長／未開通帳號／匿名
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  v_none text := '00000000-0000-0000-0000-000000000000';
begin
  -- spot_candidates：只有客服部
  perform pg_temp.vr_denyset('1 角色權限','spot_candidates', 'select * from public.spot_candidates()', 'hsna');
  perform pg_temp.vr_ok('1 角色權限','spot_candidates：客服部可呼叫', cs, 'select * from public.spot_candidates()');

  -- spot_register：只有客服部（先被角色擋下，不會碰到員工）
  perform pg_temp.vr_denyset('1 角色權限','spot_register',
    $q$select public.spot_register('MI-9801', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, 'hsna');

  -- spot_void_ticket：只有客服部
  perform pg_temp.vr_denyset('1 角色權限','spot_void_ticket',
    format($q$select public.spot_void_ticket(%L::uuid, 'x')$q$, v_none), 'hsna');
  perform pg_temp.vr_deny('1 角色權限','spot_void_ticket：客服部對不存在的單報「找不到單據」','authenticated', cs,
    format($q$select public.spot_void_ticket(%L::uuid, 'x')$q$, v_none), '%找不到單據%');

  -- spot_mark_executed：只有客服部
  perform pg_temp.vr_denyset('1 角色權限','spot_mark_executed',
    format($q$select public.spot_mark_executed(%L::uuid)$q$, v_none), 'hsna');
  perform pg_temp.vr_deny('1 角色權限','spot_mark_executed：客服部對不存在的紀錄報「找不到回考核期紀錄」','authenticated', cs,
    format($q$select public.spot_mark_executed(%L::uuid)$q$, v_none), '%找不到回考核期紀錄%');

  -- spot_cancel_probation：只有客服部
  perform pg_temp.vr_denyset('1 角色權限','spot_cancel_probation',
    format($q$select public.spot_cancel_probation(%L::uuid, 'x')$q$, v_none), 'hsna');
  perform pg_temp.vr_deny('1 角色權限','spot_cancel_probation：客服部對不存在的紀錄報「找不到回考核期紀錄」','authenticated', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, 'x')$q$, v_none), '%找不到回考核期紀錄%');

  -- spot_coach：客服部與店長可用；主管、未開通、匿名被拒（店長對別店的單另在區段 7 測）
  perform pg_temp.vr_denyset('1 角色權限','spot_coach',
    format($q$select public.spot_coach(%L::uuid, current_date, 'x')$q$, v_none), 'hna');
  perform pg_temp.vr_deny('1 角色權限','spot_coach：客服部對不存在的單報「找不到單據」','authenticated', cs,
    format($q$select public.spot_coach(%L::uuid, current_date, 'x')$q$, v_none), '%找不到單據%');
  perform pg_temp.vr_deny('1 角色權限','spot_coach：店長對不存在的單只回通用訊息','authenticated', 'vr-sm1@2motor.tw',
    format($q$select public.spot_coach(%L::uuid, current_date, 'x')$q$, v_none), '%找不到這張單據或沒有權限%');

  -- spot_status：全部已開通角色可用；未開通、匿名被拒
  perform pg_temp.vr_denyset('1 角色權限','spot_status', 'select * from public.spot_status()', 'na');
  perform pg_temp.vr_ok('1 角色權限','spot_status：客服部可呼叫', cs, 'select * from public.spot_status()');
  perform pg_temp.vr_ok('1 角色權限','spot_status：總公司主管可呼叫', 'vr-hq@2motor.tw', 'select * from public.spot_status()');
  perform pg_temp.vr_ok('1 角色權限','spot_status：店長可呼叫', 'vr-sm1@2motor.tw', 'select * from public.spot_status()');
exception when others then
  perform pg_temp.vr_rec('區段 1','角色權限意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：抽查對象名單（spot_candidates）與人員狀態的角色過濾（此時還沒登記任何抽查）
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  v_all text := 'MI-9801,MI-9802,MI-9805,MI-9808,MI-9809,MI-9810,MI-9811,MI-9812,MI-9813,MI-9814,MI-9815,MI-9816,MI-9817,MI-9819,MI-9821,MI-9822';
  v_k1 text := 'MI-9801,MI-9802,MI-9805,MI-9808,MI-9810,MI-9811,MI-9812,MI-9813,MI-9814,MI-9815,MI-9816,MI-9817,MI-9819,MI-9821';
  v_q text := $q$select string_agg(employee_id, ',' order by employee_id) from public.spot_status()
                 where employee_id between 'MI-9800' and 'MI-9899'$q$;
begin
  perform pg_temp.vr_eq('2 名單','spot_candidates：只含在職、納入考核、非新人（含未填到職日與 91 天）、非考核期；排除新人 9803／9804、不納入 9806、離職 9807、考核期 9808、新人 9818／9820',
    'MI-9801,MI-9802,MI-9805,MI-9809,MI-9810,MI-9811,MI-9812,MI-9813,MI-9814,MI-9815,MI-9816,MI-9817,MI-9819,MI-9821,MI-9822',
    pg_temp.vr_as('authenticated', cs,
      $q$select string_agg(id, ',' order by id) from public.spot_candidates() where id between 'MI-9800' and 'MI-9899'$q$, true));

  perform pg_temp.vr_eq('2 名單','spot_candidates：回傳欄位內容正確（9802 暱稱、門市、職稱、到職日為空）','假員9802/ZZ-K1/業務/(空)',
    pg_temp.vr_as('authenticated', cs,
      $q$select nickname || '/' || store_code || '/' || job_title || '/' || coalesce(hire_date::text, '(空)')
         from public.spot_candidates() where id = 'MI-9802'$q$, true));

  perform pg_temp.vr_eq('2 名單','spot_status（客服部）：看到全部「正式或考核期」人員（新人不列、考核期 9808 列入）', v_all,
    pg_temp.vr_as('authenticated', cs, v_q, true));
  perform pg_temp.vr_eq('2 名單','spot_status（總公司主管）：同客服部，看到全部', v_all,
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', v_q, true));
  perform pg_temp.vr_eq('2 名單','spot_status（店長 K1）：只看到自己門市', v_k1,
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', v_q, true));
  perform pg_temp.vr_eq('2 名單','spot_status（店長 K2）：只看到自己門市', 'MI-9809,MI-9822',
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', v_q, true));
  perform pg_temp.vr_eq('2 名單','spot_status（店長 K1）：看不到任何別間門市的列（含真實資料）','0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw',
      $q$select count(*)::text from public.spot_status() where store_code <> 'ZZ-K1'$q$, true));

  perform pg_temp.vr_eq('2 名單','spot_status：9802 的名稱與門市、初始次數為 0','假員9802/ZZ-K1/0/0/無',
    pg_temp.vr_as('authenticated', cs,
      $q$select employee_label || '/' || store_code || '/' || yellow_month::text || '/' || red_quarter::text || '/'
                || coalesce(probation_status, '無') from public.spot_status() where employee_id = 'MI-9802'$q$, true));
  perform pg_temp.vr_eq('2 名單','spot_status：考核期 9808 目前沒有回考核期紀錄，狀態欄為空','無',
    pg_temp.vr_as('authenticated', cs,
      $q$select coalesce(probation_status, '無') from public.spot_status() where employee_id = 'MI-9808'$q$, true));
exception when others then
  perform pg_temp.vr_rec('區段 2','名單意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：抽查對象資格與輸入驗證（spot_register）
-- ============================================================
do $$
declare
  j jsonb;
  v_ok2 text;
begin
  perform pg_temp.vr_deny('3 資格','新人（到職 30 天）不能被抽查','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register('MI-9803', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%新人%');
  perform pg_temp.vr_deny('3 資格','到職剛好 90 天仍算新人，不能被抽查','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register('MI-9804', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%新人%');
  perform pg_temp.vr_deny('3 資格','不納入考核的人不能被抽查','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register('MI-9806', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%不在考核名單%');
  perform pg_temp.vr_deny('3 資格','離職的人不能被抽查','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register('MI-9807', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%離職%');
  perform pg_temp.vr_deny('3 資格','考核期的人不能被抽查','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register('MI-9808', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%考核期%');
  perform pg_temp.vr_deny('3 資格','不存在的員工編號被拒','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register('MI-0000', current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%找不到員工%');
  perform pg_temp.vr_deny('3 資格','員工編號為空被拒','authenticated','vr-cs1@2motor.tw',
    $q$select public.spot_register(null, current_date, 'https://line.me/R/ti/p/test-1', '{}'::jsonb, '適當', null)$q$, '%找不到員工%');
  perform pg_temp.vr_eq('3 資格','被拒的登記沒有留下任何抽查或單據（新人 9803、考核期 9808）','0/0',
    pg_temp.vr_q1($q$select (select count(*) from public.spot_inspections where employee_id in ('MI-9803','MI-9808'))::text
                     || '/' || (select count(*) from public.spot_tickets where employee_id in ('MI-9803','MI-9808'))::text$q$));

  -- 可以被抽查：到職 91 天（正式）、未填到職日（視為正式）
  j := pg_temp.vr_reg('MI-9805', '適當');
  perform pg_temp.vr_eq('3 資格','到職 91 天的正式員工可以被抽查','有', pg_temp.vr_has(j, 'inspection_id'));
  j := pg_temp.vr_reg('MI-9802', '適當');
  perform pg_temp.vr_eq('3 資格','未填到職日者視為正式，可以被抽查','有', pg_temp.vr_has(j, 'inspection_id'));

  -- 輸入驗證（用 9814 試，最後確認一筆都沒寫進去）
  perform pg_temp.vr_deny('3 驗證','判定不是「適當／不適當」被拒','authenticated','vr-cs1@2motor.tw',
    format($q$select public.spot_register('MI-9814', current_date, 'https://line.me/R/ti/p/test-1', %L::jsonb, '亂填', null)$q$, pg_temp.vr_lv('適當')::text),
    '%判定必須是%');
  perform pg_temp.vr_deny('3 驗證','判定為空被拒','authenticated','vr-cs1@2motor.tw',
    format($q$select public.spot_register('MI-9814', current_date, 'https://line.me/R/ti/p/test-1', %L::jsonb, null, null)$q$, pg_temp.vr_lv('適當')::text),
    '%判定必須是%');
  perform pg_temp.vr_deny('3 驗證','抽查日期為空被拒','authenticated','vr-cs1@2motor.tw',
    format($q$select public.spot_register('MI-9814', null, 'https://line.me/R/ti/p/test-1', %L::jsonb, '適當', null)$q$, pg_temp.vr_lv('適當')::text),
    '%抽查日期不可空白%');
  perform pg_temp.vr_eq('3 驗證','判定不適當、原因為 null 被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_lv('不適當'), '不適當', null) like 'ERROR: %原因不可空白%')::text);
  perform pg_temp.vr_eq('3 驗證','判定不適當、原因只有空白被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_lv('不適當'), '不適當', '   ') like 'ERROR: %原因不可空白%')::text);
  perform pg_temp.vr_eq('3 驗證','判定不適當、原因只有全形空白被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_lv('不適當'), '不適當', chr(12288) || chr(12288)) like 'ERROR: %原因不可空白%')::text);
  perform pg_temp.vr_eq('3 驗證','七面向缺一個被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_lv('適當') - '文字品質', '適當', null) like 'ERROR: %七個面向必須全部有值%')::text);
  perform pg_temp.vr_eq('3 驗證','不適用 3 個（超過 2 個）被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_mk('不適用','不適用','不適用','優','優','優','優'), '適當', null)
       like 'ERROR: %不適用最多 2%')::text);
  perform pg_temp.vr_eq('3 驗證','面向名稱不在七面向內被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_lv('適當') || '{"亂來":"優"}'::jsonb, '適當', null) like 'ERROR: %未知的面向%')::text);
  perform pg_temp.vr_eq('3 驗證','等級不是 優／良／待加強／不及格／不適用 被拒','true',
    (pg_temp.vr_rawreg('MI-9814', pg_temp.vr_mk('超讚','優','優','優','優','優','優'), '適當', null) like 'ERROR: %等級不正確%')::text);
  perform pg_temp.vr_eq('3 驗證','等級物件為 null 被拒','true',
    (pg_temp.vr_rawreg('MI-9814', null, '適當', null) like 'ERROR: %評分格式不正確%')::text);
  -- 訊息抽檢-LINE聊天室網址：必填、http/https 開頭、不含空白、<= 500 字
  perform pg_temp.vr_urlbad('網址為 null 被拒', null);
  perform pg_temp.vr_urlbad('網址為空字串被拒', '');
  perform pg_temp.vr_urlbad('網址只有空白被拒', '   ');
  perform pg_temp.vr_urlbad('網址只有全形空白與換行被拒', chr(12288) || E'\n');
  perform pg_temp.vr_urlbad('不是 http／https（ftp）被拒', 'ftp://line.me/R/ti/p/abc');
  perform pg_temp.vr_urlbad('沒有通訊協定被拒', 'line.me/R/ti/p/abc');
  perform pg_temp.vr_urlbad('只有通訊協定沒有網址被拒', 'https://');
  perform pg_temp.vr_urlbad('網址中間含空白被拒', 'https://line.me/R/ti/p/a b');
  perform pg_temp.vr_urlbad('網址中間含換行被拒', E'https://line.me/R/ti/p/a\nb');
  perform pg_temp.vr_urlbad('網址 501 字被拒', 'https://line.me/' || repeat('a', 485));
  perform pg_temp.vr_eq('3 網址','網址驗證排在其他驗證之後：判定錯誤時先報判定錯誤','true',
    (pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
       format($q$select public.spot_register('MI-9814', current_date, 'bad', %L::jsonb, '亂填', null)::text$q$, pg_temp.vr_lv('適當')::text), true)
       like 'ERROR: %判定必須是%')::text);
  perform pg_temp.vr_eq('3 網址','網址驗證排在其他驗證之後：不適當沒原因時先報原因','true',
    (pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
       format($q$select public.spot_register('MI-9814', current_date, 'bad', %L::jsonb, '不適當', null)::text$q$, pg_temp.vr_lv('不適當')::text), true)
       like 'ERROR: %原因不可空白%')::text);
  perform pg_temp.vr_eq('3 網址','網址驗證排在其他驗證之後：七面向缺一個時先報等級錯誤','true',
    (pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
       format($q$select public.spot_register('MI-9814', current_date, 'bad', %L::jsonb, '適當', null)::text$q$,
              (pg_temp.vr_lv('適當') - '文字品質')::text), true)
       like 'ERROR: %七個面向必須全部有值%')::text);
  perform pg_temp.vr_eq('3 驗證','所有被拒的登記都沒有留下抽查或單據（9814）','0/0',
    pg_temp.vr_q1($q$select (select count(*) from public.spot_inspections where employee_id = 'MI-9814')::text
                     || '/' || (select count(*) from public.spot_tickets where employee_id = 'MI-9814')::text$q$));

  -- 網址合格的情況（用 9817）：前後空白去除、HTTPS 大寫可以、http 可以、剛好 500 字可以
  j := pg_temp.vr_regurl('MI-9817', E'  \t https://line.me/R/ti/p/abc \n ')::jsonb;
  perform pg_temp.vr_eq('3 網址','網址前後有空白、換行：通過，存的是去除空白後的值','https://line.me/R/ti/p/abc',
    pg_temp.vr_q1(format('select message from public.spot_inspections where id = %L::uuid', j ->> 'inspection_id')));
  j := pg_temp.vr_regurl('MI-9817', chr(12288) || 'https://line.me/R/ti/p/abc' || chr(12288))::jsonb;
  perform pg_temp.vr_eq('3 網址','網址前後有全形空白：通過，存去除後的值','https://line.me/R/ti/p/abc',
    pg_temp.vr_q1(format('select message from public.spot_inspections where id = %L::uuid', j ->> 'inspection_id')));
  j := pg_temp.vr_regurl('MI-9817', 'HTTPS://LINE.ME/R/TI/P/ABC')::jsonb;
  perform pg_temp.vr_eq('3 網址','大寫 HTTPS:// 通過（不分大小寫），原樣保存','HTTPS://LINE.ME/R/TI/P/ABC',
    pg_temp.vr_q1(format('select message from public.spot_inspections where id = %L::uuid', j ->> 'inspection_id')));
  j := pg_temp.vr_regurl('MI-9817', 'http://line.me/x')::jsonb;
  perform pg_temp.vr_eq('3 網址','http:// 開頭通過','有', pg_temp.vr_has(j, 'inspection_id'));
  j := pg_temp.vr_regurl('MI-9817', 'https://line.me/' || repeat('a', 484))::jsonb;
  perform pg_temp.vr_eq('3 網址','剛好 500 字通過','500',
    pg_temp.vr_q1(format('select length(message)::text from public.spot_inspections where id = %L::uuid', j ->> 'inspection_id')));
  perform pg_temp.vr_eq('3 網址','被拒的網址沒有留下抽查（9814 仍為 0）；9817 只留下 5 筆成功的','0/5',
    pg_temp.vr_q1($q$select (select count(*) from public.spot_inspections where employee_id = 'MI-9814')::text
                     || '/' || (select count(*) from public.spot_inspections where employee_id = 'MI-9817')::text$q$));

  -- 不適用 2 個可以通過；判定「適當」不需要原因
  j := pg_temp.vr_rawreg('MI-9811', pg_temp.vr_mk('不適用','不適用','優','優','優','優','優'), '適當', null)::jsonb;
  perform pg_temp.vr_eq('3 驗證','不適用 2 個可以登記，總分只算適用面向（全優＝100.0）','100.0', j ->> 'total_score');
  perform pg_temp.vr_eq('3 驗證','判定「適當」不開黃單（回傳 yellow_id／red_id／probation_id 皆為空）','無/無/無',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('3 驗證','「適當」只留下抽查紀錄、沒有任何單據（9805、9802、9811）','1/1/1/0',
    pg_temp.vr_q1($q$select (select count(*) from public.spot_inspections where employee_id = 'MI-9805')::text
                     || '/' || (select count(*) from public.spot_inspections where employee_id = 'MI-9802')::text
                     || '/' || (select count(*) from public.spot_inspections where employee_id = 'MI-9811')::text
                     || '/' || (select count(*) from public.spot_tickets where employee_id in ('MI-9805','MI-9802','MI-9811'))::text$q$));
  perform pg_temp.vr_eq('3 驗證','「適當」的抽查：判定／原因為空／分數／門市／登記人','適當/無/100.0/ZZ-K1/vr-cs1@2motor.tw',
    pg_temp.vr_q1($q$select verdict || '/' || coalesce(reason, '無') || '/' || total_score::text || '/' || store_code || '/' || examiner_email
                     from public.spot_inspections where employee_id = 'MI-9805'$q$));

  -- 不適當：開黃單（用 K2 的 9822）
  j := pg_temp.vr_reg('MI-9822', '不適當', '回覆錯誤');
  perform pg_temp.vr_eq('3 黃單','判定「不適當」自動開一張黃單；沒有紅單、沒有回考核期','有/無/無',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('3 黃單','回傳的總分與最弱面向（等級 待加強／良／不及格／優／良／優／優＝64.0；最弱「問題掌握」）','64.0/["問題掌握"]',
    (j ->> 'total_score') || '/' || (j -> 'weakest_dims')::text);
  perform pg_temp.vr_eq('3 黃單','黃單內容：種類／狀態／開單日（台北今天）／門市／名稱快照／原因／連到這次抽查',
    '黃/有效/' || pg_temp.vr_today()::text || '/ZZ-K2/假員9822/回覆錯誤/true',
    pg_temp.vr_q1(format($q$select kind || '/' || status || '/' || issued_on::text || '/' || store_code || '/' || employee_label
                                  || '/' || reason || '/' || (inspection_id = %L::uuid)::text
                           from public.spot_tickets where id = %L::uuid$q$, j ->> 'inspection_id', j ->> 'yellow_id')));
  perform pg_temp.vr_eq('3 黃單','抽查內容：判定／原因／分數／登記人／訊息文字','不適當/回覆錯誤/64.0/vr-cs1@2motor.tw/https://line.me/R/ti/p/test-1',
    pg_temp.vr_q1(format($q$select verdict || '/' || reason || '/' || total_score::text || '/' || examiner_email || '/' || message
                           from public.spot_inspections where id = %L::uuid$q$, j ->> 'inspection_id')));
  perform pg_temp.vr_eq('3 黃單','抽查內容：七面向各自得分（資訊正確性 8、問題掌握 0）與等級原樣保存','8/0/待加強',
    pg_temp.vr_q1(format($q$select (dim_points ->> '資訊正確性') || '/' || (dim_points ->> '問題掌握') || '/' || (levels ->> '資訊正確性')
                           from public.spot_inspections where id = %L::uuid$q$, j ->> 'inspection_id')));
  perform pg_temp.vr_eq('3 黃單','spot_status：9822 當月黃單 1、紅單 0','1/0/無', pg_temp.vr_st('MI-9822'));
exception when others then
  perform pg_temp.vr_rec('區段 3','資格與輸入驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：黃單 → 紅單 → 回考核期（9801 主情境）
-- ============================================================
do $$
declare
  j jsonb;
  v_r1 text; v_r2 text; v_p1 text;
begin
  j := pg_temp.vr_reg('MI-9801', '適當');
  perform pg_temp.vr_eq('4 紅單','先登記 1 次「適當」不算黃單','0', pg_temp.vr_tc('MI-9801', '黃'));

  j := pg_temp.vr_n('MI-9801', 4);
  perform pg_temp.vr_eq('4 紅單','累積 4 張有效黃單，不開紅單','4/0/無',
    pg_temp.vr_tc('MI-9801', '黃') || '/' || pg_temp.vr_tc('MI-9801', '紅') || '/' || pg_temp.vr_has(j, 'red_id'));
  perform pg_temp.vr_eq('4 紅單','spot_status：4 張黃單、0 張紅單','4/0/無', pg_temp.vr_st('MI-9801'));

  j := pg_temp.vr_reg('MI-9801', '不適當', '第五張');
  v_r1 := j ->> 'red_id';
  perform pg_temp.vr_eq('4 紅單','第 5 張有效黃單：同一次呼叫自動開紅單；還不到回考核期','有/有/無',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('4 紅單','紅單內容：種類／狀態／開單日／湊成它的黃單 5 張／沒有抽查連結','紅/有效/' || pg_temp.vr_today()::text || '/5/無',
    pg_temp.vr_q1(format($q$select kind || '/' || status || '/' || issued_on::text || '/' || array_length(source_ticket_ids, 1)::text
                                  || '/' || coalesce(inspection_id::text, '無')
                           from public.spot_tickets where id = %L::uuid$q$, v_r1)));
  perform pg_temp.vr_eq('4 紅單','紅單的來源黃單 5 張都真的是 9801 的黃單','5',
    pg_temp.vr_q1(format($q$select count(*)::text from public.spot_tickets
                            where kind = '黃' and employee_id = 'MI-9801'
                              and id = any(coalesce((select source_ticket_ids from public.spot_tickets where id = %L::uuid), '{}'::uuid[]))$q$, v_r1)));
  perform pg_temp.vr_eq('4 紅單','紅單之後黃單從 0 重算：status 顯示 黃 0／紅 1（還沒有回考核期）','0/1/無', pg_temp.vr_st('MI-9801'));

  -- 邊界：紅單之後再 4 張黃單，本月有效黃單總共 9 張，但「紅單之後」只有 4 張 → 不再開紅單
  j := pg_temp.vr_n('MI-9801', 4);
  perform pg_temp.vr_eq('4 紅單','紅單之後再 4 張黃單：不再開紅單（本月有效黃單共 9 張、紅單之後只算 4 張）','9/1/無',
    pg_temp.vr_tc('MI-9801', '黃') || '/' || pg_temp.vr_tc('MI-9801', '紅') || '/' || pg_temp.vr_has(j, 'red_id'));
  perform pg_temp.vr_eq('4 紅單','spot_status：紅單之後 4 張黃單、1 張紅單','4/1/無', pg_temp.vr_st('MI-9801'));

  -- 紅單之後第 5 張 → 第 2 張紅單；同一日曆季 2 張紅單 → 回考核期
  j := pg_temp.vr_reg('MI-9801', '不適當', '再第五張');
  v_r2 := j ->> 'red_id';
  v_p1 := j ->> 'probation_id';
  perform pg_temp.vr_eq('4 紅單','紅單之後的第 5 張黃單：開第 2 張紅單；同一日曆季有效紅單滿 2 張，同時開回考核期','有/有/有',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('4 紅單','第 2 張紅單的來源黃單 5 張（只含紅單之後的）','5',
    pg_temp.vr_q1(format($q$select array_length(source_ticket_ids, 1)::text from public.spot_tickets where id = %L::uuid$q$, v_r2)));
  perform pg_temp.vr_eq('4 紅單','第 2 張紅單的來源黃單都在第 1 張紅單之後（沒有重複使用第一輪的黃單）','0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.spot_tickets y, public.spot_tickets r1
                            where r1.id = %L::uuid
                              and y.id = any(coalesce((select source_ticket_ids from public.spot_tickets where id = %L::uuid), '{}'::uuid[]))
                              and y.created_at < r1.created_at$q$, v_r1, v_r2)));
  perform pg_temp.vr_set('r1', v_r1); perform pg_temp.vr_set('r2', v_r2); perform pg_temp.vr_set('p1', v_p1);

  perform pg_temp.vr_eq('4 回考核期','回考核期紀錄：狀態／開立日／觸發紅單數／門市／名稱快照','待執行/' || pg_temp.vr_today()::text || '/2/ZZ-K1/假員9801',
    pg_temp.vr_q1(format($q$select status || '/' || triggered_on::text || '/' || array_length(red_ticket_ids, 1)::text
                                  || '/' || store_code || '/' || employee_label
                           from public.spot_probations where id = %L::uuid$q$, v_p1)));
  perform pg_temp.vr_eq('4 回考核期','回考核期紀錄的觸發紅單就是那兩張紅單','true',
    pg_temp.vr_q1(format($q$select (array[%L::uuid, %L::uuid] <@ red_ticket_ids)::text from public.spot_probations where id = %L::uuid$q$,
                         v_r1, v_r2, v_p1)));
  perform pg_temp.vr_eq('4 回考核期','employees.probation_since 設為開立當天（台北今天）', pg_temp.vr_today()::text,
    pg_temp.vr_q1($q$select probation_since::text from public.employees where id = 'MI-9801'$q$));
  perform pg_temp.vr_eq('4 回考核期','spot_status：回考核期發生後紅單重新從 0 算：黃 0／紅 0／回考核期 待執行','0/0/待執行', pg_temp.vr_st('MI-9801'));
  perform pg_temp.vr_eq('4 回考核期','spot_status 回傳的 probation_id 就是剛開的那筆','true',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select (probation_id = %L::uuid)::text from public.spot_status() where employee_id = 'MI-9801'$q$, v_p1), true));
  perform pg_temp.vr_eq('4 回考核期','考核期內不再被抽查：再登記 9801 被拒','true',
    (pg_temp.vr_rawreg('MI-9801', pg_temp.vr_lv('適當'), '適當', null) like 'ERROR: %考核期%')::text);
  perform pg_temp.vr_eq('4 回考核期','spot_candidates 不再列出 9801','0',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw', $q$select count(*)::text from public.spot_candidates() where id = 'MI-9801'$q$, true));
  perform pg_temp.vr_eq('4 回考核期','employees_with_tenure 檢視帶出 9801 的 probation_since', pg_temp.vr_today()::text,
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select probation_since::text from public.employees_with_tenure where id = 'MI-9801'$q$, true));

  -- 作廢紅單不會倒回回考核期
  perform pg_temp.vr_ok('4 作廢不倒回','客服部作廢第 1 張紅單成功', 'vr-cs1@2motor.tw',
    format($q$select public.spot_void_ticket(%L::uuid, '測試作廢紅單')$q$, v_r1));
  perform pg_temp.vr_eq('4 作廢不倒回','紅單作廢後，回考核期紀錄仍是「待執行」、probation_since 仍在（不倒回）','待執行/' || pg_temp.vr_today()::text,
    pg_temp.vr_q1(format($q$select (select status from public.spot_probations where id = %L::uuid) || '/'
                                   || (select probation_since::text from public.employees where id = 'MI-9801')$q$, v_p1)));
  perform pg_temp.vr_eq('4 作廢不倒回','紅單作廢後，次數仍以回考核期之後計：黃 0／紅 0','0/0/待執行', pg_temp.vr_st('MI-9801'));
exception when others then
  perform pg_temp.vr_rec('區段 4','紅單與回考核期意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：跨月、跨季不累計（用擁有者身分寫入舊日期的單據）
-- ============================================================
do $$
declare
  v_today date := pg_temp.vr_today();
  v_m0 date := date_trunc('month', pg_temp.vr_today()::timestamp)::date;
  v_q0 date := date_trunc('quarter', pg_temp.vr_today()::timestamp)::date;
  j jsonb;
  i int;
  v_red text;
begin
  -- 跨月：9811 上個月有 4 張有效黃單，這個月登記不累計
  for i in 1 .. 4 loop
    perform pg_temp.vr_old_y('MI-9811', 'ZZ-K1', v_m0 - 1, now() - interval '40 days');
  end loop;
  perform pg_temp.vr_eq('5 跨月','上個月的 4 張黃單不算本月：status 黃 0','0/0/無', pg_temp.vr_st('MI-9811'));
  j := pg_temp.vr_reg('MI-9811', '不適當', '本月第1');
  perform pg_temp.vr_eq('5 跨月','上個月 4 張＋本月第 1 張，不開紅單（跨月不累計）','無', pg_temp.vr_has(j, 'red_id'));
  perform pg_temp.vr_eq('5 跨月','spot_status：本月黃 1','1/0/無', pg_temp.vr_st('MI-9811'));
  for i in 2 .. 4 loop
    j := pg_temp.vr_reg('MI-9811', '不適當', '本月第' || i);
  end loop;
  perform pg_temp.vr_eq('5 跨月','本月累積到 4 張仍不開紅單','無/0', pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_tc('MI-9811', '紅'));
  j := pg_temp.vr_reg('MI-9811', '不適當', '本月第5');
  v_red := j ->> 'red_id';
  perform pg_temp.vr_eq('5 跨月','本月滿 5 張才開紅單','有', pg_temp.vr_has(j, 'red_id'));
  perform pg_temp.vr_eq('5 跨月','這張紅單的來源 5 張黃單都是本月的（沒有混入上個月的）','5/0',
    pg_temp.vr_q1(format($q$select array_length(source_ticket_ids, 1)::text || '/'
                                   || (select count(*) from public.spot_tickets y
                                        where y.id = any(r.source_ticket_ids) and y.issued_on < %L::date)::text
                           from public.spot_tickets r where r.id = %L::uuid$q$, v_m0, v_red)));

  -- 跨季：9813 上一季有 1 張有效紅單，這一季開 1 張紅單 → 不回考核期
  perform pg_temp.vr_old_r('MI-9813', 'ZZ-K1', v_q0 - 1, now() - interval '120 days');
  perform pg_temp.vr_eq('5 跨季','上一季的紅單不算本季：status 紅 0','0/0/無', pg_temp.vr_st('MI-9813'));
  j := pg_temp.vr_n('MI-9813', 5);
  perform pg_temp.vr_eq('5 跨季','本月 5 張黃單照常開紅單，但上一季紅單不累計 → 不回考核期','有/無',
    pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('5 跨季','spot_status：本季紅 1、沒有回考核期；employees.probation_since 仍為空','0/1/無/(null)',
    pg_temp.vr_st('MI-9813') || '/' || pg_temp.vr_q1($q$select probation_since::text from public.employees where id = 'MI-9813'$q$));
  perform pg_temp.vr_eq('5 跨季','沒有為 9813 建立回考核期紀錄','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_probations where employee_id = 'MI-9813'$q$));

  -- 邊界：季初當天算本季、季初前一天不算；月初當天算本月、月初前一天不算
  perform pg_temp.vr_old_r('MI-9805', 'ZZ-K1', v_q0, now() - interval '100 days');
  perform pg_temp.vr_old_y('MI-9805', 'ZZ-K1', v_m0, now() - interval '1 day');
  perform pg_temp.vr_eq('5 邊界','季初當天的紅單算本季、月初當天的黃單算本月（紅單之後）','1/1/無', pg_temp.vr_st('MI-9805'));
  perform pg_temp.vr_old_r('MI-9802', 'ZZ-K1', v_q0 - 1, now() - interval '100 days');
  perform pg_temp.vr_old_y('MI-9802', 'ZZ-K1', v_m0 - 1, now() - interval '1 day');
  perform pg_temp.vr_eq('5 邊界','季初前一天的紅單不算本季、月初前一天的黃單不算本月','0/0/無', pg_temp.vr_st('MI-9802'));
exception when others then
  perform pg_temp.vr_rec('區段 5','跨月跨季意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：作廢（黃單、紅單）——次數即時少算、作廢不倒回、原因必填、不可重複
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  j jsonb;
  y1 text; y2 text;
  v_red text;
  v_ids text[];
begin
  -- 9814：3 張黃單，作廢 1 張
  j := pg_temp.vr_n('MI-9814', 3);
  select array_agg(id::text order by created_at) into v_ids
  from public.spot_tickets where employee_id = 'MI-9814' and kind = '黃';
  y1 := v_ids[1]; y2 := v_ids[2];

  perform pg_temp.vr_deny('6 作廢','店長不能作廢','authenticated','vr-sm1@2motor.tw',
    format($q$select public.spot_void_ticket(%L::uuid, '店長想作廢')$q$, y1), '%沒有權限%');
  perform pg_temp.vr_deny('6 作廢','總公司主管不能作廢','authenticated','vr-hq@2motor.tw',
    format($q$select public.spot_void_ticket(%L::uuid, '主管想作廢')$q$, y1), '%沒有權限%');
  perform pg_temp.vr_eq('6 作廢','被拒的作廢沒有改到單','有效', pg_temp.vr_q1(format('select status from public.spot_tickets where id = %L::uuid', y1)));

  perform pg_temp.vr_deny('6 作廢','作廢原因為 null 被拒','authenticated', cs,
    format($q$select public.spot_void_ticket(%L::uuid, null)$q$, y1), '%作廢原因不可空白%');
  perform pg_temp.vr_deny('6 作廢','作廢原因只有空白被拒','authenticated', cs,
    format($q$select public.spot_void_ticket(%L::uuid, '   ')$q$, y1), '%作廢原因不可空白%');
  perform pg_temp.vr_deny('6 作廢','作廢原因只有全形空白被拒','authenticated', cs,
    format($q$select public.spot_void_ticket(%L::uuid, %L)$q$, y1, chr(12288)), '%作廢原因不可空白%');
  perform pg_temp.vr_eq('6 作廢','原因不合格的作廢沒有生效','有效', pg_temp.vr_q1(format('select status from public.spot_tickets where id = %L::uuid', y1)));

  perform pg_temp.vr_ok('6 作廢','客服部作廢黃單（寫原因）成功', cs,
    format($q$select public.spot_void_ticket(%L::uuid, '誤登')$q$, y1));
  perform pg_temp.vr_set('tv', y1);
  perform pg_temp.vr_eq('6 作廢','作廢後欄位：狀態／原因／作廢人／作廢時間有值','作廢/誤登/vr-cs1@2motor.tw/true',
    pg_temp.vr_q1(format($q$select status || '/' || void_reason || '/' || voided_by || '/' || (voided_at is not null)::text
                           from public.spot_tickets where id = %L::uuid$q$, y1)));
  perform pg_temp.vr_eq('6 作廢','作廢不刪除：9814 仍有 3 張黃單紀錄（1 張作廢）','3/1',
    pg_temp.vr_q1($q$select count(*)::text || '/' || count(*) filter (where status = '作廢')::text
                     from public.spot_tickets where employee_id = 'MI-9814' and kind = '黃'$q$));
  perform pg_temp.vr_deny('6 作廢','已作廢的單不可再作廢','authenticated', cs,
    format($q$select public.spot_void_ticket(%L::uuid, '再作廢一次')$q$, y1), '%已作廢%');
  perform pg_temp.vr_eq('6 作廢','重複作廢被拒後，原作廢原因沒被覆蓋','誤登',
    pg_temp.vr_q1(format('select void_reason from public.spot_tickets where id = %L::uuid', y1)));

  perform pg_temp.vr_eq('6 作廢','作廢後次數即時少算：9814 黃 2','2/0/無', pg_temp.vr_st('MI-9814'));
  j := pg_temp.vr_n('MI-9814', 2);
  perform pg_temp.vr_eq('6 作廢','作廢的黃單不算：再 2 張後有效 4 張，不開紅單（若算進去就是 5 張）','無/0',
    pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_tc('MI-9814', '紅'));
  j := pg_temp.vr_reg('MI-9814', '不適當', '補足第五張');
  perform pg_temp.vr_eq('6 作廢','有效黃單湊滿 5 張才開紅單','有', pg_temp.vr_has(j, 'red_id'));
  perform pg_temp.vr_eq('6 作廢','紅單的來源只有 5 張有效黃單，不含作廢那張','5/0',
    pg_temp.vr_q1(format($q$select array_length(source_ticket_ids, 1)::text || '/'
                                   || (select count(*) from public.spot_tickets y
                                        where y.id = any(r.source_ticket_ids) and y.status = '作廢')::text
                           from public.spot_tickets r where r.id = %L::uuid$q$, j ->> 'red_id')));

  -- 9815：5 張黃單開紅單，作廢其中 1 張黃單 → 紅單不被取消；再作廢紅單 → 黃單次數回來
  j := pg_temp.vr_n('MI-9815', 5);
  v_red := j ->> 'red_id';
  select array_agg(id::text order by created_at) into v_ids
  from public.spot_tickets where employee_id = 'MI-9815' and kind = '黃';
  perform pg_temp.vr_eq('6 作廢不倒回','9815：5 張黃單開出 1 張紅單','有', pg_temp.vr_has(j, 'red_id'));
  perform pg_temp.vr_ok('6 作廢不倒回','作廢紅單的來源黃單之一', cs,
    format($q$select public.spot_void_ticket(%L::uuid, '黃單誤登')$q$, v_ids[1]));
  perform pg_temp.vr_eq('6 作廢不倒回','作廢黃單不會倒回去取消已開的紅單：紅單仍有效','有效',
    pg_temp.vr_q1(format('select status from public.spot_tickets where id = %L::uuid', v_red)));
  perform pg_temp.vr_eq('6 作廢不倒回','紅單仍在，黃單從紅單之後算：黃 0／紅 1','0/1/無', pg_temp.vr_st('MI-9815'));
  perform pg_temp.vr_ok('6 作廢不倒回','客服部作廢紅單成功', cs,
    format($q$select public.spot_void_ticket(%L::uuid, '紅單誤開')$q$, v_red));
  perform pg_temp.vr_eq('6 作廢不倒回','紅單作廢後，次數由有效單即時重算：黃 4（5 張扣掉已作廢的 1 張）、紅 0','4/0/無', pg_temp.vr_st('MI-9815'));
exception when others then
  perform pg_temp.vr_rec('區段 6','作廢意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：輔導回填（客服部、本門市店長可；他店店長、主管不可；備註必填；作廢單不可）
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  sm1 text := 'vr-sm1@2motor.tw';
  sm2 text := 'vr-sm2@2motor.tw';
  v_today date := pg_temp.vr_today();
  t1 text; t1b text; t2 text; tv text := pg_temp.vr_get('tv'); tr text := pg_temp.vr_get('r2');
begin
  select id::text into t1  from public.spot_tickets where employee_id = 'MI-9801' and kind = '黃' order by created_at limit 1;
  select id::text into t1b from public.spot_tickets where employee_id = 'MI-9801' and kind = '黃' order by created_at offset 1 limit 1;
  select id::text into t2  from public.spot_tickets where employee_id = 'MI-9822' and kind = '黃' limit 1;

  perform pg_temp.vr_deny('7 輔導','總公司主管不能回填輔導（唯讀）','authenticated','vr-hq@2motor.tw',
    format($q$select public.spot_coach(%L::uuid, current_date, '主管備註')$q$, t1), '%沒有權限%');
  perform pg_temp.vr_deny('7 輔導','他店店長（K2）不能對 K1 的單回填，只回通用訊息','authenticated', sm2,
    format($q$select public.spot_coach(%L::uuid, current_date, '他店備註')$q$, t1), '%找不到這張單據或沒有權限%');
  perform pg_temp.vr_deny('7 輔導','K1 店長不能對 K2 的單回填','authenticated', sm1,
    format($q$select public.spot_coach(%L::uuid, current_date, '他店備註')$q$, t2), '%找不到這張單據或沒有權限%');
  perform pg_temp.vr_eq('7 輔導','被拒的回填沒有改到單（K1 的單輔導欄位仍為空）','(null)',
    pg_temp.vr_q1(format('select coach_note from public.spot_tickets where id = %L::uuid', t1)));

  perform pg_temp.vr_ok('7 輔導','客服部回填輔導成功', cs,
    format($q$select public.spot_coach(%L::uuid, %L::date, '客服部輔導內容')$q$, t1, v_today::text));
  perform pg_temp.vr_eq('7 輔導','輔導欄位：日期／備註／回填人','true/客服部輔導內容/vr-cs1@2motor.tw',
    pg_temp.vr_q1(format($q$select (coached_on = %L::date)::text || '/' || coach_note || '/' || coached_by
                           from public.spot_tickets where id = %L::uuid$q$, v_today::text, t1)));
  perform pg_temp.vr_eq('7 輔導','回填輔導不改單的狀態與次數','有效', pg_temp.vr_q1(format('select status from public.spot_tickets where id = %L::uuid', t1)));
  perform pg_temp.vr_ok('7 輔導','本門市店長（K1）回填輔導成功', sm1,
    format($q$select public.spot_coach(%L::uuid, %L::date, '店長輔導內容')$q$, t1b, v_today::text));
  perform pg_temp.vr_eq('7 輔導','店長回填：回填人是店長信箱','店長輔導內容/vr-sm1@2motor.tw',
    pg_temp.vr_q1(format('select coach_note || ''/'' || coached_by from public.spot_tickets where id = %L::uuid', t1b)));
  perform pg_temp.vr_ok('7 輔導','K2 店長可對 K2 的單回填', sm2,
    format($q$select public.spot_coach(%L::uuid, %L::date, 'K2 店長輔導')$q$, t2, v_today::text));
  perform pg_temp.vr_ok('7 輔導','客服部也可以對紅單回填輔導', cs,
    format($q$select public.spot_coach(%L::uuid, %L::date, '紅單輔導')$q$, tr, v_today::text));

  perform pg_temp.vr_deny('7 輔導','備註為 null 被拒','authenticated', cs,
    format($q$select public.spot_coach(%L::uuid, current_date, null)$q$, t1), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('7 輔導','備註只有空白被拒','authenticated', cs,
    format($q$select public.spot_coach(%L::uuid, current_date, '   ')$q$, t1), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('7 輔導','備註只有全形空白被拒（店長）','authenticated', sm1,
    format($q$select public.spot_coach(%L::uuid, current_date, %L)$q$, t1, chr(12288)), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('7 輔導','輔導日期為空被拒','authenticated', cs,
    format($q$select public.spot_coach(%L::uuid, null, '有備註')$q$, t1), '%輔導日期不可空白%');
  perform pg_temp.vr_eq('7 輔導','被拒後原備註沒被覆蓋','客服部輔導內容',
    pg_temp.vr_q1(format('select coach_note from public.spot_tickets where id = %L::uuid', t1)));
  perform pg_temp.vr_deny('7 輔導','作廢的單不能回填輔導（客服部）','authenticated', cs,
    format($q$select public.spot_coach(%L::uuid, current_date, '想補輔導')$q$, tv), '%作廢的單不能回填%');
  perform pg_temp.vr_deny('7 輔導','作廢的單不能回填輔導（本門市店長）','authenticated', sm1,
    format($q$select public.spot_coach(%L::uuid, current_date, '想補輔導')$q$, tv), '%作廢的單不能回填%');
  perform pg_temp.vr_eq('7 輔導','作廢單的輔導欄位仍為空','(null)',
    pg_temp.vr_q1(format('select coach_note from public.spot_tickets where id = %L::uuid', tv)));
  perform pg_temp.vr_ok('7 輔導','已回填的單可以重填修改（客服部）', cs,
    format($q$select public.spot_coach(%L::uuid, %L::date, '修改後的輔導內容')$q$, t1, v_today::text));
  perform pg_temp.vr_eq('7 輔導','重填後備註已更新','修改後的輔導內容',
    pg_temp.vr_q1(format('select coach_note from public.spot_tickets where id = %L::uuid', t1)));
exception when others then
  perform pg_temp.vr_rec('區段 7','輔導回填意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 8：標記已執行、取消回考核期
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  v_today date := pg_temp.vr_today();
  p1 text := pg_temp.vr_get('p1');
  j jsonb;
  p2 text;
begin
  -- 9801 的回考核期（待執行）
  perform pg_temp.vr_deny('8 標記已執行','總公司主管不能標記已執行','authenticated','vr-hq@2motor.tw',
    format($q$select public.spot_mark_executed(%L::uuid)$q$, p1), '%沒有權限%');
  perform pg_temp.vr_deny('8 標記已執行','店長不能標記已執行','authenticated','vr-sm1@2motor.tw',
    format($q$select public.spot_mark_executed(%L::uuid)$q$, p1), '%沒有權限%');
  perform pg_temp.vr_eq('8 標記已執行','被拒後狀態仍是待執行','待執行', pg_temp.vr_q1(format('select status from public.spot_probations where id = %L::uuid', p1)));
  perform pg_temp.vr_ok('8 標記已執行','客服部標記已執行成功', cs, format($q$select public.spot_mark_executed(%L::uuid)$q$, p1));
  perform pg_temp.vr_eq('8 標記已執行','狀態改已執行，記日期（台北今天）與人','已執行/' || v_today::text || '/vr-cs1@2motor.tw',
    pg_temp.vr_q1(format($q$select status || '/' || executed_on::text || '/' || executed_by from public.spot_probations where id = %L::uuid$q$, p1)));
  perform pg_temp.vr_deny('8 標記已執行','已執行的不能再標記','authenticated', cs,
    format($q$select public.spot_mark_executed(%L::uuid)$q$, p1), '%待執行%');
  perform pg_temp.vr_eq('8 標記已執行','spot_status：回考核期狀態顯示已執行（紅單回考核期後重算為 0）','0/0/已執行', pg_temp.vr_st('MI-9801'));
  perform pg_temp.vr_eq('8 標記已執行','標記已執行不動 probation_since（仍在考核期）', v_today::text,
    pg_temp.vr_q1($q$select probation_since::text from public.employees where id = 'MI-9801'$q$));

  perform pg_temp.vr_deny('8 取消','總公司主管不能取消回考核期','authenticated','vr-hq@2motor.tw',
    format($q$select public.spot_cancel_probation(%L::uuid, '主管想取消')$q$, p1), '%沒有權限%');
  perform pg_temp.vr_deny('8 取消','店長不能取消回考核期','authenticated','vr-sm1@2motor.tw',
    format($q$select public.spot_cancel_probation(%L::uuid, '店長想取消')$q$, p1), '%沒有權限%');

  -- 9812：另造一筆回考核期（10 張黃單 → 2 張紅單）用來測取消
  j := pg_temp.vr_n('MI-9812', 10);
  p2 := j ->> 'probation_id';
  perform pg_temp.vr_eq('8 取消','9812：10 張黃單開出 2 張紅單與 1 筆回考核期（待執行）','有/2/待執行',
    pg_temp.vr_has(j, 'probation_id') || '/' || pg_temp.vr_tc('MI-9812', '紅') || '/'
    || pg_temp.vr_q1(format('select status from public.spot_probations where id = %L::uuid', p2)));
  perform pg_temp.vr_deny('8 取消','取消原因為 null 被拒','authenticated', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, null)$q$, p2), '%取消原因不可空白%');
  perform pg_temp.vr_deny('8 取消','取消原因只有空白被拒','authenticated', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, '  ')$q$, p2), '%取消原因不可空白%');
  perform pg_temp.vr_eq('8 取消','原因不合格的取消沒有生效：仍待執行、probation_since 仍在','待執行/' || v_today::text,
    pg_temp.vr_q1(format($q$select (select status from public.spot_probations where id = %L::uuid) || '/'
                                   || (select probation_since::text from public.employees where id = 'MI-9812')$q$, p2)));
  perform pg_temp.vr_ok('8 取消','客服部取消回考核期（待執行）成功', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, '誤判，取消')$q$, p2));
  perform pg_temp.vr_eq('8 取消','取消後：狀態已取消、原因有記、probation_since 清除','已取消/誤判，取消/(null)',
    pg_temp.vr_q1(format($q$select (select status || '/' || cancel_reason from public.spot_probations where id = %L::uuid) || '/'
                                   || coalesce((select probation_since::text from public.employees where id = 'MI-9812'), '(null)')$q$, p2)));
  perform pg_temp.vr_deny('8 取消','已取消的不能再取消','authenticated', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, '再取消')$q$, p2), '%已經取消%');
  perform pg_temp.vr_deny('8 取消','已取消的不能標記已執行','authenticated', cs,
    format($q$select public.spot_mark_executed(%L::uuid)$q$, p2), '%待執行%');
  perform pg_temp.vr_eq('8 取消','取消回考核期不會作廢紅單：9812 仍有 2 張有效紅單','2', pg_temp.vr_tc('MI-9812', '紅'));
  perform pg_temp.vr_eq('8 取消','取消後 spot_status：不再有進行中的回考核期；紅單計數仍從回考核期之後算（紅 0、黃 0）','0/0/無', pg_temp.vr_st('MI-9812'));
  perform pg_temp.vr_eq('8 取消','取消後 9812 回到抽查名單','1',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.spot_candidates() where id = 'MI-9812'$q$, true));
  perform pg_temp.vr_eq('8 取消','取消後 9812 又可以被抽查','有',
    pg_temp.vr_has(pg_temp.vr_reg('MI-9812', '適當'), 'inspection_id'));

  -- 回考核期發生後紅單重新從 0 算：9812 已取消過一次回考核期，同一季再開 1 張紅單不會立刻再開回考核期，再開第 2 張才會
  j := pg_temp.vr_n('MI-9812', 4);
  perform pg_temp.vr_eq('8 重算','9812 取消後再累積 4 張黃單：不開紅單','無', pg_temp.vr_has(j, 'red_id'));
  j := pg_temp.vr_reg('MI-9812', '不適當', '取消後第五張');
  perform pg_temp.vr_eq('8 重算','取消回考核期後同季再開第 3 張紅單：開紅單，但不會立刻再開回考核期','有/無',
    pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('8 重算','本季有效紅單共 3 張，但回考核期之後只算 1 張：status 黃 0／紅 1／無回考核期','3/0/1/無',
    pg_temp.vr_tc('MI-9812', '紅') || '/' || split_part(pg_temp.vr_st('MI-9812'), '/', 1) || '/'
    || split_part(pg_temp.vr_st('MI-9812'), '/', 2) || '/' || split_part(pg_temp.vr_st('MI-9812'), '/', 3));
  perform pg_temp.vr_eq('8 重算','9812 目前只有最早那 1 筆（已取消）回考核期紀錄','1',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_probations where employee_id = 'MI-9812'$q$));
  j := pg_temp.vr_n('MI-9812', 4);
  perform pg_temp.vr_eq('8 重算','再累積 4 張黃單：不開紅單','無', pg_temp.vr_has(j, 'red_id'));
  j := pg_temp.vr_reg('MI-9812', '不適當', '再第五張');
  perform pg_temp.vr_eq('8 重算','回考核期之後第 2 張紅單：開紅單，並再開回考核期','有/有',
    pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('8 重算','新的回考核期只含回考核期之後的 2 張紅單（不含取消前的舊紅單）','2/0',
    pg_temp.vr_q1(format($q$select array_length(p.red_ticket_ids, 1)::text || '/'
                                   || (select count(*) from public.spot_tickets o
                                        where o.id = any(p.red_ticket_ids)
                                          and o.created_at < (select created_at from public.spot_probations where id = %L::uuid))::text
                           from public.spot_probations p where p.id = %L::uuid$q$, p2, j ->> 'probation_id')));
  perform pg_temp.vr_eq('8 重算','新的回考核期開出後：待執行、紅單重新從 0 算、probation_since 重新設定','0/0/待執行/' || v_today::text,
    pg_temp.vr_st('MI-9812') || '/' || pg_temp.vr_q1($q$select probation_since::text from public.employees where id = 'MI-9812'$q$));

  -- 9801：已執行也可以取消
  perform pg_temp.vr_ok('8 取消','已執行的回考核期也可以取消（客服部）', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, '已執行後發現誤判')$q$, p1));
  perform pg_temp.vr_eq('8 取消','9801 取消後：狀態已取消、probation_since 清除；已執行的日期紀錄保留','已取消/(null)/' || v_today::text,
    pg_temp.vr_q1(format($q$select (select status from public.spot_probations where id = %L::uuid) || '/'
                                   || coalesce((select probation_since::text from public.employees where id = 'MI-9801'), '(null)') || '/'
                                   || (select executed_on::text from public.spot_probations where id = %L::uuid)$q$, p1, p1)));
exception when others then
  perform pg_temp.vr_rec('區段 8','標記與取消意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 9：與考核串接（assess_start／assess_submit）與既有行為不變
-- 前置：假題庫（questions）；考核期的人用擁有者身分直接造「回考核期紀錄＋probation_since」；
-- 考核流程以客服部身分真的呼叫 assess_start → assess_draw → assess_save_item → assess_submit → assess_void。
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  v_today date := pg_temp.vr_today();
  a uuid; a2 uuid; a3 uuid;
  j jsonb;
  v_p text;
  lv85 jsonb := pg_temp.vr_mk('待加強','優','優','優','優','優','良');   -- 20×40% + 其餘 + 10×70% → 85.0
  lv835 jsonb := pg_temp.vr_mk('待加強','良','優','優','優','優','優');  -- 83.5
  lv100 jsonb := pg_temp.vr_mk('優','優','優','優','優','優','優');
  lv70 jsonb := pg_temp.vr_mk('良','良','良','良','良','良','良');
begin
  insert into public.questions (category, code, title, steps) values
    ('ZZ分類K', 'K1', '假題組K1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類K', 'K2', '假題組K2', '[{"action":"動作1","point":"考點1"}]'::jsonb);

  -- 造考核期：9810（待執行）、9816（待執行）、9820（新人，待執行）、9821（未填到職日，已執行）
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9810', '假員9810', 'ZZ-K1', '{}'::uuid[], v_today, '待執行'),
         ('MI-9816', '假員9816', 'ZZ-K1', '{}'::uuid[], v_today, '待執行'),
         ('MI-9820', '假員9820', 'ZZ-K1', '{}'::uuid[], v_today, '待執行');
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status, executed_on, executed_by)
  values ('MI-9821', '假員9821', 'ZZ-K1', '{}'::uuid[], v_today, '已執行', v_today, cs);
  update public.employees set probation_since = v_today where id in ('MI-9810', 'MI-9816', 'MI-9820', 'MI-9821');

  -- ===== 9810：考核期、剛好 85.0 通過 =====
  a := pg_temp.vr_flow('MI-9810', null, lv85);
  perform pg_temp.vr_set('a9810', a::text);
  perform pg_temp.vr_eq('9 串接','考核期的人 assess_start：身分「正式」、來源「考核期」、到職日快照照存','正式/考核期/true/draft',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source || '/' || (hire_date_snapshot = %L::date)::text || '/' || status
                           from public.assessments where id = %L::uuid$q$, (v_today - 300)::text, a)));
  perform pg_temp.vr_eq('9 串接','同考官對同員工再 assess_start：回傳同一張草稿（原有行為）', a::text,
    pg_temp.vr_as('authenticated', cs, $q$select public.assess_start('MI-9810', null)::text$q$, true));
  perform pg_temp.vr_eq('9 串接','考核期送出前：probation_since 仍在、回考核期仍待執行','true/待執行',
    pg_temp.vr_q1($q$select (select (probation_since is not null)::text from public.employees where id = 'MI-9810') || '/'
                           || (select status from public.spot_probations where employee_id = 'MI-9810')$q$));
  perform pg_temp.vr_eq('9 串接','考核期送出總分剛好 85.0：判定及格、合格線 85（正式標準）','85.0/及格/85', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('9 串接','總分 >= 85：probation_since 清除','(null)',
    pg_temp.vr_q1($q$select probation_since::text from public.employees where id = 'MI-9810'$q$));
  perform pg_temp.vr_eq('9 串接','總分 >= 85：回考核期紀錄改「已通過」並記下通過的成績單','已通過/true',
    pg_temp.vr_q1(format($q$select status || '/' || (passed_assessment_id = %L::uuid)::text
                           from public.spot_probations where employee_id = 'MI-9810'$q$, a)));
  perform pg_temp.vr_eq('9 串接','成績單檢視 assessment_summaries 帶出 tenure_source「考核期」','考核期/正式',
    pg_temp.vr_as('authenticated', cs,
      format($q$select tenure_source || '/' || tenure from public.assessment_summaries where id = %L::uuid$q$, a), true));
  perform pg_temp.vr_eq('9 串接','通過後 9810 回到抽查名單','1',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.spot_candidates() where id = 'MI-9810'$q$, true));
  perform pg_temp.vr_ok('9 串接','作廢該張成績單（assess_void）成功', cs,
    format($q$select public.assess_void(%L::uuid, '假作廢')$q$, a));
  perform pg_temp.vr_eq('9 串接','作廢成績單不倒回已通過的考核期：probation_since 仍為空、紀錄仍已通過','(null)/已通過',
    pg_temp.vr_q1($q$select coalesce((select probation_since::text from public.employees where id = 'MI-9810'), '(null)') || '/'
                           || (select status from public.spot_probations where employee_id = 'MI-9810')$q$));
  perform pg_temp.vr_deny('9 串接','已通過的回考核期不可取消','authenticated', cs,
    format($q$select public.spot_cancel_probation(%L::uuid, '想取消')$q$,
           pg_temp.vr_q1($q$select id::text from public.spot_probations where employee_id = 'MI-9810'$q$)),
    '%已通過%');
  perform pg_temp.vr_eq('9 串接','已通過的紀錄被拒取消後仍是已通過','已通過',
    pg_temp.vr_q1($q$select status from public.spot_probations where employee_id = 'MI-9810'$q$));

  -- 考核期通過後同季再開紅單：同樣從 0 重算（已通過的回考核期也算「最近一筆回考核期紀錄」）
  j := pg_temp.vr_n('MI-9810', 5);
  perform pg_temp.vr_eq('9 重算','9810 通過後同季再開第 1 張紅單：不會立刻再開回考核期；紅單計 1','有/無/0/1/無',
    pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id') || '/' || pg_temp.vr_st('MI-9810'));
  j := pg_temp.vr_n('MI-9810', 5);
  perform pg_temp.vr_eq('9 重算','9810 通過後同季再開第 2 張紅單：才再開回考核期，紅單重算為 0','有/有/0/0/待執行',
    pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id') || '/' || pg_temp.vr_st('MI-9810'));

  -- ===== 9816：考核期、83.5 沒過 =====
  a := pg_temp.vr_flow('MI-9816', null, lv835);
  perform pg_temp.vr_eq('9 串接','考核期送出 83.5：判定需複訓、合格線 85（正式標準）','83.5/需複訓/85', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('9 串接','總分 < 85：維持考核期（probation_since 仍在、回考核期仍待執行）', v_today::text || '/待執行',
    pg_temp.vr_q1($q$select (select probation_since::text from public.employees where id = 'MI-9816') || '/'
                           || (select status from public.spot_probations where employee_id = 'MI-9816')$q$));
  perform pg_temp.vr_eq('9 串接','沒過之後仍不在抽查名單、spot_status 顯示待執行','0/0/待執行', pg_temp.vr_st('MI-9816'));
  perform pg_temp.vr_eq('9 串接','沒過之後仍不在抽查名單','0',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.spot_candidates() where id = 'MI-9816'$q$, true));
  a2 := pg_temp.vr_flow('MI-9816', null, lv85);
  perform pg_temp.vr_eq('9 串接','沒過後再考一次：仍是「正式／考核期」','正式/考核期',
    pg_temp.vr_q1(format('select tenure || ''/'' || tenure_source from public.assessments where id = %L::uuid', a2)));
  perform pg_temp.vr_eq('9 串接','再考一次 85.0 過關','85.0/及格/85', pg_temp.vr_submit(a2));
  perform pg_temp.vr_eq('9 串接','補考通過：probation_since 清除、紀錄已通過','(null)/已通過',
    pg_temp.vr_q1($q$select coalesce((select probation_since::text from public.employees where id = 'MI-9816'), '(null)') || '/'
                           || (select status from public.spot_probations where employee_id = 'MI-9816')$q$));

  -- ===== 9820：新人且考核期 → 仍用正式標準 =====
  perform pg_temp.vr_eq('9 串接','新人但在考核期：assess_start 忽略到職日與指定值，身分「正式」、來源「考核期」','正式/考核期',
    pg_temp.vr_q1(format('select tenure || ''/'' || tenure_source from public.assessments where id = %L::uuid',
      pg_temp.vr_as('authenticated', cs, $q$select public.assess_start('MI-9820', '新人')::text$q$, true))));
  perform pg_temp.vr_eq('9 串接','新人但在考核期：spot_status 仍列出（考核期人員）','有',
    case when pg_temp.vr_as('authenticated', cs,
         $q$select count(*)::text from public.spot_status() where employee_id = 'MI-9820'$q$, true) = '1' then '有' else '無' end);

  -- ===== 9821：未填到職日 + 考核期（已執行）→ 不需手動指定；100 分通過，已執行也改已通過 =====
  a := pg_temp.vr_flow('MI-9821', null, lv100);
  perform pg_temp.vr_eq('9 串接','未填到職日但在考核期：不需手動指定，來源「考核期」','正式/考核期/(null)',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source || '/' || coalesce(hire_date_snapshot::text, '(null)')
                            from public.assessments where id = %L::uuid$q$, a)));
  perform pg_temp.vr_eq('9 串接','考核期送出 100 分：優秀、合格線 85','100.0/優秀/85', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('9 串接','「已執行」的回考核期通過後也改已通過、probation_since 清除','已通過/(null)',
    pg_temp.vr_q1($q$select (select status from public.spot_probations where employee_id = 'MI-9821') || '/'
                           || coalesce((select probation_since::text from public.employees where id = 'MI-9821'), '(null)')$q$));

  -- ===== 既有行為不變：一般正式 9817 =====
  a := pg_temp.vr_flow('MI-9817', null, lv85);
  perform pg_temp.vr_eq('9 既有','一般正式員工：assess_start 仍是「正式／自動」','正式/自動/true',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source || '/' || (hire_date_snapshot = %L::date)::text
                            from public.assessments where id = %L::uuid$q$, (v_today - 200)::text, a)));
  perform pg_temp.vr_eq('9 既有','一般正式員工送出 85.0：及格、合格線 85（與串接前一致）','85.0/及格/85', pg_temp.vr_submit(a));
  a2 := pg_temp.vr_flow('MI-9817', null, lv835);
  perform pg_temp.vr_eq('9 既有','一般正式員工送出 83.5：需複訓、合格線 85','83.5/需複訓/85', pg_temp.vr_submit(a2));
  perform pg_temp.vr_eq('9 既有','一般員工送出考核不碰考核期：沒有回考核期紀錄、probation_since 為空','0/(null)',
    pg_temp.vr_q1($q$select (select count(*) from public.spot_probations where employee_id = 'MI-9817')::text || '/'
                           || coalesce((select probation_since::text from public.employees where id = 'MI-9817'), '(null)')$q$));

  -- ===== 既有行為不變：新人 9818 =====
  a := pg_temp.vr_flow('MI-9818', null, lv70);
  perform pg_temp.vr_eq('9 既有','新人：assess_start 仍是「新人／自動」','新人/自動',
    pg_temp.vr_q1(format('select tenure || ''/'' || tenure_source from public.assessments where id = %L::uuid', a)));
  perform pg_temp.vr_eq('9 既有','新人送出 70.0：及格、合格線 70（與串接前一致）','70.0/及格/70', pg_temp.vr_submit(a));

  -- ===== 既有行為不變：未填到職日 9819 =====
  perform pg_temp.vr_deny('9 既有','未填到職日、沒指定身分：照舊報錯','authenticated', cs,
    $q$select public.assess_start('MI-9819', null)$q$, '%到職日空白%');
  perform pg_temp.vr_deny('9 既有','未填到職日、指定值不是新人／正式：照舊報錯','authenticated', cs,
    $q$select public.assess_start('MI-9819', '亂指定')$q$, '%到職日空白%');
  perform pg_temp.vr_eq('9 既有','未填到職日、手動指定「正式」：身分正式、來源「手動指定」','正式/手動指定',
    pg_temp.vr_q1(format('select tenure || ''/'' || tenure_source from public.assessments where id = %L::uuid',
      pg_temp.vr_as('authenticated', cs, $q$select public.assess_start('MI-9819', '正式')::text$q$, true))));

  -- ===== 既有行為不變：其他檢查 =====
  perform pg_temp.vr_deny('9 既有','不納入考核的員工：照舊報「不在考核名單」','authenticated', cs,
    $q$select public.assess_start('MI-9806', '正式')$q$, '%不在考核名單%');
  perform pg_temp.vr_deny('9 既有','不存在的員工：照舊報「找不到員工」','authenticated', cs,
    $q$select public.assess_start('MI-0000', '正式')$q$, '%找不到員工%');
  perform pg_temp.vr_denyset('9 既有','assess_start', $q$select public.assess_start('MI-9817', null)$q$, 'hsna');
  perform pg_temp.vr_denyset('9 既有','assess_submit', $q$select * from public.assess_submit('00000000-0000-0000-0000-000000000000'::uuid)$q$, 'hsna');
  perform pg_temp.vr_deny('9 既有','assess_submit：找不到的考核照舊報錯','authenticated', cs,
    $q$select * from public.assess_submit('00000000-0000-0000-0000-000000000000'::uuid)$q$, '%找不到考核%');
exception when others then
  perform pg_temp.vr_rec('區段 9','考核串接意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 10：資料表可見範圍（RLS）與直接寫入被拒
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  hq text := 'vr-hq@2motor.tw';
  sm1 text := 'vr-sm1@2motor.tw';
  sm2 text := 'vr-sm2@2motor.tw';
  nb text := 'vr-nobody@2motor.tw';
  t text;
  v_before text;
begin
  -- K2 也要有一筆回考核期資料，才能證明店長只看自己門市
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9809', '假員9809', 'ZZ-K2', '{}'::uuid[], pg_temp.vr_today(), '待執行');

  foreach t in array array['spot_inspections', 'spot_tickets', 'spot_probations'] loop
    perform pg_temp.vr_cmp('10 可見範圍', t || '：客服部看到全部（假資料）', 'authenticated', cs,
      format($q$select count(*)::text from public.%I where store_code like 'ZZ-K%%'$q$, t),
      format($q$select count(*)::text from public.%I where store_code like 'ZZ-K%%'$q$, t));
    perform pg_temp.vr_cmp('10 可見範圍', t || '：總公司主管看到全部（假資料）', 'authenticated', hq,
      format($q$select count(*)::text from public.%I where store_code like 'ZZ-K%%'$q$, t),
      format($q$select count(*)::text from public.%I where store_code like 'ZZ-K%%'$q$, t));
    perform pg_temp.vr_cmp('10 可見範圍', t || '：店長 K1 只看到自己門市（沒有加條件也只有 K1）', 'authenticated', sm1,
      format('select count(*)::text from public.%I', t),
      format($q$select count(*)::text from public.%I where store_code = 'ZZ-K1'$q$, t));
    perform pg_temp.vr_cmp('10 可見範圍', t || '：店長 K2 只看到自己門市', 'authenticated', sm2,
      format('select count(*)::text from public.%I', t),
      format($q$select count(*)::text from public.%I where store_code = 'ZZ-K2'$q$, t));
    perform pg_temp.vr_eq('10 可見範圍', t || '：K1 與 K2 都有資料（上面的比對不是空轉）', 'true',
      pg_temp.vr_q1(format($q$select ((select count(*) from public.%I where store_code = 'ZZ-K1') > 0
                                  and (select count(*) from public.%I where store_code = 'ZZ-K2') > 0)::text$q$, t, t)));
    perform pg_temp.vr_eq('10 可見範圍', t || '：有登入但未開通帳號什麼都看不到', '0',
      pg_temp.vr_as('authenticated', nb, format('select count(*)::text from public.%I', t), true));
    perform pg_temp.vr_deny('10 可見範圍', t || '：未登入（anon）讀取被拒', 'anon', null,
      format('select count(*) from public.%I', t), '%permission denied%');
  end loop;

  perform pg_temp.vr_eq('10 可見範圍','店長看得到作廢的單（規格：店長看自己門市全部單據）','true',
    pg_temp.vr_as('authenticated', sm1,
      format($q$select (count(*) = 1)::text from public.spot_tickets where id = %L::uuid$q$, pg_temp.vr_get('tv')), true));
  perform pg_temp.vr_eq('10 可見範圍','店長 K2 看不到 K1 的單（以單號直接查也是 0 筆）','0',
    pg_temp.vr_as('authenticated', sm2,
      format($q$select count(*)::text from public.spot_tickets where id = %L::uuid$q$, pg_temp.vr_get('tv')), true));

  -- 直接寫入一律被拒（含客服部）
  v_before := pg_temp.vr_q1($q$select (select count(*) from public.spot_tickets)::text || '/'
                                   || (select count(*) from public.spot_inspections)::text || '/'
                                   || (select count(*) from public.spot_probations)::text$q$);

  foreach t in array array['spot_inspections', 'spot_tickets', 'spot_probations'] loop
    perform pg_temp.vr_deny('10 直接寫入', t || '：客服部直接 update 被拒', 'authenticated', cs,
      format($q$update public.%I set store_code = store_code$q$, t), '%permission denied%');
    perform pg_temp.vr_deny('10 直接寫入', t || '：客服部直接 delete 被拒', 'authenticated', cs,
      format('delete from public.%I', t), '%permission denied%');
  end loop;

  perform pg_temp.vr_deny('10 直接寫入','spot_inspections：客服部直接 insert 被拒','authenticated', cs,
    $q$insert into public.spot_inspections (employee_id, employee_label, store_code, checked_on, levels, total_score, verdict, examiner_email)
       values ('MI-9801', 'x', 'ZZ-K1', current_date, '{}'::jsonb, 50, '適當', 'vr-cs1@2motor.tw')$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_tickets：客服部直接 insert 被拒','authenticated', cs,
    $q$insert into public.spot_tickets (kind, employee_id, employee_label, store_code, source_ticket_ids, issued_on)
       values ('紅', 'MI-9801', 'x', 'ZZ-K1', '{}'::uuid[], current_date)$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_probations：客服部直接 insert 被拒','authenticated', cs,
    $q$insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on)
       values ('MI-9801', 'x', 'ZZ-K1', '{}'::uuid[], current_date)$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_tickets：總公司主管直接 update 被拒','authenticated', hq,
    $q$update public.spot_tickets set status = '作廢'$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_tickets：店長直接 update 被拒（想自己改輔導欄位）','authenticated', sm1,
    $q$update public.spot_tickets set coach_note = '偷改'$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_probations：店長直接 insert 被拒','authenticated', sm1,
    $q$insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on)
       values ('MI-9801', 'x', 'ZZ-K1', '{}'::uuid[], current_date)$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_inspections：店長直接 delete 被拒','authenticated', sm1,
    'delete from public.spot_inspections', '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_tickets：有登入但未開通帳號直接 insert 被拒','authenticated', nb,
    $q$insert into public.spot_tickets (kind, employee_id, employee_label, store_code, source_ticket_ids, issued_on)
       values ('紅', 'MI-9801', 'x', 'ZZ-K1', '{}'::uuid[], current_date)$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_tickets：未登入（anon）直接 insert 被拒','anon', null,
    $q$insert into public.spot_tickets (kind, employee_id, employee_label, store_code, source_ticket_ids, issued_on)
       values ('紅', 'MI-9801', 'x', 'ZZ-K1', '{}'::uuid[], current_date)$q$, '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_inspections：未登入（anon）直接 delete 被拒','anon', null,
    'delete from public.spot_inspections', '%permission denied%');
  perform pg_temp.vr_deny('10 直接寫入','spot_probations：未登入（anon）直接 update 被拒','anon', null,
    $q$update public.spot_probations set status = '已取消'$q$, '%permission denied%');

  perform pg_temp.vr_eq('10 直接寫入','所有被拒的寫入都沒有改到任何一筆資料（三張表筆數不變）', v_before,
    pg_temp.vr_q1($q$select (select count(*) from public.spot_tickets)::text || '/'
                           || (select count(*) from public.spot_inspections)::text || '/'
                           || (select count(*) from public.spot_probations)::text$q$));
exception when others then
  perform pg_temp.vr_rec('區段 10','可見範圍意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 11：資料完整性與並發保護（靜態確認）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('11 完整性','所有黃單都連到一筆抽查、都沒有來源黃單；所有紅單都沒有抽查連結（約束生效）','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_tickets
                     where (kind = '黃' and (inspection_id is null or source_ticket_ids is not null))
                        or (kind = '紅' and (inspection_id is not null or source_ticket_ids is null))$q$));
  perform pg_temp.vr_ownerr('11 完整性','約束：黃單不能沒有抽查連結（擁有者直接寫入也被擋）',
    $q$insert into public.spot_tickets (kind, employee_id, employee_label, store_code, issued_on)
       values ('黃', 'MI-9801', 'x', 'ZZ-K1', current_date)$q$, '%spot_tickets_kind_fields%');
  perform pg_temp.vr_ownerr('11 完整性','約束：判定不適當的抽查必須有原因（擁有者直接寫入也被擋）',
    $q$insert into public.spot_inspections (employee_id, employee_label, store_code, checked_on, levels, total_score, verdict, examiner_email)
       values ('MI-9801', 'x', 'ZZ-K1', current_date, '{}'::jsonb, 50, '不適當', 'vr-cs1@2motor.tw')$q$,
    '%spot_inspections_reason_required%');
  perform pg_temp.vr_eq('11 完整性','所有作廢的單都有原因、作廢人、作廢時間；有效的單都沒有作廢資料','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_tickets
                     where (status = '作廢' and (nullif(btrim(void_reason), '') is null or voided_by is null or voided_at is null))
                        or (status = '有效' and (void_reason is not null or voided_by is not null or voided_at is not null))$q$));
  perform pg_temp.vr_eq('11 並發保護','靜態確認：登記、作廢、標記已執行、取消回考核期四個函式都先 for update 鎖員工列','4',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.proname in ('spot_register','spot_void_ticket','spot_mark_executed','spot_cancel_probation')
                       and p.prosrc like '%from public.employees%for update%'$q$));
  perform pg_temp.vr_rec('11 並發保護','說明（單一連線無法實測）',
    '文字說明',
    '同一人的並發登記會在「select … from employees … for update」排隊，第二個請求看到第一個已提交的黃單／紅單後才計數，不會重複開紅單或回考核期；請另開兩個連線手動對同一人同時登記以實證',
    true);
exception when others then
  perform pg_temp.vr_rec('區段 11','完整性意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate spotcheck_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare spotcheck_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_ok = v_total then ''
                                   else '；未通過：' || (select string_agg(n::text, '、' order by n) from pg_temp.vr where not pass) end)
          || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate spotcheck_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare spotcheck_vr_out as select '
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
execute spotcheck_vr_out;
