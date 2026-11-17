-- ============================================================
-- 業務考核系統：黃單輔導紀錄「編輯版本」驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 spot_coach_history_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-S1／ZZ-S2、假員工 MI-9761～MI-9765、假帳號（vr-xxx@2motor.tw），
--   直接寫入假的抽查與黃單，用 set local role ＋ request.jwt.claims 模擬各角色登入，
--   呼叫 spot_coach、spot_coach_versions、spot_coach_version_stats，把每項斷言記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果＝「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算成功。
--   （表在 rollback 之前先存成預備陳述式 spot_coach_history_vr_out，rollback 之後再 execute，做法與其他驗證腳本相同；
--    若畫面出現兩張一樣的表，看最後一張即可。）
-- 驗證重點：首次回填＝第 1 版、再編輯＝第 2 版且舊版不變、日期與備註都記在版本裡、被拒絕的操作不產生版本、
--   作廢黃單的行為與原本一致（不能回填、不產生版本，作廢前的版本仍保留且可讀）、
--   店長只能讀自己門市（別店、主管、沒帳號、未登入都被拒）、信箱只給客服部、編輯人顯示「門市-暱稱」、
--   版本不可改不可刪（含直接 update／delete／truncate／insert）、既有已輔導的黃單補第 1 版（補資料語法與 schema 第 3 節相同）、
--   版本統計函式（單據清單用）的範圍與數字。
-- 假門市代碼 ZZ-S1／ZZ-S2、假員工編號 MI-9761～MI-9765、假信箱 vr-cs／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw
--   若撞到真實資料，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regclass('public.spot_ticket_coach_versions') is null
     or to_regprocedure('public.spot_coach_versions(uuid)') is null
     or to_regprocedure('public.spot_coach_version_stats()') is null then
    raise exception '請先執行 spot_coach_history_schema.sql';
  end if;
end
$$;

-- ---------- 驗證工具（全部是暫存物件，rollback 後消失） ----------
create temp table vr (
  n int generated always as identity primary key,
  grp text, name text, expected text, actual text, pass boolean
);

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

-- 以資料庫擁有者身分執行單一值查詢
create or replace function pg_temp.vr_q1(p_sql text)
returns text language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, '(null)');
end $$;

-- 以指定資料庫角色＋email 執行一段 SQL；p_scalar=true 回傳單一值文字，false 只執行成功回 'OK'；失敗回 'ERROR: 訊息'
create or replace function pg_temp.vr_as(p_role text, p_email text, p_sql text, p_scalar boolean)
returns text language plpgsql as $$
declare v_res text;
begin
  perform set_config('request.jwt.claims',
    case when p_email is null then '' else json_build_object('email', p_email, 'role', p_role)::text end, true);
  begin
    execute format('set local role %I', p_role);
    if p_scalar then execute p_sql into v_res; else execute p_sql; v_res := 'OK'; end if;
    reset role;
    return coalesce(v_res, '(null)');
  exception when others then
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

create or replace function pg_temp.vr_ok(p_grp text, p_name text, p_email text, p_sql text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_eq(p_grp, p_name, 'OK', pg_temp.vr_as('authenticated', p_email, p_sql, false));
end $$;

create or replace function pg_temp.vr_deny(p_grp text, p_name text, p_role text, p_email text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare v_r text := pg_temp.vr_as(p_role, p_email, p_sql, false);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r, v_r like 'ERROR: ' || p_pattern);
end $$;

-- 以擁有者身分執行一段會失敗的 SQL（測觸發器擋改刪）；結果應為 ERROR 且訊息符合樣式
create or replace function pg_temp.vr_owner_deny(p_grp text, p_name text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare v_r text;
begin
  perform set_config('request.jwt.claims', '', true);
  begin
    execute p_sql;
    v_r := 'OK（沒被擋）';
  exception when others then
    v_r := 'ERROR: ' || sqlerrm;
  end;
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r, v_r like 'ERROR: ' || p_pattern);
end $$;

-- 造一張黃單（先寫一筆假抽查，再寫黃單），回傳黃單 id；開單日預設台北今天
create or replace function pg_temp.vr_ticket(p_emp text, p_store text, p_kind text default '黃')
returns uuid language plpgsql as $$
declare v_i uuid; v_t uuid; v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  if p_kind = '黃' then
    insert into public.spot_inspections
      (employee_id, employee_label, store_code, checked_on, message, levels, total_score,
       verdict, reason, examiner_email)
    values
      (p_emp, '假員' || right(p_emp, 4), p_store, v_today, 'https://example.com/chat', '{}'::jsonb, 0,
       '不適當', '假原因', 'vr-cs@2motor.tw')
    returning id into v_i;
    insert into public.spot_tickets
      (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on)
    values
      ('黃', p_emp, '假員' || right(p_emp, 4), p_store, v_i, '假原因', v_today)
    returning id into v_t;
  else
    insert into public.spot_tickets
      (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on)
    values
      ('紅', p_emp, '假員' || right(p_emp, 4), p_store, array[gen_random_uuid()], '假紅單', v_today)
    returning id into v_t;
  end if;
  return v_t;
end $$;

-- 某張單的版本摘要（以指定角色查）：'版本:日期:備註:編輯人:是否目前' 以 | 串接，新到舊
create or replace function pg_temp.vr_vers(p_role text, p_email text, p_ticket uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as(p_role, p_email,
    format($q$select coalesce(string_agg(version_no || ':' || coached_on || ':' || coach_note || ':' || editor_label || ':' || is_current,
                                         '|' order by version_no desc), '(空)')
              from public.spot_coach_versions(%L::uuid)$q$, p_ticket), true);
end $$;

-- ---------- 建立假資料 ----------
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-S1', 'ZZ輔導甲店'), ('ZZ-S2', 'ZZ輔導乙店');

  -- MI-9761：甲店店長（有暱稱）；MI-9762：客服部（只有姓名，沒有暱稱）；MI-9763：乙店店長（沒有綁員工）；
  -- MI-9764／9765：被抽查的業務（甲店、乙店）
  insert into public.employees (id, nickname, full_name, store_code, job_title, status, include_in_assessment) values
    ('MI-9761', '阿甲', '王甲', 'ZZ-S1', '店長', '在職', false),
    ('MI-9762', null, '陳客服', 'ZZ-S1', '客服', '在職', false),
    ('MI-9764', '假業務9764', null, 'ZZ-S1', '業務', '在職', true),
    ('MI-9765', '假業務9765', null, 'ZZ-S2', '業務', '在職', true);

  insert into public.app_users (email, role, store_code, employee_id) values
    ('vr-cs@2motor.tw',  'cs_admin',      null,    'MI-9762'),
    ('vr-hq@2motor.tw',  'hq_viewer',     null,    null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-S1', 'MI-9761'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-S2', null);
exception when others then
  perform pg_temp.vr_rec('建立假資料', '建立假資料意外中斷（可能真實資料撞名）', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：首次回填、再編輯、舊版不變
-- ============================================================
do $$
declare
  cs text := 'vr-cs@2motor.tw'; s1 text := 'vr-sm1@2motor.tw';
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_sql text := $q$select public.spot_coach(%L::uuid, %L::date, %L)$q$;
  t1 uuid; t2 uuid; v_d1 date := (now() at time zone 'Asia/Taipei')::date - 3;
begin
  t1 := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');
  t2 := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');

  perform pg_temp.vr_eq('1 版本', '回填前沒有任何版本', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L', t1)));

  -- 首次回填（店長）＝第 1 版
  perform pg_temp.vr_ok('1 版本', '店長首次回填成功', s1, format(v_sql, t1, v_d1, '第一次備註'));
  perform pg_temp.vr_eq('1 版本', '首次回填產生第 1 版（目前），編輯人「門市-暱稱」＝ZZ輔導甲店-阿甲',
    '1:' || v_d1 || ':第一次備註:ZZ輔導甲店-阿甲:true', pg_temp.vr_vers('authenticated', s1, t1));
  perform pg_temp.vr_eq('1 版本', '黃單本身：日期、備註、填寫人照舊寫入（原行為不變）',
    v_d1 || '/第一次備註/' || s1,
    pg_temp.vr_q1(format($q$select coached_on || '/' || coach_note || '/' || coached_by from public.spot_tickets where id = %L$q$, t1)));

  -- 再編輯（改日期與備註）＝第 2 版，第 1 版內容不變
  perform pg_temp.vr_ok('1 版本', '店長再編輯成功（改日期與備註）', s1, format(v_sql, t1, v_today, '第二次備註'));
  perform pg_temp.vr_eq('1 版本', '再編輯後：第 2 版（目前）在前、第 1 版內容原封不動且不再是目前版',
    '2:' || v_today || ':第二次備註:ZZ輔導甲店-阿甲:true|1:' || v_d1 || ':第一次備註:ZZ輔導甲店-阿甲:false',
    pg_temp.vr_vers('authenticated', s1, t1));
  perform pg_temp.vr_eq('1 版本', '版本表共 2 筆（編輯是新增，不是覆蓋）', '2',
    pg_temp.vr_q1(format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L', t1)));
  perform pg_temp.vr_eq('1 版本', '黃單本身只留最新內容（原行為不變）', v_today || '/第二次備註',
    pg_temp.vr_q1(format($q$select coached_on || '/' || coach_note from public.spot_tickets where id = %L$q$, t1)));

  -- 客服部也能編輯，版本記客服部（總公司-名字；沒有暱稱用姓名）
  perform pg_temp.vr_ok('1 版本', '客服部編輯成功', cs, format(v_sql, t1, v_today, '客服補充'));
  perform pg_temp.vr_eq('1 版本', '客服部編輯＝第 3 版，編輯人顯示「總公司-陳客服」（沒暱稱用姓名）',
    '3:' || v_today || ':客服補充:總公司-陳客服:true',
    split_part(pg_temp.vr_vers('authenticated', cs, t1), '|', 1));
  perform pg_temp.vr_eq('1 版本', '版本表記下編輯人信箱（三筆依序：店長、店長、客服部）',
    s1 || ',' || s1 || ',' || cs,
    pg_temp.vr_q1(format($q$select string_agg(edited_by, ',' order by version_no) from public.spot_ticket_coach_versions where ticket_id = %L$q$, t1)));
  perform pg_temp.vr_eq('1 版本', '版本編輯時間與黃單 coached_at 一致（最新一版）', 'true',
    pg_temp.vr_q1(format($q$select (v.edited_at = t.coached_at)::text from public.spot_ticket_coach_versions v
                            join public.spot_tickets t on t.id = v.ticket_id where t.id = %L and v.version_no = 3$q$, t1)));

  -- 另一張單不受影響
  perform pg_temp.vr_eq('1 版本', '另一張單沒有版本', '(空)', pg_temp.vr_vers('authenticated', cs, t2));

  -- 超長備註
  perform pg_temp.vr_ok('1 版本', '超長備註（5000 字）編輯成功', s1,
    format($q$select public.spot_coach(%L::uuid, %L::date, repeat('字', 5000))$q$, t2, v_today));
  perform pg_temp.vr_eq('1 版本', '超長備註完整存進版本', '1/5000',
    pg_temp.vr_q1(format('select version_no || ''/'' || length(coach_note) from public.spot_ticket_coach_versions where ticket_id = %L', t2)));
  perform pg_temp.vr_eq('1 版本', '備註前後空白（含全形空白與換行）已去掉再存進版本', '去空白備註',
    (select pg_temp.vr_q1(format($q$select coach_note from public.spot_ticket_coach_versions where ticket_id = %L and version_no = 2$q$, t2))
     where pg_temp.vr_as('authenticated', s1, format(v_sql, t2, v_today, E'\n　 去空白備註 \n'), false) = 'OK'));
exception when others then
  perform pg_temp.vr_rec('區段 1', '版本流程意外中斷', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：被拒絕的操作不產生版本、原行為保留（含作廢黃單）
-- ============================================================
do $$
declare
  cs text := 'vr-cs@2motor.tw'; hq text := 'vr-hq@2motor.tw'; s1 text := 'vr-sm1@2motor.tw'; s2 text := 'vr-sm2@2motor.tw';
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_sql text := $q$select public.spot_coach(%L::uuid, %L::date, %L)$q$;
  v_cnt text := $q$select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L$q$;
  a uuid; b uuid; x uuid; r uuid;
begin
  a := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');
  b := pg_temp.vr_ticket('MI-9765', 'ZZ-S2');
  x := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');
  r := pg_temp.vr_ticket('MI-9764', 'ZZ-S1', '紅');
  -- 用正式的作廢函式作廢 x（確認與作廢流程搭得起來）
  perform pg_temp.vr_eq('2 作廢', '客服部作廢黃單 x 成功', 'OK',
    pg_temp.vr_as('authenticated', cs, format($q$select public.spot_void_ticket(%L::uuid, %L)$q$, x, '假作廢'), false));

  perform pg_temp.vr_deny('2 被拒', '別店店長回填被拒（通用訊息）', 'authenticated', s2, format(v_sql, a, v_today, '備註'), '%找不到這張單據或沒有權限%');
  perform pg_temp.vr_deny('2 被拒', '店長回填不存在的單被拒（與別店同一句，不洩漏存在）', 'authenticated', s1,
    format(v_sql, gen_random_uuid(), v_today, '備註'), '%找不到這張單據或沒有權限%');
  perform pg_temp.vr_deny('2 被拒', '客服部回填不存在的單：找不到單據', 'authenticated', cs,
    format(v_sql, gen_random_uuid(), v_today, '備註'), '%找不到單據%');
  perform pg_temp.vr_deny('2 被拒', '總公司主管回填被拒', 'authenticated', hq, format(v_sql, a, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('2 被拒', '沒開通帳號回填被拒', 'authenticated', 'vr-nobody@2motor.tw', format(v_sql, a, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('2 被拒', '備註空白被拒', 'authenticated', s1, format(v_sql, a, v_today, '   '), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('2 被拒', '日期空白被拒', 'authenticated', s1, format($q$select public.spot_coach(%L::uuid, null::date, '備註')$q$, a), '%輔導日期不可空白%');
  perform pg_temp.vr_deny('2 作廢', '作廢的黃單不能回填（店長，原行為保留）', 'authenticated', s1, format(v_sql, x, v_today, '備註'), '%作廢的單不能回填輔導%');
  perform pg_temp.vr_deny('2 作廢', '作廢的黃單不能回填（客服部，原行為保留）', 'authenticated', cs, format(v_sql, x, v_today, '備註'), '%作廢的單不能回填輔導%');
  perform pg_temp.vr_deny('2 被拒', 'anon 沒有 execute 權限', 'anon', null, format(v_sql, a, v_today, '備註'), '%permission denied%');
  perform pg_temp.vr_eq('2 被拒', '以上全部被拒之後，各單都沒有版本、黃單 a 沒有被寫入輔導欄位',
    '0/0/0/true',
    pg_temp.vr_q1(format(v_cnt, a)) || '/' || pg_temp.vr_q1(format(v_cnt, b)) || '/' || pg_temp.vr_q1(format(v_cnt, x))
      || '/' || pg_temp.vr_q1(format('select (coached_on is null and coach_note is null)::text from public.spot_tickets where id = %L', a)));

  -- 原行為：店長回填自己門市、客服部回填任何門市、舊的紅單照舊可回填（函式沒有限制種類）
  perform pg_temp.vr_ok('2 原行為', '乙店店長回填乙店的單成功', s2, format(v_sql, b, v_today, '乙店備註'));
  perform pg_temp.vr_eq('2 原行為', '回填並產生第 1 版（編輯人沒綁員工 → 乙店-（未填暱稱））',
    '1:' || v_today || ':乙店備註:ZZ輔導乙店-（未填暱稱）:true', pg_temp.vr_vers('authenticated', s2, b));
  perform pg_temp.vr_ok('2 原行為', '客服部回填甲店的單成功', cs, format(v_sql, a, v_today, '客服代填'));
  perform pg_temp.vr_eq('2 原行為', '客服部回填也產生第 1 版', '1:' || v_today || ':客服代填:總公司-陳客服:true',
    pg_temp.vr_vers('authenticated', cs, a));
  perform pg_temp.vr_ok('2 原行為', '舊紅單回填仍可成功（原函式不限種類，保留）', cs, format(v_sql, r, v_today, '紅單輔導'));
  perform pg_temp.vr_eq('2 原行為', '舊紅單回填也記第 1 版', '1:' || v_today || ':紅單輔導:總公司-陳客服:true',
    pg_temp.vr_vers('authenticated', cs, r));

  -- 作廢發生在輔導之後：版本仍在、仍可讀，但不能再編輯
  perform pg_temp.vr_eq('2 作廢', '客服部作廢已輔導的黃單 a 成功', 'OK',
    pg_temp.vr_as('authenticated', cs, format($q$select public.spot_void_ticket(%L::uuid, %L)$q$, a, '輔導後作廢'), false));
  perform pg_temp.vr_eq('2 作廢', '作廢後版本仍保留（客服部讀）', '1:' || v_today || ':客服代填:總公司-陳客服:true',
    pg_temp.vr_vers('authenticated', cs, a));
  perform pg_temp.vr_eq('2 作廢', '作廢後版本店長也讀得到（與黃單既有可見範圍一致）', '1:' || v_today || ':客服代填:總公司-陳客服:true',
    pg_temp.vr_vers('authenticated', s1, a));
  perform pg_temp.vr_deny('2 作廢', '作廢後不能再編輯（不產生第 2 版）', 'authenticated', cs, format(v_sql, a, v_today, '作廢後想改'), '%作廢的單不能回填輔導%');
  perform pg_temp.vr_eq('2 作廢', '作廢後版本數仍是 1', '1', pg_temp.vr_q1(format(v_cnt, a)));

  -- ============================================================
  -- 區段 3：讀取權限與統計
  -- ============================================================
  perform pg_temp.vr_eq('3 讀取', '甲店店長讀自己門市的版本（單 r）', '1:' || v_today || ':紅單輔導:總公司-陳客服:true', pg_temp.vr_vers('authenticated', s1, r));
  perform pg_temp.vr_eq('3 讀取', '客服部讀任何門市的版本（乙店那張）', '1:' || v_today || ':乙店備註:ZZ輔導乙店-（未填暱稱）:true', pg_temp.vr_vers('authenticated', cs, b));
  perform pg_temp.vr_deny('3 讀取', '甲店店長讀乙店的單被拒', 'authenticated', s1, format('select count(*) from public.spot_coach_versions(%L::uuid)', b), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '乙店店長讀甲店的單被拒', 'authenticated', s2, format('select count(*) from public.spot_coach_versions(%L::uuid)', r), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '總公司主管被拒', 'authenticated', hq, format('select count(*) from public.spot_coach_versions(%L::uuid)', r), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '有登入但沒開通帳號被拒', 'authenticated', 'vr-nobody@2motor.tw', format('select count(*) from public.spot_coach_versions(%L::uuid)', r), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '未登入（anon）被拒', 'anon', null, format('select count(*) from public.spot_coach_versions(%L::uuid)', r), '%permission denied%');
  perform pg_temp.vr_deny('3 讀取', '店長讀不存在的單被拒（與別店同一句，不洩漏存在）', 'authenticated', s1,
    format('select count(*) from public.spot_coach_versions(%L::uuid)', gen_random_uuid()), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '客服部讀不存在的單：找不到單據', 'authenticated', cs,
    format('select count(*) from public.spot_coach_versions(%L::uuid)', gen_random_uuid()), '%找不到單據%');
  perform pg_temp.vr_eq('3 讀取', '客服部讀沒有版本的黃單：回空清單', '(空)', pg_temp.vr_vers('authenticated', cs, x));
  perform pg_temp.vr_eq('3 讀取', '信箱只給客服部：客服部看得到編輯人信箱', 'vr-cs@2motor.tw',
    pg_temp.vr_as('authenticated', cs, format('select edited_by from public.spot_coach_versions(%L::uuid)', r), true));
  perform pg_temp.vr_eq('3 讀取', '店長看到的信箱欄是空的', '(null)',
    pg_temp.vr_as('authenticated', s1, format('select edited_by from public.spot_coach_versions(%L::uuid)', r), true));
  perform pg_temp.vr_eq('3 讀取', '直接讀版本表：客服部看得到', '1',
    pg_temp.vr_as('authenticated', cs, format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L', r), true));
  perform pg_temp.vr_eq('3 讀取', '直接讀版本表：店長讀到 0 筆（只能走函式）', '0',
    pg_temp.vr_as('authenticated', s1, format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L', r), true));
  perform pg_temp.vr_eq('3 讀取', '直接讀版本表：主管讀到 0 筆', '0',
    pg_temp.vr_as('authenticated', hq, format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L', r), true));
  perform pg_temp.vr_deny('3 讀取', '直接讀版本表：anon 被拒', 'anon', null, 'select count(*) from public.spot_ticket_coach_versions', '%permission denied%');

  -- 統計函式（單據清單用）：客服部看全部有版本的單、店長只看自己門市、其他人被拒
  perform pg_temp.vr_eq('3 統計', '客服部：本腳本三張有版本的單（a、b、r）都在，且版本數／最後編輯時間正確', '3/true',
    pg_temp.vr_as('authenticated', cs,
      format($q$select count(*)::text || '/' || bool_and(version_count = 1 and last_edited_at is not null)::text
                from public.spot_coach_version_stats() where ticket_id in (%L, %L, %L)$q$, a, b, r), true));
  perform pg_temp.vr_eq('3 統計', '甲店店長：只看到自己門市的（a、r），看不到乙店的 b', '2/0',
    pg_temp.vr_as('authenticated', s1,
      format($q$select count(*) filter (where ticket_id in (%L, %L))::text || '/' || count(*) filter (where ticket_id = %L)::text
                from public.spot_coach_version_stats()$q$, a, r, b), true));
  perform pg_temp.vr_eq('3 統計', '乙店店長：只看到 b', '1/0',
    pg_temp.vr_as('authenticated', s2,
      format($q$select count(*) filter (where ticket_id = %L)::text || '/' || count(*) filter (where ticket_id in (%L, %L))::text
                from public.spot_coach_version_stats()$q$, b, a, r), true));
  perform pg_temp.vr_deny('3 統計', '總公司主管被拒', 'authenticated', hq, 'select count(*) from public.spot_coach_version_stats()', '%沒有權限%');
  perform pg_temp.vr_deny('3 統計', '沒開通帳號被拒', 'authenticated', 'vr-nobody@2motor.tw', 'select count(*) from public.spot_coach_version_stats()', '%沒有權限%');
  perform pg_temp.vr_deny('3 統計', 'anon 被拒', 'anon', null, 'select count(*) from public.spot_coach_version_stats()', '%permission denied%');
  perform pg_temp.vr_eq('3 統計', '版本數隨編輯增加：b 再編輯一次後版本數 2、最後編輯時間＝第 2 版時間', '2/true',
    (select pg_temp.vr_as('authenticated', cs,
        format($q$select version_count || '/' || (last_edited_at = (select max(v.edited_at) from public.spot_ticket_coach_versions v where v.ticket_id = %L))::text
                  from public.spot_coach_version_stats() where ticket_id = %L$q$, b, b), true)
     where pg_temp.vr_as('authenticated', s2, format(v_sql, b, v_today, '乙店再編'), false) = 'OK'));

  -- ============================================================
  -- 區段 4：版本不可改、不可刪、不可由網頁角色直接新增
  -- ============================================================
  perform pg_temp.vr_deny('4 不可改刪', '客服部直接 update 被拒（沒有權限）', 'authenticated', cs,
    format($q$update public.spot_ticket_coach_versions set coach_note = '偷改' where ticket_id = %L$q$, r), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', '客服部直接 delete 被拒（沒有權限）', 'authenticated', cs,
    format($q$delete from public.spot_ticket_coach_versions where ticket_id = %L$q$, r), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', '客服部直接 insert 被拒（沒有權限）', 'authenticated', cs,
    format($q$insert into public.spot_ticket_coach_versions (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label) values (%L, 99, current_date, '偽造', 'x', 'x')$q$, r), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', '店長直接 update 被拒', 'authenticated', s1,
    format($q$update public.spot_ticket_coach_versions set coach_note = '偷改' where ticket_id = %L$q$, r), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', 'anon 直接 delete 被拒', 'anon', null, 'delete from public.spot_ticket_coach_versions', '%permission denied%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '連資料庫擁有者直接 update 也被觸發器擋下',
    format($q$update public.spot_ticket_coach_versions set coach_note = '偷改' where ticket_id = %L$q$, r), '%只增不改%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '連資料庫擁有者直接 delete 也被觸發器擋下',
    format($q$delete from public.spot_ticket_coach_versions where ticket_id = %L$q$, r), '%只增不改%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '連資料庫擁有者 truncate 也被觸發器擋下',
    'truncate table public.spot_ticket_coach_versions', '%只增不改%');
  perform pg_temp.vr_eq('4 不可改刪', '以上都沒改到：單 r 的版本內容原樣', '紅單輔導',
    pg_temp.vr_q1(format('select coach_note from public.spot_ticket_coach_versions where ticket_id = %L and version_no = 1', r)));
  perform pg_temp.vr_owner_deny('4 不可改刪', '同一張單同一版序號不可重複', format($q$insert into public.spot_ticket_coach_versions
      (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label) values (%L, 1, current_date, '重複', 'x', 'x')$q$, r), '%duplicate key%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '版本序號必須 >= 1', format($q$insert into public.spot_ticket_coach_versions
      (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label) values (%L, 0, current_date, '零版', 'x', 'x')$q$, r), '%check constraint%');
exception when others then
  perform pg_temp.vr_rec('區段 2-4', '被拒／讀取／不可改刪意外中斷', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：既有已輔導的黃單補第 1 版（補資料語法與 schema 第 3 節相同）
-- ============================================================
do $$
declare
  cs text := 'vr-cs@2motor.tw';
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; p5 uuid; v_n int;
begin
  -- 模擬「舊資料」：直接寫入輔導欄位、不經過函式，所以沒有任何版本
  p1 := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');   -- 已輔導，編輯人是甲店店長
  p2 := pg_temp.vr_ticket('MI-9765', 'ZZ-S2');   -- 已輔導，編輯人是客服部
  p3 := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');   -- 尚未輔導（沒有輔導紀錄）→ 不補
  p4 := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');   -- 已輔導，編輯人帳號已被移除
  p5 := pg_temp.vr_ticket('MI-9764', 'ZZ-S1');   -- 已有版本（走函式）→ 不重複補
  update public.spot_tickets
     set coached_on = v_today, coach_note = '舊輔導一', coached_by = 'vr-sm1@2motor.tw', coached_at = now() - interval '2 days'
   where id = p1;
  update public.spot_tickets
     set coached_on = v_today, coach_note = '舊輔導二', coached_by = cs, coached_at = now() - interval '1 day'
   where id = p2;
  update public.spot_tickets
     set coached_on = v_today, coach_note = '舊輔導四', coached_by = 'vr-gone@2motor.tw', coached_at = now() - interval '3 days'
   where id = p4;
  perform pg_temp.vr_eq('5 補第1版', '補之前：舊資料沒有版本', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id in (%L, %L, %L)', p1, p2, p4)));
  perform pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', format('select public.spot_coach(%L::uuid, %L::date, %L)', p5, v_today, '走函式'), false);

  -- 與 spot_coach_history_schema.sql 第 3 節相同的補資料語法
  insert into public.spot_ticket_coach_versions
    (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label, edited_at)
  select t.id, 1, t.coached_on, t.coach_note,
         coalesce(nullif(btrim(t.coached_by), ''), '(SQL Editor)'),
         public.spot_coach_editor_label(t.coached_by),
         t.coached_at
  from public.spot_tickets t
  where t.coached_on is not null
    and nullif(btrim(coalesce(t.coach_note, '')), '') is not null
    and not exists (select 1 from public.spot_ticket_coach_versions v where v.ticket_id = t.id);

  perform pg_temp.vr_eq('5 補第1版', '舊的甲店店長輔導補成第 1 版：內容、編輯人信箱與顯示名', '舊輔導一/vr-sm1@2motor.tw/ZZ輔導甲店-阿甲/1',
    pg_temp.vr_q1(format($q$select coach_note || '/' || edited_by || '/' || editor_label || '/' || version_no from public.spot_ticket_coach_versions where ticket_id = %L$q$, p1)));
  perform pg_temp.vr_eq('5 補第1版', '補的版本用原本的 coached_at 當編輯時間', 'true',
    pg_temp.vr_q1(format($q$select (v.edited_at = t.coached_at)::text from public.spot_ticket_coach_versions v join public.spot_tickets t on t.id = v.ticket_id where t.id = %L$q$, p1)));
  perform pg_temp.vr_eq('5 補第1版', '舊的客服部輔導補成第 1 版，顯示「總公司-陳客服」', '舊輔導二/vr-cs@2motor.tw/總公司-陳客服/1',
    pg_temp.vr_q1(format($q$select coach_note || '/' || edited_by || '/' || editor_label || '/' || version_no from public.spot_ticket_coach_versions where ticket_id = %L$q$, p2)));
  perform pg_temp.vr_eq('5 補第1版', '尚未輔導的黃單不補', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.spot_ticket_coach_versions where ticket_id = %L', p3)));
  perform pg_temp.vr_eq('5 補第1版', '編輯人帳號已不存在：顯示「（已移除帳號）」，信箱照記', '舊輔導四/（已移除帳號）/vr-gone@2motor.tw',
    pg_temp.vr_q1(format($q$select coach_note || '/' || editor_label || '/' || edited_by from public.spot_ticket_coach_versions where ticket_id = %L$q$, p4)));
  perform pg_temp.vr_eq('5 補第1版', '已有版本的單不重複補（仍只有 1 筆，內容是走函式那次）', '1/走函式',
    pg_temp.vr_q1(format($q$select count(*) || '/' || max(coach_note) from public.spot_ticket_coach_versions where ticket_id = %L$q$, p5)));
  perform pg_temp.vr_eq('5 補第1版', '補好後舊單再編輯＝第 2 版，第 1 版（舊內容）還在',
    '2:' || v_today || ':補後再編:ZZ輔導甲店-阿甲:true|1:' || v_today || ':舊輔導一:ZZ輔導甲店-阿甲:false',
    (select pg_temp.vr_vers('authenticated', 'vr-sm1@2motor.tw', p1)
     where pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', format('select public.spot_coach(%L::uuid, %L::date, %L)', p1, v_today, '補後再編'), false) = 'OK'));

  -- 重跑補資料語法不重複補：再跑一次，新增 0 筆
  insert into public.spot_ticket_coach_versions
    (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label, edited_at)
  select t.id, 1, t.coached_on, t.coach_note,
         coalesce(nullif(btrim(t.coached_by), ''), '(SQL Editor)'),
         public.spot_coach_editor_label(t.coached_by),
         t.coached_at
  from public.spot_tickets t
  where t.coached_on is not null
    and nullif(btrim(coalesce(t.coach_note, '')), '') is not null
    and not exists (select 1 from public.spot_ticket_coach_versions v where v.ticket_id = t.id);
  get diagnostics v_n = row_count;
  perform pg_temp.vr_eq('5 補第1版', '再跑一次補資料語法：新增 0 筆（不重複補）', '0', v_n::text);
exception when others then
  perform pg_temp.vr_rec('區段 5', '補第 1 版意外中斷', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：函式權限與安全設定
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('6 權限', 'spot_coach_versions／spot_coach_version_stats：authenticated 可執行、anon 不可', 'true/false/true/false',
    has_function_privilege('authenticated', 'public.spot_coach_versions(uuid)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.spot_coach_versions(uuid)', 'execute')::text || '/'
    || has_function_privilege('authenticated', 'public.spot_coach_version_stats()', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.spot_coach_version_stats()', 'execute')::text);
  perform pg_temp.vr_eq('6 權限', 'spot_coach：authenticated 可執行、anon 不可（覆蓋後權限不變）', 'true/false',
    has_function_privilege('authenticated', 'public.spot_coach(uuid, date, text)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.spot_coach(uuid, date, text)', 'execute')::text);
  perform pg_temp.vr_eq('6 權限', '內部函式（算編輯人顯示名、觸發器函式）網頁角色不能直接呼叫', 'false/false/false',
    has_function_privilege('authenticated', 'public.spot_coach_editor_label(text)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.spot_coach_editor_label(text)', 'execute')::text || '/'
    || has_function_privilege('authenticated', 'public.spot_coach_ver_immutable()', 'execute')::text);
  perform pg_temp.vr_eq('6 權限', '版本表權限：authenticated 只有 select，沒有 insert／update／delete／truncate', 'true/false/false/false/false',
    has_table_privilege('authenticated', 'public.spot_ticket_coach_versions', 'select')::text || '/'
    || has_table_privilege('authenticated', 'public.spot_ticket_coach_versions', 'insert')::text || '/'
    || has_table_privilege('authenticated', 'public.spot_ticket_coach_versions', 'update')::text || '/'
    || has_table_privilege('authenticated', 'public.spot_ticket_coach_versions', 'delete')::text || '/'
    || has_table_privilege('authenticated', 'public.spot_ticket_coach_versions', 'truncate')::text);
  perform pg_temp.vr_eq('6 權限', '版本表權限：anon 與 service_role 完全沒有', 'false/false',
    has_table_privilege('anon', 'public.spot_ticket_coach_versions', 'select')::text || '/'
    || has_table_privilege('service_role', 'public.spot_ticket_coach_versions', 'select')::text);
  perform pg_temp.vr_eq('6 權限', '版本表已啟用 RLS', 'true',
    (select relrowsecurity::text from pg_class where oid = 'public.spot_ticket_coach_versions'::regclass));
  perform pg_temp.vr_eq('6 權限', '四個新增／覆蓋的函式都是 security definer 且固定 search_path', '4',
    (select count(*)::text from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('spot_coach', 'spot_coach_versions', 'spot_coach_version_stats', 'spot_coach_editor_label')
        and p.prosecdef
        and exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')));
  perform pg_temp.vr_eq('6 權限', '版本表有三個「只增不改」觸發器（update／delete／truncate）', '3',
    (select count(*)::text from pg_trigger
      where tgrelid = 'public.spot_ticket_coach_versions'::regclass and not tgisinternal));
end
$$;

-- ---------- 結果表：先組成「已準備好的查詢」（資料已嵌入），rollback 之後再執行它 ----------
do $$
declare
  v_total int; v_ok int; v_rows text;
begin
  select count(*), count(*) filter (where pass) into v_total, v_ok from pg_temp.vr;
  select string_agg(
           format('(%s, %L, %L, %L, %L)', n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vr;
  begin execute 'deallocate spot_coach_history_vr_out'; exception when others then null; end;
  execute 'prepare spot_coach_history_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_ok = v_total then ''
                                   else '；未通過：' || (select string_agg(n::text, '、' order by n) from pg_temp.vr where not pass) end)
          || ', ' || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
end
$$;

-- 備援：rollback 前先顯示一次（若畫面出現兩張一樣的表，看最後一張即可）
select n as "序號", grp || '｜' || name as "測項", expected as "預期", actual as "實際",
       case when pass then '通過' else '失敗' end as "通過"
from pg_temp.vr order by n;

rollback;

execute spot_coach_history_vr_out;
