-- ============================================================
-- 業務考核系統：階段 3 考核後台（改善單）驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 backoffice_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw，符合 accounts 網域檢查）／假成績單，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。
--   假成績單以資料庫擁有者身分直接建立 draft，再 UPDATE 成 submitted 來觸發自動開單，不依賴 assess_submit。
-- 怎麼看結果：
--   * 因為 SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     腳本在 rollback 之前把結果表存成「預備陳述式 backoffice_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- 假門市代碼 ZZ-B1／ZZ-B2、假員工編號 MI-9701～MI-9704、假信箱 vr-cs1／vr-hq／vr-sm1／vr-sm2@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 注意：同一個交易內 now() 是固定值，所以「複檢成績單的送出時間」以明確的時間戳記
--   （開單後 1 小時、開單前 1 天）直接寫入來測，不靠等待。
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
  if to_regclass('public.improvement_tickets') is null
     or to_regclass('public.improvement_ticket_view') is null
     or to_regclass('public.analytics_dim_rates') is null then
    raise exception '請先執行 backoffice_schema.sql';
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

-- 組出七面向評分物件
create or replace function pg_temp.vr_mk(a text, b text, c text, d text, e text, f text, g text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('資訊正確性', a, '預設訊息運用', b, '問題掌握', c, '主動引導', d,
                            '風險意識', e, '語氣與禮貌', f, '文字品質', g);
$$;

-- 直接寫入一張成績單（以資料庫擁有者身分；INSERT 不會觸發本次的 AFTER UPDATE 觸發器）。
-- p_status = 'draft' 時忽略判定與時間；'voided' 會補上作廢欄位。
create or replace function pg_temp.vr_ins(p_emp text, p_store text, p_status text, p_verdict text,
                                          p_weak text[], p_at timestamptz)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
     total_score, verdict, pass_line, weakest_dims, submitted_at, voided_at, voided_by, void_reason)
  values
    (p_emp, '假考生' || right(p_emp, 4), p_store, 'vr-cs1@2motor.tw', p_status, '正式', '自動',
     case when p_status = 'draft' then null else 80 end,
     case when p_status = 'draft' then null else p_verdict end,
     case when p_status = 'draft' then null else 85 end,
     case when p_status = 'draft' then null else p_weak end,
     case when p_status = 'draft' then null else p_at end,
     case when p_status = 'voided' then now() end,
     case when p_status = 'voided' then 'vr-cs1@2motor.tw' end,
     case when p_status = 'voided' then '假作廢' end)
  returning id into v_id;
  return v_id;
end $$;

-- 把草稿 UPDATE 成已送出（會觸發自動開單）
create or replace function pg_temp.vr_sub(p_id uuid, p_verdict text, p_weak text[])
returns void language plpgsql as $$
begin
  update public.assessments
     set status = 'submitted',
         total_score = case p_verdict when '優秀' then 96 when '及格' then 88 when '需複訓' then 80 else 50 end,
         verdict = p_verdict,
         pass_line = 85,
         weakest_dims = p_weak,
         submitted_at = now()
   where id = p_id;
end $$;

-- 造一張「需複訓」的成績單並送出，回傳自動開出的改善單 id
create or replace function pg_temp.vr_ticket(p_emp text, p_store text, p_weak text[])
returns uuid language plpgsql as $$
declare
  v_a uuid;
  v_t uuid;
begin
  v_a := pg_temp.vr_ins(p_emp, p_store, 'draft', null, null, null);
  perform pg_temp.vr_sub(v_a, '需複訓', p_weak);
  select id into v_t from public.improvement_tickets where assessment_id = v_a;
  return v_t;
end $$;

-- 改善單 → 來源成績單 id
create or replace function pg_temp.vr_src(p_ticket uuid)
returns uuid language sql as $$
  select assessment_id from public.improvement_tickets where id = p_ticket;
$$;

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  -- 先記下既有物件的基準，最後比對有沒有被動到
  perform pg_temp.vr_set('asm_cols',
    (select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'assessments'));

  insert into public.stores (code, name) values
    ('ZZ-B1', 'ZZ測試門市丙'), ('ZZ-B2', 'ZZ測試門市丁');

  insert into public.employees (id, nickname, store_code, job_title, status, include_in_assessment) values
    ('MI-9701', '假考生9701', 'ZZ-B1', '業務', '在職', true),
    ('MI-9702', '假考生9702', 'ZZ-B1', '業務', '在職', true),
    ('MI-9703', '假考生9703', 'ZZ-B2', '業務', '在職', true),
    ('MI-9704', '假考生9704', 'ZZ-B1', '業務', '在職', true);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-B1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-B2');
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：自動開單
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  a1 uuid; a2 uuid; a3 uuid; a4 uuid;
  v_tid uuid;
  v_cnt text := $q$select count(*)::text from public.improvement_tickets where assessment_id = %L$q$;
  v_fld text := $q$select status || '/' || array_to_string(target_dims, ',') || '/' || due_date::text
                          || '/' || store_code || '/' || employee_id
                   from public.improvement_tickets where assessment_id = %L$q$;
begin
  a1 := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'draft', null, null, null);
  perform pg_temp.vr_sub(a1, '需複訓', '{主動引導}');
  a2 := pg_temp.vr_ins('MI-9702', 'ZZ-B1', 'draft', null, null, null);
  perform pg_temp.vr_sub(a2, '不及格', '{風險意識,文字品質}');
  a3 := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'draft', null, null, null);
  perform pg_temp.vr_sub(a3, '及格', '{問題掌握}');
  a4 := pg_temp.vr_ins('MI-9702', 'ZZ-B1', 'draft', null, null, null);
  perform pg_temp.vr_sub(a4, '優秀', '{語氣與禮貌}');

  perform pg_temp.vr_eq('1 自動開單','判定「需複訓」開 1 張','1', pg_temp.vr_q1(format(v_cnt, a1)));
  perform pg_temp.vr_eq('1 自動開單','判定「不及格」開 1 張','1', pg_temp.vr_q1(format(v_cnt, a2)));
  perform pg_temp.vr_eq('1 自動開單','判定「及格」不開','0', pg_temp.vr_q1(format(v_cnt, a3)));
  perform pg_temp.vr_eq('1 自動開單','判定「優秀」不開','0', pg_temp.vr_q1(format(v_cnt, a4)));

  perform pg_temp.vr_eq('1 自動開單','需複訓單：狀態／面向／期限（今天＋14）／門市／考生',
    'open/主動引導/' || (v_today + 14)::text || '/ZZ-B1/MI-9701', pg_temp.vr_q1(format(v_fld, a1)));
  perform pg_temp.vr_eq('1 自動開單','不及格單：面向等於成績單 weakest_dims（兩個）',
    'open/風險意識,文字品質/' || (v_today + 14)::text || '/ZZ-B1/MI-9702', pg_temp.vr_q1(format(v_fld, a2)));

  -- 重複 UPDATE 不會重複開單
  select id into v_tid from public.improvement_tickets where assessment_id = a1;
  update public.assessments set total_score = 81 where id = a1;
  update public.assessments set status = 'submitted' where id = a1;
  perform pg_temp.vr_eq('1 自動開單','重複 UPDATE（狀態沒變）不重複開單','1', pg_temp.vr_q1(format(v_cnt, a1)));

  -- 退回草稿後再送出一次：觸發器會再跑，但「已存在就略過」，原單不變（面向不被覆蓋）
  update public.assessments
     set status = 'draft', total_score = null, verdict = null, pass_line = null,
         weakest_dims = null, submitted_at = null
   where id = a1;
  perform pg_temp.vr_sub(a1, '需複訓', '{資訊正確性}');
  perform pg_temp.vr_eq('1 自動開單','退回草稿再送出：仍只有 1 張、id 與面向都沒變',
    v_tid::text || '/1/主動引導',
    pg_temp.vr_q1(format($q$select id::text || '/' || (select count(*) from public.improvement_tickets where assessment_id = %L)
                                  || '/' || array_to_string(target_dims, ',')
                           from public.improvement_tickets where assessment_id = %L$q$, a1, a1)));

  perform pg_temp.vr_eq('1 自動開單','四張成績單合計只開 2 張','2',
    pg_temp.vr_q1(format('select count(*)::text from public.improvement_tickets where assessment_id in (%L, %L, %L, %L)', a1, a2, a3, a4)));
exception when others then
  perform pg_temp.vr_rec('區段 1','自動開單意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：成績單作廢 → 自動取消
-- ============================================================
do $$
declare
  bo uuid; bc uuid; bk uuid; bx uuid;
  v_f text := $q$select status || '/' || coalesce(cancelled_by, '無') || '/' || coalesce(cancel_reason, '無')
                  from public.improvement_tickets where id = %L$q$;
begin
  bo := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  bc := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  bk := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  bx := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');

  update public.improvement_tickets
     set status = 'coached', coached_on = (now() at time zone 'Asia/Taipei')::date, coach_note = '假輔導',
         coached_by = 'vr-sm1@2motor.tw', coached_at = now()
   where id = bc;
  update public.improvement_tickets
     set status = 'closed', closed_by = 'vr-cs1@2motor.tw', closed_at = now()
   where id = bk;
  update public.improvement_tickets
     set status = 'cancelled', cancelled_by = 'vr-cs1@2motor.tw', cancelled_at = now(), cancel_reason = '手動取消'
   where id = bx;

  -- 作廢四張來源成績單
  update public.assessments
     set status = 'voided', voided_at = now(), voided_by = 'vr-cs1@2motor.tw', void_reason = '假作廢'
   where id in (select assessment_id from public.improvement_tickets where id in (bo, bc, bk, bx));

  perform pg_temp.vr_eq('2 作廢','open 的單 → cancelled，cancelled_by／原因正確',
    'cancelled/(系統：成績單作廢)/成績單已作廢', pg_temp.vr_q1(format(v_f, bo)));
  perform pg_temp.vr_eq('2 作廢','open 的單 cancelled_at 有填','true',
    pg_temp.vr_q1(format('select (cancelled_at is not null)::text from public.improvement_tickets where id = %L', bo)));
  perform pg_temp.vr_eq('2 作廢','coached 的單 → cancelled，cancelled_by／原因正確',
    'cancelled/(系統：成績單作廢)/成績單已作廢', pg_temp.vr_q1(format(v_f, bc)));
  perform pg_temp.vr_eq('2 作廢','closed 的單不動','closed/無/無', pg_temp.vr_q1(format(v_f, bk)));
  perform pg_temp.vr_eq('2 作廢','原本就 cancelled 的單不被覆蓋','cancelled/vr-cs1@2motor.tw/手動取消',
    pg_temp.vr_q1(format(v_f, bx)));
exception when others then
  perform pg_temp.vr_rec('區段 2','作廢意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：improve_update_plan
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  cs text := 'vr-cs1@2motor.tw'; hq text := 'vr-hq@2motor.tw';
  s1 text := 'vr-sm1@2motor.tw'; nb text := 'vr-nobody@2motor.tw';
  tp uuid; tpc uuid; tpx uuid; tpn uuid;
  v_sql text := $q$select public.improve_update_plan(%L::uuid, %L::text[], %L::date)$q$;
  v_f text := $q$select array_to_string(target_dims, ',') || '/' || due_date::text
                  from public.improvement_tickets where id = %L$q$;
begin
  tp  := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tpc := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tpx := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tpn := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '假輔導', coached_by = s1, coached_at = now()
   where id = tpc;
  update public.improvement_tickets set status = 'closed', closed_by = cs, closed_at = now() where id = tpx;
  update public.improvement_tickets
     set status = 'cancelled', cancelled_by = cs, cancelled_at = now(), cancel_reason = '假取消' where id = tpn;

  -- 被拒（先測，確認失敗不會改到資料）
  perform pg_temp.vr_deny('3 update_plan','店長被拒','authenticated', s1, format(v_sql, tp, '{風險意識}', v_today + 5), '%沒有權限%');
  perform pg_temp.vr_deny('3 update_plan','總公司主管被拒','authenticated', hq, format(v_sql, tp, '{風險意識}', v_today + 5), '%沒有權限%');
  perform pg_temp.vr_deny('3 update_plan','沒帳號被拒','authenticated', nb, format(v_sql, tp, '{風險意識}', v_today + 5), '%沒有權限%');
  perform pg_temp.vr_deny('3 update_plan','anon 被拒（沒有 execute 權限）','anon', null, format(v_sql, tp, '{風險意識}', v_today + 5), '%permission denied%');
  perform pg_temp.vr_eq('3 update_plan','被拒之後資料沒被改','主動引導/' || (v_today + 14)::text, pg_temp.vr_q1(format(v_f, tp)));

  perform pg_temp.vr_deny('3 update_plan','面向為空陣列被拒','authenticated', cs, format(v_sql, tp, '{}', v_today + 5), '%至少要選 1 個%');
  perform pg_temp.vr_deny('3 update_plan','面向為 null 被拒','authenticated', cs, format(v_sql, tp, null, v_today + 5), '%至少要選 1 個%');
  perform pg_temp.vr_deny('3 update_plan','面向含非七面向名稱被拒','authenticated', cs, format(v_sql, tp, '{主動引導,亂寫}', v_today + 5), '%七個面向之一%');
  perform pg_temp.vr_deny('3 update_plan','期限早於開單日被拒','authenticated', cs, format(v_sql, tp, '{風險意識}', v_today - 1), '%早於開單日%');
  perform pg_temp.vr_deny('3 update_plan','期限為 null 被拒','authenticated', cs, format(v_sql, tp, '{風險意識}', null), '%期限不可空白%');
  perform pg_temp.vr_deny('3 update_plan','已結案（closed）的單被拒','authenticated', cs, format(v_sql, tpx, '{風險意識}', v_today + 5), '%待改善或已輔導%');
  perform pg_temp.vr_deny('3 update_plan','已取消（cancelled）的單被拒','authenticated', cs, format(v_sql, tpn, '{風險意識}', v_today + 5), '%待改善或已輔導%');
  perform pg_temp.vr_deny('3 update_plan','找不到的單被拒','authenticated', cs,
    format(v_sql, '00000000-0000-0000-0000-000000000000', '{風險意識}', v_today + 5), '%找不到改善單%');

  -- 成功
  perform pg_temp.vr_ok('3 update_plan','客服部成功（open）', cs, format(v_sql, tp, '{風險意識,資訊正確性}', v_today + 7));
  perform pg_temp.vr_eq('3 update_plan','面向照固定順序存、期限已更新','資訊正確性,風險意識/' || (v_today + 7)::text,
    pg_temp.vr_q1(format(v_f, tp)));
  perform pg_temp.vr_ok('3 update_plan','重複的面向會去重', cs, format(v_sql, tp, '{風險意識,風險意識,問題掌握}', v_today + 7));
  perform pg_temp.vr_eq('3 update_plan','去重後只剩兩個','問題掌握,風險意識/' || (v_today + 7)::text,
    pg_temp.vr_q1(format(v_f, tp)));
  perform pg_temp.vr_ok('3 update_plan','期限等於開單日可以', cs, format(v_sql, tp, '{風險意識}', v_today));
  perform pg_temp.vr_ok('3 update_plan','已輔導（coached）的單也可調整', cs, format(v_sql, tpc, '{問題掌握}', v_today + 3));
  perform pg_temp.vr_eq('3 update_plan','已輔導單調整後狀態仍是 coached','coached/問題掌握/' || (v_today + 3)::text,
    pg_temp.vr_q1(format($q$select status || '/' || array_to_string(target_dims, ',') || '/' || due_date::text
                           from public.improvement_tickets where id = %L$q$, tpc)));
exception when others then
  perform pg_temp.vr_rec('區段 3','update_plan 意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：improve_mark_coached
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  cs text := 'vr-cs1@2motor.tw'; hq text := 'vr-hq@2motor.tw';
  s1 text := 'vr-sm1@2motor.tw'; s2 text := 'vr-sm2@2motor.tw'; nb text := 'vr-nobody@2motor.tw';
  tc1 uuid; tc2 uuid; tc3 uuid; tc4 uuid; tcb uuid; tcx uuid; tcn uuid;
  v_sql text := $q$select public.improve_mark_coached(%L::uuid, %L::date, %L)$q$;
  v_f text := $q$select status || '/' || coalesce(coached_on::text, '無') || '/' || coalesce(coached_by, '無')
                       || '/' || coalesce(coach_note, '無') || '/' || (coached_at is not null)::text
                  from public.improvement_tickets where id = %L$q$;
begin
  tc1 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tc2 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tc3 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tc4 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tcb := pg_temp.vr_ticket('MI-9703', 'ZZ-B2', '{主動引導}');
  tcx := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tcn := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  update public.improvement_tickets set status = 'closed', closed_by = cs, closed_at = now() where id = tcx;
  update public.improvement_tickets
     set status = 'cancelled', cancelled_by = cs, cancelled_at = now(), cancel_reason = '假取消' where id = tcn;

  -- 被拒
  perform pg_temp.vr_deny('4 mark_coached','別間門市的店長被拒','authenticated', s2, format(v_sql, tc1, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','自己門市的店長不能動別間門市的單','authenticated', s1, format(v_sql, tcb, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','總公司主管被拒','authenticated', hq, format(v_sql, tc1, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','沒帳號被拒','authenticated', nb, format(v_sql, tc1, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','anon 被拒（沒有 execute 權限）','anon', null, format(v_sql, tc1, v_today, '備註'), '%permission denied%');
  perform pg_temp.vr_eq('4 mark_coached','被拒之後單仍是 open','open', pg_temp.vr_q1(format('select status from public.improvement_tickets where id = %L', tc1)));

  perform pg_temp.vr_deny('4 mark_coached','備註為空字串被拒','authenticated', s1, format(v_sql, tc3, v_today, ''), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('4 mark_coached','備註只有空白被拒','authenticated', s1, format(v_sql, tc3, v_today, '    '), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('4 mark_coached','備註只有換行與全形空白被拒','authenticated', s1,
    format($q$select public.improve_mark_coached(%L::uuid, %L::date, chr(10) || chr(12288) || ' ')$q$, tc3, v_today), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('4 mark_coached','備註為 null 被拒','authenticated', s1, format(v_sql, tc3, v_today, null), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('4 mark_coached','輔導日期晚於今天被拒','authenticated', s1, format(v_sql, tc4, v_today + 1, '備註'), '%不可晚於今天%');
  perform pg_temp.vr_deny('4 mark_coached','輔導日期早於開單日被拒','authenticated', s1, format(v_sql, tc4, v_today - 1, '備註'), '%不可早於開單日%');
  perform pg_temp.vr_deny('4 mark_coached','輔導日期為 null 被拒','authenticated', s1, format(v_sql, tc4, null, '備註'), '%輔導日期不可空白%');
  perform pg_temp.vr_deny('4 mark_coached','已結案（closed）的單被拒（客服部）','authenticated', cs, format(v_sql, tcx, v_today, '備註'), '%待改善或已輔導%');
  perform pg_temp.vr_deny('4 mark_coached','已結案的單被拒（店長，回通用訊息）','authenticated', s1, format(v_sql, tcx, v_today, '備註'), '%找不到這張改善單或沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','已取消的單被拒（店長，回通用訊息，不洩漏存在）','authenticated', s1, format(v_sql, tcn, v_today, '備註'), '%找不到這張改善單或沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','不存在的單被拒（店長，與已取消單同一句通用訊息）','authenticated', s1,
    format(v_sql, '00000000-0000-0000-0000-000000000000', v_today, '備註'), '%找不到這張改善單或沒有權限%');
  perform pg_temp.vr_deny('4 mark_coached','已取消的單被拒（客服部，狀態用中文）','authenticated', cs, format(v_sql, tcn, v_today, '備註'), '%待改善或已輔導（目前：已取消）');
  perform pg_temp.vr_eq('4 mark_coached','客服部看到的錯誤訊息不含英文狀態值','false',
    (pg_temp.vr_as('authenticated', cs, format(v_sql, tcx, v_today, '備註'), false) ~* '(open|coached|closed|cancelled)')::text);

  -- 成功
  perform pg_temp.vr_ok('4 mark_coached','自己門市的店長成功', s1, format(v_sql, tc1, v_today, '  已面談，重點：主動引導  '));
  perform pg_temp.vr_eq('4 mark_coached','店長成功：狀態／日期／操作人／備註（已去前後空白）／時間',
    'coached/' || v_today::text || '/vr-sm1@2motor.tw/已面談，重點：主動引導/true', pg_temp.vr_q1(format(v_f, tc1)));
  perform pg_temp.vr_ok('4 mark_coached','客服部成功', cs, format(v_sql, tc2, v_today, '客服部代填'));
  perform pg_temp.vr_eq('4 mark_coached','客服部成功：操作人是客服部信箱',
    'coached/' || v_today::text || '/vr-cs1@2motor.tw/客服部代填/true', pg_temp.vr_q1(format(v_f, tc2)));
  perform pg_temp.vr_ok('4 mark_coached','超長備註（5000 字）成功', s1,
    format($q$select public.improve_mark_coached(%L::uuid, %L::date, repeat('字', 5000))$q$, tc3, v_today));
  perform pg_temp.vr_eq('4 mark_coached','超長備註完整存入（不限字數）','coached/5000',
    pg_temp.vr_q1(format('select status || ''/'' || length(coach_note) from public.improvement_tickets where id = %L', tc3)));
  perform pg_temp.vr_ok('4 mark_coached','已輔導後重填（改備註）成功', s1, format(v_sql, tc1, v_today, '改寫後的備註'));
  perform pg_temp.vr_eq('4 mark_coached','重填後備註已更新、狀態仍是 coached',
    'coached/' || v_today::text || '/vr-sm1@2motor.tw/改寫後的備註/true', pg_temp.vr_q1(format(v_f, tc1)));
exception when others then
  perform pg_temp.vr_rec('區段 4','mark_coached 意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：improve_close
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  cs text := 'vr-cs1@2motor.tw'; hq text := 'vr-hq@2motor.tw';
  s1 text := 'vr-sm1@2motor.tw'; nb text := 'vr-nobody@2motor.tw';
  tk1 uuid; tk2 uuid;
  rc_good uuid; rc_exc uuid; rc_other uuid; rc_early uuid; rc_low uuid; rc_draft uuid; rc_void uuid;
  v_sql text := $q$select public.improve_close(%L::uuid, %L::uuid, %L)$q$;
  v_f text := $q$select status || '/' || coalesce(closed_by, '無') || '/' || (closed_by_assessment_id = %L::uuid)::text
                       || '/' || coalesce(close_note, '無') || '/' || (closed_at is not null)::text
                  from public.improvement_tickets where id = %L$q$;
begin
  tk1 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tk2 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');

  -- 複檢成績單（直接寫入；送出時間：開單後 1 小時，或開單前 1 天）
  rc_good  := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'submitted', '及格',   '{問題掌握}', now() + interval '1 hour');
  rc_exc   := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'submitted', '優秀',   '{問題掌握}', now() + interval '1 hour');
  rc_other := pg_temp.vr_ins('MI-9702', 'ZZ-B1', 'submitted', '及格',   '{問題掌握}', now() + interval '1 hour');
  rc_early := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'submitted', '及格',   '{問題掌握}', now() - interval '1 day');
  rc_low   := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'submitted', '需複訓', '{問題掌握}', now() + interval '1 hour');
  rc_draft := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'draft', null, null, null);
  rc_void  := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'voided', '及格',     '{問題掌握}', now() + interval '1 hour');

  perform pg_temp.vr_deny('5 close','複檢不是同一位考生被拒','authenticated', cs, format(v_sql, tk1, rc_other, null), '%同一位考生%');
  perform pg_temp.vr_deny('5 close','複檢就是來源成績單被拒','authenticated', cs, format(v_sql, tk1, pg_temp.vr_src(tk1), null), '%不可以是來源成績單%');
  perform pg_temp.vr_deny('5 close','複檢送出時間早於開單被拒','authenticated', cs, format(v_sql, tk1, rc_early, null), '%開單之後%');
  perform pg_temp.vr_deny('5 close','複檢判定未達及格（需複訓）被拒','authenticated', cs, format(v_sql, tk1, rc_low, null), '%及格或優秀%');
  perform pg_temp.vr_deny('5 close','複檢尚未送出（草稿）被拒','authenticated', cs, format(v_sql, tk1, rc_draft, null), '%已送出%');
  perform pg_temp.vr_deny('5 close','複檢已作廢被拒','authenticated', cs, format(v_sql, tk1, rc_void, null), '%已送出%');
  perform pg_temp.vr_deny('5 close','找不到複檢成績單被拒','authenticated', cs,
    format(v_sql, tk1, '00000000-0000-0000-0000-000000000000', null), '%找不到複檢成績單%');
  perform pg_temp.vr_deny('5 close','找不到改善單被拒','authenticated', cs,
    format(v_sql, '00000000-0000-0000-0000-000000000000', rc_good, null), '%找不到改善單%');
  perform pg_temp.vr_deny('5 close','店長被拒','authenticated', s1, format(v_sql, tk1, rc_good, null), '%沒有權限%');
  perform pg_temp.vr_deny('5 close','總公司主管被拒','authenticated', hq, format(v_sql, tk1, rc_good, null), '%沒有權限%');
  perform pg_temp.vr_deny('5 close','沒帳號被拒','authenticated', nb, format(v_sql, tk1, rc_good, null), '%沒有權限%');
  perform pg_temp.vr_deny('5 close','anon 被拒（沒有 execute 權限）','anon', null, format(v_sql, tk1, rc_good, null), '%permission denied%');
  perform pg_temp.vr_eq('5 close','被拒之後單仍是 open','open', pg_temp.vr_q1(format('select status from public.improvement_tickets where id = %L', tk1)));

  perform pg_temp.vr_ok('5 close','客服部：複檢「及格」→ 結案成功', cs, format(v_sql, tk1, rc_good, '  複檢通過  '));
  perform pg_temp.vr_eq('5 close','結案欄位：狀態／操作人／連到複檢成績單／備註（去空白）／時間',
    'closed/vr-cs1@2motor.tw/true/複檢通過/true', pg_temp.vr_q1(format(v_f, rc_good, tk1)));
  perform pg_temp.vr_deny('5 close','已結案的單不能再結案','authenticated', cs, format(v_sql, tk1, rc_good, null), '%待改善或已輔導%');
  perform pg_temp.vr_ok('5 close','客服部：複檢「優秀」→ 結案成功（不填備註）', cs, format(v_sql, tk2, rc_exc, null));
  perform pg_temp.vr_eq('5 close','不填備註時 close_note 為空','closed/vr-cs1@2motor.tw/true/無/true',
    pg_temp.vr_q1(format(v_f, rc_exc, tk2)));

  -- 清掉測試用草稿，避免佔用「同考官同考生只能一張草稿」
  delete from public.assessments where id = rc_draft;
exception when others then
  perform pg_temp.vr_rec('區段 5','close 意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：improve_cancel
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  cs text := 'vr-cs1@2motor.tw'; hq text := 'vr-hq@2motor.tw';
  s1 text := 'vr-sm1@2motor.tw'; nb text := 'vr-nobody@2motor.tw';
  tx1 uuid; tx2 uuid; tx3 uuid; txc uuid;
  v_sql text := $q$select public.improve_cancel(%L::uuid, %L)$q$;
  v_f text := $q$select status || '/' || coalesce(cancelled_by, '無') || '/' || coalesce(cancel_reason, '無')
                       || '/' || (cancelled_at is not null)::text
                  from public.improvement_tickets where id = %L$q$;
begin
  tx1 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tx2 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  tx3 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  txc := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '假輔導', coached_by = s1, coached_at = now()
   where id = tx2;
  update public.improvement_tickets set status = 'closed', closed_by = cs, closed_at = now() where id = txc;

  perform pg_temp.vr_deny('6 cancel','原因為空字串被拒','authenticated', cs, format(v_sql, tx3, ''), '%取消原因不可空白%');
  perform pg_temp.vr_deny('6 cancel','原因只有空白被拒','authenticated', cs, format(v_sql, tx3, '   '), '%取消原因不可空白%');
  perform pg_temp.vr_deny('6 cancel','原因為 null 被拒','authenticated', cs, format(v_sql, tx3, null), '%取消原因不可空白%');
  perform pg_temp.vr_deny('6 cancel','店長被拒','authenticated', s1, format(v_sql, tx3, '考生離職'), '%沒有權限%');
  perform pg_temp.vr_deny('6 cancel','總公司主管被拒','authenticated', hq, format(v_sql, tx3, '考生離職'), '%沒有權限%');
  perform pg_temp.vr_deny('6 cancel','沒帳號被拒','authenticated', nb, format(v_sql, tx3, '考生離職'), '%沒有權限%');
  perform pg_temp.vr_deny('6 cancel','anon 被拒（沒有 execute 權限）','anon', null, format(v_sql, tx3, '考生離職'), '%permission denied%');
  perform pg_temp.vr_deny('6 cancel','已結案的單被拒','authenticated', cs, format(v_sql, txc, '考生離職'), '%待改善或已輔導%');
  perform pg_temp.vr_eq('6 cancel','被拒之後單仍是 open','open', pg_temp.vr_q1(format('select status from public.improvement_tickets where id = %L', tx3)));

  perform pg_temp.vr_ok('6 cancel','客服部取消 open 的單成功', cs, format(v_sql, tx1, '  考生已離職  '));
  perform pg_temp.vr_eq('6 cancel','取消欄位：狀態／操作人／原因（去空白）／時間','cancelled/vr-cs1@2motor.tw/考生已離職/true',
    pg_temp.vr_q1(format(v_f, tx1)));
  perform pg_temp.vr_ok('6 cancel','客服部取消 coached 的單成功', cs, format(v_sql, tx2, '轉調他店'));
  perform pg_temp.vr_eq('6 cancel','coached 單取消後欄位正確','cancelled/vr-cs1@2motor.tw/轉調他店/true', pg_temp.vr_q1(format(v_f, tx2)));
  perform pg_temp.vr_deny('6 cancel','已取消的單不能再取消','authenticated', cs, format(v_sql, tx1, '再取消'), '%待改善或已輔導%');
exception when others then
  perform pg_temp.vr_rec('區段 6','cancel 意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：可見性矩陣、直接寫入被拒、機密欄位
-- 改善單：M1（門市丙 open）、M2（門市丙 cancelled）、M3（門市丁 open）、M4（門市丁 coached）
-- 成績單：S1（門市丙 submitted，2 個題組）、S2（門市丁 submitted，1 個題組）、
--         D1（門市丙 draft，1 個題組）、V1（門市丙 voided，1 個題組）→ 只有 S1、S2 的 3 個題組×7 面向 = 21 列
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  m1 uuid; m2 uuid; m3 uuid; m4 uuid;
  s1a uuid; s2a uuid; d1a uuid; v1a uuid;
  v_i1 uuid; v_i2 uuid;
  v_ids text; v_aids text;
  qt text; qv text; qa text;
  r record;
begin
  m1 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  m2 := pg_temp.vr_ticket('MI-9701', 'ZZ-B1', '{主動引導}');
  m3 := pg_temp.vr_ticket('MI-9703', 'ZZ-B2', '{主動引導}');
  m4 := pg_temp.vr_ticket('MI-9703', 'ZZ-B2', '{主動引導}');
  update public.improvement_tickets
     set status = 'cancelled', cancelled_by = 'vr-cs1@2motor.tw', cancelled_at = now(), cancel_reason = '假取消'
   where id = m2;
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '假輔導', coached_by = 'vr-sm2@2motor.tw', coached_at = now()
   where id = m4;
  perform pg_temp.vr_set('m1', m1::text);
  v_ids := format('%L,%L,%L,%L', m1, m2, m3, m4);

  -- 弱項分析用的成績單與題組
  s1a := pg_temp.vr_ins('MI-9701', 'ZZ-B1', 'submitted', '及格', '{主動引導}', now());
  s2a := pg_temp.vr_ins('MI-9703', 'ZZ-B2', 'submitted', '及格', '{主動引導}', now());
  d1a := pg_temp.vr_ins('MI-9704', 'ZZ-B1', 'draft', null, null, null);
  v1a := pg_temp.vr_ins('MI-9702', 'ZZ-B1', 'voided', '及格', '{主動引導}', now());
  insert into public.assessment_items (assessment_id, seq, category, code, levels)
  values (s1a, 1, 'ZZ分類A', 'A1', pg_temp.vr_mk('優','良','待加強','不及格','不適用','優','良'))
  returning id into v_i1;
  insert into public.assessment_items (assessment_id, seq, category, code, levels)
  values (s1a, 2, 'ZZ分類B', 'B1', pg_temp.vr_mk('優','優','優','優','優','優','優'))
  returning id into v_i2;
  insert into public.assessment_items (assessment_id, seq, category, code, levels) values
    (s2a, 1, 'ZZ分類A', 'A1', pg_temp.vr_mk('優','優','優','優','優','優','優')),
    (d1a, 1, 'ZZ分類A', 'A1', pg_temp.vr_mk('優','優','優','優','優','優','優')),
    (v1a, 1, 'ZZ分類A', 'A1', pg_temp.vr_mk('優','優','優','優','優','優','優'));
  v_aids := format('%L,%L,%L,%L', s1a, s2a, d1a, v1a);
  perform pg_temp.vr_set('s1_item1', v_i1::text);
  perform pg_temp.vr_set('s1a', s1a::text);

  qt := format('select count(*)::text from public.improvement_tickets where id in (%s)', v_ids);
  qv := format('select count(*)::text from public.improvement_ticket_view where id in (%s)', v_ids);
  qa := format('select count(*)::text from public.analytics_dim_rates where assessment_id in (%s)', v_aids);

  for r in
    select * from (values
      ('客服部',        'vr-cs1@2motor.tw',    '4', '4', '21'),
      ('總公司主管',    'vr-hq@2motor.tw',     '3', '3', '21'),
      ('店長（門市丙）','vr-sm1@2motor.tw',    '1', '1', '14'),
      ('店長（門市丁）','vr-sm2@2motor.tw',    '2', '2', '7'),
      ('有登入但沒帳號','vr-nobody@2motor.tw', '0', '0', '0')
    ) as t(label, email, e_t, e_v, e_a)
  loop
    perform pg_temp.vr_eq('7 可見性', r.label || '：improvement_tickets 可見筆數', r.e_t, pg_temp.vr_as('authenticated', r.email, qt, true));
    perform pg_temp.vr_eq('7 可見性', r.label || '：improvement_ticket_view 可見筆數', r.e_v, pg_temp.vr_as('authenticated', r.email, qv, true));
    perform pg_temp.vr_eq('7 可見性', r.label || '：analytics_dim_rates 可見筆數（draft／voided 不出現）', r.e_a, pg_temp.vr_as('authenticated', r.email, qa, true));
  end loop;

  perform pg_temp.vr_eq('7 可見性','anon：三個物件都被拒絕讀取','3/3',
    (select count(*)::text || '/3' from (values (qt), (qv), (qa)) as t(sql)
      where pg_temp.vr_as('anon', null, t.sql, true) like 'ERROR: permission denied%'));

  -- 直接寫入一律被拒
  perform pg_temp.vr_deny('7 直接寫入','客服部直接 insert 被拒','authenticated', 'vr-cs1@2motor.tw',
    format($q$insert into public.improvement_tickets (assessment_id, employee_id, store_code, due_date)
              values (%L, 'MI-9701', 'ZZ-B1', current_date)$q$, s1a), '%permission denied%');
  perform pg_temp.vr_deny('7 直接寫入','客服部直接 update 被拒','authenticated', 'vr-cs1@2motor.tw',
    format($q$update public.improvement_tickets set status = 'closed' where id = %L$q$, m1), '%permission denied%');
  perform pg_temp.vr_deny('7 直接寫入','客服部直接 delete 被拒','authenticated', 'vr-cs1@2motor.tw',
    format($q$delete from public.improvement_tickets where id = %L$q$, m1), '%permission denied%');
  perform pg_temp.vr_deny('7 直接寫入','客服部直接 truncate 被拒','authenticated', 'vr-cs1@2motor.tw',
    'truncate table public.improvement_tickets', '%permission denied%');
  perform pg_temp.vr_deny('7 直接寫入','店長直接 update 被拒','authenticated', 'vr-sm1@2motor.tw',
    format($q$update public.improvement_tickets set status = 'closed' where id = %L$q$, m1), '%permission denied%');
  perform pg_temp.vr_deny('7 直接寫入','anon 直接 insert 被拒','anon', null,
    format($q$insert into public.improvement_tickets (assessment_id, employee_id, store_code, due_date)
              values (%L, 'MI-9701', 'ZZ-B1', current_date)$q$, s1a), '%permission denied%');
  perform pg_temp.vr_eq('7 直接寫入','被拒之後 M1 仍是 open','open', pg_temp.vr_q1(format('select status from public.improvement_tickets where id = %L', m1)));
  perform pg_temp.vr_eq('7 直接寫入','authenticated／anon 都沒有 insert／update／delete／truncate 權限','false',
    (select bool_or(has_table_privilege(rl, 'public.improvement_tickets', p))::text
       from (values ('anon'), ('authenticated')) as a(rl),
            (values ('insert'), ('update'), ('delete'), ('truncate')) as b(p)));
  perform pg_temp.vr_eq('7 直接寫入','anon 連 select 都沒有','false',
    has_table_privilege('anon', 'public.improvement_tickets', 'select')::text);
  perform pg_temp.vr_eq('7 直接寫入','improvement_tickets 已開 RLS 且只有 1 條 policy','true/improvement_tickets_select',
    pg_temp.vr_q1($q$select c.relrowsecurity::text || '/' || (select string_agg(policyname, ',')
                       from pg_policies where schemaname = 'public' and tablename = 'improvement_tickets')
                     from pg_class c where c.oid = 'public.improvement_tickets'::regclass$q$));

  -- 函式權限
  perform pg_temp.vr_eq('7 函式權限','四個 improve_ 函式：anon 不能執行、authenticated 可以','false/true',
    (select bool_or(has_function_privilege('anon', f, 'execute'))::text || '/'
            || bool_and(has_function_privilege('authenticated', f, 'execute'))::text
       from (values ('public.improve_update_plan(uuid, text[], date)'),
                    ('public.improve_mark_coached(uuid, date, text)'),
                    ('public.improve_close(uuid, uuid, text)'),
                    ('public.improve_cancel(uuid, text)')) as t(f)));
  perform pg_temp.vr_eq('7 函式權限','兩個觸發器函式：anon／authenticated 都不能直接呼叫','false',
    (select bool_or(has_function_privilege(rl, f, 'execute'))::text
       from (values ('anon'), ('authenticated')) as a(rl),
            (values ('public.improvement_auto_open()'), ('public.improvement_auto_cancel()')) as t(f)));

  -- analytics_dim_rates：內容與機密
  perform pg_temp.vr_eq('7 analytics','S1 題組 1 的七面向等級百分比（不適用為 null，依面向順序）','100,70,40,0,null,100,70',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select string_agg(coalesce(level_pct::text, 'null'), ',' order by array_position(public.assess_dim_order(), dim))
                from public.analytics_dim_rates where item_id = %L$q$, v_i1), true));
  perform pg_temp.vr_eq('7 analytics','每個題組每個面向一列（S1 題組 1 共 7 列）','7',
    pg_temp.vr_q1(format('select count(*)::text from public.analytics_dim_rates where item_id = %L', v_i1)));
  perform pg_temp.vr_eq('7 analytics','欄位只有 8 個，沒有題組名稱／步驟／考點／備註',
    'assessment_id,employee_id,store_code,submitted_at,item_id,seq,dim,level_pct',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position)
                     from information_schema.columns
                     where table_schema = 'public' and table_name = 'analytics_dim_rates'$q$));
  perform pg_temp.vr_eq('7 analytics','檢視定義沒有碰機密表 assessment_item_secrets','true',
    (pg_get_viewdef('public.analytics_dim_rates'::regclass) not like '%assessment_item_secrets%')::text);
  perform pg_temp.vr_eq('7 analytics','analytics_dim_rates 與 improvement_ticket_view 兩個檢視都是 security_invoker','true',
    (select bool_and(coalesce(reloptions::text, '') like '%security_invoker=true%')::text
       from pg_class where oid in ('public.analytics_dim_rates'::regclass, 'public.improvement_ticket_view'::regclass)));

  -- improvement_ticket_view 內容（考生名稱快照、來源成績單摘要）
  perform pg_temp.vr_eq('7 view','M1：考生名稱／來源判定／身分／總分／考核日期',
    '假考生9701/需複訓/正式/80.0/' || v_today::text,
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select employee_label || '/' || source_verdict || '/' || source_tenure || '/' || source_total_score::text
                       || '/' || source_assessed_on::text
                from public.improvement_ticket_view where id = %L$q$, m1), true));
exception when others then
  perform pg_temp.vr_rec('區段 7','可見性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 8：is_overdue／days_overdue
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid;
  v_f text := $q$select is_overdue::text || '/' || days_overdue::text from public.improvement_ticket_view where id = %L$q$;
begin
  o1 := pg_temp.vr_ticket('MI-9702', 'ZZ-B1', '{主動引導}');
  o2 := pg_temp.vr_ticket('MI-9702', 'ZZ-B1', '{主動引導}');
  o3 := pg_temp.vr_ticket('MI-9702', 'ZZ-B1', '{主動引導}');
  o4 := pg_temp.vr_ticket('MI-9702', 'ZZ-B1', '{主動引導}');
  o5 := pg_temp.vr_ticket('MI-9702', 'ZZ-B1', '{主動引導}');

  update public.improvement_tickets set due_date = v_today - 3 where id = o1;
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '假輔導', coached_by = 'vr-sm1@2motor.tw',
         coached_at = now(), due_date = v_today - 3
   where id = o2;
  update public.improvement_tickets set due_date = v_today where id = o3;
  update public.improvement_tickets set due_date = v_today + 5 where id = o4;
  update public.improvement_tickets set due_date = v_today - 1 where id = o5;

  perform pg_temp.vr_eq('8 逾期','open 且過期 3 天 → 逾期、3 天','true/3', pg_temp.vr_q1(format(v_f, o1)));
  perform pg_temp.vr_eq('8 逾期','已輔導（coached）即使過了期限也不算逾期','false/0', pg_temp.vr_q1(format(v_f, o2)));
  perform pg_temp.vr_eq('8 逾期','期限就是今天 → 不算逾期','false/0', pg_temp.vr_q1(format(v_f, o3)));
  perform pg_temp.vr_eq('8 逾期','期限還有 5 天 → 不算逾期','false/0', pg_temp.vr_q1(format(v_f, o4)));
  perform pg_temp.vr_eq('8 逾期','open 且過期 1 天 → 逾期、1 天','true/1', pg_temp.vr_q1(format(v_f, o5)));
  perform pg_temp.vr_eq('8 逾期','客服部身分讀檢視結果相同','true/3',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw', format(v_f, o1), true));
exception when others then
  perform pg_temp.vr_rec('區段 8','逾期意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 9：既有資料表與函式未被改動
-- ============================================================
do $$
begin
  -- 以下用「必要物件存在」「數量不少於」的形式，不寫死總數，日後別處新增物件不會讓驗證誤報
  perform pg_temp.vr_eq('9 既有物件','assessments 上本次新增的兩個觸發器都在','2',
    pg_temp.vr_q1($q$select count(*)::text from pg_trigger
                     where tgrelid = 'public.assessments'::regclass and not tgisinternal
                       and tgname in ('improvement_auto_open_trg', 'improvement_auto_cancel_trg')$q$));
  perform pg_temp.vr_eq('9 既有物件','assessments 欄位數沒變（與本腳本開頭記下的相同）', pg_temp.vr_get('asm_cols'),
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessments'$q$));
  perform pg_temp.vr_eq('9 既有物件','assessments 原本的 policy assessments_select 仍在','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_policies
                     where schemaname = 'public' and tablename = 'assessments' and policyname = 'assessments_select'$q$));
  perform pg_temp.vr_eq('9 既有物件','assess_ 開頭函式不少於 19 個（原本 19 個都在）','true',
    pg_temp.vr_q1($q$select (count(*) >= 19)::text from pg_proc
                     where pronamespace = 'public'::regnamespace and proname like 'assess\_%'$q$));
  perform pg_temp.vr_eq('9 既有物件','assess_submit／assess_void 都在，且仍是 security definer','assess_submit:true,assess_void:true',
    pg_temp.vr_q1($q$select string_agg(proname || ':' || prosecdef::text, ',' order by proname) from pg_proc
                     where pronamespace = 'public'::regnamespace and proname in ('assess_submit', 'assess_void')$q$));
  perform pg_temp.vr_eq('9 既有物件','本次新增的必要函式都在（improve_ 4 個＋improvement_auto_ 2 個＋improvement_status_zh）','7',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc
                     where pronamespace = 'public'::regnamespace
                       and proname in ('improve_update_plan', 'improve_mark_coached', 'improve_close', 'improve_cancel',
                                       'improvement_auto_open', 'improvement_auto_cancel', 'improvement_status_zh')$q$));
  perform pg_temp.vr_eq('9 既有物件','既有的名冊／成績單函式與檢視都還在','true',
    (to_regprocedure('public.roster_my_role()') is not null
     and to_regprocedure('public.roster_my_store()') is not null
     and to_regprocedure('public.roster_touch_updated_at()') is not null
     and to_regclass('public.assessment_summaries') is not null
     and to_regclass('public.employees_with_tenure') is not null)::text);
exception when others then
  perform pg_temp.vr_rec('區段 9','既有物件檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 10：真實流程（以客服部身分真的呼叫 assess_start／assess_draw／assess_save_item／assess_submit／assess_void）
-- 前置資料沿用 assess_verify_fake.sql 的建法：假題庫（questions）、假員工，其餘（草稿、題組、drawn、
-- 機密表 assessment_item_secrets、category_last）由真函式自己建立；全部在交易內，rollback 後消失。
-- 區段 1～9 都是直接寫資料表模擬；這一段才證明改善單觸發器與真正的 assess_submit／assess_void 配合無誤。
-- ============================================================
create or replace function pg_temp.vr_real(p_levels jsonb)
returns uuid language plpgsql as $$
declare
  v_r text;
  v_aid uuid;
  v_item uuid;
begin
  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           $q$select public.assess_start('MI-9705', '正式')::text$q$, true);
  if v_r like 'ERROR%' then raise exception 'assess_start：%', v_r; end if;
  v_aid := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select item_id::text from public.assess_draw(%L::uuid, array['ZZ分類R'])$q$, v_aid), true);
  if v_r like 'ERROR%' then raise exception 'assess_draw：%', v_r; end if;
  v_item := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '假備註')$q$, v_item, p_levels::text), false);
  if v_r like 'ERROR%' then raise exception 'assess_save_item：%', v_r; end if;
  return v_aid;
end $$;

do $$
declare
  cs text := 'vr-cs1@2motor.tw'; hq text := 'vr-hq@2motor.tw';
  r record;
  v_aid uuid;
  v_t_open uuid; v_t_coach uuid; v_t_close uuid;
  v_f text := $q$select status || '/' || coalesce(cancelled_by, '無') from public.improvement_tickets where id = %L$q$;
begin
  insert into public.employees (id, nickname, store_code, job_title, status, include_in_assessment)
  values ('MI-9705', '假考生9705', 'ZZ-B1', '業務', '在職', true);
  insert into public.questions (category, code, title, steps) values
    ('ZZ分類R', 'R1', '假題組R1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類R', 'R2', '假題組R2', '[{"action":"動作1","point":"考點1"}]'::jsonb);

  -- 正式員工（合格線 85）：全優＝100 優秀；資訊正確性待加強其餘優＝88 及格；
  -- 再加預設訊息運用良＝83.5 需複訓；全良＝70 不及格
  for r in
    select * from (values
      ('exc',  '優秀',   pg_temp.vr_mk('優','優','優','優','優','優','優')::text,        '0'),
      ('pass', '及格',   pg_temp.vr_mk('待加強','優','優','優','優','優','優')::text,    '0'),
      ('re1',  '需複訓', pg_temp.vr_mk('待加強','良','優','優','優','優','優')::text,    '1'),
      ('fail', '不及格', pg_temp.vr_mk('良','良','良','良','良','良','良')::text,        '1'),
      ('re2',  '需複訓', pg_temp.vr_mk('待加強','良','優','優','優','優','優')::text,    '1')
    ) as t(tag, verdict, lv, n_tickets)
  loop
    v_aid := pg_temp.vr_real(r.lv::jsonb);
    perform pg_temp.vr_set('real_' || r.tag, v_aid::text);
    perform pg_temp.vr_eq('10 真實流程','真的呼叫 assess_submit，判定為「' || r.verdict || '」', r.verdict,
      pg_temp.vr_as('authenticated', cs, format('select verdict from public.assess_submit(%L::uuid)', v_aid), true));
    perform pg_temp.vr_eq('10 真實流程','「' || r.verdict || '」送出後改善單張數', r.n_tickets,
      pg_temp.vr_q1(format('select count(*)::text from public.improvement_tickets where assessment_id = %L', v_aid)));
    if r.n_tickets = '1' then
      perform pg_temp.vr_eq('10 真實流程','「' || r.verdict || '」的改善單：open／面向等於成績單最弱面向／門市／考生','true',
        pg_temp.vr_q1(format($q$select (t.status = 'open' and t.target_dims = a.weakest_dims
                                        and t.store_code = 'ZZ-B1' and t.employee_id = 'MI-9705')::text
                                from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id
                                where t.assessment_id = %L$q$, v_aid)));
    end if;
  end loop;

  -- 真的作廢：re1（open）、fail（改成 coached）、re2（改成 closed）
  select id into v_t_open  from public.improvement_tickets where assessment_id = pg_temp.vr_get('real_re1')::uuid;
  select id into v_t_coach from public.improvement_tickets where assessment_id = pg_temp.vr_get('real_fail')::uuid;
  select id into v_t_close from public.improvement_tickets where assessment_id = pg_temp.vr_get('real_re2')::uuid;
  update public.improvement_tickets
     set status = 'coached', coached_on = (now() at time zone 'Asia/Taipei')::date, coach_note = '假輔導',
         coached_by = 'vr-sm1@2motor.tw', coached_at = now()
   where id = v_t_coach;
  update public.improvement_tickets set status = 'closed', closed_by = cs, closed_at = now() where id = v_t_close;

  perform pg_temp.vr_eq('10 真實流程','真的呼叫 assess_void（open 單的來源）成功','OK',
    pg_temp.vr_as('authenticated', cs, format($q$select public.assess_void(%L::uuid, '假作廢')$q$, pg_temp.vr_get('real_re1')), false));
  perform pg_temp.vr_eq('10 真實流程','真的呼叫 assess_void（coached 單的來源）成功','OK',
    pg_temp.vr_as('authenticated', cs, format($q$select public.assess_void(%L::uuid, '假作廢')$q$, pg_temp.vr_get('real_fail')), false));
  perform pg_temp.vr_eq('10 真實流程','真的呼叫 assess_void（closed 單的來源）成功','OK',
    pg_temp.vr_as('authenticated', cs, format($q$select public.assess_void(%L::uuid, '假作廢')$q$, pg_temp.vr_get('real_re2')), false));
  perform pg_temp.vr_eq('10 真實流程','作廢後 open 的單自動取消','cancelled/(系統：成績單作廢)', pg_temp.vr_q1(format(v_f, v_t_open)));
  perform pg_temp.vr_eq('10 真實流程','作廢後 coached 的單自動取消','cancelled/(系統：成績單作廢)', pg_temp.vr_q1(format(v_f, v_t_coach)));
  perform pg_temp.vr_eq('10 真實流程','作廢後 closed 的單不動','closed/無', pg_temp.vr_q1(format(v_f, v_t_close)));

  -- 已結案的單，來源成績單被作廢後各角色讀到的內容
  perform pg_temp.vr_eq('10 真實流程','已結案單（來源已作廢）：客服部讀檢視，名稱與來源判定仍在','假考生9705/需複訓/closed',
    pg_temp.vr_as('authenticated', cs,
      format($q$select coalesce(employee_label, '(null)') || '/' || coalesce(source_verdict, '(null)') || '/' || status
                from public.improvement_ticket_view where id = %L$q$, v_t_close), true));
  perform pg_temp.vr_eq('10 真實流程','已結案單（來源已作廢）：主管仍看得到單，但 employee_label／來源判定為 null（前端要能處理）','(null)/(null)/closed',
    pg_temp.vr_as('authenticated', hq,
      format($q$select coalesce(employee_label, '(null)') || '/' || coalesce(source_verdict, '(null)') || '/' || status
                from public.improvement_ticket_view where id = %L$q$, v_t_close), true));
exception when others then
  perform pg_temp.vr_rec('區段 10','真實流程意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate backoffice_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare backoffice_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過') || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate backoffice_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare backoffice_vr_out as select '
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
execute backoffice_vr_out;
