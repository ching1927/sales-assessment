-- ============================================================
-- 業務考核系統：改善單輔導紀錄「編輯版本」驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 coach_history_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-H1／ZZ-H2、假員工 MI-9751～MI-9755、假帳號（vr-xxx@2motor.tw），
--   造假成績單觸發自動開單，用 set local role ＋ request.jwt.claims 模擬各角色登入，
--   呼叫 improve_mark_coached 與 improve_coach_versions，把每項斷言記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果＝「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算成功。
--   （表在 rollback 之前先存成預備陳述式 coach_history_vr_out，rollback 之後再 execute，做法與其他驗證腳本相同；
--    若畫面出現兩張一樣的表，看最後一張即可。）
-- 驗證重點：首次回填＝第 1 版、再編輯＝第 2 版且舊版不變、日期與備註都記在版本裡、被拒絕的操作不產生版本、
--   店長只能讀自己門市（別店、主管、沒帳號、未登入都被拒）、信箱只給客服部、編輯人顯示「門市-暱稱」、
--   版本不可改不可刪（含直接 update／delete／truncate／insert）、既有已輔導的單補第 1 版（補資料語法與 schema 第 3 節相同）。
-- 假門市代碼 ZZ-H1／ZZ-H2、假員工編號 MI-9751～MI-9755、假信箱 vr-cs／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw
--   若撞到真實資料，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regclass('public.improvement_ticket_coach_versions') is null
     or to_regprocedure('public.improve_coach_versions(uuid)') is null then
    raise exception '請先執行 coach_history_schema.sql';
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

-- 造一張「需複訓」的成績單並送出（觸發自動開單），回傳改善單 id
create or replace function pg_temp.vr_ticket(p_emp text, p_store text)
returns uuid language plpgsql as $$
declare v_a uuid; v_t uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source)
  values (p_emp, '假考生' || right(p_emp, 4), p_store, 'vr-cs@2motor.tw', 'draft', '正式', '自動')
  returning id into v_a;
  update public.assessments
     set status = 'submitted', total_score = 80, verdict = '需複訓', pass_line = 85,
         weakest_dims = '{主動引導}', submitted_at = now()
   where id = v_a;
  select id into v_t from public.improvement_tickets where assessment_id = v_a;
  return v_t;
end $$;

-- 某張單的版本摘要（以指定角色查）：'版本:日期:備註:編輯人:是否目前' 以 | 串接，新到舊
create or replace function pg_temp.vr_vers(p_role text, p_email text, p_ticket uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as(p_role, p_email,
    format($q$select coalesce(string_agg(version_no || ':' || coached_on || ':' || coach_note || ':' || editor_label || ':' || is_current,
                                         '|' order by version_no desc), '(空)')
              from public.improve_coach_versions(%L::uuid)$q$, p_ticket), true);
end $$;

-- ---------- 建立假資料 ----------
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-H1', 'ZZ輔導甲店'), ('ZZ-H2', 'ZZ輔導乙店');

  -- MI-9751：甲店店長（有暱稱）；MI-9752：客服部（只有姓名，沒有暱稱）；MI-9753：乙店店長（沒有綁員工）；
  -- MI-9754／9755：被輔導的考生（甲店、乙店）
  insert into public.employees (id, nickname, full_name, store_code, job_title, status, include_in_assessment) values
    ('MI-9751', '阿甲', '王甲', 'ZZ-H1', '店長', '在職', false),
    ('MI-9752', null, '陳客服', 'ZZ-H1', '客服', '在職', false),
    ('MI-9754', '假考生9754', null, 'ZZ-H1', '業務', '在職', true),
    ('MI-9755', '假考生9755', null, 'ZZ-H2', '業務', '在職', true);

  insert into public.app_users (email, role, store_code, employee_id) values
    ('vr-cs@2motor.tw',  'cs_admin',      null,    'MI-9752'),
    ('vr-hq@2motor.tw',  'hq_viewer',     null,    null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-H1', 'MI-9751'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-H2', null);
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
  v_sql text := $q$select public.improve_mark_coached(%L::uuid, %L::date, %L)$q$;
  t1 uuid; t2 uuid; v_d1 date := (now() at time zone 'Asia/Taipei')::date - 3;
begin
  t1 := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');
  t2 := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');
  -- 開單日往前挪 10 天，才能測「不同輔導日期」
  update public.improvement_tickets set created_at = now() - interval '10 days' where id in (t1, t2);

  perform pg_temp.vr_eq('1 版本', '回填前沒有任何版本', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L', t1)));

  -- 首次回填（店長）＝第 1 版
  perform pg_temp.vr_ok('1 版本', '店長首次回填成功', s1, format(v_sql, t1, v_d1, '第一次備註'));
  perform pg_temp.vr_eq('1 版本', '首次回填產生第 1 版（目前），編輯人「門市-暱稱」＝ZZ輔導甲店-阿甲',
    '1:' || v_d1 || ':第一次備註:ZZ輔導甲店-阿甲:true', pg_temp.vr_vers('authenticated', s1, t1));
  perform pg_temp.vr_eq('1 版本', '改善單本身：狀態 coached、日期、備註、操作人照舊',
    'coached/' || v_d1 || '/第一次備註/' || s1,
    pg_temp.vr_q1(format($q$select status || '/' || coached_on || '/' || coach_note || '/' || coached_by from public.improvement_tickets where id = %L$q$, t1)));

  -- 再編輯（改日期與備註）＝第 2 版，第 1 版內容不變
  perform pg_temp.vr_ok('1 版本', '店長再編輯成功（改日期與備註）', s1, format(v_sql, t1, v_today, '第二次備註'));
  perform pg_temp.vr_eq('1 版本', '再編輯後：第 2 版（目前）在前、第 1 版內容原封不動且不再是目前版',
    '2:' || v_today || ':第二次備註:ZZ輔導甲店-阿甲:true|1:' || v_d1 || ':第一次備註:ZZ輔導甲店-阿甲:false',
    pg_temp.vr_vers('authenticated', s1, t1));
  perform pg_temp.vr_eq('1 版本', '版本表共 2 筆（編輯是新增，不是覆蓋）', '2',
    pg_temp.vr_q1(format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L', t1)));

  -- 客服部也能編輯，版本記客服部（總公司-名字；沒有暱稱用姓名）
  perform pg_temp.vr_ok('1 版本', '客服部編輯成功', cs, format(v_sql, t1, v_today, '客服補充'));
  perform pg_temp.vr_eq('1 版本', '客服部編輯＝第 3 版，編輯人顯示「總公司-陳客服」（沒暱稱用姓名）',
    '3:' || v_today || ':客服補充:總公司-陳客服:true',
    split_part(pg_temp.vr_vers('authenticated', cs, t1), '|', 1));
  perform pg_temp.vr_eq('1 版本', '版本表記下編輯人信箱（三筆依序：店長、店長、客服部）',
    s1 || ',' || s1 || ',' || cs,
    pg_temp.vr_q1(format($q$select string_agg(edited_by, ',' order by version_no) from public.improvement_ticket_coach_versions where ticket_id = %L$q$, t1)));
  perform pg_temp.vr_eq('1 版本', '版本編輯時間與改善單 coached_at 一致（最新一版）', 'true',
    pg_temp.vr_q1(format($q$select (v.edited_at = t.coached_at)::text from public.improvement_ticket_coach_versions v
                            join public.improvement_tickets t on t.id = v.ticket_id where t.id = %L and v.version_no = 3$q$, t1)));

  -- 另一張單不受影響
  perform pg_temp.vr_eq('1 版本', '另一張單沒有版本', '(空)', pg_temp.vr_vers('authenticated', cs, t2));

  -- 超長備註
  perform pg_temp.vr_ok('1 版本', '超長備註（5000 字）編輯成功', s1,
    format($q$select public.improve_mark_coached(%L::uuid, %L::date, repeat('字', 5000))$q$, t2, v_today));
  perform pg_temp.vr_eq('1 版本', '超長備註完整存進版本', '1/5000',
    pg_temp.vr_q1(format('select version_no || ''/'' || length(coach_note) from public.improvement_ticket_coach_versions where ticket_id = %L', t2)));
  perform pg_temp.vr_eq('1 版本', '備註前後空白（含全形空白與換行）已去掉再存進版本', '去空白備註',
    (select pg_temp.vr_q1(format($q$select coach_note from public.improvement_ticket_coach_versions where ticket_id = %L and version_no = 2$q$, t2))
     where pg_temp.vr_as('authenticated', s1, format(v_sql, t2, v_today, E'\n　 去空白備註 \n'), false) = 'OK'));
exception when others then
  perform pg_temp.vr_rec('區段 1', '版本流程意外中斷', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：被拒絕的操作不產生版本、原行為保留
-- ============================================================
do $$
declare
  cs text := 'vr-cs@2motor.tw'; hq text := 'vr-hq@2motor.tw'; s1 text := 'vr-sm1@2motor.tw'; s2 text := 'vr-sm2@2motor.tw';
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_sql text := $q$select public.improve_mark_coached(%L::uuid, %L::date, %L)$q$;
  v_cnt text := $q$select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L$q$;
  a uuid; b uuid; x uuid; n uuid;
begin
  a := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');
  b := pg_temp.vr_ticket('MI-9755', 'ZZ-H2');
  x := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');
  n := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');
  update public.improvement_tickets set status = 'closed', closed_by = cs, closed_at = now() where id = x;
  update public.improvement_tickets set status = 'cancelled', cancelled_by = cs, cancelled_at = now(), cancel_reason = '假取消' where id = n;

  perform pg_temp.vr_deny('2 被拒', '別店店長回填被拒', 'authenticated', s2, format(v_sql, a, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('2 被拒', '總公司主管回填被拒', 'authenticated', hq, format(v_sql, a, v_today, '備註'), '%沒有權限%');
  perform pg_temp.vr_deny('2 被拒', '備註空白被拒', 'authenticated', s1, format(v_sql, a, v_today, '   '), '%輔導備註不可為空%');
  perform pg_temp.vr_deny('2 被拒', '日期晚於今天被拒', 'authenticated', s1, format(v_sql, a, v_today + 1, '備註'), '%不可晚於今天%');
  perform pg_temp.vr_deny('2 被拒', '日期早於開單日被拒', 'authenticated', s1, format(v_sql, a, v_today - 1, '備註'), '%不可早於開單日%');
  perform pg_temp.vr_deny('2 被拒', '已結案的單被拒（客服部）', 'authenticated', cs, format(v_sql, x, v_today, '備註'), '%待改善或已輔導%');
  perform pg_temp.vr_deny('2 被拒', '已取消的單被拒（店長，通用訊息）', 'authenticated', s1, format(v_sql, n, v_today, '備註'), '%找不到這張改善單或沒有權限%');
  perform pg_temp.vr_deny('2 被拒', 'anon 沒有 execute 權限', 'anon', null, format(v_sql, a, v_today, '備註'), '%permission denied%');
  perform pg_temp.vr_eq('2 被拒', '以上全部被拒之後，各單都沒有版本、甲店那張單仍是待改善',
    '0/0/0/0/open',
    pg_temp.vr_q1(format(v_cnt, a)) || '/' || pg_temp.vr_q1(format(v_cnt, b)) || '/' || pg_temp.vr_q1(format(v_cnt, x)) || '/' || pg_temp.vr_q1(format(v_cnt, n))
      || '/' || pg_temp.vr_q1(format('select status from public.improvement_tickets where id = %L', a)));

  -- 狀態轉換 pending→coached 與限自己門市仍有效
  perform pg_temp.vr_ok('2 原行為', '乙店店長回填乙店的單成功', s2, format(v_sql, b, v_today, '乙店備註'));
  perform pg_temp.vr_eq('2 原行為', '待改善 → 已輔導，並產生第 1 版（編輯人沒綁員工 → 乙店-（未填暱稱））',
    'coached/1:' || v_today || ':乙店備註:ZZ輔導乙店-（未填暱稱）:true',
    pg_temp.vr_q1(format('select status from public.improvement_tickets where id = %L', b)) || '/' || pg_temp.vr_vers('authenticated', s2, b));
  perform pg_temp.vr_eq('2 原行為', '客服部回填甲店的單成功（待改善 → 已輔導）', 'OK',
    pg_temp.vr_as('authenticated', cs, format(v_sql, a, v_today, '客服代填'), false));
  perform pg_temp.vr_eq('2 原行為', '客服部回填也產生第 1 版', '1:' || v_today || ':客服代填:總公司-陳客服:true',
    pg_temp.vr_vers('authenticated', cs, a));

  -- ============================================================
  -- 區段 3：讀取權限
  -- ============================================================
  perform pg_temp.vr_eq('3 讀取', '甲店店長讀自己門市的版本', '1:' || v_today || ':客服代填:總公司-陳客服:true', pg_temp.vr_vers('authenticated', s1, a));
  perform pg_temp.vr_eq('3 讀取', '客服部讀任何門市的版本（乙店那張）', '1:' || v_today || ':乙店備註:ZZ輔導乙店-（未填暱稱）:true', pg_temp.vr_vers('authenticated', cs, b));
  perform pg_temp.vr_deny('3 讀取', '甲店店長讀乙店的單被拒', 'authenticated', s1, format('select count(*) from public.improve_coach_versions(%L::uuid)', b), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '乙店店長讀甲店的單被拒', 'authenticated', s2, format('select count(*) from public.improve_coach_versions(%L::uuid)', a), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '總公司主管被拒', 'authenticated', hq, format('select count(*) from public.improve_coach_versions(%L::uuid)', a), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '有登入但沒開通帳號被拒', 'authenticated', 'vr-nobody@2motor.tw', format('select count(*) from public.improve_coach_versions(%L::uuid)', a), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '未登入（anon）被拒', 'anon', null, format('select count(*) from public.improve_coach_versions(%L::uuid)', a), '%permission denied%');
  perform pg_temp.vr_deny('3 讀取', '店長讀已取消的單被拒（與改善單既有可見範圍一致）', 'authenticated', s1, format('select count(*) from public.improve_coach_versions(%L::uuid)', n), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '店長讀不存在的單被拒（與別店同一句，不洩漏存在）', 'authenticated', s1,
    format('select count(*) from public.improve_coach_versions(%L::uuid)', gen_random_uuid()), '%沒有權限%');
  perform pg_temp.vr_deny('3 讀取', '客服部讀不存在的單：找不到改善單', 'authenticated', cs,
    format('select count(*) from public.improve_coach_versions(%L::uuid)', gen_random_uuid()), '%找不到改善單%');
  perform pg_temp.vr_eq('3 讀取', '客服部讀已取消的單：可讀（沒有版本回空清單）', '(空)', pg_temp.vr_vers('authenticated', cs, n));
  perform pg_temp.vr_eq('3 讀取', '信箱只給客服部：客服部看得到編輯人信箱', 'vr-cs@2motor.tw',
    pg_temp.vr_as('authenticated', cs, format('select edited_by from public.improve_coach_versions(%L::uuid)', a), true));
  perform pg_temp.vr_eq('3 讀取', '店長看到的信箱欄是空的', '(null)',
    pg_temp.vr_as('authenticated', s1, format('select edited_by from public.improve_coach_versions(%L::uuid)', a), true));
  perform pg_temp.vr_eq('3 讀取', '直接讀版本表：客服部看得到', '1',
    pg_temp.vr_as('authenticated', cs, format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L', a), true));
  perform pg_temp.vr_eq('3 讀取', '直接讀版本表：店長讀到 0 筆（只能走函式）', '0',
    pg_temp.vr_as('authenticated', s1, format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L', a), true));
  perform pg_temp.vr_eq('3 讀取', '直接讀版本表：主管讀到 0 筆', '0',
    pg_temp.vr_as('authenticated', hq, format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L', a), true));
  perform pg_temp.vr_deny('3 讀取', '直接讀版本表：anon 被拒', 'anon', null, 'select count(*) from public.improvement_ticket_coach_versions', '%permission denied%');

  -- ============================================================
  -- 區段 4：版本不可改、不可刪、不可由網頁角色直接新增
  -- ============================================================
  perform pg_temp.vr_deny('4 不可改刪', '客服部直接 update 被拒（沒有權限）', 'authenticated', cs,
    format($q$update public.improvement_ticket_coach_versions set coach_note = '偷改' where ticket_id = %L$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', '客服部直接 delete 被拒（沒有權限）', 'authenticated', cs,
    format($q$delete from public.improvement_ticket_coach_versions where ticket_id = %L$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', '客服部直接 insert 被拒（沒有權限）', 'authenticated', cs,
    format($q$insert into public.improvement_ticket_coach_versions (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label) values (%L, 99, current_date, '偽造', 'x', 'x')$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', '店長直接 update 被拒', 'authenticated', s1,
    format($q$update public.improvement_ticket_coach_versions set coach_note = '偷改' where ticket_id = %L$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('4 不可改刪', 'anon 直接 delete 被拒', 'anon', null, 'delete from public.improvement_ticket_coach_versions', '%permission denied%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '連資料庫擁有者直接 update 也被觸發器擋下',
    format($q$update public.improvement_ticket_coach_versions set coach_note = '偷改' where ticket_id = %L$q$, a), '%只增不改%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '連資料庫擁有者直接 delete 也被觸發器擋下',
    format($q$delete from public.improvement_ticket_coach_versions where ticket_id = %L$q$, a), '%只增不改%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '連資料庫擁有者 truncate 也被觸發器擋下',
    'truncate table public.improvement_ticket_coach_versions', '%只增不改%');
  perform pg_temp.vr_eq('4 不可改刪', '以上都沒改到：甲店那張單的版本內容原樣', '客服代填',
    pg_temp.vr_q1(format('select coach_note from public.improvement_ticket_coach_versions where ticket_id = %L and version_no = 1', a)));
  perform pg_temp.vr_owner_deny('4 不可改刪', '同一張單同一版序號不可重複', format($q$insert into public.improvement_ticket_coach_versions
      (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label) values (%L, 1, current_date, '重複', 'x', 'x')$q$, a), '%duplicate key%');
  perform pg_temp.vr_owner_deny('4 不可改刪', '版本序號必須 >= 1', format($q$insert into public.improvement_ticket_coach_versions
      (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label) values (%L, 0, current_date, '零版', 'x', 'x')$q$, a), '%check constraint%');

  -- 改善單被取消／結案後，歷史版本仍在
  perform pg_temp.vr_eq('4 不可改刪', '改善單改成已結案後，版本仍保留', '1',
    (select pg_temp.vr_q1(format(v_cnt, a))
     where pg_temp.vr_q1(format($q$update public.improvement_tickets set status = 'closed', closed_by = 'vr-cs@2motor.tw', closed_at = now() where id = %L returning 'ok'$q$, a)) = 'ok'));
exception when others then
  perform pg_temp.vr_rec('區段 2-4', '被拒／讀取／不可改刪意外中斷', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：既有已輔導的單補第 1 版（補資料語法與 schema 第 3 節相同）
-- ============================================================
do $$
declare
  cs text := 'vr-cs@2motor.tw';
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; p5 uuid;
begin
  -- 模擬「舊資料」：直接寫入輔導欄位、不經過函式，所以沒有任何版本
  p1 := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');   -- 已輔導，編輯人是甲店店長
  p2 := pg_temp.vr_ticket('MI-9755', 'ZZ-H2');   -- 已輔導，編輯人是客服部
  p3 := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');   -- 待改善（沒有輔導紀錄）→ 不補
  p4 := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');   -- 已輔導，編輯人帳號已被移除
  p5 := pg_temp.vr_ticket('MI-9754', 'ZZ-H1');   -- 已有版本（走函式）→ 不重複補
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '舊輔導一', coached_by = 'vr-sm1@2motor.tw', coached_at = now() - interval '2 days'
   where id = p1;
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '舊輔導二', coached_by = cs, coached_at = now() - interval '1 day'
   where id = p2;
  update public.improvement_tickets
     set status = 'coached', coached_on = v_today, coach_note = '舊輔導四', coached_by = 'vr-gone@2motor.tw', coached_at = null
   where id = p4;
  perform pg_temp.vr_eq('5 補第1版', '補之前：舊資料沒有版本', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id in (%L, %L, %L)', p1, p2, p4)));
  perform pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', format('select public.improve_mark_coached(%L::uuid, %L::date, %L)', p5, v_today, '走函式'), false);

  -- 與 coach_history_schema.sql 第 3 節相同的補資料語法
  insert into public.improvement_ticket_coach_versions
    (ticket_id, version_no, coached_on, coach_note, edited_by, editor_label, edited_at)
  select t.id, 1, t.coached_on, t.coach_note,
         coalesce(nullif(btrim(t.coached_by), ''), '(SQL Editor)'),
         public.improve_coach_editor_label(t.coached_by),
         coalesce(t.coached_at, t.updated_at)
  from public.improvement_tickets t
  where t.coached_on is not null
    and nullif(btrim(coalesce(t.coach_note, '')), '') is not null
    and not exists (select 1 from public.improvement_ticket_coach_versions v where v.ticket_id = t.id);

  perform pg_temp.vr_eq('5 補第1版', '舊的甲店店長輔導補成第 1 版：內容、編輯人信箱與顯示名', '舊輔導一/vr-sm1@2motor.tw/ZZ輔導甲店-阿甲/1',
    pg_temp.vr_q1(format($q$select coach_note || '/' || edited_by || '/' || editor_label || '/' || version_no from public.improvement_ticket_coach_versions where ticket_id = %L$q$, p1)));
  perform pg_temp.vr_eq('5 補第1版', '補的版本用原本的 coached_at 當編輯時間', 'true',
    pg_temp.vr_q1(format($q$select (v.edited_at = t.coached_at)::text from public.improvement_ticket_coach_versions v join public.improvement_tickets t on t.id = v.ticket_id where t.id = %L$q$, p1)));
  perform pg_temp.vr_eq('5 補第1版', '舊的客服部輔導補成第 1 版，顯示「總公司-陳客服」', '舊輔導二/vr-cs@2motor.tw/總公司-陳客服/1',
    pg_temp.vr_q1(format($q$select coach_note || '/' || edited_by || '/' || editor_label || '/' || version_no from public.improvement_ticket_coach_versions where ticket_id = %L$q$, p2)));
  perform pg_temp.vr_eq('5 補第1版', '沒有輔導紀錄的待改善單不補', '0',
    pg_temp.vr_q1(format('select count(*)::text from public.improvement_ticket_coach_versions where ticket_id = %L', p3)));
  perform pg_temp.vr_eq('5 補第1版', '編輯人帳號已不存在：顯示「（已移除帳號）」，沒有 coached_at 時用 updated_at', '舊輔導四/（已移除帳號）/true',
    pg_temp.vr_q1(format($q$select v.coach_note || '/' || v.editor_label || '/' || (v.edited_at = t.updated_at)::text
                            from public.improvement_ticket_coach_versions v join public.improvement_tickets t on t.id = v.ticket_id where t.id = %L$q$, p4)));
  perform pg_temp.vr_eq('5 補第1版', '已有版本的單不重複補（仍只有 1 筆，內容是走函式那次）', '1/走函式',
    pg_temp.vr_q1(format($q$select count(*) || '/' || max(coach_note) from public.improvement_ticket_coach_versions where ticket_id = %L$q$, p5)));
  perform pg_temp.vr_eq('5 補第1版', '補好後舊單再編輯＝第 2 版，第 1 版（舊內容）還在',
    '2:' || v_today || ':補後再編:ZZ輔導甲店-阿甲:true|1:' || v_today || ':舊輔導一:ZZ輔導甲店-阿甲:false',
    (select pg_temp.vr_vers('authenticated', 'vr-sm1@2motor.tw', p1)
     where pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', format('select public.improve_mark_coached(%L::uuid, %L::date, %L)', p1, v_today, '補後再編'), false) = 'OK'));
exception when others then
  perform pg_temp.vr_rec('區段 5', '補第 1 版意外中斷', '無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：函式權限與安全設定
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('6 權限', 'improve_coach_versions：authenticated 可執行、anon 不可', 'true/false',
    has_function_privilege('authenticated', 'public.improve_coach_versions(uuid)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.improve_coach_versions(uuid)', 'execute')::text);
  perform pg_temp.vr_eq('6 權限', 'improve_mark_coached：authenticated 可執行、anon 不可（覆蓋後權限不變）', 'true/false',
    has_function_privilege('authenticated', 'public.improve_mark_coached(uuid, date, text)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.improve_mark_coached(uuid, date, text)', 'execute')::text);
  perform pg_temp.vr_eq('6 權限', '內部函式（算編輯人顯示名、觸發器函式）網頁角色不能直接呼叫', 'false/false/false',
    has_function_privilege('authenticated', 'public.improve_coach_editor_label(text)', 'execute')::text || '/'
    || has_function_privilege('anon', 'public.improve_coach_editor_label(text)', 'execute')::text || '/'
    || has_function_privilege('authenticated', 'public.improvement_coach_ver_immutable()', 'execute')::text);
  perform pg_temp.vr_eq('6 權限', '版本表權限：authenticated 只有 select，沒有 insert／update／delete／truncate', 'true/false/false/false/false',
    has_table_privilege('authenticated', 'public.improvement_ticket_coach_versions', 'select')::text || '/'
    || has_table_privilege('authenticated', 'public.improvement_ticket_coach_versions', 'insert')::text || '/'
    || has_table_privilege('authenticated', 'public.improvement_ticket_coach_versions', 'update')::text || '/'
    || has_table_privilege('authenticated', 'public.improvement_ticket_coach_versions', 'delete')::text || '/'
    || has_table_privilege('authenticated', 'public.improvement_ticket_coach_versions', 'truncate')::text);
  perform pg_temp.vr_eq('6 權限', '版本表權限：anon 與 service_role 完全沒有', 'false/false',
    has_table_privilege('anon', 'public.improvement_ticket_coach_versions', 'select')::text || '/'
    || has_table_privilege('service_role', 'public.improvement_ticket_coach_versions', 'select')::text);
  perform pg_temp.vr_eq('6 權限', '版本表已啟用 RLS', 'true',
    (select relrowsecurity::text from pg_class where oid = 'public.improvement_ticket_coach_versions'::regclass));
  perform pg_temp.vr_eq('6 權限', '三個新增／覆蓋的對外函式都是 security definer 且固定 search_path', '3',
    (select count(*)::text from pg_proc p
      where p.pronamespace = 'public'::regnamespace
        and p.proname in ('improve_mark_coached', 'improve_coach_versions', 'improve_coach_editor_label')
        and p.prosecdef
        and exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')));
  perform pg_temp.vr_eq('6 權限', '版本表有三個「只增不改」觸發器（update／delete／truncate）', '3',
    (select count(*)::text from pg_trigger
      where tgrelid = 'public.improvement_ticket_coach_versions'::regclass and not tgisinternal));
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
  begin execute 'deallocate coach_history_vr_out'; exception when others then null; end;
  execute 'prepare coach_history_vr_out as select * from (values (0, '
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

execute coach_history_vr_out;
