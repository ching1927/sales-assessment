-- ============================================================
-- 業務考核系統：評分資料庫驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 assess_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw，符合 accounts 網域檢查）／假題庫，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：
--   * 因為 SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     腳本在 rollback 之前把結果表存成「預備陳述式 assess_vr_out」
--     （它是連線層級的物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- 注意：假題庫的 questions.id 會用掉幾個流水號（序號不會因 rollback 倒退），無害。
-- 假員工編號用 MI-9901～MI-9910、假門市代碼 ZZ-T1／ZZ-T2／ZZ-HQ、假分類 ZZ分類A／B／C／F，
-- 若你的真實資料剛好撞到這些，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.assessment_items') is null
     or to_regclass('public.assessment_item_secrets') is null then
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
create temp table vr_draw (
  tag text, item_id uuid, category text, code text, title text, steps jsonb,
  repeated boolean, new_round boolean
);
-- 題組 + 機密欄位（question_id、was_drawn_before 已移到機密表）的合併檢視，只給腳本以擁有者身分查
create temp view vr_q as
  select i.id as item_id, i.assessment_id, i.category, s.question_id, s.was_drawn_before
  from public.assessment_items i
  join public.assessment_item_secrets s on s.item_id = i.id;

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

-- 模擬登入：設定 JWT 的 email（本交易內有效）；p_email 為 null 代表未登入
create or replace function pg_temp.vr_login(p_email text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    case when p_email is null then ''
         else json_build_object('email', p_email, 'role', 'authenticated')::text end,
    true);
end $$;

-- 以指定資料庫角色（authenticated／anon）＋指定 email 執行一段 SQL。
-- p_scalar = true：SQL 必須回傳單一值，回傳該值的文字；false：只執行，成功回 'OK'。
-- 失敗回 'ERROR: 訊息'。失敗時子交易自動回復，不會讓整個腳本中斷。
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

-- 預期「這段 SQL 會報錯」，且錯誤訊息符合 like 樣式（以目前身分執行，不切換角色）
create or replace function pg_temp.vr_err(p_grp text, p_name text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare
  v_msg text := '(沒有報錯)';
begin
  begin
    execute p_sql;
  exception when others then
    v_msg := sqlerrm;
  end;
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_msg, v_msg like p_pattern);
end $$;

-- 組出七面向評分物件
create or replace function pg_temp.vr_mk(a text, b text, c text, d text, e text, f text, g text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('資訊正確性', a, '預設訊息運用', b, '問題掌握', c, '主動引導', d,
                            '風險意識', e, '語氣與禮貌', f, '文字品質', g);
$$;

-- ============================================================
-- 區段 1：純計算（題組分數、整場總分、判定、拒絕不合法輸入）
-- ============================================================
do $$
declare
  t text[];
  v_v1 jsonb := pg_temp.vr_mk('良','優','良','待加強','優','良','優');
begin
  -- V1：77.5
  perform pg_temp.vr_eq('V1','題組分數','77.5',
    (select s.item_score::text from public.assess_score_item(v_v1) s));
  perform pg_temp.vr_eq('V1','最弱面向','主動引導',
    (select array_to_string(s.weakest_dims, ',') from public.assess_score_item(v_v1) s));
  perform pg_temp.vr_eq('V1','沒有不適用','',
    (select array_to_string(s.na_dims, ',') from public.assess_score_item(v_v1) s));
  perform pg_temp.vr_eq('V1','新人判定（77.5）','及格',
    (select v.verdict from public.assess_verdict(77.5, '新人') v));
  perform pg_temp.vr_eq('V1','正式判定（77.5，未達合格線 85）','需複訓',
    (select v.verdict from public.assess_verdict(77.5, '正式') v));
  perform pg_temp.vr_eq('V1','面向得分：資訊正確性 20×70%','14',
    (select s.dim_points ->> '資訊正確性' from public.assess_score_item(v_v1) s));
  perform pg_temp.vr_eq('V1','面向得分：主動引導 15×40%','6',
    (select s.dim_points ->> '主動引導' from public.assess_score_item(v_v1) s));
  perform pg_temp.vr_eq('V1','面向得分：問題掌握 15×70%','10.5',
    (select s.dim_points ->> '問題掌握' from public.assess_score_item(v_v1) s));

  -- V2：風險意識、文字品質不適用 → 70.0
  perform pg_temp.vr_eq('V2','題組分數','70.0',
    (select s.item_score::text
     from public.assess_score_item(pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用')) s));
  perform pg_temp.vr_eq('V2','不適用面向','風險意識,文字品質',
    (select array_to_string(s.na_dims, ',')
     from public.assess_score_item(pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用')) s));
  perform pg_temp.vr_eq('V2','最弱面向（不適用不參與）','主動引導',
    (select array_to_string(s.weakest_dims, ',')
     from public.assess_score_item(pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用')) s));
  perform pg_temp.vr_eq('V2','不適用面向的得分為 null','null',
    (select (s.dim_points -> '風險意識')::text
     from public.assess_score_item(pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用')) s));
  perform pg_temp.vr_eq('V2','新人判定（70.0 剛好合格線）','及格',
    (select v.verdict from public.assess_verdict(70.0, '新人') v));
  perform pg_temp.vr_eq('V2','正式判定（70.0）','不及格',
    (select v.verdict from public.assess_verdict(70.0, '正式') v));

  -- V3：全優
  perform pg_temp.vr_eq('V3','題組分數','100.0',
    (select s.item_score::text from public.assess_score_item(pg_temp.vr_mk('優','優','優','優','優','優','優')) s));
  perform pg_temp.vr_eq('V3','最弱七個並列（依固定順序）','資訊正確性,預設訊息運用,問題掌握,主動引導,風險意識,語氣與禮貌,文字品質',
    (select array_to_string(s.weakest_dims, ',')
     from public.assess_score_item(pg_temp.vr_mk('優','優','優','優','優','優','優')) s));

  -- V4：全不及格
  perform pg_temp.vr_eq('V4','題組分數','0.0',
    (select s.item_score::text
     from public.assess_score_item(pg_temp.vr_mk('不及格','不及格','不及格','不及格','不及格','不及格','不及格')) s));

  -- V5：兩題組 77.5 + 100.0 → 88.8
  perform pg_temp.vr_eq('T88','兩題組 77.5＋100.0 → 整場總分（88.75 五入）','88.8',
    (select s.total_score::text
     from public.assess_score_session(jsonb_build_array(v_v1, pg_temp.vr_mk('優','優','優','優','優','優','優'))) s));
  perform pg_temp.vr_eq('V5','整場最弱面向','主動引導',
    (select array_to_string(s.weakest_dims, ',')
     from public.assess_score_session(jsonb_build_array(v_v1, pg_temp.vr_mk('優','優','優','優','優','優','優'))) s));
  perform pg_temp.vr_eq('V5','新人判定（88.8）','優秀',
    (select v.verdict from public.assess_verdict(88.8, '新人') v));
  perform pg_temp.vr_eq('V5','正式判定（88.8）','及格',
    (select v.verdict from public.assess_verdict(88.8, '正式') v));
  -- 整場最弱：不適用不計入分母（V2 風險意識不適用，只剩 V1 的 優=100 一筆）
  perform pg_temp.vr_eq('V5','整場最弱：某面向只有部分題組適用時只算適用者','主動引導',
    (select array_to_string(s.weakest_dims, ',')
     from public.assess_score_session(jsonb_build_array(
            v_v1, pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用'))) s));
  perform pg_temp.vr_eq('V5','整場總分（77.5 與 70.0 平均 73.75 進位）','73.8',
    (select s.total_score::text
     from public.assess_score_session(jsonb_build_array(
            v_v1, pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用'))) s));

  -- 題組分數剛好 70.5（資訊正確性待加強、預設訊息運用良、文字品質不及格，其餘優：
  -- 800+1050+1500+1500+1500+700+0 = 7050，÷100），與 V2 的 70.0 平均 70.25 → 五入 70.3
  perform pg_temp.vr_eq('70.25','題組分數 70.5','70.5',
    (select s.item_score::text
     from public.assess_score_item(pg_temp.vr_mk('待加強','良','優','優','優','良','不及格')) s));
  perform pg_temp.vr_eq('70.25','整場平均 (70.5+70.0)/2=70.25 → 五入 70.3','70.3',
    (select s.total_score::text
     from public.assess_score_session(jsonb_build_array(
            pg_temp.vr_mk('待加強','良','優','優','優','良','不及格'),
            pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用'))) s));

  -- 拒絕不合法輸入
  perform pg_temp.vr_err('拒絕','不適用 3 個',
    $q$select * from public.assess_score_item(pg_temp.vr_mk('不適用','不適用','不適用','優','優','優','優'))$q$,
    '%不適用最多%');
  perform pg_temp.vr_err('拒絕','缺面向',
    $q$select * from public.assess_score_item('{"資訊正確性":"優"}'::jsonb)$q$,
    '%七個面向必須全部有值%');
  perform pg_temp.vr_err('拒絕','未知等級',
    $q$select * from public.assess_score_item(pg_temp.vr_mk('普通','優','優','優','優','優','優'))$q$,
    '%等級不正確%');
  perform pg_temp.vr_err('拒絕','未知面向',
    $q$select * from public.assess_score_item((pg_temp.vr_mk('優','優','優','優','優','優','優') - '文字品質') || '{"亂寫":"優"}'::jsonb)$q$,
    '%未知的面向%');
  perform pg_temp.vr_err('拒絕','評分不是物件',
    $q$select * from public.assess_score_item(null)$q$,
    '%格式不正確%');
  perform pg_temp.vr_err('拒絕','整場沒有題組',
    $q$select * from public.assess_score_session('[]'::jsonb)$q$,
    '%至少要有 1 個題組%');
  perform pg_temp.vr_err('拒絕','判定：身分不明',
    $q$select * from public.assess_verdict(80, '實習')$q$,
    '%新人%正式%');
  perform pg_temp.vr_err('拒絕','判定：總分超過 100',
    $q$select * from public.assess_verdict(101, '新人')$q$,
    '%0 到 100%');

  -- 判定邊界（身分、總分、預期判定）
  foreach t slice 1 in array array[
    ['新人','59.9','不及格'], ['新人','60.0','需複訓'],
    ['新人','69.9','需複訓'], ['新人','70.0','及格'],
    ['新人','84.9','及格'],   ['新人','85.0','優秀'],
    ['正式','74.9','不及格'], ['正式','75.0','需複訓'],
    ['正式','84.9','需複訓'], ['正式','85.0','及格'],
    ['正式','94.9','及格'],   ['正式','95.0','優秀']
  ] loop
    perform pg_temp.vr_eq('判定邊界', t[1] || ' ' || t[2], t[3],
      (select v.verdict from public.assess_verdict(t[2]::numeric, t[1]) v));
  end loop;
  perform pg_temp.vr_eq('判定邊界','新人合格線','70',
    (select v.pass_line::text from public.assess_verdict(80, '新人') v));
  perform pg_temp.vr_eq('判定邊界','正式合格線','85',
    (select v.pass_line::text from public.assess_verdict(80, '正式') v));
exception when others then
  perform pg_temp.vr_rec('區段 1','純計算意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 建立假資料（以資料庫擁有者身分直接寫入，rollback 後消失）
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  -- 先記下舊抽選器「真實資料」的筆數，最後比對有沒有被動到
  perform pg_temp.vr_set('real_questions',
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_set('real_drawn',
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_set('real_last',
    (select count(*)::text from public.category_last where category not like 'ZZ%'));

  insert into public.stores (code, name) values
    ('ZZ-T1', 'ZZ測試門市甲'), ('ZZ-T2', 'ZZ測試門市乙'), ('ZZ-HQ', 'ZZ測試總公司');

  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment) values
    ('MI-9901', '假新人甲', 'ZZ-T1', '業務', v_today - 30,  '在職', true),
    ('MI-9902', '假正式乙', 'ZZ-T1', '業務', v_today - 200, '在職', true),
    ('MI-9903', '假無到職日', 'ZZ-T1', '業務', null,        '在職', true),
    ('MI-9904', '假不納入', 'ZZ-T1', '店長', v_today - 400, '在職', false),
    ('MI-9905', '假離職',   'ZZ-T1', '業務', v_today - 400, '離職', true),
    ('MI-9906', '假他店員', 'ZZ-T2', '業務', v_today - 30,  '在職', true),
    ('MI-9907', '假第90天', 'ZZ-T1', '業務', v_today - 90,  '在職', true),
    ('MI-9908', '假第91天', 'ZZ-T1', '業務', v_today - 91,  '在職', true),
    ('MI-9909', '假正式丙', 'ZZ-T1', '業務', v_today - 200, '在職', true);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw',  'cs_admin',      null),
    ('vr-cs2@2motor.tw',  'cs_admin',      null),
    ('vr-hq@2motor.tw',   'hq_viewer',     null),
    ('vr-sm1@2motor.tw',  'store_manager', 'ZZ-T1'),
    ('vr-sm2@2motor.tw',  'store_manager', 'ZZ-T2');

  insert into public.questions (category, code, title, steps) values
    ('ZZ分類A', 'A1', '假題組A1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類A', 'A2', '假題組A2', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類A', 'A3', '假題組A3', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類B', 'B1', '假題組B1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類B', 'B2', '假題組B2', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類C', 'C1', '假題組C1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類F', 'F1', '假題組F1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類F', 'F2', '假題組F2', '[{"action":"動作1","point":"考點1"}]'::jsonb);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：權限矩陣
-- ============================================================

-- 2-0 直接寫入測試資料：草稿、已送出、作廢各一（門市甲），另加門市乙已送出一筆
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_qa bigint := (select min(id) from public.questions where category = 'ZZ分類A');
  v_d uuid; v_s uuid; v_v uuid; v_s2 uuid; v_x uuid; v_i uuid;
  v_iids text := '';
begin
  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot)
  values ('MI-9902', '假正式乙', 'ZZ-T1', 'vr-cs1@2motor.tw', 'draft', '正式', '自動', v_today - 200)
  returning id into v_d;

  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot,
                                  total_score, verdict, pass_line, weakest_dims, submitted_at)
  values ('MI-9902', '假正式乙', 'ZZ-T1', 'vr-cs1@2motor.tw', 'submitted', '正式', '自動', v_today - 200,
          77.5, '需複訓', 85, '{主動引導}', now())
  returning id into v_s;

  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot,
                                  total_score, verdict, pass_line, weakest_dims, submitted_at, voided_at, voided_by, void_reason)
  values ('MI-9902', '假正式乙', 'ZZ-T1', 'vr-cs1@2motor.tw', 'voided', '正式', '自動', v_today - 200,
          77.5, '需複訓', 85, '{主動引導}', now(), now(), 'vr-cs1@2motor.tw', '假作廢')
  returning id into v_v;

  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot,
                                  total_score, verdict, pass_line, weakest_dims, submitted_at)
  values ('MI-9906', '假他店員', 'ZZ-T2', 'vr-cs1@2motor.tw', 'submitted', '新人', '自動', v_today - 30,
          77.5, '及格', 70, '{主動引導}', now())
  returning id into v_s2;

  foreach v_x in array array[v_d, v_s, v_v, v_s2] loop
    insert into public.assessment_items (assessment_id, seq, category, code, levels)
    values (v_x, 1, 'ZZ分類A', 'A1', '{}'::jsonb)
    returning id into v_i;
    insert into public.assessment_item_secrets (item_id, question_id, was_drawn_before, title, steps, note)
    values (v_i, v_qa, false, '機密標題', '[{"action":"a","point":"p"}]'::jsonb, '機密備註');
    -- 每筆考核的題組各附一張備註圖片（直接寫入），測各角色看不看得到
    insert into public.assessment_item_images (item_id, storage_path, mime, size_bytes)
    values (v_i, v_x::text || '/' || v_i::text || '/zz-matrix.jpg', 'image/jpeg', 1000);
    v_iids := v_iids || case when v_iids = '' then '' else ',' end || quote_literal(v_i::text);
  end loop;

  perform pg_temp.vr_set('m_ids', format('%L,%L,%L,%L', v_d, v_s, v_v, v_s2));
  perform pg_temp.vr_set('m_iids', v_iids);
  perform pg_temp.vr_set('m_sub', v_s::text);
  perform pg_temp.vr_set('m_item', (select id::text from public.assessment_items where assessment_id = v_s));
  perform pg_temp.vr_set('m_draft', v_d::text);
  perform pg_temp.vr_set('m_void', v_v::text);
  perform pg_temp.vr_set('m_sub2', v_s2::text);
exception when others then
  perform pg_temp.vr_rec('區段 2','建立矩陣測試資料意外中斷','無例外', sqlerrm, false);
end
$$;

-- 2-1 各角色可見筆數（草稿／已送出／作廢）、機密表、成績單檢視
do $$
declare
  r record;
  v_ids text := pg_temp.vr_get('m_ids');
  v_iids text := pg_temp.vr_get('m_iids');
  q1 text; q2 text; q3 text; q4 text; q5 text;
begin
  q1 := format($q$select count(*) filter (where status='draft')::text || '/' || count(*) filter (where status='submitted')::text
                       || '/' || count(*) filter (where status='voided')::text
                  from public.assessments where id in (%s)$q$, v_ids);
  q2 := format($q$select count(*)::text from public.assessment_items where assessment_id in (%s)$q$, v_ids);
  q3 := format($q$select count(*)::text from public.assessment_item_secrets where item_id in (%s)$q$, v_iids);
  q4 := format($q$select count(*)::text from public.assessment_summaries where id in (%s)$q$, v_ids);
  q5 := format($q$select count(*)::text from public.assessment_item_images where item_id in (%s)$q$, v_iids);

  for r in
    select * from (values
      ('客服部',      'authenticated', 'vr-cs1@2motor.tw',   '1/2/1', '4', '4', '4', '4'),
      ('總公司主管',  'authenticated', 'vr-hq@2motor.tw',    '0/2/0', '2', '0', '2', '2'),
      ('店長（門市甲）','authenticated', 'vr-sm1@2motor.tw',  '0/1/0', '1', '0', '1', '1'),
      ('店長（門市乙）','authenticated', 'vr-sm2@2motor.tw',  '0/1/0', '1', '0', '1', '1'),
      ('有登入但沒帳號','authenticated', 'vr-nobody@2motor.tw','0/0/0', '0', '0', '0', '0')
    ) as t(label, rl, email, e_status, e_items, e_secrets, e_view, e_img)
  loop
    perform pg_temp.vr_eq('權限矩陣', r.label || '：assessments 草稿/已送出/作廢 筆數', r.e_status, pg_temp.vr_as(r.rl, r.email, q1, true));
    perform pg_temp.vr_eq('權限矩陣', r.label || '：assessment_items 筆數', r.e_items, pg_temp.vr_as(r.rl, r.email, q2, true));
    perform pg_temp.vr_eq('權限矩陣', r.label || '：assessment_item_secrets（機密）筆數', r.e_secrets, pg_temp.vr_as(r.rl, r.email, q3, true));
    perform pg_temp.vr_eq('權限矩陣', r.label || '：assessment_summaries 檢視筆數', r.e_view, pg_temp.vr_as(r.rl, r.email, q4, true));
    perform pg_temp.vr_eq('權限矩陣', r.label || '：assessment_item_images（備註圖片）筆數', r.e_img, pg_temp.vr_as(r.rl, r.email, q5, true));
  end loop;

  -- 未登入 anon：四個物件都不能讀
  perform pg_temp.vr_eq('權限矩陣', '未登入 anon：五個物件（含備註圖片表）都被拒絕讀取', '5/5',
    (select count(*)::text || '/5' from (values (q1), (q2), (q3), (q4), (q5)) as t(sql)
      where pg_temp.vr_as('anon', null, t.sql, true) like 'ERROR: permission denied%'));

  -- 檢視與題組表沒有機密欄位
  perform pg_temp.vr_eq('權限矩陣', 'assessment_summaries 沒有 title／steps／note 欄位', '0',
    (select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'assessment_summaries'
        and column_name in ('title', 'steps', 'note')));
  perform pg_temp.vr_eq('權限矩陣', 'assessment_items 沒有 title／steps／question_id／was_drawn_before 欄位', '0',
    (select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'assessment_items'
        and column_name in ('title', 'steps', 'question_id', 'was_drawn_before')));
  perform pg_temp.vr_eq('權限矩陣', 'assessment_summaries 沒有 question_id／was_drawn_before 欄位', '0',
    (select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'assessment_summaries'
        and column_name in ('question_id', 'was_drawn_before')));
  perform pg_temp.vr_eq('權限矩陣', '機密表有 question_id／was_drawn_before 欄位', '2',
    (select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'assessment_item_secrets'
        and column_name in ('question_id', 'was_drawn_before')));
  perform pg_temp.vr_eq('權限矩陣', '總公司主管讀 assessment_items.question_id 被拒（欄位不存在）', 'ERROR',
    split_part(pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw',
      'select count(question_id)::text from public.assessment_items', true), ':', 1));
  perform pg_temp.vr_eq('權限矩陣', '總公司主管讀機密表 question_id 看不到任何列', '0',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw',
      'select count(*)::text from public.assessment_item_secrets', true));
  perform pg_temp.vr_eq('權限矩陣', 'assessment_summaries 是 security_invoker', 'true',
    (select (coalesce(reloptions::text, '') like '%security_invoker=true%')::text
       from pg_class where oid = 'public.assessment_summaries'::regclass));
  perform pg_temp.vr_eq('權限矩陣', '三張新表都開了 RLS',
    'assessment_item_secrets:true,assessment_items:true,assessments:true',
    (select string_agg(relname || ':' || relrowsecurity::text, ',' order by relname)
       from pg_class
      where oid in ('public.assessments'::regclass, 'public.assessment_items'::regclass,
                    'public.assessment_item_secrets'::regclass)));
exception when others then
  perform pg_temp.vr_rec('區段 2','可見筆數意外中斷','無例外', sqlerrm, false);
end
$$;

-- 2-2 直接 insert／update／delete 一律被拒（包含客服部）
do $$
declare
  r record;
  v_sub text := pg_temp.vr_get('m_sub');
  v_item text := pg_temp.vr_get('m_item');
  v_stmts text[];
  v_sql text;
  v_n int;
begin
  v_stmts := array[
    $q$insert into public.assessments (employee_id, store_code, examiner_email, tenure, tenure_source)
       values ('MI-9902', 'ZZ-T1', 'vr-x@2motor.tw', '正式', '自動')$q$,
    format($q$update public.assessments set void_reason = 'x' where id = %L$q$, v_sub),
    format($q$delete from public.assessments where id = %L$q$, v_sub),
    format($q$insert into public.assessment_items (assessment_id, seq, category)
              values (%L, 99, 'ZZ')$q$, v_sub),
    format($q$update public.assessment_items set category = 'x' where id = %L$q$, v_item),
    format($q$delete from public.assessment_items where id = %L$q$, v_item),
    format($q$insert into public.assessment_item_secrets (item_id, title) values (%L, 'x')$q$, v_item),
    format($q$update public.assessment_item_secrets set title = 'x' where item_id = %L$q$, v_item),
    format($q$delete from public.assessment_item_secrets where item_id = %L$q$, v_item),
    format($q$insert into public.assessment_item_images (item_id, storage_path, mime, size_bytes)
              values (%L, 'x/y/z.jpg', 'image/jpeg', 10)$q$, v_item),
    format($q$update public.assessment_item_images set mime = 'image/png' where item_id = %L$q$, v_item),
    format($q$delete from public.assessment_item_images where item_id = %L$q$, v_item)
  ];

  for r in
    select * from (values
      ('客服部',       'authenticated', 'vr-cs1@2motor.tw'),
      ('總公司主管',   'authenticated', 'vr-hq@2motor.tw'),
      ('店長（門市甲）','authenticated', 'vr-sm1@2motor.tw'),
      ('有登入但沒帳號','authenticated', 'vr-nobody@2motor.tw'),
      ('未登入 anon',  'anon',          null)
    ) as t(label, rl, email)
  loop
    v_n := 0;
    foreach v_sql in array v_stmts loop
      if pg_temp.vr_as(r.rl, r.email, v_sql, false) like 'ERROR:%' then
        v_n := v_n + 1;
      end if;
    end loop;
    perform pg_temp.vr_eq('權限矩陣', r.label || '：四張表的 insert／update／delete 共 12 種寫法全被拒', '12/12', v_n::text || '/12');
  end loop;

  -- 被拒之後資料沒被動到
  perform pg_temp.vr_eq('權限矩陣', '被拒後已送出那筆仍在、備註未被改', '1/機密備註',
    (select (select count(*) from public.assessments where id = v_sub::uuid)::text || '/' ||
            (select note from public.assessment_item_secrets where item_id = v_item::uuid)));
exception when others then
  perform pg_temp.vr_rec('區段 2','直接寫入測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- 2-3 呼叫 assess_* 函式：非客服部被拒、anon 不能 execute
do $$
declare
  r record;
  v_zero text := '00000000-0000-0000-0000-000000000000';
  v_stmts text[];
  v_sql text;
  v_n int;
begin
  v_stmts := array[
    $q$select * from public.assess_candidates()$q$,
    $q$select * from public.assess_categories()$q$,
    $q$select public.assess_start('MI-9901')$q$,
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ分類A'])$q$, v_zero),
    format($q$select public.assess_save_item(%L::uuid, '{}'::jsonb, null)$q$, v_zero),
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_zero),
    format($q$select public.assess_void(%L::uuid, 'x')$q$, v_zero),
    format($q$select public.assess_abandon(%L::uuid)$q$, v_zero),
    format($q$select public.assess_add_image(%L::uuid, 'x/y/z.jpg', 'image/jpeg', 100)$q$, v_zero),
    format($q$select public.assess_remove_image(%L::uuid)$q$, v_zero)
  ];

  for r in
    select * from (values
      ('總公司主管',   'vr-hq@2motor.tw'),
      ('店長（門市甲）','vr-sm1@2motor.tw'),
      ('有登入但沒帳號','vr-nobody@2motor.tw')
    ) as t(label, email)
  loop
    v_n := 0;
    foreach v_sql in array v_stmts loop
      if pg_temp.vr_as('authenticated', r.email, v_sql, false) = 'ERROR: 沒有權限' then
        v_n := v_n + 1;
      end if;
    end loop;
    perform pg_temp.vr_eq('權限矩陣', r.label || '：10 個對外 assess_* 函式（candidates、categories、start、draw、save_item、submit、void、abandon、add_image、remove_image）全回「沒有權限」', '10/10', v_n::text || '/10');
  end loop;

  v_n := 0;
  foreach v_sql in array v_stmts loop
    if pg_temp.vr_as('anon', null, v_sql, false) like 'ERROR: permission denied%' then
      v_n := v_n + 1;
    end if;
  end loop;
  perform pg_temp.vr_eq('權限矩陣', '未登入 anon：10 個對外 assess_* 函式都不能 execute', '10/10', v_n::text || '/10');

  perform pg_temp.vr_eq('權限矩陣', 'anon 不能呼叫純計算函式', '2/2',
    (select count(*)::text || '/2' from (values
        ($q$select * from public.assess_verdict(80, '新人')$q$),
        ($q$select * from public.assess_dim_order()$q$)) as t(sql)
      where pg_temp.vr_as('anon', null, t.sql, false) like 'ERROR: permission denied%'));
  perform pg_temp.vr_eq('權限矩陣', 'authenticated（總公司主管）可呼叫純計算函式', '及格',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select verdict from public.assess_verdict(80, '新人')$q$, true));

  perform pg_temp.vr_eq('權限矩陣', '客服部（authenticated 角色）可呼叫 assess_candidates，看到 7 位假員工', '7',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select count(*)::text from public.assess_candidates() c where c.id like 'MI-99__'$q$, true));
  perform pg_temp.vr_eq('權限矩陣', '客服部（authenticated 角色）可呼叫 assess_categories', '3',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select c.total::text from public.assess_categories() c where c.category = 'ZZ分類A'$q$, true));

  -- 以系統目錄再核對一次 execute 權限
  perform pg_temp.vr_eq('權限矩陣', 'anon 對任何 assess_* 函式都沒有 execute', '0',
    (select count(*)::text from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname like 'assess%'
        and has_function_privilege('anon', p.oid, 'execute')));
  perform pg_temp.vr_eq('權限矩陣', 'authenticated 對 assess_* 都有 execute（內部的 assess_assert_cs 除外）', 'true',
    (select (count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute')) = count(*) - 1)::text
       from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'assess%'));
  perform pg_temp.vr_eq('權限矩陣', 'authenticated 不能直接呼叫 assess_assert_cs', 'false',
    has_function_privilege('authenticated', 'public.assess_assert_cs()', 'execute')::text);
  perform pg_temp.vr_eq('權限矩陣', '11 個資料函式（10 個對外＋assess_assert_cs）都是 security definer 且固定 search_path', '無',
    (select coalesce(string_agg(p.proname, ','), '無') from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('assess_candidates', 'assess_categories', 'assess_start', 'assess_draw',
                          'assess_save_item', 'assess_submit', 'assess_void', 'assess_abandon', 'assess_add_image',
                          'assess_remove_image', 'assess_assert_cs')
        and not (p.prosecdef and coalesce(p.proconfig::text, '') like '%search_path%')));
  perform pg_temp.vr_eq('權限矩陣', '所有 assess* 函式（含 assess_dim_order／dim_points／level_pct 三個純計算輔助）都固定 search_path', '無',
    (select coalesce(string_agg(p.proname, ','), '無') from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname like 'assess%'
        and coalesce(p.proconfig::text, '') not like '%search_path%'));
  perform pg_temp.vr_eq('權限矩陣', '三個輔助函式仍可正常計算', '7/100/70',
    (select coalesce(array_length(public.assess_dim_order(), 1), 0)::text || '/' ||
            (select sum(value::numeric)::text from jsonb_each_text(public.assess_dim_points())) || '/' ||
            public.assess_level_pct('良')::text));
exception when others then
  perform pg_temp.vr_rec('區段 2','函式權限測試意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：流程
-- ============================================================

-- 3-1 候選名單、分類、start
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_id uuid; v_id2 uuid; v_s1 uuid; v_n907 uuid;
begin
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  perform pg_temp.vr_eq('流程 名單','納入考核且在職的假員工（9901/9902/9903/9906/9907/9908/9909）','7',
    (select count(*)::text from public.assess_candidates() c where c.id like 'MI-99__'));
  perform pg_temp.vr_eq('流程 名單','不納入與離職者不在名單','0',
    (select count(*)::text from public.assess_candidates() c where c.id in ('MI-9904', 'MI-9905')));
  perform pg_temp.vr_eq('流程 分類','ZZ分類A 總數/剩餘（抽之前）','3/3',
    (select c.total::text || '/' || c.remaining::text from public.assess_categories() c where c.category = 'ZZ分類A'));

  -- 到職日空白
  perform pg_temp.vr_err('流程 start','到職日空白且沒給 override 要報錯',
    $q$select public.assess_start('MI-9903')$q$, '%到職日空白%');
  perform pg_temp.vr_err('流程 start','到職日空白且 override 亂填要報錯',
    $q$select public.assess_start('MI-9903', '隨便')$q$, '%到職日空白%');
  perform pg_temp.vr_err('流程 start','不納入考核的員工要報錯',
    $q$select public.assess_start('MI-9904')$q$, '%不在考核名單%');
  perform pg_temp.vr_err('流程 start','離職員工要報錯',
    $q$select public.assess_start('MI-9905')$q$, '%不在考核名單%');
  perform pg_temp.vr_err('流程 start','不存在的員工要報錯',
    $q$select public.assess_start('MI-9999')$q$, '%找不到員工%');

  v_id := public.assess_start('MI-9903', '正式');
  perform pg_temp.vr_set('s_manual', v_id::text);
  perform pg_temp.vr_eq('流程 start','到職日空白＋override 正式 → 正式／手動指定／到職日快照空','正式/手動指定/null',
    (select a.tenure || '/' || a.tenure_source || '/' || coalesce(a.hire_date_snapshot::text, 'null')
       from public.assessments a where a.id = v_id));
  v_id2 := public.assess_start('MI-9903', '新人');
  perform pg_temp.vr_eq('流程 start','同考官同員工已有草稿 → 回傳同一張','true', (v_id2 = v_id)::text);

  -- 有到職日：override 被忽略
  v_s1 := public.assess_start('MI-9901', '正式');
  perform pg_temp.vr_set('s1', v_s1::text);
  perform pg_temp.vr_eq('流程 start','有到職日（30 天）時 override 被忽略 → 新人／自動／到職日快照','新人/自動/' || (v_today - 30)::text,
    (select a.tenure || '/' || a.tenure_source || '/' || a.hire_date_snapshot::text
       from public.assessments a where a.id = v_s1));
  perform pg_temp.vr_eq('流程 start','狀態 draft、門市快照 ZZ-T1、考官為本人','draft/ZZ-T1/vr-cs1@2motor.tw',
    (select a.status || '/' || a.store_code || '/' || a.examiner_email from public.assessments a where a.id = v_s1));

  v_id := public.assess_start('MI-9907');
  v_n907 := v_id;
  perform pg_temp.vr_eq('流程 start','第 90 天仍是新人','新人/自動',
    (select a.tenure || '/' || a.tenure_source from public.assessments a where a.id = v_id));
  v_id := public.assess_start('MI-9908');
  perform pg_temp.vr_eq('流程 start','第 91 天是正式／自動','正式/自動',
    (select a.tenure || '/' || a.tenure_source from public.assessments a where a.id = v_id));

  -- 另一位考官對同一員工會有自己的草稿
  perform pg_temp.vr_login('vr-cs2@2motor.tw');
  v_id2 := public.assess_start('MI-9901');
  perform pg_temp.vr_eq('流程 start','另一位考官對同一員工 → 另開一張草稿','true', (v_id2 <> v_s1)::text);
  -- 非本人不能抽題／暫存／送出／放棄
  perform pg_temp.vr_err('流程 權限','非建立者抽題要報錯',
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ分類A'])$q$, v_s1), '%建立者本人%');
  perform pg_temp.vr_err('流程 權限','非建立者送出要報錯',
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_s1), '%建立者本人%');
  -- 放棄：任一客服部都可以放棄別人的草稿（cs1 建立的 MI-9907 草稿由 cs2 放棄）
  perform public.assess_abandon(v_n907);
  perform pg_temp.vr_eq('流程 權限','另一位客服部可以放棄別人的草稿','0',
    (select count(*)::text from public.assessments where id = v_n907));
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  -- 調店後門市快照不變
  update public.employees set store_code = 'ZZ-T2' where id = 'MI-9901';
  perform pg_temp.vr_eq('流程 start','員工調店後，考核的門市快照不變','ZZ-T1',
    (select a.store_code from public.assessments a where a.id = v_s1));
  perform pg_temp.vr_eq('流程 start','成績單列表顯示的姓名是快照（assessment_summaries.employee_label）','假新人甲',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select employee_label from public.assessment_summaries where id = %L$q$, v_s1), true));
  update public.employees set nickname = '改名後' where id = 'MI-9901';
  perform pg_temp.vr_eq('流程 start','員工改暱稱後，成績單姓名快照不變','假新人甲',
    (select a.employee_label from public.assessments a where a.id = v_s1));
  update public.employees set nickname = '假新人甲' where id = 'MI-9901';
  update public.employees set store_code = 'ZZ-T1' where id = 'MI-9901';
exception when others then
  perform pg_temp.vr_rec('區段 3-1','start 流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- 3-2 S1：draw → save_item → submit → void
do $$
declare
  v_s1 uuid := pg_temp.vr_get('s1')::uuid;
  v_ia uuid; v_ib uuid;
  r record;
begin
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  -- draw 的錯誤輸入
  perform pg_temp.vr_err('流程 draw','分類重複要報錯',
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ分類A','ZZ分類A'])$q$, v_s1), '%分類不可重複%');
  perform pg_temp.vr_err('流程 draw','沒選分類要報錯',
    format($q$select * from public.assess_draw(%L::uuid, array[]::text[])$q$, v_s1), '%至少選一個分類%');
  perform pg_temp.vr_err('流程 draw','分類不存在要報錯',
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ不存在'])$q$, v_s1), '%分類不存在%');
  perform pg_temp.vr_err('流程 draw','分類含空值要報錯',
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ分類A', null])$q$, v_s1), '%分類不可空白%');

  insert into pg_temp.vr_draw
    select 'S1', d.* from public.assess_draw(v_s1, array['ZZ分類A', 'ZZ分類B']) d;

  perform pg_temp.vr_eq('流程 draw','S1 抽到 2 個題組（一分類一題）','2',
    (select count(*)::text from pg_temp.vr_draw where tag = 'S1'));
  perform pg_temp.vr_eq('流程 draw','S1 沒有重複（該考生沒考過）','false',
    (select bool_or(repeated)::text from pg_temp.vr_draw where tag = 'S1'));
  perform pg_temp.vr_eq('流程 draw','回傳含題組名稱與步驟','2',
    (select count(*)::text from pg_temp.vr_draw where tag = 'S1' and title like '假題組%' and jsonb_array_length(steps) = 1));
  perform pg_temp.vr_eq('流程 draw','assessment_items 2 筆、secrets 2 筆（快照名稱）','2/2',
    (select (select count(*) from public.assessment_items where assessment_id = v_s1)::text || '/' ||
            (select count(*) from public.assessment_item_secrets s
              join public.assessment_items i on i.id = s.item_id
             where i.assessment_id = v_s1 and s.title like '假題組%')::text));
  perform pg_temp.vr_eq('流程 draw','抽出的題已寫入 drawn（與舊抽選器共用）','2',
    (select count(*)::text from public.drawn
      where question_id in (select question_id from pg_temp.vr_q where assessment_id = v_s1)));
  perform pg_temp.vr_eq('流程 draw','category_last 記下 A 分類這次抽的題','true',
    (select (l.question_id = i.question_id)::text
       from public.category_last l
       join pg_temp.vr_q i on i.category = l.category and i.assessment_id = v_s1
      where l.category = 'ZZ分類A'));
  perform pg_temp.vr_eq('流程 draw','抽的時候題不在 drawn → was_drawn_before 都是 false','false',
    (select bool_or(was_drawn_before)::text from pg_temp.vr_q where assessment_id = v_s1));
  perform pg_temp.vr_eq('流程 分類','抽完後 ZZ分類A 總數/剩餘','3/2',
    (select c.total::text || '/' || c.remaining::text from public.assess_categories() c where c.category = 'ZZ分類A'));
  perform pg_temp.vr_eq('流程 分類','抽完後 ZZ分類B 總數/剩餘','2/1',
    (select c.total::text || '/' || c.remaining::text from public.assess_categories() c where c.category = 'ZZ分類B'));
  perform pg_temp.vr_err('流程 draw','同一場同分類再抽要報錯',
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ分類A'])$q$, v_s1), '%已抽過%');

  select id into v_ia from public.assessment_items where assessment_id = v_s1 and category = 'ZZ分類A';
  select id into v_ib from public.assessment_items where assessment_id = v_s1 and category = 'ZZ分類B';
  perform pg_temp.vr_set('s1_ia', v_ia::text);

  -- save_item 的錯誤輸入
  perform pg_temp.vr_err('流程 save','未知等級要報錯',
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"普通"}'::jsonb, null)$q$, v_ia), '%等級不正確%');
  perform pg_temp.vr_err('流程 save','不適用 3 個要報錯',
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"不適用","預設訊息運用":"不適用","問題掌握":"不適用"}'::jsonb, null)$q$, v_ia), '%不適用最多%');
  perform pg_temp.vr_err('流程 save','未知面向要報錯',
    format($q$select public.assess_save_item(%L::uuid, '{"亂寫":"優"}'::jsonb, null)$q$, v_ia), '%未知的面向%');

  -- 暫存部分面向
  perform public.assess_save_item(v_ia, '{"資訊正確性":"良","預設訊息運用":"優"}'::jsonb, '暫存備註');
  perform pg_temp.vr_eq('流程 save','暫存只填 2 個面向可成功','2',
    (select count(*)::text from public.assessment_items i, jsonb_object_keys(i.levels) k where i.id = v_ia));
  -- 評分不完整不能送出
  perform pg_temp.vr_err('流程 submit','評分不齊全不能送出',
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_s1), '%評分不完整%');

  -- 非本人不能暫存
  perform pg_temp.vr_login('vr-cs2@2motor.tw');
  perform pg_temp.vr_err('流程 權限','非建立者暫存要報錯',
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, null)$q$, v_ia), '%建立者本人%');
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  -- 完整評分並送出
  perform public.assess_save_item(v_ia, pg_temp.vr_mk('良','優','良','待加強','優','良','優'), '考官備註甲');
  perform public.assess_save_item(v_ib, pg_temp.vr_mk('優','優','優','優','優','優','優'), null);
  perform pg_temp.vr_eq('流程 save','考官備註已存入 assessment_items.note','考官備註甲',
    (select i.note from public.assessment_items i where i.id = v_ia));

  select * into r from public.assess_submit(v_s1);
  perform pg_temp.vr_eq('流程 submit','總分','88.8', r.total_score::text);
  perform pg_temp.vr_eq('流程 submit','判定（新人 88.8）','優秀', r.verdict);
  perform pg_temp.vr_eq('流程 submit','合格線','70', r.pass_line::text);
  perform pg_temp.vr_eq('流程 submit','最弱面向','主動引導', array_to_string(r.weakest_dims, ','));
  perform pg_temp.vr_eq('流程 submit','身分與題組數','新人/2', r.tenure || '/' || r.item_count::text);
  perform pg_temp.vr_eq('流程 submit','assessments 已寫入結果','submitted/88.8/優秀/70/主動引導/true',
    (select a.status || '/' || a.total_score::text || '/' || a.verdict || '/' || a.pass_line::text || '/' ||
            array_to_string(a.weakest_dims, ',') || '/' || (a.submitted_at is not null)::text
       from public.assessments a where a.id = v_s1));
  perform pg_temp.vr_eq('流程 submit','題組分數 77.5 與 100.0','77.5/100.0',
    (select (select item_score::text from public.assessment_items where id = v_ia) || '/' ||
            (select item_score::text from public.assessment_items where id = v_ib)));
  perform pg_temp.vr_eq('流程 submit','題組面向得分與最弱面向已存','14/6/主動引導',
    (select (i.dim_points ->> '資訊正確性') || '/' || (i.dim_points ->> '主動引導') || '/' || array_to_string(i.weakest_dims, ',')
       from public.assessment_items i where i.id = v_ia));

  -- 送出後不能再改
  perform pg_temp.vr_err('流程 submit','已送出不能再送出',
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_s1), '%只有草稿%');
  perform pg_temp.vr_err('流程 submit','已送出不能再暫存',
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"優"}'::jsonb, null)$q$, v_ia), '%只有草稿%');
  perform pg_temp.vr_err('流程 submit','已送出不能再抽題',
    format($q$select * from public.assess_draw(%L::uuid, array['ZZ分類C'])$q$, v_s1), '%只有草稿%');
  perform pg_temp.vr_err('流程 submit','已送出不能放棄',
    format($q$select public.assess_abandon(%L::uuid)$q$, v_s1), '%只有草稿%');
  perform pg_temp.vr_err('流程 submit','沒有任何題組不能送出',
    format($q$select * from public.assess_submit(%L::uuid)$q$, pg_temp.vr_get('s_manual')), '%至少要有 1 個題組%');

  -- 作廢
  perform pg_temp.vr_err('流程 void','草稿不能作廢',
    format($q$select public.assess_void(%L::uuid, '原因')$q$, pg_temp.vr_get('s_manual')), '%只有已送出%');
  perform pg_temp.vr_login('vr-cs2@2motor.tw');
  perform pg_temp.vr_err('流程 void','作廢原因空字串要報錯',
    format($q$select public.assess_void(%L::uuid, '')$q$, v_s1), '%原因不可空白%');
  perform pg_temp.vr_err('流程 void','作廢原因只有空白要報錯',
    format($q$select public.assess_void(%L::uuid, '   ')$q$, v_s1), '%原因不可空白%');
  perform public.assess_void(v_s1, ' 評錯題組 ');
  perform pg_temp.vr_eq('流程 void','作廢後狀態、作廢者、原因（已去空白）','voided/vr-cs2@2motor.tw/評錯題組',
    (select a.status || '/' || a.voided_by || '/' || a.void_reason from public.assessments a where a.id = v_s1));
  perform pg_temp.vr_eq('流程 void','作廢時間有記','true',
    (select (a.voided_at is not null)::text from public.assessments a where a.id = v_s1));
  perform pg_temp.vr_eq('流程 void','作廢不刪除：題組仍在、drawn 沒動','2/2',
    (select (select count(*) from public.assessment_items where assessment_id = v_s1)::text || '/' ||
            (select count(*) from public.drawn
              where question_id in (select question_id from pg_temp.vr_q where assessment_id = v_s1))::text));
  perform pg_temp.vr_err('流程 void','已作廢不能再作廢',
    format($q$select public.assess_void(%L::uuid, '再來一次')$q$, v_s1), '%只有已送出%');
  perform pg_temp.vr_login('vr-cs1@2motor.tw');
exception when others then
  perform pg_temp.vr_rec('區段 3-2','S1 流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- 3-3 S2、S3：避開考過的題組（含已作廢的）、一分類一題、repeated／new_round 旗標、abandon 還原
do $$
declare
  v_s1 uuid := pg_temp.vr_get('s1')::uuid;
  v_s2 uuid; v_s3 uuid;
  v_a1 bigint; v_a2 bigint; v_b1 bigint; v_b2 bigint;
  v_picks bigint[];
  v_items uuid[];
  r record;
begin
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  select question_id into v_a1 from pg_temp.vr_q where assessment_id = v_s1 and category = 'ZZ分類A';
  select question_id into v_b1 from pg_temp.vr_q where assessment_id = v_s1 and category = 'ZZ分類B';

  -- S2：S1 已作廢但仍算「考過」，要避開
  v_s2 := public.assess_start('MI-9901');
  perform pg_temp.vr_eq('流程 避開','S1 作廢後同員工可開新考核（新的一張）','true', (v_s2 <> v_s1)::text);
  insert into pg_temp.vr_draw
    select 'S2', d.* from public.assess_draw(v_s2, array['ZZ分類A', 'ZZ分類B', 'ZZ分類C']) d;
  select question_id into v_a2 from pg_temp.vr_q where assessment_id = v_s2 and category = 'ZZ分類A';
  select question_id into v_b2 from pg_temp.vr_q where assessment_id = v_s2 and category = 'ZZ分類B';
  perform pg_temp.vr_eq('流程 避開','S2 的 A 題避開 S1（含作廢）考過的','true', (v_a2 <> v_a1)::text);
  perform pg_temp.vr_eq('流程 避開','S2 的 B 題避開 S1（含作廢）考過的','true', (v_b2 <> v_b1)::text);
  perform pg_temp.vr_eq('流程 避開','S2 三個題組都不是重複','false',
    (select bool_or(repeated)::text from pg_temp.vr_draw where tag = 'S2'));
  perform pg_temp.vr_eq('流程 避開','S2 沒有開新一輪','false',
    (select bool_or(new_round)::text from pg_temp.vr_draw where tag = 'S2'));
  perform pg_temp.vr_eq('流程 避開','S2 三個分類各一題','3',
    (select count(distinct category)::text from pg_temp.vr_draw where tag = 'S2'));

  -- S2 全部評 V2（風險意識、文字品質不適用）→ 每題組 70.0 → 總分 70.0
  for r in select id from public.assessment_items where assessment_id = v_s2 loop
    perform public.assess_save_item(r.id, pg_temp.vr_mk('良','優','良','待加強','不適用','良','不適用'), null);
  end loop;
  select * into r from public.assess_submit(v_s2);
  perform pg_temp.vr_eq('流程 submit','S2 總分（3 題組都 70.0）','70.0', r.total_score::text);
  perform pg_temp.vr_eq('流程 submit','S2 判定（新人 70.0 剛好合格線）','及格/70', r.verdict || '/' || r.pass_line::text);
  perform pg_temp.vr_eq('流程 submit','S2 整場最弱面向','主動引導', array_to_string(r.weakest_dims, ','));
  perform pg_temp.vr_eq('流程 submit','S2 題組的不適用面向與其得分為 null','風險意識,文字品質/null',
    (select array_to_string(i.na_dims, ',') || '/' || (i.dim_points -> '風險意識')::text
       from public.assessment_items i where i.assessment_id = v_s2 limit 1));

  -- S3：A 剩第三題；B 兩題都考過 → 新一輪且 repeated；C 只有一題且考過 → 新一輪且 repeated
  v_s3 := public.assess_start('MI-9901');
  insert into pg_temp.vr_draw
    select 'S3', d.* from public.assess_draw(v_s3, array['ZZ分類A', 'ZZ分類B', 'ZZ分類C']) d;
  perform pg_temp.vr_eq('流程 避開','S3 的 A 題是沒考過的第三題','true',
    (select (i.question_id not in (v_a1, v_a2))::text
       from pg_temp.vr_q i where i.assessment_id = v_s3 and i.category = 'ZZ分類A'));
  perform pg_temp.vr_eq('流程 避開','S3 的 A：repeated/new_round','false/false',
    (select repeated::text || '/' || new_round::text from pg_temp.vr_draw where tag = 'S3' and category = 'ZZ分類A'));
  perform pg_temp.vr_eq('流程 避開','S3 的 B（都考過）：repeated/new_round','true/true',
    (select repeated::text || '/' || new_round::text from pg_temp.vr_draw where tag = 'S3' and category = 'ZZ分類B'));
  perform pg_temp.vr_eq('流程 避開','S3 的 C（只有一題且考過）：repeated/new_round','true/true',
    (select repeated::text || '/' || new_round::text from pg_temp.vr_draw where tag = 'S3' and category = 'ZZ分類C'));
  perform pg_temp.vr_eq('流程 abandon','S3 三題的 was_drawn_before 都是 false','false',
    (select bool_or(was_drawn_before)::text from pg_temp.vr_q where assessment_id = v_s3));

  select array_agg(question_id), array_agg(item_id) into v_picks, v_items
  from pg_temp.vr_q where assessment_id = v_s3;
  perform pg_temp.vr_eq('流程 abandon','放棄前 S3 的題都在 drawn','3',
    (select count(*)::text from public.drawn where question_id = any(v_picks)));

  perform public.assess_abandon(v_s3);
  perform pg_temp.vr_eq('流程 abandon','放棄後考核、題組、機密都刪除','0/0/0',
    (select (select count(*) from public.assessments where id = v_s3)::text || '/' ||
            (select count(*) from public.assessment_items where assessment_id = v_s3)::text || '/' ||
            (select count(*) from public.assessment_item_secrets where item_id = any(v_items))::text));
  perform pg_temp.vr_eq('流程 abandon','was_drawn_before=false 的題從 drawn 刪掉（回到題池）','0',
    (select count(*)::text from public.drawn where question_id = any(v_picks)));
  perform pg_temp.vr_eq('流程 abandon','別場已送出考核（S1 作廢、S2）的 A 題仍在 drawn','2',
    (select count(*)::text from public.drawn where question_id in (v_a1, v_a2)));
exception when others then
  perform pg_temp.vr_rec('區段 3-3','S2／S3 流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- 3-4 was_drawn_before = true 的情況（題已在 drawn，放棄時不動）與正式員工判定
do $$
declare
  v_pa uuid; v_pb uuid;
  v_fp bigint; v_fo bigint;
  r record;
begin
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  -- P（MI-9909，正式）先考過 F 分類的一題並送出
  v_pa := public.assess_start('MI-9909');
  insert into pg_temp.vr_draw select 'PA', d.* from public.assess_draw(v_pa, array['ZZ分類F']) d;
  select question_id into v_fp from pg_temp.vr_q where assessment_id = v_pa;
  perform public.assess_save_item((select id from public.assessment_items where assessment_id = v_pa),
                                  pg_temp.vr_mk('優','優','優','優','優','優','優'), null);
  select * into r from public.assess_submit(v_pa);
  perform pg_temp.vr_eq('流程 判定','正式員工 100.0 → 優秀／合格線 85','優秀/85', r.verdict || '/' || r.pass_line::text);

  -- 模擬題池狀態：P 考過的 f_p 不在 drawn，另一題 f_o 已在 drawn
  select q.id into v_fo from public.questions q where q.category = 'ZZ分類F' and q.id <> v_fp;
  delete from public.drawn where question_id = v_fp;
  insert into public.drawn (question_id) values (v_fo) on conflict do nothing;

  v_pb := public.assess_start('MI-9909');
  insert into pg_temp.vr_draw select 'PB', d.* from public.assess_draw(v_pb, array['ZZ分類F']) d;
  perform pg_temp.vr_eq('流程 避開','P 再抽 F：避開自己考過的 f_p，抽到另一題（雖已在 drawn）','true',
    (select (i.question_id = v_fo)::text from pg_temp.vr_q i where i.assessment_id = v_pb));
  perform pg_temp.vr_eq('流程 避開','這種情況 repeated/new_round','false/false',
    (select repeated::text || '/' || new_round::text from pg_temp.vr_draw where tag = 'PB'));
  perform pg_temp.vr_eq('流程 abandon','題已在 drawn 才抽的 → was_drawn_before = true','true',
    (select i.was_drawn_before::text from pg_temp.vr_q i where i.assessment_id = v_pb));

  perform public.assess_abandon(v_pb);
  perform pg_temp.vr_eq('流程 abandon','放棄後 was_drawn_before=true 的題仍在 drawn（不動）','1',
    (select count(*)::text from public.drawn where question_id = v_fo));
  perform pg_temp.vr_eq('流程 abandon','放棄後草稿已刪除','0',
    (select count(*)::text from public.assessments where id = v_pb));
exception when others then
  perform pg_temp.vr_rec('區段 3-4','was_drawn_before 流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- 3-5 結束後的可見性：主管看得到已送出、看不到草稿與作廢
do $$
declare
  v_ids text;
begin
  v_ids := (select string_agg(quote_literal(id::text), ',')
              from public.assessments where employee_id in ('MI-9901', 'MI-9903', 'MI-9909', 'MI-9907', 'MI-9908'));
  -- MI-9901：S1 作廢、S2 已送出、cs2 的草稿；MI-9903：手動草稿；MI-9909：已送出；MI-9908：草稿（MI-9907 的已被放棄）
  perform pg_temp.vr_eq('權限矩陣','流程資料：客服部草稿/已送出/作廢','3/2/1',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select count(*) filter (where status='draft')::text || '/' || count(*) filter (where status='submitted')::text
                       || '/' || count(*) filter (where status='voided')::text
                  from public.assessments where id in (%s)$q$, v_ids), true));
  perform pg_temp.vr_eq('權限矩陣','流程資料：總公司主管草稿/已送出/作廢','0/2/0',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw',
      format($q$select count(*) filter (where status='draft')::text || '/' || count(*) filter (where status='submitted')::text
                       || '/' || count(*) filter (where status='voided')::text
                  from public.assessments where id in (%s)$q$, v_ids), true));
  perform pg_temp.vr_eq('權限矩陣','流程資料：店長（門市甲）看到門市甲已送出（MI-9901、MI-9909 各一）','2',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw',
      format($q$select count(*)::text from public.assessments where id in (%s)$q$, v_ids), true));
  perform pg_temp.vr_eq('權限矩陣','流程資料：店長（門市乙）看不到門市甲的','0',
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw',
      format($q$select count(*)::text from public.assessments where id in (%s)$q$, v_ids), true));
exception when others then
  perform pg_temp.vr_rec('區段 3-5','可見性意外中斷','無例外', sqlerrm, false);
end
$$;

-- 3-6 備註圖片：上限、格式、路徑、權限、送出後鎖定、放棄回傳路徑清單
do $$
declare
  v_a uuid; v_i uuid; v_pre text; v_img uuid; v_ret text; v_first text;
  v_b uuid; v_bi uuid; v_prb text; v_paths text[]; v_arr text[]; k int;
  v_mimes text[] := array['image/jpeg', 'image/png', 'image/webp', 'image/jpeg', 'image/png'];
begin
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  -- MI-9908 的草稿（3-1 建立）：抽一題 ZZ分類C 後加圖
  v_a := public.assess_start('MI-9908');
  insert into pg_temp.vr_draw select 'IMG', d.* from public.assess_draw(v_a, array['ZZ分類C']) d;
  select item_id into v_i from pg_temp.vr_draw where tag = 'IMG';
  v_pre := v_a::text || '/' || v_i::text || '/';

  for k in 1..5 loop
    v_img := public.assess_add_image(v_i, v_pre || 'img' || k || '.jpg', v_mimes[k], 1000 * k);
    if k = 1 then v_first := v_pre || 'img1.jpg'; perform pg_temp.vr_set('img_first', v_img::text); end if;
  end loop;
  perform pg_temp.vr_eq('流程 圖片','一個題組可加 5 張（jpeg／png／webp 都可）','5',
    (select count(*)::text from public.assessment_item_images where item_id = v_i));

  perform pg_temp.vr_err('流程 圖片','第 6 張被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, v_pre || 'img6.jpg'),
    '%最多 5 張%');
  perform pg_temp.vr_err('流程 圖片','mime 不合（gif）被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/gif', 1000)$q$, v_i, v_pre || 'g.gif'),
    '%圖片格式%');
  perform pg_temp.vr_err('流程 圖片','mime 不合（pdf）被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'application/pdf', 1000)$q$, v_i, v_pre || 'p.pdf'),
    '%圖片格式%');
  perform pg_temp.vr_err('流程 圖片','超過 2MB 被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 2097153)$q$, v_i, v_pre || 'big.jpg'),
    '%2MB%');
  perform pg_temp.vr_err('流程 圖片','大小為 0 被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 0)$q$, v_i, v_pre || 'zero.jpg'),
    '%2MB%');
  perform pg_temp.vr_err('流程 圖片','路徑前綴不對被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, 'other/' || v_i::text || '/x.jpg'),
    '%路徑%');
  perform pg_temp.vr_err('流程 圖片','路徑只有前綴沒有檔名被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, v_pre),
    '%路徑%');

  -- 非本人不能加、不能移除
  perform pg_temp.vr_login('vr-cs2@2motor.tw');
  perform pg_temp.vr_err('流程 圖片','非建立者新增圖片被拒',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, v_pre || 'cs2.jpg'),
    '%建立者本人%');
  perform pg_temp.vr_err('流程 圖片','非建立者移除圖片被拒',
    format($q$select public.assess_remove_image(%L::uuid)$q$, pg_temp.vr_get('img_first')),
    '%建立者本人%');
  perform pg_temp.vr_login('vr-cs1@2motor.tw');

  -- 移除：回傳路徑、資料列刪除；之後可再補一張；重複路徑被唯一鍵擋下
  v_ret := public.assess_remove_image(pg_temp.vr_get('img_first')::uuid);
  perform pg_temp.vr_eq('流程 圖片','移除圖片回傳 storage_path', v_first, v_ret);
  perform pg_temp.vr_eq('流程 圖片','移除後剩 4 張','4',
    (select count(*)::text from public.assessment_item_images where item_id = v_i));
  perform pg_temp.vr_err('流程 圖片','路徑重複被唯一鍵擋下',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, v_pre || 'img2.jpg'),
    '%unique%');
  perform public.assess_add_image(v_i, v_pre || 'img7.jpg', 'image/webp', 500);
  perform pg_temp.vr_eq('流程 圖片','移除後可再補到 5 張','5',
    (select count(*)::text from public.assessment_item_images where item_id = v_i));

  -- 送出後：圖片保留，不可再增刪
  perform public.assess_save_item(v_i, pg_temp.vr_mk('良','優','良','待加強','優','良','優'), null);
  perform public.assess_submit(v_a);
  perform pg_temp.vr_err('流程 圖片','已送出不能再新增圖片',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, v_pre || 'late.jpg'),
    '%只有草稿%');
  perform pg_temp.vr_err('流程 圖片','已送出不能移除圖片',
    format($q$select public.assess_remove_image(%L::uuid)$q$,
           (select id from public.assessment_item_images where item_id = v_i limit 1)),
    '%只有草稿%');
  perform pg_temp.vr_eq('流程 圖片','已送出後圖片仍保留 5 張','5',
    (select count(*)::text from public.assessment_item_images where item_id = v_i));
  perform public.assess_void(v_a, '測試作廢');
  perform pg_temp.vr_err('流程 圖片','已作廢也不能再新增圖片',
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, v_i, v_pre || 'late2.jpg'),
    '%只有草稿%');
  perform pg_temp.vr_eq('流程 圖片','作廢後圖片仍保留 5 張','5',
    (select count(*)::text from public.assessment_item_images where item_id = v_i));

  -- 放棄：回傳該草稿所有圖片的 storage_path 清單，圖片列連帶刪除
  v_b := public.assess_start('MI-9907');
  insert into pg_temp.vr_draw select 'IMG2', d.* from public.assess_draw(v_b, array['ZZ分類A']) d;
  select item_id into v_bi from pg_temp.vr_draw where tag = 'IMG2';
  v_prb := v_b::text || '/' || v_bi::text || '/';
  perform public.assess_add_image(v_bi, v_prb || 'a.jpg', 'image/jpeg', 100);
  perform public.assess_add_image(v_bi, v_prb || 'b.png', 'image/png', 200);
  v_paths := public.assess_abandon(v_b);
  select array_agg(p order by p) into v_arr from unnest(v_paths) as t(p);
  perform pg_temp.vr_eq('流程 圖片','放棄回傳兩張圖片的路徑清單', v_prb || 'a.jpg,' || v_prb || 'b.png', array_to_string(v_arr, ','));
  perform pg_temp.vr_eq('流程 圖片','放棄後考核與圖片列都刪除','0/0',
    (select (select count(*) from public.assessments where id = v_b)::text || '/' ||
            (select count(*) from public.assessment_item_images where item_id = v_bi)::text));

  -- 沒有圖片的草稿放棄 → 回傳空清單
  v_b := public.assess_start('MI-9907');
  v_paths := public.assess_abandon(v_b);
  perform pg_temp.vr_eq('流程 圖片','沒有圖片的草稿放棄 → 空清單','0',
    coalesce(array_length(v_paths, 1), 0)::text);
exception when others then
  perform pg_temp.vr_rec('區段 3-6','備註圖片流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- 3-7 Storage：bucket 設定與 storage.objects 的 policy
-- （metadata 檢查很穩；實際以各角色讀寫 storage.objects 的測試依賴 Supabase storage 的表結構，
--  若這一段意外中斷，請改照 README 的手動檢查步驟驗證，不代表權限有問題）
do $$
declare
  v_q text;
  v_n1 text := 'zz-test/obj.jpg';
  v_n2 text := pg_temp.vr_get('m_draft') || '/x/d.jpg';
  v_n3 text := pg_temp.vr_get('m_sub')   || '/x/s.jpg';
  v_n4 text := pg_temp.vr_get('m_void')  || '/x/v.jpg';
  v_n5 text := pg_temp.vr_get('m_sub2')  || '/x/s2.jpg';
  v_d  text := pg_temp.vr_get('m_draft');
  v_s  text := pg_temp.vr_get('m_sub');
  v_v  text := pg_temp.vr_get('m_void');
  v_di text := (select id::text from public.assessment_items where assessment_id = pg_temp.vr_get('m_draft')::uuid);
  v_si text := (select id::text from public.assessment_items where assessment_id = pg_temp.vr_get('m_sub')::uuid);
  v_vi text := (select id::text from public.assessment_items where assessment_id = pg_temp.vr_get('m_void')::uuid);
  v_res text;
  r record;
begin
  perform pg_temp.vr_eq('Storage','bucket assess-notes：不公開／2MB／三種 mime','false/2097152/image/jpeg,image/png,image/webp',
    (select b.public::text || '/' || b.file_size_limit::text || '/' || array_to_string(b.allowed_mime_types, ',')
       from storage.buckets b where b.id = 'assess-notes'));
  perform pg_temp.vr_eq('Storage','storage.objects 有 3 條 assess_notes_* policy（DELETE,INSERT,SELECT）','3/DELETE,INSERT,SELECT',
    (select count(*)::text || '/' || string_agg(cmd, ',' order by cmd)
       from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'assess_notes_%'));
  perform pg_temp.vr_eq('Storage','三條 policy 都限 authenticated、bucket assess-notes、且判斷 cs_admin','3',
    (select count(*)::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects' and policyname like 'assess_notes_%'
        and roles = '{authenticated}'
        and coalesce(qual, '') || coalesce(with_check, '') like '%assess-notes%'
        and coalesce(qual, '') || coalesce(with_check, '') like '%cs_admin%'));

  -- 以擁有者身分放 5 筆假物件列：
  --   1 個第一段不是 uuid（非法路徑）、門市甲的草稿／已送出／作廢各 1、門市乙的已送出 1，
  --   再看各角色看不看得到（主管：已送出 2；店長甲：1；店長乙：1；無帳號：0；非法路徑只有客服部看得到且不報錯）
  insert into storage.objects (bucket_id, name) values
    ('assess-notes', v_n1), ('assess-notes', v_n2), ('assess-notes', v_n3),
    ('assess-notes', v_n4), ('assess-notes', v_n5);
  v_q := format($q$select count(*)::text from storage.objects where bucket_id = 'assess-notes' and name in (%L,%L,%L,%L,%L)$q$,
                v_n1, v_n2, v_n3, v_n4, v_n5);
  for r in
    select * from (values
      ('客服部（5 筆全看）',              'vr-cs1@2motor.tw',    '5'),
      ('總公司主管（只看已送出 2 筆）',   'vr-hq@2motor.tw',     '2'),
      ('店長甲（只看門市甲已送出 1 筆）', 'vr-sm1@2motor.tw',    '1'),
      ('店長乙（只看門市乙已送出 1 筆）', 'vr-sm2@2motor.tw',    '1'),
      ('有登入但沒帳號',                  'vr-nobody@2motor.tw', '0')
    ) as t(label, email, expected)
  loop
    perform pg_temp.vr_eq('Storage', r.label || '：storage.objects 可見筆數', r.expected,
      pg_temp.vr_as('authenticated', r.email, v_q, true));
  end loop;
  perform pg_temp.vr_eq('Storage','anon 看不到物件（0 筆或被拒）','true',
    (select (a = '0' or a like 'ERROR:%')::text
       from (select pg_temp.vr_as('anon', null, v_q, true) as a) s));
  -- insert policy：路徑格式、考核必須是「本人的草稿」、第二段題組必須屬於該考核
  --（delete 規則不在此測：Supabase 的 storage.protect_delete 會擋直接 delete storage.objects，
  --  請依 README 第八節用 Storage API／儀表板手動驗證）
  perform pg_temp.vr_eq('Storage','insert／delete policy 內容含「draft」與本人判斷','2',
    (select count(*)::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and policyname in ('assess_notes_insert', 'assess_notes_delete')
        and coalesce(qual, '') || coalesce(with_check, '') like '%draft%'
        and coalesce(qual, '') || coalesce(with_check, '') like '%roster_my_email%'));
  for r in
    select * from (values
      ('客服部＋自己的草稿＋自己的題組＋合法 jpg 路徑', 'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'OK'),
      ('客服部＋合法 png 路徑',                          'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.png', 'OK'),
      ('客服部＋合法 webp 路徑',                         'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.webp', 'OK'),
      ('另一位客服部（不是草稿建立者）被拒',             'authenticated', 'vr-cs2@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('已送出考核的路徑被拒（即使是同一位考官）',       'authenticated', 'vr-cs1@2motor.tw', v_s || '/' || v_si || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('已作廢考核的路徑被拒',                           'authenticated', 'vr-cs1@2motor.tw', v_v || '/' || v_vi || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('第二段題組不屬於該考核被拒',                     'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || v_si || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('考核不存在的路徑被拒',                           'authenticated', 'vr-cs1@2motor.tw', gen_random_uuid()::text || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('副檔名不合（gif）被拒',                          'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.gif', 'ERROR'),
      ('檔名不是 uuid 被拒',                             'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || v_di || '/photo.jpg', 'ERROR'),
      ('少一層路徑被拒',                                 'authenticated', 'vr-cs1@2motor.tw', v_d || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('總公司主管＋合法路徑也被拒',                     'authenticated', 'vr-hq@2motor.tw',  v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('店長＋合法路徑也被拒',                           'authenticated', 'vr-sm1@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('有登入但沒帳號＋合法路徑被拒',                   'authenticated', 'vr-nobody@2motor.tw', v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('未登入 anon＋合法路徑被拒',                      'anon',          null,                  v_d || '/' || v_di || '/' || gen_random_uuid()::text || '.jpg', 'ERROR')
    ) as t(label, rl, email, path, expected)
  loop
    v_res := pg_temp.vr_as(r.rl, r.email,
      format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, r.path), false);
    perform pg_temp.vr_eq('Storage', 'insert policy：' || r.label, r.expected,
      case when v_res like 'ERROR:%' then 'ERROR' else v_res end);
  end loop;
exception when others then
  perform pg_temp.vr_rec('區段 3-7','Storage 檢查意外中斷（請改照 README 手動檢查）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：舊抽選器資料表與函式沒有被改動
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('舊抽選器','questions 欄位與型別不變',
    'category:text,code:text,created_at:timestamp with time zone,id:bigint,steps:jsonb,title:text',
    (select string_agg(column_name || ':' || data_type, ',' order by column_name)
       from information_schema.columns
      where table_schema = 'public' and table_name = 'questions' and column_name <> 'text'));
  perform pg_temp.vr_eq('舊抽選器','drawn 欄位與型別不變',
    'drawn_at:timestamp with time zone,question_id:bigint',
    (select string_agg(column_name || ':' || data_type, ',' order by column_name)
       from information_schema.columns where table_schema = 'public' and table_name = 'drawn'));
  perform pg_temp.vr_eq('舊抽選器','category_last 欄位與型別不變',
    'category:text,question_id:bigint',
    (select string_agg(column_name || ':' || data_type, ',' order by column_name)
       from information_schema.columns where table_schema = 'public' and table_name = 'category_last'));
  perform pg_temp.vr_eq('舊抽選器','三張表仍開 RLS、且沒有任何 policy','true,true,true/0',
    (select (select string_agg(relrowsecurity::text, ',' order by relname) from pg_class
              where oid in ('public.questions'::regclass, 'public.drawn'::regclass, 'public.category_last'::regclass))
            || '/' ||
            (select count(*)::text from pg_policies
              where schemaname = 'public' and tablename in ('questions', 'drawn', 'category_last'))));
  perform pg_temp.vr_eq('舊抽選器','三張表仍然 anon／authenticated 都沒有直接權限','false',
    (select bool_or(has_table_privilege(rl, t, 'select') or has_table_privilege(rl, t, 'insert')
                    or has_table_privilege(rl, t, 'update') or has_table_privilege(rl, t, 'delete'))::text
       from (values ('anon'), ('authenticated')) as a(rl),
            (values ('public.questions'), ('public.drawn'), ('public.category_last')) as b(t)));
  perform pg_temp.vr_eq('舊抽選器','舊函式 10 個都還在','10',
    (select count(*)::text from pg_proc
      where pronamespace = 'public'::regnamespace
        and proname in ('list_categories', 'draw_questions', 'admin_login', 'admin_list_questions',
                        'admin_save_question', 'admin_delete_question', 'admin_rename_category',
                        'admin_reset', '_pw_ok', '_assert_pw')));
  perform pg_temp.vr_eq('舊抽選器','draw_questions 仍開放 anon 執行（舊抽選器照常運作）','true',
    has_function_privilege('anon', 'public.draw_questions(text, text[])', 'execute')::text);
  perform pg_temp.vr_eq('舊抽選器','真實題目筆數沒變', pg_temp.vr_get('real_questions'),
    (select count(*)::text from public.questions where category not like 'ZZ%'));
  perform pg_temp.vr_eq('舊抽選器','真實題目的已抽記錄 drawn 沒變', pg_temp.vr_get('real_drawn'),
    (select count(*)::text from public.drawn
      where question_id in (select id from public.questions where category not like 'ZZ%')));
  perform pg_temp.vr_eq('舊抽選器','真實分類的 category_last 沒變', pg_temp.vr_get('real_last'),
    (select count(*)::text from public.category_last where category not like 'ZZ%'));
exception when others then
  perform pg_temp.vr_rec('區段 4','舊抽選器檢查意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate assess_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare assess_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過') || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（上面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate assess_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare assess_vr_out as select '
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
execute assess_vr_out;
