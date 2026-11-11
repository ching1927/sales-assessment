-- ============================================================
-- 業務考核系統：三級制評分＋新人面向備註必填 驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行；必須先執行過 grade3_schema.sql（及它前面所有檔案，順序見該檔檔頭）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-gxxx@2motor.tw）／假成績單，
--   用真正的 assess_save_item、assess_save_dim_notes、assess_submit 以客服部身分跑完所有驗證，
--   結果記在暫存表，最後 rollback（假資料全部消失）。
--   「改制前就存在的舊單／舊草稿」以資料庫擁有者身分直接寫入（寫入當下暫時停用等級觸發器、寫完立刻恢復，
--   整段在交易內，rollback 後一切復原）。
-- 怎麼看結果：最後一個結果就是「序號／測項／預期／實際／通過」表（做法同其他 *_verify_fake.sql）；
--   第一列「總結」顯示 N/M 項通過，「通過」欄全是「通過」才算成功。
-- 假門市代碼 ZZ-G1、假員工編號 MI-9871～MI-9884、
--   假信箱 vr-gcs1／vr-gcs2／vr-ghq／vr-gsm1／vr-gsm2／vr-gnobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;

set local lock_timeout = '5s';

do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_item_secrets') is null then
    raise exception '請先執行 assess_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_item_secrets'
                   and column_name = 'dim_notes') then
    raise exception '請先執行 grade3_schema.sql（assessment_item_secrets 還沒有 dim_notes 欄位）';
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


-- 直接寫入一張草稿成績單（考官 vr-gcs1；以資料庫擁有者身分）。p_tenure：新人或正式
create or replace function pg_temp.vr_asm(p_emp text, p_store text, p_tenure text)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
  values
    (p_emp, '假考生' || right(p_emp, 4), p_store, 'vr-gcs1@2motor.tw', 'draft', p_tenure, '自動')
  returning id into v_id;
  return v_id;
end $$;

-- 直接寫入一個題組與它的機密列（模擬 assess_draw 的結果）。
-- p_levels 可直接給舊等級（模擬改制前就存在的資料）：寫入時暫時停用等級觸發器，寫完立刻恢復。
create or replace function pg_temp.vr_it(p_asm uuid, p_seq int, p_cat text, p_extra boolean, p_levels jsonb)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  alter table public.assessment_items disable trigger grade3_items_levels_trg;
  insert into public.assessment_items (assessment_id, seq, category, code, levels, is_extra)
  values (p_asm, p_seq, p_cat, 'ZZ' || p_seq, coalesce(p_levels, '{}'::jsonb), p_extra)
  returning id into v_id;
  alter table public.assessment_items enable trigger grade3_items_levels_trg;
  insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps)
  values (v_id, -9600 - (random() * 1000000)::int, false, '機密標題', '[]'::jsonb);
  return v_id;
end $$;

-- 以客服部 vr-gcs1 存評分與面向備註（走真正的函式）；p_notes 為 null 時不呼叫備註函式。回傳第一個失敗的結果文字，全成功回 OK
create or replace function pg_temp.vr_save(p_item uuid, p_levels jsonb, p_notes jsonb)
returns text language plpgsql as $$
declare
  r1 text;
  r2 text := 'OK';
begin
  r1 := pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw',
          format($q$select public.assess_save_item(%L::uuid, %L::jsonb, null)$q$, p_item, p_levels), false);
  if p_notes is not null then
    r2 := pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw',
          format($q$select public.assess_save_dim_notes(%L::uuid, %L::jsonb)$q$, p_item, p_notes), false);
  end if;
  return case when r1 <> 'OK' then r1 else r2 end;
end $$;

-- 以客服部 vr-gcs1 送出成績單；成功回「總分/判定/合格線」，失敗回 ERROR: 訊息
create or replace function pg_temp.vr_submit(p_asm uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw',
           format($q$select total_score::text || '/' || verdict || '/' || pass_line::text from public.assess_submit(%L::uuid)$q$, p_asm), true);
end $$;

create or replace function pg_temp.vr_status(p_asm uuid)
returns text language sql as $$
  select status from public.assessments where id = p_asm;
$$;

-- ============================================================
-- 建立假資料
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-G1', 'ZZ測試門市G1'), ('ZZ-G2', 'ZZ測試門市G2');

  insert into public.employees (id, nickname, store_code, job_title, status, include_in_assessment)
  select 'MI-' || (9870 + g), '假考生' || (9870 + g), 'ZZ-G1', '業務', '在職', true from generate_series(1, 14) g;

  insert into public.app_users (email, role, store_code) values
    ('vr-gcs1@2motor.tw', 'cs_admin',      null),
    ('vr-gcs2@2motor.tw', 'cs_admin',      null),
    ('vr-ghq@2motor.tw',  'hq_viewer',     null),
    ('vr-gsm1@2motor.tw', 'store_manager', 'ZZ-G1'),
    ('vr-gsm2@2motor.tw', 'store_manager', 'ZZ-G2');
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- 舊單基準（模擬改制前已存在的成績單：等級是舊字串）；記下指紋，最後比對有沒有被動到
do $$
declare
  a uuid; i uuid; i2 uuid;
begin
  perform set_config('request.jwt.claims', '', true);
  a := pg_temp.vr_asm('MI-9871', 'ZZ-G1', '正式');
  i := pg_temp.vr_it(a, 1, 'ZZ分類A', false, pg_temp.vr_mk('優','良','良','優','不及格','優','待加強'));
  i2 := pg_temp.vr_it(a, 2, 'ZZ分類B', false, pg_temp.vr_mk('優','優','良','良','優','優','不適用'));
  update public.assessment_items set item_score = 70.0, dim_points = '{}'::jsonb where id = i;
  update public.assessment_items set item_score = 93.0, dim_points = '{}'::jsonb where id = i2;
  alter table public.assessments disable trigger grade3_submit_guard_trg;   -- 模擬改制前就已送出的舊單
  update public.assessments set status = 'submitted', total_score = 81.5, verdict = '需複訓', pass_line = 85,
         weakest_dims = '{風險意識}', submitted_at = now() where id = a;
  alter table public.assessments enable trigger grade3_submit_guard_trg;
  perform pg_temp.vr_set('old_asm', a::text);
  perform pg_temp.vr_set('old_item1', i::text);
  perform pg_temp.vr_set('old_fp',
    (select md5(string_agg(levels::text || coalesce(item_score::text,''), '|' order by seq))
       from public.assessment_items where assessment_id = a));
exception when others then
  perform pg_temp.vr_rec('舊單基準','寫入舊單意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：計分函式（純計算）新舊等級都認得、結果與改制前一致
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('1 等級換算','優良＝100','100', pg_temp.vr_q1($q$select public.assess_level_pct('優良')::text$q$));
  perform pg_temp.vr_eq('1 等級換算','尚可＝70','70',  pg_temp.vr_q1($q$select public.assess_level_pct('尚可')::text$q$));
  perform pg_temp.vr_eq('1 等級換算','待加強＝40','40', pg_temp.vr_q1($q$select public.assess_level_pct('待加強')::text$q$));
  perform pg_temp.vr_eq('1 等級換算','舊：優＝100','100', pg_temp.vr_q1($q$select public.assess_level_pct('優')::text$q$));
  perform pg_temp.vr_eq('1 等級換算','舊：良＝70','70',  pg_temp.vr_q1($q$select public.assess_level_pct('良')::text$q$));
  perform pg_temp.vr_eq('1 等級換算','舊：不及格＝0','0', pg_temp.vr_q1($q$select public.assess_level_pct('不及格')::text$q$));
  perform pg_temp.vr_eq('1 等級換算','不適用與亂寫＝null','(null)/(null)',
    pg_temp.vr_q1($q$select coalesce(public.assess_level_pct('不適用')::text,'(null)') || '/' || coalesce(public.assess_level_pct('超讚')::text,'(null)')$q$));

  perform pg_temp.vr_eq('1 題組分數','新：全優良＝100.0','100.0',
    pg_temp.vr_q1($q$select item_score::text from public.assess_score_item(pg_temp.vr_mk('優良','優良','優良','優良','優良','優良','優良'))$q$));
  perform pg_temp.vr_eq('1 題組分數','新：優良／尚可／待加強混合＝82.0（20+10.5+10.5+15+6+10+10）','82.0',
    pg_temp.vr_q1($q$select item_score::text from public.assess_score_item(pg_temp.vr_mk('優良','尚可','尚可','優良','待加強','優良','優良'))$q$));
  perform pg_temp.vr_eq('1 題組分數','舊：同樣組合（優良→優、尚可→良）＝82.0，與新單相同','82.0',
    pg_temp.vr_q1($q$select item_score::text from public.assess_score_item(pg_temp.vr_mk('優','良','良','優','待加強','優','優'))$q$));
  perform pg_temp.vr_eq('1 題組分數','舊：含不及格（風險意識 0）＝85.0，與改制前相同','85.0',
    pg_temp.vr_q1($q$select item_score::text from public.assess_score_item(pg_temp.vr_mk('優','優','優','優','不及格','優','優'))$q$));
  perform pg_temp.vr_eq('1 題組分數','新舊字串混在同一題組也算得出（優良＋良）＝95.5','95.5',
    pg_temp.vr_q1($q$select item_score::text from public.assess_score_item(pg_temp.vr_mk('優良','良','優','優','優','優','優'))$q$));
  perform pg_temp.vr_eq('1 題組分數','不適用不計入：2 個不適用其餘全優良＝100.0','100.0',
    pg_temp.vr_q1($q$select item_score::text from public.assess_score_item(pg_temp.vr_mk('優良','優良','優良','優良','優良','不適用','不適用'))$q$));
  begin
    perform * from public.assess_score_item(pg_temp.vr_mk('優良','優良','優良','不適用','不適用','不適用','優良'));
    perform pg_temp.vr_rec('1 題組分數','3 個不適用被拒（上限不變）','報錯：不適用最多 2 個', '沒報錯', false);
  exception when others then
    perform pg_temp.vr_rec('1 題組分數','3 個不適用被拒（上限不變）','報錯：不適用最多 2 個', sqlerrm, sqlerrm like '%不適用最多 2 個%');
  end;

  perform pg_temp.vr_eq('1 整場總分','新：82.0 與 100.0 的平均＝91.0','91.0',
    pg_temp.vr_q1($q$select total_score::text from public.assess_score_session(jsonb_build_array(
      pg_temp.vr_mk('優良','尚可','尚可','優良','待加強','優良','優良'), pg_temp.vr_mk('優良','優良','優良','優良','優良','優良','優良')))$q$));
  perform pg_temp.vr_eq('1 整場總分','舊：同組合（優／良）＝91.0','91.0',
    pg_temp.vr_q1($q$select total_score::text from public.assess_score_session(jsonb_build_array(
      pg_temp.vr_mk('優','良','良','優','待加強','優','優'), pg_temp.vr_mk('優','優','優','優','優','優','優')))$q$));
  perform pg_temp.vr_eq('1 整場總分','最弱面向：新單風險意識（待加強）','{風險意識}',
    pg_temp.vr_q1($q$select weakest_dims::text from public.assess_score_session(jsonb_build_array(
      pg_temp.vr_mk('優良','優良','優良','優良','待加強','優良','優良')))$q$));
  perform pg_temp.vr_eq('1 整場總分','最弱面向：舊單含不及格的面向仍判最弱','{風險意識}',
    pg_temp.vr_q1($q$select weakest_dims::text from public.assess_score_session(jsonb_build_array(
      pg_temp.vr_mk('優','良','良','良','不及格','優','待加強')))$q$));

  perform pg_temp.vr_eq('1 判定','新人 85.0 優秀','優秀/70', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(85.0, '新人')$q$));
  perform pg_temp.vr_eq('1 判定','新人 84.9 及格','及格/70', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(84.9, '新人')$q$));
  perform pg_temp.vr_eq('1 判定','新人 70.0 及格','及格/70', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(70.0, '新人')$q$));
  perform pg_temp.vr_eq('1 判定','新人 69.9 需複訓','需複訓/70', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(69.9, '新人')$q$));
  perform pg_temp.vr_eq('1 判定','新人 59.9 不及格（分數低於門檻的「不及格」判定仍在）','不及格/70', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(59.9, '新人')$q$));
  perform pg_temp.vr_eq('1 判定','正式 95.0 優秀','優秀/85', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(95.0, '正式')$q$));
  perform pg_temp.vr_eq('1 判定','正式 85.0 及格','及格/85', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(85.0, '正式')$q$));
  perform pg_temp.vr_eq('1 判定','正式 84.9 需複訓','需複訓/85', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(84.9, '正式')$q$));
  perform pg_temp.vr_eq('1 判定','正式 74.9 不及格','不及格/85', pg_temp.vr_q1($q$select verdict || '/' || pass_line from public.assess_verdict(74.9, '正式')$q$));
exception when others then
  perform pg_temp.vr_rec('區段 1','計分驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：暫存（assess_save_item）新字串可存、舊字串被擋、既有規則不變
-- ============================================================
do $$
declare
  cs text := 'vr-gcs1@2motor.tw';
  a uuid; i uuid; ia uuid; aa uuid;
  v_sv text := $q$select public.assess_save_item(%L::uuid, %L::jsonb, null)$q$;
  v_lv text := $q$select concat_ws('/', levels->>'資訊正確性', levels->>'預設訊息運用', levels->>'問題掌握', levels->>'主動引導') from public.assessment_items where id = %L$q$;
begin
  a := pg_temp.vr_asm('MI-9872', 'ZZ-G1', '正式'); i := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null);
  perform pg_temp.vr_eq('2 暫存','新字串（優良／尚可／待加強／不適用）可暫存','OK',
    pg_temp.vr_as('authenticated', cs, format(v_sv, i, '{"資訊正確性":"優良","預設訊息運用":"尚可","問題掌握":"待加強","主動引導":"不適用"}'), false));
  perform pg_temp.vr_eq('2 暫存','暫存後 levels 內容正確','優良/尚可/待加強/不適用', pg_temp.vr_q1(format(v_lv, i)));
  perform pg_temp.vr_deny('2 暫存','舊字串「優」被擋','authenticated', cs, format(v_sv, i, '{"資訊正確性":"優"}'), '%舊制等級%');
  perform pg_temp.vr_deny('2 暫存','舊字串「良」被擋','authenticated', cs, format(v_sv, i, '{"問題掌握":"良"}'), '%舊制等級%');
  perform pg_temp.vr_deny('2 暫存','舊字串「不及格」被擋','authenticated', cs, format(v_sv, i, '{"風險意識":"不及格"}'), '%舊制等級%');
  perform pg_temp.vr_eq('2 暫存','被擋時 levels 沒被改','優良/尚可/待加強/不適用', pg_temp.vr_q1(format(v_lv, i)));
  perform pg_temp.vr_deny('2 暫存','亂寫的等級仍被擋（既有規則）','authenticated', cs, format(v_sv, i, '{"資訊正確性":"超讚"}'), '%等級不正確%');
  perform pg_temp.vr_deny('2 暫存','3 個不適用仍被擋（既有規則）','authenticated', cs,
    format(v_sv, i, '{"資訊正確性":"不適用","預設訊息運用":"不適用","問題掌握":"不適用"}'), '%不適用最多 2 個%');
  perform pg_temp.vr_deny('2 暫存','未知面向仍被擋（既有規則）','authenticated', cs, format(v_sv, i, '{"亂寫":"優良"}'), '%未知的面向%');

  -- 舊草稿（含舊等級）沒改 levels 就不擋：模擬改制前就存在的草稿
  aa := pg_temp.vr_asm('MI-9873', 'ZZ-G1', '正式'); ia := pg_temp.vr_it(aa, 1, 'ZZ分類A', false, '{"資訊正確性":"優","問題掌握":"良"}'::jsonb);
  perform pg_temp.vr_eq('2 暫存','舊草稿原封不動重存（levels 沒變）不被擋','OK',
    pg_temp.vr_as('authenticated', cs, format(v_sv, ia, '{"資訊正確性":"優","問題掌握":"良"}'), false));
  perform pg_temp.vr_deny('2 暫存','舊草稿要改成別的舊字串仍被擋','authenticated', cs, format(v_sv, ia, '{"資訊正確性":"優","問題掌握":"不及格"}'), '%舊制等級%');
  perform pg_temp.vr_eq('2 暫存','舊草稿改成新字串可存','OK',
    pg_temp.vr_as('authenticated', cs, format(v_sv, ia, '{"資訊正確性":"優良","問題掌握":"尚可"}'), false));
exception when others then
  perform pg_temp.vr_rec('區段 2','暫存驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：面向備註（assess_save_dim_notes）
-- ============================================================
do $$
declare
  cs text := 'vr-gcs1@2motor.tw';
  a uuid; i uuid;
  v_nt text := $q$select public.assess_save_dim_notes(%L::uuid, %L::jsonb)$q$;
  v_cnt text := $q$select (select count(*) from jsonb_object_keys(dim_notes))::text from public.assessment_item_secrets where item_id = %L$q$;
begin
  a := pg_temp.vr_asm('MI-9874', 'ZZ-G1', '新人'); i := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null);
  perform pg_temp.vr_eq('3 備註','新建題組的 dim_notes 預設為空物件','{}',
    pg_temp.vr_q1(format($q$select dim_notes::text from public.assessment_item_secrets where item_id = %L$q$, i)));
  perform pg_temp.vr_save(i, pg_temp.vr_mk('優良','尚可','待加強','優良','不適用','優良','優良'), null);

  perform pg_temp.vr_eq('3 備註','尚可與待加強的備註可存（前後半形與全形空白去除）','OK',
    pg_temp.vr_as('authenticated', cs, format(v_nt, i, jsonb_build_object('預設訊息運用', E'  沒改寫預設訊息　', '問題掌握', '沒問異音時機')), false));
  perform pg_temp.vr_eq('3 備註','內容正確（已去空白）','沒改寫預設訊息/沒問異音時機',
    pg_temp.vr_q1(format($q$select (dim_notes->>'預設訊息運用') || '/' || (dim_notes->>'問題掌握') from public.assessment_item_secrets where item_id = %L$q$, i)));
  perform pg_temp.vr_eq('3 備註','優良與不適用面向也一起送，只留尚可／待加強的','OK',
    pg_temp.vr_as('authenticated', cs, format(v_nt, i, jsonb_build_object('資訊正確性', '優良不該有備註', '風險意識', '不適用不該有備註', '問題掌握', '留下')), false));
  perform pg_temp.vr_eq('3 備註','整組覆蓋：只剩 問題掌握 一則','1/留下',
    pg_temp.vr_q1(format($q$select (select count(*) from jsonb_object_keys(dim_notes))::text || '/' || (dim_notes->>'問題掌握') from public.assessment_item_secrets where item_id = %L$q$, i)));
  perform pg_temp.vr_as('authenticated', cs, format(v_nt, i, jsonb_build_object('問題掌握', E' 　 ')), false);
  perform pg_temp.vr_eq('3 備註','全空白備註不存（等於清空）','0', pg_temp.vr_q1(format(v_cnt, i)));
  perform pg_temp.vr_eq('3 備註','一個字也可以（無字數下限）','OK',
    pg_temp.vr_as('authenticated', cs, format(v_nt, i, jsonb_build_object('問題掌握', '遲')), false));
  perform pg_temp.vr_eq('3 備註','一個字有存進去','遲',
    pg_temp.vr_q1(format($q$select dim_notes->>'問題掌握' from public.assessment_item_secrets where item_id = %L$q$, i)));
  perform pg_temp.vr_eq('3 備註','2000 字可存','OK',
    pg_temp.vr_as('authenticated', cs, format(v_nt, i, jsonb_build_object('問題掌握', repeat('字', 2000))), false));
  perform pg_temp.vr_deny('3 備註','2001 字被拒','authenticated', cs, format(v_nt, i, jsonb_build_object('問題掌握', repeat('字', 2001))), '%太長%');
  perform pg_temp.vr_deny('3 備註','未知面向被拒','authenticated', cs, format(v_nt, i, '{"亂寫":"x"}'::jsonb), '%未知的面向%');
  perform pg_temp.vr_deny('3 備註','非文字被拒','authenticated', cs, format(v_nt, i, '{"問題掌握":123}'::jsonb), '%必須是文字%');
  perform pg_temp.vr_deny('3 備註','不是物件被拒','authenticated', cs, format(v_nt, i, '[1]'::jsonb), '%必須是物件%');
  perform pg_temp.vr_deny('3 備註','null 被拒','authenticated', cs, format($q$select public.assess_save_dim_notes(%L::uuid, null)$q$, i), '%必須是物件%');
  perform pg_temp.vr_deny('3 備註','找不到題組被拒','authenticated', cs, format(v_nt, gen_random_uuid(), '{}'::jsonb), '%找不到題組%');
  perform pg_temp.vr_eq('3 備註','被拒時既有備註不被動到（仍是 2000 字那則）','2000',
    pg_temp.vr_q1(format($q$select length(dim_notes->>'問題掌握')::text from public.assessment_item_secrets where item_id = %L$q$, i)));
  -- 改等級後再存備註：不再是尚可／待加強的面向，備註被丟掉
  perform pg_temp.vr_save(i, pg_temp.vr_mk('優良','尚可','優良','優良','不適用','優良','優良'), jsonb_build_object('問題掌握', '已改優良', '預設訊息運用', '仍是尚可'));
  perform pg_temp.vr_eq('3 備註','問題掌握改成優良後，該面向備註被丟掉、預設訊息運用的保留','1/仍是尚可',
    pg_temp.vr_q1(format($q$select (select count(*) from jsonb_object_keys(dim_notes))::text || '/' || (dim_notes->>'預設訊息運用') from public.assessment_item_secrets where item_id = %L$q$, i)));

  perform pg_temp.vr_deny('3 權限','另一位客服部（非建立者）被拒','authenticated', 'vr-gcs2@2motor.tw', format(v_nt, i, '{}'::jsonb), '%建立者本人%');
  perform pg_temp.vr_deny('3 權限','總公司主管被拒','authenticated', 'vr-ghq@2motor.tw', format(v_nt, i, '{}'::jsonb), '%沒有權限%');
  perform pg_temp.vr_deny('3 權限','店長被拒','authenticated', 'vr-gsm1@2motor.tw', format(v_nt, i, '{}'::jsonb), '%沒有權限%');
  perform pg_temp.vr_deny('3 權限','沒帳號的登入者被拒','authenticated', 'vr-gnobody@2motor.tw', format(v_nt, i, '{}'::jsonb), '%沒有權限%');
  perform pg_temp.vr_deny('3 權限','未登入（anon）不能執行','anon', null, format(v_nt, i, '{}'::jsonb), '%');
  perform pg_temp.vr_deny('3 草稿限定','已送出的成績單不能再寫面向備註','authenticated', cs,
    format(v_nt, pg_temp.vr_get('old_item1')::uuid, '{}'::jsonb), '%只有草稿%');
exception when others then
  perform pg_temp.vr_rec('區段 3','面向備註驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：送出把關（assess_submit 經觸發器）：新人備註必填、非新人不擋、舊等級保險
-- ============================================================
do $$
declare
  a uuid; i1 uuid; i2 uuid; ix uuid;
begin
  -- 4-1 新人：全優良＋2 個不適用，不需備註 → 送出成功
  a := pg_temp.vr_asm('MI-9875', 'ZZ-G1', '新人'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null);
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','優良','優良','優良','優良','不適用','不適用'), null);
  perform pg_temp.vr_eq('4 新人','全優良（含 2 個不適用）不需備註，送出成功','100.0/優秀/70', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('4 新人','送出後狀態 submitted','submitted', pg_temp.vr_status(a));

  -- 4-2 新人：尚可缺備註 → 被擋，狀態仍是草稿；補備註後可送
  a := pg_temp.vr_asm('MI-9876', 'ZZ-G1', '新人'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null);
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','尚可','優良','優良','優良','優良','優良'), null);
  perform pg_temp.vr_deny('4 新人','尚可缺備註被擋（訊息含題組序號、面向名與等級）','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select * from public.assess_submit(%L::uuid)$q$, a), '%新人考核：第 1 個題組的「預設訊息運用」評為「尚可」，必須寫下備註才能送出%');
  perform pg_temp.vr_eq('4 新人','被擋後仍是草稿','draft', pg_temp.vr_status(a));
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','尚可','優良','優良','優良','優良','優良'), '{"預設訊息運用":"沒依客人狀況改寫"}'::jsonb);
  perform pg_temp.vr_eq('4 新人','補上備註後送出成功（20+10.5+15+15+15+10+10＝95.5）','95.5/優秀/70', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('4 新人','備註隨成績單保留（機密表 dim_notes）','沒依客人狀況改寫',
    pg_temp.vr_q1(format($q$select dim_notes->>'預設訊息運用' from public.assessment_item_secrets where item_id = %L$q$, i1)));

  -- 4-3 新人：待加強缺備註被擋
  a := pg_temp.vr_asm('MI-9877', 'ZZ-G1', '新人'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null);
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','優良','優良','優良','待加強','優良','優良'), null);
  perform pg_temp.vr_deny('4 新人','待加強缺備註被擋（訊息含面向名與等級）','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select * from public.assess_submit(%L::uuid)$q$, a), '%新人考核：第 1 個題組的「風險意識」評為「待加強」，必須寫下備註才能送出%');

  -- 4-4 新人：備註只有空白＝沒寫（assess_save_dim_notes 不存空白）→ 被擋；一個字就夠
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','優良','優良','優良','待加強','優良','優良'), jsonb_build_object('風險意識', E'  　 '));
  perform pg_temp.vr_deny('4 新人','備註只有空白＝沒寫，被擋','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select * from public.assess_submit(%L::uuid)$q$, a), '%新人考核：%');
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','優良','優良','優良','待加強','優良','優良'), '{"風險意識":"漏"}'::jsonb);
  perform pg_temp.vr_eq('4 新人','備註只有 1 個字即可送出（20+15+15+15+6+10+10＝91.0）','91.0/優秀/70', pg_temp.vr_submit(a));

  -- 4-5 新人：兩個題組，第二題組缺備註 → 被擋並指出第 2 個題組
  a := pg_temp.vr_asm('MI-9878', 'ZZ-G1', '新人'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null); i2 := pg_temp.vr_it(a, 2, 'ZZ分類B', false, null);
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','尚可','優良','優良','優良','優良','優良'), '{"預設訊息運用":"有備註"}'::jsonb);
  perform pg_temp.vr_save(i2, pg_temp.vr_mk('優良','優良','優良','優良','優良','優良','待加強'), null);
  perform pg_temp.vr_deny('4 新人','第 2 個題組缺備註被擋，訊息指出第 2 個題組與面向','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select * from public.assess_submit(%L::uuid)$q$, a), '%新人考核：第 2 個題組的「文字品質」評為「待加強」%');

  -- 4-6 新人：追加題（is_extra）缺備註一樣被擋，補上後可送（追加題不計總分）
  a := pg_temp.vr_asm('MI-9879', 'ZZ-G1', '新人'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null); ix := pg_temp.vr_it(a, 2, 'ZZ分類X', true, null);
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','優良','優良','優良','優良','優良','優良'), null);
  perform pg_temp.vr_save(ix, pg_temp.vr_mk('優良','優良','尚可','優良','優良','優良','優良'), null);
  perform pg_temp.vr_deny('4 新人','追加題缺備註也被擋','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select * from public.assess_submit(%L::uuid)$q$, a), '%新人考核：第 2 個題組的「問題掌握」%');
  perform pg_temp.vr_save(ix, pg_temp.vr_mk('優良','優良','尚可','優良','優良','優良','優良'), '{"問題掌握":"追加題備註"}'::jsonb);
  perform pg_temp.vr_eq('4 新人','追加題補備註後送出成功（追加題不計總分，總分仍 100.0）','100.0/優秀/70', pg_temp.vr_submit(a));

  -- 4-7 正式（含回考核期）：尚可／待加強不強迫備註
  a := pg_temp.vr_asm('MI-9880', 'ZZ-G1', '正式'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, null);
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','尚可','待加強','優良','優良','優良','優良'), null);
  perform pg_temp.vr_eq('4 正式','正式：尚可＋待加強都沒備註仍可送出（20+10.5+6+15+15+10+10＝86.5，及格）','86.5/及格/85', pg_temp.vr_submit(a));

  -- 4-8 舊等級保險：草稿裡有舊字串（模擬改制前的舊草稿）→ 正式或新人都不能送出
  a := pg_temp.vr_asm('MI-9881', 'ZZ-G1', '正式'); i1 := pg_temp.vr_it(a, 1, 'ZZ分類A', false, pg_temp.vr_mk('優','良','優','優','優','優','優'));
  perform pg_temp.vr_deny('4 舊等級','舊草稿含舊字串，正式也不能送出（要先重新評分）','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select * from public.assess_submit(%L::uuid)$q$, a), '%第 1 個題組的「資訊正確性」還是舊制等級「優」%');
  perform pg_temp.vr_eq('4 舊等級','被擋後仍是草稿','draft', pg_temp.vr_status(a));
  perform pg_temp.vr_save(i1, pg_temp.vr_mk('優良','尚可','優良','優良','優良','優良','優良'), null);
  perform pg_temp.vr_eq('4 舊等級','重新評分成新字串後可送出（正式不需備註）','95.5/優秀/85', pg_temp.vr_submit(a));
  perform pg_temp.vr_deny('4 既有規則','已送出的不能再暫存','authenticated', 'vr-gcs1@2motor.tw',
    format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, null)$q$, i1), '%只有草稿%');
exception when others then
  perform pg_temp.vr_rec('區段 4','送出驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：舊單與新單並存：讀取、檢視、弱項分析、作廢、資料表層把關、抽查
-- ============================================================
do $$
declare
  old_a uuid := pg_temp.vr_get('old_asm')::uuid;
  old_i uuid := pg_temp.vr_get('old_item1')::uuid;
begin
  perform pg_temp.vr_eq('5 舊單','舊單等級字串原樣（優／良／不及格／待加強）','優/良/不及格/待加強',
    pg_temp.vr_q1(format($q$select concat_ws('/', levels->>'資訊正確性', levels->>'預設訊息運用', levels->>'風險意識', levels->>'文字品質') from public.assessment_items where id = %L$q$, old_i)));
  perform pg_temp.vr_eq('5 舊單','舊單用函式重算題組分數＝70.0（20+10.5+10.5+15+0+10+4，不及格＝0）','70.0',
    pg_temp.vr_q1(format($q$select item_score::text from public.assess_score_item((select levels from public.assessment_items where id = %L))$q$, old_i)));
  perform pg_temp.vr_eq('5 舊單','檢視 analytics_dim_rates（近期考核／雷達圖資料）：舊單 風險意識＝0、資訊正確性＝100、預設訊息運用＝70、文字品質＝40','0/100/70/40',
    pg_temp.vr_q1(format($q$select concat_ws('/',
        (select level_pct from public.analytics_dim_rates where item_id = %L and dim = '風險意識'),
        (select level_pct from public.analytics_dim_rates where item_id = %L and dim = '資訊正確性'),
        (select level_pct from public.analytics_dim_rates where item_id = %L and dim = '預設訊息運用'),
        (select level_pct from public.analytics_dim_rates where item_id = %L and dim = '文字品質'))$q$, old_i, old_i, old_i, old_i)));
  perform pg_temp.vr_eq('5 新單','同一檢視裡新單：尚可＝70、優良＝100（MI-9876 的成績單）','70/100',
    pg_temp.vr_q1($q$select concat_ws('/',
        (select level_pct from public.analytics_dim_rates r join public.assessments a on a.id = r.assessment_id where a.employee_id = 'MI-9876' and r.dim = '預設訊息運用'),
        (select level_pct from public.analytics_dim_rates r join public.assessments a on a.id = r.assessment_id where a.employee_id = 'MI-9876' and r.dim = '資訊正確性'))$q$));
  perform pg_temp.vr_eq('5 弱項分析','assess_weak_profile 同時吃新舊單不報錯','OK',
    pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw', $q$select * from public.assess_weak_profile('MI-9871')$q$, false));
  perform pg_temp.vr_eq('5 弱項分析','舊單弱項：風險意識平均（不及格＝0）低於預設訊息運用','true',
    pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw',
      $q$select ((select avg(public.assess_level_pct(i.levels ->> '風險意識')) from public.assessment_items i join public.assessments a on a.id = i.assessment_id where a.employee_id = 'MI-9871') <
                 (select avg(public.assess_level_pct(i.levels ->> '預設訊息運用')) from public.assessment_items i join public.assessments a on a.id = i.assessment_id where a.employee_id = 'MI-9871'))::text$q$, true));

  perform pg_temp.vr_eq('5 舊單','作廢舊單（只改狀態）不被觸發器擋','OK',
    pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw', format($q$select public.assess_void(%L::uuid, '驗證用作廢')$q$, old_a), false));
  perform pg_temp.vr_eq('5 舊單','作廢後舊單 levels 與題組分數指紋不變（沒有被換算或改寫）','true',
    pg_temp.vr_q1(format($q$select (md5(string_agg(levels::text || coalesce(item_score::text,''), '|' order by seq)) = %L)::text from public.assessment_items where assessment_id = %L$q$, pg_temp.vr_get('old_fp'), old_a)));

  begin
    insert into public.assessment_items (assessment_id, seq, category, levels)
    values (pg_temp.vr_asm('MI-9882', 'ZZ-G1', '正式'), 1, 'ZZ分類A', '{"資訊正確性":"優"}');
    perform pg_temp.vr_rec('5 資料表層','直接新增含「優」的題組被擋（即使不經函式）','報錯：舊制等級','沒報錯', false);
  exception when others then
    perform pg_temp.vr_rec('5 資料表層','直接新增含「優」的題組被擋（即使不經函式）','報錯：舊制等級', sqlerrm, sqlerrm like '%舊制等級%');
  end;
  begin
    update public.assessment_items set levels = '{"資訊正確性":"良"}' where id = old_i;
    perform pg_temp.vr_rec('5 資料表層','把舊單 levels 改成含「良」被擋（舊單等級不得被改寫）','報錯：舊制等級','沒報錯', false);
  exception when others then
    perform pg_temp.vr_rec('5 資料表層','把舊單 levels 改成含「良」被擋（舊單等級不得被改寫）','報錯：舊制等級', sqlerrm, sqlerrm like '%舊制等級%');
  end;
  update public.assessment_items set item_score = 71.5 where id = old_i;
  perform pg_temp.vr_eq('5 資料表層','不改 levels 的更新（舊單改分數欄）不被擋','71.5',
    pg_temp.vr_q1(format($q$select item_score::text from public.assessment_items where id = %L$q$, old_i)));
  update public.assessment_items set item_score = 70.0 where id = old_i;

  begin
    insert into public.spot_inspections (employee_id, employee_label, store_code, checked_on, message, levels, total_score, verdict, reason, examiner_email)
    values ('MI-9883', '假考生9883', 'ZZ-G1', current_date, 'https://example.invalid/chat', pg_temp.vr_mk('優良','尚可','優良','優良','優良','優良','優良'), 95.5, '適當', null, 'vr-gcs1@2motor.tw');
    perform pg_temp.vr_rec('5 抽查','抽查登記：新字串可寫入','OK','OK', true);
  exception when others then
    perform pg_temp.vr_rec('5 抽查','抽查登記：新字串可寫入','OK', sqlerrm, false);
  end;
  begin
    insert into public.spot_inspections (employee_id, employee_label, store_code, checked_on, message, levels, total_score, verdict, reason, examiner_email)
    values ('MI-9883', '假考生9883', 'ZZ-G1', current_date, 'https://example.invalid/chat', pg_temp.vr_mk('優','良','優','優','優','優','優'), 95.5, '適當', null, 'vr-gcs1@2motor.tw');
    perform pg_temp.vr_rec('5 抽查','抽查登記：舊字串被擋','報錯：舊制等級','沒報錯', false);
  exception when others then
    perform pg_temp.vr_rec('5 抽查','抽查登記：舊字串被擋','報錯：舊制等級', sqlerrm, sqlerrm like '%舊制等級%');
  end;
exception when others then
  perform pg_temp.vr_rec('區段 5','新舊並存驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：結構與權限
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('6 結構','dim_notes 欄位存在（jsonb、預設空物件、不可為空）','jsonb/{}/NO',
    pg_temp.vr_q1($q$select data_type || '/' || replace(split_part(column_default, '::', 1), '''', '') || '/' || is_nullable from information_schema.columns
                      where table_schema = 'public' and table_name = 'assessment_item_secrets' and column_name = 'dim_notes'$q$));
  perform pg_temp.vr_eq('6 結構','三個觸發器各一個（重跑不會重複）','3',
    pg_temp.vr_q1($q$select count(*)::text from pg_trigger where not tgisinternal and tgname in ('grade3_items_levels_trg','grade3_spot_levels_trg','grade3_submit_guard_trg')$q$));
  perform pg_temp.vr_eq('6 權限','authenticated 可執行 assess_save_dim_notes、anon 不行','true/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.assess_save_dim_notes(uuid, jsonb)', 'execute')::text || '/' ||
                           has_function_privilege('anon', 'public.assess_save_dim_notes(uuid, jsonb)', 'execute')::text$q$));
  perform pg_temp.vr_eq('6 權限','兩個觸發器函式不開放 authenticated／anon 直接呼叫','false/false/false/false',
    pg_temp.vr_q1($q$select concat_ws('/',
        has_function_privilege('authenticated', 'public.grade3_levels_guard()', 'execute')::text,
        has_function_privilege('anon', 'public.grade3_levels_guard()', 'execute')::text,
        has_function_privilege('authenticated', 'public.grade3_submit_guard()', 'execute')::text,
        has_function_privilege('anon', 'public.grade3_submit_guard()', 'execute')::text)$q$));
  perform pg_temp.vr_eq('6 可見性','店長讀機密表（含面向備註）看到 0 筆','0',
    pg_temp.vr_as('authenticated', 'vr-gsm1@2motor.tw', $q$select count(*)::text from public.assessment_item_secrets where dim_notes <> '{}'::jsonb$q$, true));
  perform pg_temp.vr_eq('6 可見性','總公司主管讀機密表看到 0 筆','0',
    pg_temp.vr_as('authenticated', 'vr-ghq@2motor.tw', $q$select count(*)::text from public.assessment_item_secrets where dim_notes <> '{}'::jsonb$q$, true));
  perform pg_temp.vr_eq('6 可見性','客服部讀得到面向備註（至少 1 筆）','true',
    pg_temp.vr_as('authenticated', 'vr-gcs1@2motor.tw', $q$select (count(*) >= 1)::text from public.assessment_item_secrets where dim_notes <> '{}'::jsonb$q$, true));
  perform pg_temp.vr_deny('6 可見性','店長不能直接改面向備註','authenticated', 'vr-gsm1@2motor.tw',
    $q$update public.assessment_item_secrets set dim_notes = '{}'::jsonb$q$, '%');
exception when others then
  perform pg_temp.vr_rec('區段 6','結構與權限驗證意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate grade3_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare grade3_vr_out as select * from (values (0, '
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
    execute 'deallocate grade3_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare grade3_vr_out as select '
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
execute grade3_vr_out;
