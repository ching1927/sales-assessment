-- ============================================================
-- 業務考核系統：考官備註文字開放主管與店長檢視 驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 assess_schema.sql 與 notes_visible_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-nxxx@2motor.tw，符合 accounts 網域檢查）／假成績單，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。
--   假成績單與題組以資料庫擁有者身分直接寫入（模擬 assess_draw 的結果），
--   備註一律透過真正的 assess_save_item 以客服部身分寫入，再把狀態改成已送出／已作廢。
-- 怎麼看結果：
--   * SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     所以腳本在 rollback 之前把結果表存成「預備陳述式 notes_visible_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；有失敗時，同一列會列出「未通過序號」。
--     「通過」欄全是「通過」才算驗證成功。
-- 假門市代碼 ZZ-N1／ZZ-N2、假員工編號 MI-9851～MI-9858、
--   假信箱 vr-ncs1／vr-ncs2／vr-nhq／vr-nsm1／vr-nsm2／vr-nobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 注意：區段 2「資料搬移」會對整個資料庫執行搬移與清空舊欄位的 SQL（與 notes_visible_schema.sql 的第 2、3 段相同），
--   但整段在交易內，最後 rollback，不會真的改到任何真實資料。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯停下（rollback 後無影響），不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null then
    raise exception '請先執行 assess_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_items'
                   and column_name = 'note') then
    raise exception '請先執行 notes_visible_schema.sql（assessment_items 還沒有 note 欄位）';
  end if;
  if to_regclass('public.analytics_dim_rates') is null or to_regclass('public.improvement_ticket_view') is null then
    raise exception '請先執行 backoffice_schema.sql（可見性檢查要實際查這兩個檢視）';
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

-- 直接寫入一張草稿成績單（考官 vr-ncs1；以資料庫擁有者身分）
create or replace function pg_temp.vr_asm(p_emp text, p_store text)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
  values
    (p_emp, '假考生' || right(p_emp, 4), p_store, 'vr-ncs1@2motor.tw', 'draft', '正式', '自動')
  returning id into v_id;
  return v_id;
end $$;

-- 直接寫入一個題組與它的機密列（模擬 assess_draw 的結果：secrets.note 為空）。
-- p_items_note／p_secret_note 讓「資料搬移」測項能造出不同的起始狀態。
create or replace function pg_temp.vr_it(p_asm uuid, p_seq int, p_cat text, p_items_note text, p_secret_note text)
returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.assessment_items (assessment_id, seq, category, code, levels, note)
  values (p_asm, p_seq, p_cat, 'ZZ' || p_seq, '{}'::jsonb, p_items_note)
  returning id into v_id;
  insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps, note)
  values (v_id, -9500 - p_seq, false, '機密標題', '[{"action":"a","point":"機密考點"}]'::jsonb, p_secret_note);
  return v_id;
end $$;

-- 草稿 → 已送出（以擁有者直接 UPDATE；判定「及格」不會自動開改善單）
create or replace function pg_temp.vr_submit(p_id uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  update public.assessments
     set status = 'submitted', total_score = 88, verdict = '及格', pass_line = 85,
         weakest_dims = '{主動引導}', submitted_at = now()
   where id = p_id;
end $$;

-- 已送出 → 已作廢
create or replace function pg_temp.vr_void(p_id uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  update public.assessments
     set status = 'voided', voided_at = now(), voided_by = 'vr-ncs1@2motor.tw', void_reason = '假作廢'
   where id = p_id;
end $$;

-- ============================================================
-- 建立假資料
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values
    ('ZZ-N1', 'ZZ測試門市戊'), ('ZZ-N2', 'ZZ測試門市己');

  insert into public.employees (id, nickname, store_code, job_title, status, include_in_assessment) values
    ('MI-9851', '假考生9851', 'ZZ-N1', '業務', '在職', true),
    ('MI-9852', '假考生9852', 'ZZ-N1', '業務', '在職', true),
    ('MI-9853', '假考生9853', 'ZZ-N2', '業務', '在職', true),
    ('MI-9854', '假考生9854', 'ZZ-N1', '業務', '在職', true),
    ('MI-9855', '假考生9855', 'ZZ-N1', '業務', '在職', true),
    ('MI-9856', '假考生9856', 'ZZ-N1', '業務', '在職', true),
    ('MI-9857', '假考生9857', 'ZZ-N1', '業務', '在職', true),
    ('MI-9858', '假考生9858', 'ZZ-N1', '業務', '在職', true);

  insert into public.app_users (email, role, store_code) values
    ('vr-ncs1@2motor.tw', 'cs_admin',      null),
    ('vr-ncs2@2motor.tw', 'cs_admin',      null),
    ('vr-nhq@2motor.tw',  'hq_viewer',     null),
    ('vr-nsm1@2motor.tw', 'store_manager', 'ZZ-N1'),
    ('vr-nsm2@2motor.tw', 'store_manager', 'ZZ-N2');
  -- vr-nobody@2motor.tw 刻意不建立帳號（有登入但沒帳號）
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：assess_save_item 備註寫入新欄位
-- ============================================================
do $$
declare
  cs  text := 'vr-ncs1@2motor.tw';
  cs2 text := 'vr-ncs2@2motor.tw';
  a1 uuid; i1 uuid;      -- 草稿（測寫入）
  a2 uuid; i2 uuid;      -- 已送出（測非草稿被拒）
  a3 uuid; i3 uuid;      -- 已作廢（測非草稿被拒）
  v_sv text := $q$select public.assess_save_item(%L::uuid, %L::jsonb, %s)$q$;
  v_n  text := $q$select coalesce(note, '(null)') from public.assessment_items where id = %L$q$;
  v_sn text := $q$select coalesce(note, '(null)') from public.assessment_item_secrets where item_id = %L$q$;
begin
  a1 := pg_temp.vr_asm('MI-9851', 'ZZ-N1'); i1 := pg_temp.vr_it(a1, 1, 'ZZ分類A', null, null);
  a2 := pg_temp.vr_asm('MI-9852', 'ZZ-N1'); i2 := pg_temp.vr_it(a2, 1, 'ZZ分類A', null, null);
  a3 := pg_temp.vr_asm('MI-9854', 'ZZ-N1'); i3 := pg_temp.vr_it(a3, 1, 'ZZ分類A', null, null);

  -- 1-1 客服部對草稿帶備註（前後有空白，確認 btrim 行為與原函式一致）
  perform pg_temp.vr_eq('1 寫入','客服部對自己的草稿帶備註暫存成功','OK',
    pg_temp.vr_as('authenticated', cs,
      format(v_sv, i1, '{"資訊正確性":"優"}', quote_literal('  考官備註甲  ')), false));
  perform pg_temp.vr_eq('1 寫入','備註寫進 assessment_items.note（前後空白已去除）','考官備註甲',
    pg_temp.vr_q1(format(v_n, i1)));
  perform pg_temp.vr_eq('1 寫入','assessment_item_secrets.note 不變（仍為 null）','(null)',
    pg_temp.vr_q1(format(v_sn, i1)));
  perform pg_temp.vr_eq('1 寫入','評分 levels 仍照常寫入','優',
    pg_temp.vr_q1(format($q$select levels ->> '資訊正確性' from public.assessment_items where id = %L$q$, i1)));
  perform pg_temp.vr_eq('1 寫入','機密標題未被動到','機密標題',
    pg_temp.vr_q1(format($q$select title from public.assessment_item_secrets where item_id = %L$q$, i1)));

  -- 1-2 備註為 null／空字串／全空白：與原函式一致＝清除備註（存成 null）
  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', quote_literal('先放一個備註')), false);
  perform pg_temp.vr_eq('1 寫入','先寫入備註（準備測清除）','先放一個備註', pg_temp.vr_q1(format(v_n, i1)));
  perform pg_temp.vr_eq('1 寫入','備註傳 null → 清除（null）','OK',
    pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', 'null'), false));
  perform pg_temp.vr_eq('1 寫入','備註傳 null 後 items.note 為 null','(null)', pg_temp.vr_q1(format(v_n, i1)));

  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', quote_literal('再放一個')), false);
  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', quote_literal('')), false);
  perform pg_temp.vr_eq('1 寫入','備註傳空字串 → 清除（null，不是空字串）','(null)', pg_temp.vr_q1(format(v_n, i1)));

  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', quote_literal('再放一個')), false);
  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', quote_literal('   ')), false);
  perform pg_temp.vr_eq('1 寫入','備註傳全半形空白 → 清除（null）','(null)', pg_temp.vr_q1(format(v_n, i1)));

  -- 1-3 超長備註（5000 字）可存，且不被截斷
  perform pg_temp.vr_eq('1 寫入','5000 字備註可存','OK',
    pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', $q$repeat('字', 5000)$q$), false));
  perform pg_temp.vr_eq('1 寫入','5000 字備註長度完整','5000',
    pg_temp.vr_q1(format($q$select length(note)::text from public.assessment_items where id = %L$q$, i1)));
  perform pg_temp.vr_eq('1 寫入','5000 字備註時 secrets.note 仍為 null','(null)', pg_temp.vr_q1(format(v_sn, i1)));

  -- 1-4 既有驗證一字不改：照樣被拒（且被拒時備註不被改）
  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i1, '{}', quote_literal('保持不變')), false);
  perform pg_temp.vr_deny('1 既有驗證','未知面向被拒','authenticated', cs,
    format(v_sv, i1, '{"亂寫":"優"}', quote_literal('不該寫入')), '%未知的面向%');
  perform pg_temp.vr_deny('1 既有驗證','等級不正確被拒','authenticated', cs,
    format(v_sv, i1, '{"資訊正確性":"超讚"}', quote_literal('不該寫入')), '%等級不正確%');
  perform pg_temp.vr_deny('1 既有驗證','不適用超過 2 個被拒','authenticated', cs,
    format(v_sv, i1, '{"資訊正確性":"不適用","預設訊息運用":"不適用","問題掌握":"不適用"}', quote_literal('不該寫入')),
    '%不適用最多 2%');
  perform pg_temp.vr_eq('1 既有驗證','驗證失敗時備註沒被改','保持不變', pg_temp.vr_q1(format(v_n, i1)));
  perform pg_temp.vr_eq('1 既有驗證','不適用剛好 2 個可暫存','OK',
    pg_temp.vr_as('authenticated', cs,
      format(v_sv, i1, '{"資訊正確性":"不適用","預設訊息運用":"不適用"}', quote_literal('兩個不適用')), false));
  perform pg_temp.vr_deny('1 既有驗證','找不到題組被拒','authenticated', cs,
    format(v_sv, gen_random_uuid(), '{}', quote_literal('x')), '%找不到題組%');

  -- 1-5 非本人、非客服部被拒
  perform pg_temp.vr_deny('1 權限','客服部但非建立者（vr-ncs2）被拒','authenticated', cs2,
    format(v_sv, i1, '{}', quote_literal('別人想改')), '%建立者本人%');
  perform pg_temp.vr_deny('1 權限','總公司主管被拒','authenticated', 'vr-nhq@2motor.tw',
    format(v_sv, i1, '{}', quote_literal('別人想改')), '%沒有權限%');
  perform pg_temp.vr_deny('1 權限','店長被拒','authenticated', 'vr-nsm1@2motor.tw',
    format(v_sv, i1, '{}', quote_literal('別人想改')), '%沒有權限%');
  perform pg_temp.vr_deny('1 權限','有登入但沒帳號被拒','authenticated', 'vr-nobody@2motor.tw',
    format(v_sv, i1, '{}', quote_literal('別人想改')), '%沒有權限%');
  perform pg_temp.vr_deny('1 權限','anon 不能呼叫（permission denied）','anon', null,
    format(v_sv, i1, '{}', quote_literal('別人想改')), '%permission denied%');
  perform pg_temp.vr_eq('1 權限','被拒之後備註沒被改','兩個不適用', pg_temp.vr_q1(format(v_n, i1)));

  -- 1-6 非草稿被拒：已送出、已作廢（備註不被改）
  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i2, '{}', quote_literal('送出前的備註')), false);
  perform pg_temp.vr_submit(a2);
  perform pg_temp.vr_deny('1 非草稿','已送出的成績單暫存被拒','authenticated', cs,
    format(v_sv, i2, '{}', quote_literal('送出後想改')), '%只有草稿%');
  perform pg_temp.vr_eq('1 非草稿','已送出被拒後備註沒被改','送出前的備註', pg_temp.vr_q1(format(v_n, i2)));

  perform pg_temp.vr_as('authenticated', cs, format(v_sv, i3, '{}', quote_literal('作廢前的備註')), false);
  perform pg_temp.vr_submit(a3);
  perform pg_temp.vr_void(a3);
  perform pg_temp.vr_deny('1 非草稿','已作廢的成績單暫存被拒','authenticated', cs,
    format(v_sv, i3, '{}', quote_literal('作廢後想改')), '%只有草稿%');
  perform pg_temp.vr_eq('1 非草稿','已作廢被拒後備註沒被改','作廢前的備註', pg_temp.vr_q1(format(v_n, i3)));
exception when others then
  perform pg_temp.vr_rec('區段 1','備註寫入意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：資料搬移與清空舊欄位（與 notes_visible_schema.sql 第 2、3 段相同的 SQL）
-- ============================================================
-- 下面的函式裡兩段 update，文字與 notes_visible_schema.sql 第 2 段（搬移）、第 3 段（清空舊欄位）完全相同
create or replace function pg_temp.vr_migrate(out moved bigint, out cleared bigint)
language plpgsql as $$
begin
  update public.assessment_items i
     set note = s.note
    from public.assessment_item_secrets s
   where s.item_id = i.id
     and nullif(btrim(s.note), '') is not null
     and nullif(btrim(i.note), '') is null;
  get diagnostics moved = row_count;

  update public.assessment_item_secrets s
     set note = null
    from public.assessment_items i
   where i.id = s.item_id
     and nullif(btrim(i.note), '') is not null
     and s.note is not null;
  get diagnostics cleared = row_count;
end $$;

do $$
declare
  a uuid;
  m1 uuid; m2 uuid; m3 uuid; m4 uuid; m5 uuid;
  v_n  text := $q$select coalesce(note, '(null)') from public.assessment_items where id = %L$q$;
  v_sn text := $q$select coalesce(note, '(null)') from public.assessment_item_secrets where item_id = %L$q$;
  r record;
begin
  perform set_config('request.jwt.claims', '', true);
  a := pg_temp.vr_asm('MI-9855', 'ZZ-N1');
  -- 起始狀態：secrets 有舊備註、items.note 的各種情況
  m1 := pg_temp.vr_it(a, 1, 'ZZ分類A', null,        '舊備註一');    -- 應搬移，舊欄位清空
  m2 := pg_temp.vr_it(a, 2, 'ZZ分類B', '新備註二',  '舊備註二');    -- items 已有不同值：不覆蓋；舊欄位清空
  m3 := pg_temp.vr_it(a, 3, 'ZZ分類C', null,        null);          -- 兩邊都空：維持空
  m4 := pg_temp.vr_it(a, 4, 'ZZ分類D', null,        '   ');      -- 舊備註只有半形空白：不搬、不清
  m5 := pg_temp.vr_it(a, 5, 'ZZ分類E', '',          '舊備註五');    -- items.note 是空字串：視為空，應搬移

  -- 第一次執行
  perform * from pg_temp.vr_migrate();

  perform pg_temp.vr_eq('2 搬移','舊備註有值、items.note 空 → 搬移成功','舊備註一', pg_temp.vr_q1(format(v_n, m1)));
  perform pg_temp.vr_eq('2 搬移','items.note 已有不同值 → 不被舊值覆蓋','新備註二', pg_temp.vr_q1(format(v_n, m2)));
  perform pg_temp.vr_eq('2 搬移','兩邊都空 → items.note 維持 null','(null)', pg_temp.vr_q1(format(v_n, m3)));
  perform pg_temp.vr_eq('2 搬移','舊備註只有空白 → 不搬（items.note 仍為 null）','(null)', pg_temp.vr_q1(format(v_n, m4)));
  perform pg_temp.vr_eq('2 搬移','items.note 是空字串 → 視為空，搬移成功','舊備註五', pg_temp.vr_q1(format(v_n, m5)));

  perform pg_temp.vr_eq('2 清舊欄位','搬移過的列：舊欄位 secrets.note 已清空','(null)', pg_temp.vr_q1(format(v_sn, m1)));
  perform pg_temp.vr_eq('2 清舊欄位','items 已有值的列：舊欄位也清空（第二筆）','(null)', pg_temp.vr_q1(format(v_sn, m2)));
  perform pg_temp.vr_eq('2 清舊欄位','第五筆搬移後舊欄位清空','(null)', pg_temp.vr_q1(format(v_sn, m5)));
  perform pg_temp.vr_eq('2 清舊欄位','items.note 為空的列，舊欄位不動（只有空白的那筆仍在）','true',
    pg_temp.vr_q1(format($q$select (note is not null)::text from public.assessment_item_secrets where item_id = %L$q$, m4)));
  perform pg_temp.vr_eq('2 清舊欄位','secrets.note 欄位本身保留（沒被刪除）','1',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_item_secrets' and column_name = 'note'$q$));
  perform pg_temp.vr_eq('2 清舊欄位','機密表其他欄位不受影響（title 仍在）','機密標題',
    pg_temp.vr_q1(format($q$select title from public.assessment_item_secrets where item_id = %L$q$, m1)));

  -- 第二次執行：可重複執行，不覆蓋、不重複、一列都不再處理
  select * into r from pg_temp.vr_migrate();
  perform pg_temp.vr_eq('2 搬移','重複執行：第二次沒有任何列被搬移','0', r.moved::text);
  perform pg_temp.vr_eq('2 清舊欄位','重複執行：第二次沒有任何列需要清空','0', r.cleared::text);
  perform pg_temp.vr_eq('2 搬移','重複執行後：搬移過的值不變','舊備註一', pg_temp.vr_q1(format(v_n, m1)));
  perform pg_temp.vr_eq('2 搬移','重複執行後：未覆蓋的值不變','新備註二', pg_temp.vr_q1(format(v_n, m2)));
  perform pg_temp.vr_eq('2 搬移','重複執行後：空的仍是空','(null)', pg_temp.vr_q1(format(v_n, m3)));
  perform pg_temp.vr_eq('2 搬移','重複執行後：第五筆不變','舊備註五', pg_temp.vr_q1(format(v_n, m5)));

  -- 搬移後使用者在草稿改備註，備註只寫 items.note，不會被舊值蓋回
  perform pg_temp.vr_eq('2 搬移','搬移後客服部改備註成功','OK',
    pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
      format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, '改過的備註')$q$, m1), false));
  perform pg_temp.vr_eq('2 搬移','改過的備註寫在 items.note','改過的備註', pg_temp.vr_q1(format(v_n, m1)));
  perform pg_temp.vr_eq('2 清舊欄位','改備註後舊欄位仍是 null（不再被寫入）','(null)', pg_temp.vr_q1(format(v_sn, m1)));

  -- 備註復活測試：使用者把備註清空後，重跑搬移不會把舊備註搬回來
  perform pg_temp.vr_eq('2 復活','客服部把備註清空（傳空字串）成功','OK',
    pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
      format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, '')$q$, m1), false));
  perform pg_temp.vr_eq('2 復活','清空後 items.note 為 null','(null)', pg_temp.vr_q1(format(v_n, m1)));
  perform set_config('request.jwt.claims', '', true);
  select * into r from pg_temp.vr_migrate();
  perform pg_temp.vr_eq('2 復活','重跑搬移後，已清空的備註沒有復活（仍為 null）','(null)', pg_temp.vr_q1(format(v_n, m1)));
  perform pg_temp.vr_eq('2 復活','重跑搬移：沒有任何列被搬移','0', r.moved::text);
  perform pg_temp.vr_eq('2 復活','重跑後舊欄位仍為 null','(null)', pg_temp.vr_q1(format(v_sn, m1)));
exception when others then
  perform pg_temp.vr_rec('區段 2','資料搬移意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：可見性矩陣（備註透過真正的 assess_save_item 寫入，再改狀態）
-- ============================================================
do $$
declare
  cs text := 'vr-ncs1@2motor.tw';
  d uuid; s1 uuid; s2 uuid; v uuid;          -- 草稿、已送出（門市 N1）、已送出（門市 N2）、已作廢（門市 N1）
  id_d uuid; id_s1 uuid; id_s2 uuid; id_v uuid;
begin
  perform set_config('request.jwt.claims', '', true);
  d  := pg_temp.vr_asm('MI-9856', 'ZZ-N1'); id_d  := pg_temp.vr_it(d,  1, 'ZZ分類A', null, null);
  s1 := pg_temp.vr_asm('MI-9857', 'ZZ-N1'); id_s1 := pg_temp.vr_it(s1, 1, 'ZZ分類A', null, null);
  s2 := pg_temp.vr_asm('MI-9853', 'ZZ-N2'); id_s2 := pg_temp.vr_it(s2, 1, 'ZZ分類A', null, null);
  v  := pg_temp.vr_asm('MI-9858', 'ZZ-N1'); id_v  := pg_temp.vr_it(v,  1, 'ZZ分類A', null, null);

  perform pg_temp.vr_set('x_d',  id_d::text);
  perform pg_temp.vr_set('x_s1', id_s1::text);
  perform pg_temp.vr_set('x_s2', id_s2::text);
  perform pg_temp.vr_set('x_v',  id_v::text);
  perform pg_temp.vr_set('x_as1', s1::text);   -- 已送出（甲店）那張成績單的 id，後面查檢視用

  -- 備註一律透過真正的函式寫入
  perform pg_temp.vr_eq('3 前提','寫入草稿備註','OK', pg_temp.vr_as('authenticated', cs,
    format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, '草稿備註')$q$, id_d), false));
  perform pg_temp.vr_eq('3 前提','寫入甲店備註','OK', pg_temp.vr_as('authenticated', cs,
    format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, '甲店備註')$q$, id_s1), false));
  perform pg_temp.vr_eq('3 前提','寫入乙店備註','OK', pg_temp.vr_as('authenticated', cs,
    format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, '乙店備註')$q$, id_s2), false));
  perform pg_temp.vr_eq('3 前提','寫入作廢前備註','OK', pg_temp.vr_as('authenticated', cs,
    format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, '作廢備註')$q$, id_v), false));

  -- 送出（草稿 d 維持草稿）；v 先送出再作廢
  perform pg_temp.vr_submit(s1);
  perform pg_temp.vr_submit(s2);
  perform pg_temp.vr_submit(v);
  perform pg_temp.vr_void(v);

  -- 在機密表放一筆舊備註（模擬舊資料），驗證主管與店長仍讀不到機密表
  perform set_config('request.jwt.claims', '', true);
  update public.assessment_item_secrets set note = '舊機密備註' where item_id = id_s1;

  perform pg_temp.vr_eq('3 前提','四張成績單狀態：草稿／已送出／已送出／已作廢','draft/submitted/submitted/voided',
    pg_temp.vr_q1(format($q$select (select status from public.assessments where id = %L) || '/' ||
                                   (select status from public.assessments where id = %L) || '/' ||
                                   (select status from public.assessments where id = %L) || '/' ||
                                   (select status from public.assessments where id = %L)$q$, d, s1, s2, v)));
exception when others then
  perform pg_temp.vr_rec('區段 3','可見性矩陣的準備工作意外中斷','無例外', sqlerrm, false);
end
$$;

do $$
declare
  r record;
  v_q text := $q$select count(*)::text || '/' || coalesce(max(note), '(null)') from public.assessment_items where id = %L$q$;
  v_ids text[] := array[pg_temp.vr_get('x_d'), pg_temp.vr_get('x_s1'), pg_temp.vr_get('x_s2'), pg_temp.vr_get('x_v')];
  v_labels text[] := array['草稿', '已送出（甲店）', '已送出（乙店）', '已作廢（甲店）'];
  v_notes text[] := array['草稿備註', '甲店備註', '乙店備註', '作廢備註'];
  k int;
  v_exp text;
  v_sec_total text := $q$select count(*)::text from public.assessment_item_secrets$q$;
begin
  -- 角色 × 四張成績單的備註可見性。vis_* 欄位依序：草稿、已送出甲店、已送出乙店、已作廢甲店
  for r in
    select * from (values
      ('客服部',            'vr-ncs1@2motor.tw',   true,  true,  true,  true),
      ('總公司主管',        'vr-nhq@2motor.tw',    false, true,  true,  false),
      ('甲店店長',          'vr-nsm1@2motor.tw',   false, true,  false, false),
      ('乙店店長',          'vr-nsm2@2motor.tw',   false, false, true,  false),
      ('有登入但沒帳號',    'vr-nobody@2motor.tw', false, false, false, false)
    ) as t(label, email, vis_d, vis_s1, vis_s2, vis_v)
  loop
    for k in 1..4 loop
      v_exp := case when (case k when 1 then r.vis_d when 2 then r.vis_s1 when 3 then r.vis_s2 else r.vis_v end)
                    then '1/' || v_notes[k] else '0/(null)' end;
      perform pg_temp.vr_eq('3 備註可見性', r.label || ' 讀「' || v_labels[k] || '」的 items.note',
        v_exp, pg_temp.vr_as('authenticated', r.email, format(v_q, v_ids[k]), true));
    end loop;
  end loop;

  -- anon 連資料表都不能讀
  perform pg_temp.vr_deny('3 備註可見性','未登入 anon 讀 assessment_items 被拒','anon', null,
    format(v_q, v_ids[2]), '%permission denied%');

  -- 機密表：只有客服部。主管、店長、無帳號、anon 都讀不到（含 title、steps、舊 note）
  perform pg_temp.vr_eq('3 機密表','客服部讀得到四個題組的機密列','4',
    pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
      format($q$select count(*)::text from public.assessment_item_secrets where item_id = any(%L::uuid[])$q$, v_ids), true));
  perform pg_temp.vr_eq('3 機密表','客服部讀得到 title','機密標題',
    pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
      format($q$select title from public.assessment_item_secrets where item_id = %L$q$, v_ids[2]), true));
  perform pg_temp.vr_eq('3 機密表','客服部讀得到舊欄位 secrets.note（舊資料保留）','舊機密備註',
    pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
      format($q$select note from public.assessment_item_secrets where item_id = %L$q$, v_ids[2]), true));
  perform pg_temp.vr_eq('3 機密表','新寫入的備註沒有進 secrets.note（除了手動放舊資料的甲店，其餘三筆仍為 null）','0',
    pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
      format($q$select count(*)::text from public.assessment_item_secrets
                where item_id = any(%L::uuid[]) and note is not null and item_id <> %L$q$,
             v_ids, v_ids[2]), true));

  for r in
    select * from (values
      ('總公司主管',     'vr-nhq@2motor.tw'),
      ('甲店店長',       'vr-nsm1@2motor.tw'),
      ('乙店店長',       'vr-nsm2@2motor.tw'),
      ('有登入但沒帳號', 'vr-nobody@2motor.tw')
    ) as t(label, email)
  loop
    perform pg_temp.vr_eq('3 機密表', r.label || ' 讀 assessment_item_secrets 全表：0 列', '0',
      pg_temp.vr_as('authenticated', r.email, v_sec_total, true));
    perform pg_temp.vr_eq('3 機密表', r.label || ' 讀不到 title／steps／舊 note', '0',
      pg_temp.vr_as('authenticated', r.email,
        $q$select count(*)::text from public.assessment_item_secrets
           where title = '機密標題' or steps is not null or note = '舊機密備註'$q$, true));
  end loop;
  perform pg_temp.vr_deny('3 機密表','未登入 anon 讀 assessment_item_secrets 被拒','anon', null,
    v_sec_total, '%permission denied%');

  -- 沒有任何人能繞過函式直接改 note
  perform pg_temp.vr_deny('3 直接寫入','客服部直接 UPDATE assessment_items.note 被拒（只能走函式）','authenticated',
    'vr-ncs1@2motor.tw', format($q$update public.assessment_items set note = '偷改' where id = %L$q$, v_ids[1]),
    '%permission denied%');
  perform pg_temp.vr_deny('3 直接寫入','主管直接 UPDATE assessment_items.note 被拒','authenticated',
    'vr-nhq@2motor.tw', format($q$update public.assessment_items set note = '偷改' where id = %L$q$, v_ids[2]),
    '%permission denied%');
  perform pg_temp.vr_deny('3 直接寫入','店長直接 UPDATE assessment_items.note 被拒','authenticated',
    'vr-nsm1@2motor.tw', format($q$update public.assessment_items set note = '偷改' where id = %L$q$, v_ids[2]),
    '%permission denied%');
  perform pg_temp.vr_eq('3 直接寫入','被拒之後備註沒被改','1/甲店備註',
    pg_temp.vr_q1(format(v_q, v_ids[2])));

  -- 沒有任何檢視把 note 暴露出去（欄位清單不含 note）
  perform pg_temp.vr_eq('3 檢視','assessment_summaries 沒有 note 欄位','0',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_summaries' and column_name = 'note'$q$));
  perform pg_temp.vr_eq('3 檢視','專案內其他檢視（analytics_dim_rates、improvement_ticket_view、accounts_list、employees_with_tenure）也沒有 note 欄位','0',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and column_name = 'note'
                       and table_name in ('analytics_dim_rates', 'improvement_ticket_view', 'accounts_list', 'employees_with_tenure')$q$));
  -- 以主管、店長身分「實際查」會碰到成績單的檢視：整列轉成文字後，不得出現任何備註內容
  --（不只比對欄名；同時確認檢視對該角色確實回得出假資料那張成績單，避免因為查不到資料而假通過）
  perform pg_temp.vr_eq('3 檢視','主管實際查 assessment_summaries 看得到假成績單（甲店已送出）','1',
    pg_temp.vr_as('authenticated', 'vr-nhq@2motor.tw',
      format($q$select count(*)::text from public.assessment_summaries where id = %L$q$, pg_temp.vr_get('x_as1')), true));
  perform pg_temp.vr_eq('3 檢視','店長實際查 assessment_summaries 看得到假成績單（甲店已送出）','1',
    pg_temp.vr_as('authenticated', 'vr-nsm1@2motor.tw',
      format($q$select count(*)::text from public.assessment_summaries where id = %L$q$, pg_temp.vr_get('x_as1')), true));
  perform pg_temp.vr_eq('3 檢視','主管實際查 analytics_dim_rates 看得到假成績單的題組','7',
    pg_temp.vr_as('authenticated', 'vr-nhq@2motor.tw',
      format($q$select count(*)::text from public.analytics_dim_rates where assessment_id = %L$q$, pg_temp.vr_get('x_as1')), true));
  for r in
    select * from (values
      ('總公司主管', 'vr-nhq@2motor.tw'),
      ('甲店店長',   'vr-nsm1@2motor.tw'),
      ('乙店店長',   'vr-nsm2@2motor.tw')
    ) as t(label, email)
  loop
    for k in 1..3 loop
      perform pg_temp.vr_eq('3 檢視', r.label || ' 實際查 ' ||
          (array['assessment_summaries', 'analytics_dim_rates', 'improvement_ticket_view'])[k] || '：整列內容不含任何備註文字',
        '0',
        pg_temp.vr_as('authenticated', r.email,
          format($q$select count(*)::text from public.%I t
                    where to_jsonb(t)::text ~ '(草稿|甲店|乙店|作廢)備註'$q$,
                 (array['assessment_summaries', 'analytics_dim_rates', 'improvement_ticket_view'])[k]), true));
    end loop;
  end loop;
  perform pg_temp.vr_eq('3 授權','authenticated／anon 對 assessment_items.note 沒有任何寫入類授權（只有 select）','0',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.column_privileges
                     where table_schema = 'public' and table_name = 'assessment_items'
                       and grantee in ('authenticated', 'anon') and column_name = 'note'
                       and privilege_type <> 'SELECT'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 3','可見性矩陣意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：既有函式簽名與回傳型別沒被改動；機密表 policy 沒被放寬
-- ============================================================
do $$
declare
  v_oid oid := 'public.assess_save_item(uuid, jsonb, text, text)'::regprocedure;
begin
  perform pg_temp.vr_eq('4 簽名','assess_save_item 只有一個版本（沒有多出不同簽名的重載）','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public' and p.proname = 'assess_save_item'$q$));
  perform pg_temp.vr_eq('4 簽名','參數：p_item_id uuid, p_levels jsonb, p_note text, p_note_url text（url_patch.sql 之後）','p_item_id uuid, p_levels jsonb, p_note text, p_note_url text',
    pg_get_function_identity_arguments(v_oid));
  perform pg_temp.vr_eq('4 簽名','回傳型別 void','void', pg_get_function_result(v_oid));
  perform pg_temp.vr_eq('4 簽名','仍是 security definer','true',
    (select prosecdef::text from pg_proc where oid = v_oid));
  perform pg_temp.vr_eq('4 簽名','search_path 設定不變','search_path=public, pg_temp',
    (select array_to_string(proconfig, ',') from pg_proc where oid = v_oid));
  perform pg_temp.vr_eq('4 簽名','語言仍是 plpgsql','plpgsql',
    (select l.lanname::text from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = v_oid));
  perform pg_temp.vr_eq('4 簽名','anon 不能 execute','false', has_function_privilege('anon', v_oid, 'execute')::text);
  perform pg_temp.vr_eq('4 簽名','authenticated 可以 execute','true', has_function_privilege('authenticated', v_oid, 'execute')::text);
  -- 只比對「寫入敘述」的形式（update／insert into／delete from 機密表），不比對註解或單純提到表名的文字
  perform pg_temp.vr_eq('4 內容','函式本體沒有對 assessment_item_secrets 的 update／insert／delete 寫入敘述','false',
    (select (prosrc ~* '(update|insert\s+into|delete\s+from)\s+(public\.)?assessment_item_secrets')::text
       from pg_proc where oid = v_oid));
  perform pg_temp.vr_eq('4 內容','函式本體有「update assessment_items … note = nullif(btrim(p_note)」寫入敘述','true',
    (select (prosrc ~* 'update\s+(public\.)?assessment_items\s+set\s+levels\s*=\s*p_levels,\s*note\s*=\s*nullif\(btrim\(p_note\)')::text
       from pg_proc where oid = v_oid));
  perform pg_temp.vr_eq('4 簽名','其他相關函式簽名未變：assess_draw 參數','p_assessment_id uuid, p_cats text[]',
    pg_get_function_identity_arguments('public.assess_draw(uuid, text[])'::regprocedure));
  perform pg_temp.vr_eq('4 簽名','其他相關函式簽名未變：assess_submit 回傳型別',
    'TABLE(total_score numeric, verdict text, pass_line integer, weakest_dims text[], tenure text, item_count integer)',
    pg_get_function_result('public.assess_submit(uuid)'::regprocedure));
  perform pg_temp.vr_eq('4 內容','assess_draw 沒有碰 note（本次不需調整）','false',
    (select (prosrc ~ '\mnote\M')::text from pg_proc where oid = 'public.assess_draw(uuid, text[])'::regprocedure));
  perform pg_temp.vr_eq('4 內容','assess_submit 沒有碰 note（本次不需調整）','false',
    (select (prosrc ~ '\mnote\M')::text from pg_proc where oid = 'public.assess_submit(uuid)'::regprocedure));
  -- policy 只數條數（沒放寬、沒多加），可見性一律用實際角色查詢驗證（不解析 policy 條件文字）
  perform pg_temp.vr_eq('4 policy','機密表 policy 條數仍是 1','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_policies where schemaname = 'public' and tablename = 'assessment_item_secrets'$q$));
  perform pg_temp.vr_eq('4 policy','assessment_items policy 條數仍是 1','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_policies where schemaname = 'public' and tablename = 'assessment_items'$q$));
  declare
    v_ids text := format('%L::uuid[]', array[pg_temp.vr_get('x_d'), pg_temp.vr_get('x_s1'), pg_temp.vr_get('x_s2'), pg_temp.vr_get('x_v')]);
  begin
    -- 四個假題組（草稿、甲店已送出、乙店已送出、甲店已作廢）各角色實際看到幾個
    perform pg_temp.vr_eq('4 可見性','客服部看得到 4 個題組、4 筆機密列','4/4',
      pg_temp.vr_as('authenticated', 'vr-ncs1@2motor.tw',
        format($q$select (select count(*) from public.assessment_items where id = any(%s))::text || '/' ||
                         (select count(*) from public.assessment_item_secrets where item_id = any(%s))::text$q$, v_ids, v_ids), true));
    perform pg_temp.vr_eq('4 可見性','總公司主管看得到 2 個題組（兩家已送出）、0 筆機密列','2/0',
      pg_temp.vr_as('authenticated', 'vr-nhq@2motor.tw',
        format($q$select (select count(*) from public.assessment_items where id = any(%s))::text || '/' ||
                         (select count(*) from public.assessment_item_secrets where item_id = any(%s))::text$q$, v_ids, v_ids), true));
    perform pg_temp.vr_eq('4 可見性','甲店店長看得到 1 個題組（甲店已送出）、0 筆機密列','1/0',
      pg_temp.vr_as('authenticated', 'vr-nsm1@2motor.tw',
        format($q$select (select count(*) from public.assessment_items where id = any(%s))::text || '/' ||
                         (select count(*) from public.assessment_item_secrets where item_id = any(%s))::text$q$, v_ids, v_ids), true));
    perform pg_temp.vr_eq('4 可見性','乙店店長看得到 1 個題組（乙店已送出）、0 筆機密列','1/0',
      pg_temp.vr_as('authenticated', 'vr-nsm2@2motor.tw',
        format($q$select (select count(*) from public.assessment_items where id = any(%s))::text || '/' ||
                         (select count(*) from public.assessment_item_secrets where item_id = any(%s))::text$q$, v_ids, v_ids), true));
  end;
  perform pg_temp.vr_eq('4 欄位','assessment_item_secrets.note 欄位仍保留（舊欄位停用但不刪）','1',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_item_secrets' and column_name = 'note'$q$));
  perform pg_temp.vr_eq('4 欄位','assessment_items.note 為 text、可為空','text/YES',
    pg_temp.vr_q1($q$select data_type || '/' || is_nullable from information_schema.columns
                     where table_schema = 'public' and table_name = 'assessment_items' and column_name = 'note'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 4','簽名與 policy 檢查意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate notes_visible_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare notes_visible_vr_out as select * from (values (0, '
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
    execute 'deallocate notes_visible_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare notes_visible_vr_out as select '
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
execute notes_visible_vr_out;
