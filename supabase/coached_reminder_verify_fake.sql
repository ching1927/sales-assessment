-- ============================================================
-- 業務考核系統：「已輔導 → 尚未約考」提醒驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行（且必須先執行過 coached_reminder_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市（ZZ-C1／ZZ-C2／ZZ-C3）、假員工（MI-9801～MI-9820）、假帳號（vr-xxx@2motor.tw）、
--   假成績單與假改善單、假待考回報，用 set_config('request.jwt.claims', …) ＋ set local role 模擬各角色登入，
--   驗證：「尚未約考」各種情形、情況預填判斷、各角色看得到的範圍、提醒信第 2 天／第 4 天到期與當天不重複、
--   已約考／已取消／已結案停止、輔導紀錄重填後重新計算、沒有店長帳號的處理、信件內容、排程註冊、
--   既有 exam_req_badge 行為不變、內部函式與寫入權限。最後 rollback（假資料全部消失）。
-- 寄信：整段不真的寄信（rollback 後 pg_net 的請求也不會送出）；信件狀態只驗證為 queued 或 skipped（看有沒有 pg_net 與寄信設定）。
-- 怎麼看結果：SQL Editor 只顯示「最後一個」結果，所以腳本把結果表存成預備陳述式 coachedrem_vr_out，rollback 之後再 execute；
--   第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算成功。若畫面出現兩張一樣的表，看最後一張。
-- 假資料若剛好撞到真實代碼（ZZ-C1、MI-98xx、vr-xxx 信箱），腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regprocedure('public.coached_pending()') is null
     or to_regprocedure('public.coached_reminder_run(timestamptz)') is null then
    raise exception '請先執行 coached_reminder_schema.sql';
  end if;
  if to_regclass('public.exam_requests') is null or to_regclass('public.improvement_tickets') is null then
    raise exception '請先執行 backoffice_schema.sql 與 exam_request_schema.sql';
  end if;
end
$$;

-- ---------- 驗證工具（全部是暫存物件，rollback 後消失） ----------
create temp table vr (
  n int generated always as identity primary key,
  grp text, name text, expected text, actual text, pass boolean
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

create or replace function pg_temp.vr_set(p_k text, p_v text) returns void language plpgsql as $$
begin
  insert into pg_temp.vr_ctx values (p_k, p_v) on conflict (k) do update set v = excluded.v;
end $$;

create or replace function pg_temp.vr_get(p_k text) returns text language sql as $$
  select v from pg_temp.vr_ctx where k = p_k;
$$;

-- 以目前身分（資料庫擁有者）執行單一值查詢，回傳文字；沒有值回 '(null)'
create or replace function pg_temp.vr_q1(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, '(null)');
end $$;

-- 擁有者身分執行一段 SQL：成功 'OK'，失敗 'ERROR: 訊息'
create or replace function pg_temp.vr_own(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return 'ERROR: ' || sqlerrm;
end $$;

-- 以指定資料庫角色＋email 執行 SQL（p_scalar=true 回傳單一值文字；false 只執行回 'OK'）；失敗回 'ERROR: 訊息'
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

-- 預期被拒：結果須為 ERROR 開頭且訊息符合 like 樣式
create or replace function pg_temp.vr_deny(p_grp text, p_name text, p_role text, p_email text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare v_r text := pg_temp.vr_as(p_role, p_email, p_sql, false);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r, v_r like 'ERROR: ' || p_pattern);
end $$;

-- 假員工範圍（只數這批，避免真實資料干擾）
create or replace function pg_temp.vr_ids(p_sql text) returns text language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, '(空)');
end $$;

-- 某角色看到的尚未約考（只看假員工）：員工編號串
create or replace function pg_temp.vr_pend(p_email text) returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    $q$select coalesce(string_agg(employee_id, ',' order by employee_id), '(空)')
       from public.coached_pending() where employee_id between 'MI-9801' and 'MI-9899'$q$, true);
end $$;

-- 造一張改善單（含來源成績單），擁有者身分；回傳改善單 id。
-- p_status：open／coached／closed／cancelled；coached 時 coached_at 用 p_coached_at。
create or replace function pg_temp.vr_tk(p_emp text, p_store text, p_status text, p_verdict text, p_coached_at timestamptz)
returns uuid language plpgsql as $$
declare
  v_a uuid;
  v_t uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
     total_score, verdict, pass_line, submitted_at)
  values
    (p_emp, '假員' || right(p_emp, 4), p_store, 'vr-cs1@2motor.tw', 'submitted', '正式', '自動',
     50, p_verdict, 70, now())
  returning id into v_a;
  insert into public.improvement_tickets
    (assessment_id, employee_id, store_code, status, due_date, coached_on, coach_note, coached_by, coached_at,
     closed_at, cancelled_at, cancel_reason)
  values
    (v_a, p_emp, p_store, p_status, (now() at time zone 'Asia/Taipei')::date + 14,
     case when p_status = 'coached' then (p_coached_at at time zone 'Asia/Taipei')::date else null end,
     case when p_status = 'coached' then '假輔導備註' else null end,
     case when p_status = 'coached' then 'vr-sm1@2motor.tw' else null end,
     case when p_status = 'coached' then p_coached_at else null end,
     case when p_status = 'closed' then now() else null end,
     case when p_status = 'cancelled' then now() else null end,
     case when p_status = 'cancelled' then '假取消' else null end)
  returning id into v_t;
  perform pg_temp.vr_set('t' || right(p_emp, 4), v_t::text);
  return v_t;
end $$;

-- 為某員工直接寫一筆待考回報（擁有者身分）
create or replace function pg_temp.vr_req(p_emp text, p_store text, p_status text, p_cancel_by text default null)
returns void language plpgsql as $$
begin
  insert into public.exam_requests
    (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, status,
     cancel_by, cancel_reason)
  values
    ('複檢', p_emp, '假員' || right(p_emp, 4), p_store, 'vr-sm1@2motor.tw', '店長',
     array[(now() at time zone 'Asia/Taipei')::date + 3], p_status,
     case when p_status = '已取消' then coalesce(p_cancel_by, '店長') else null end,
     case when p_status = '已取消' then '假原因' else null end);
end $$;

-- 台北時間的某日 09:00（排程模擬用）
create or replace function pg_temp.vr_at(p_day text) returns timestamptz language sql as $$
  select (p_day || ' 09:00:00+08')::timestamptz;
$$;

-- 假改善單的提醒信封數（依員工編號）
create or replace function pg_temp.vr_mails(p_emp text) returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format($q$select count(*)::text from public.mail_outbox
    where kind = 'coached_reminder' and request_id = %L::uuid$q$, pg_temp.vr_get('t' || right(p_emp, 4))));
end $$;

-- 某員工的提醒記錄欄位
create or replace function pg_temp.vr_tkf(p_emp text, p_col text) returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select %s::text from public.improvement_tickets where id = %L::uuid',
                              p_col, pg_temp.vr_get('t' || right(p_emp, 4))));
end $$;

-- 執行排程函式並回傳「這次新增的提醒封數」（含是否與函式回傳值一致）
create or replace function pg_temp.vr_run(p_day text) returns text language plpgsql as $$
declare
  v_before int;
  v_ret int;
  v_after int;
begin
  select count(*) into v_before from public.mail_outbox where kind = 'coached_reminder';
  v_ret := public.coached_reminder_run(pg_temp.vr_at(p_day));
  select count(*) into v_after from public.mail_outbox where kind = 'coached_reminder';
  return (v_after - v_before)::text || case when v_ret = v_after - v_before then '' else '（回傳值不一致：' || v_ret || '）' end;
end $$;

-- ============================================================
-- 建立假資料（擁有者身分、沒有登入者）
-- X1＝ZZ-C1（店長 vr-sm1）、X2＝ZZ-C2（店長 vr-sm2）、X3＝ZZ-C3（沒有店長帳號）
-- 輔導時間統一為 2026-11-10 15:00（台北）；到期測試用 coached_reminder_run(模擬時間) 往後推
--   9801 需複訓      → 尚未約考、預填「複檢」
--   9802 不及格＋考核期 → 尚未約考、預填「回考核期」
--   9803 不及格（不在考核期）→ 尚未約考、預填空（判斷不了）
--   9804 已有「待處理」回報  9805 已有「已排定」回報  9806 只有「已取消（退回）」回報→仍尚未約考
--   9807 只有「已取消（撤回）」回報→仍尚未約考  9808 改善單待改善  9809 已結案  9810 已取消
--   9811 離職  9812 不納入考核  9813 X2 需複訓→尚未約考  9814 已有「已完成」回報
--   9815 先退回後又有「待處理」→已約考  9816 X3（沒有店長）→尚未約考  9817 來源成績單判定「及格」→尚未約考、預填空
-- ============================================================
do $$
declare
  v_c timestamptz := '2026-11-10 15:00:00+08';
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values
    ('ZZ-C1', 'ZZ測試門市甲'), ('ZZ-C2', 'ZZ測試門市乙'), ('ZZ-C3', 'ZZ測試門市丙');

  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, probation_since)
  values
    ('MI-9801', '假員9801', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9802', '假員9802', 'ZZ-C1', '業務', current_date - 200, '在職', true,  current_date),
    ('MI-9803', '假員9803', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9804', '假員9804', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9805', '假員9805', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9806', '假員9806', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9807', '假員9807', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9808', '假員9808', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9809', '假員9809', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9810', '假員9810', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9811', '假員9811', 'ZZ-C1', '業務', current_date - 200, '離職', true,  null),
    ('MI-9812', '假員9812', 'ZZ-C1', '業務', current_date - 200, '在職', false, null),
    ('MI-9813', '假員9813', 'ZZ-C2', '業務', current_date - 200, '在職', true,  null),
    ('MI-9814', '假員9814', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9815', '假員9815', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null),
    ('MI-9816', '假員9816', 'ZZ-C3', '業務', current_date - 200, '在職', true,  null),
    ('MI-9817', '假員9817', 'ZZ-C1', '業務', current_date - 200, '在職', true,  null);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-C1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-C2');

  perform pg_temp.vr_tk('MI-9801', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9802', 'ZZ-C1', 'coached',   '不及格', v_c);
  perform pg_temp.vr_tk('MI-9803', 'ZZ-C1', 'coached',   '不及格', v_c);
  perform pg_temp.vr_tk('MI-9804', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9805', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9806', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9807', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9808', 'ZZ-C1', 'open',      '需複訓', null);
  perform pg_temp.vr_tk('MI-9809', 'ZZ-C1', 'closed',    '需複訓', null);
  perform pg_temp.vr_tk('MI-9810', 'ZZ-C1', 'cancelled', '需複訓', null);
  perform pg_temp.vr_tk('MI-9811', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9812', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9813', 'ZZ-C2', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9814', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9815', 'ZZ-C1', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9816', 'ZZ-C3', 'coached',   '需複訓', v_c);
  perform pg_temp.vr_tk('MI-9817', 'ZZ-C1', 'coached',   '及格',   v_c);

  perform pg_temp.vr_req('MI-9804', 'ZZ-C1', '待處理');
  perform pg_temp.vr_req('MI-9805', 'ZZ-C1', '已排定');
  perform pg_temp.vr_req('MI-9806', 'ZZ-C1', '已取消', '客服部');
  perform pg_temp.vr_req('MI-9807', 'ZZ-C1', '已取消', '店長');
  perform pg_temp.vr_req('MI-9814', 'ZZ-C1', '已完成');
  perform pg_temp.vr_req('MI-9815', 'ZZ-C1', '已取消', '客服部');
  perform pg_temp.vr_req('MI-9815', 'ZZ-C1', '待處理');
  -- 開單前就存在、且已完成的舊回報不影響判斷：給 9801 一筆「開單前」的已完成回報
  insert into public.exam_requests
    (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done, status, created_at)
  values
    ('新人', 'MI-9801', '假員9801', 'ZZ-C1', 'vr-sm1@2motor.tw', '店長', array[current_date + 3], true, '已完成', now() - interval '30 days');

  delete from public.app_settings where key in ('mail_relay_url', 'mail_relay_token');
end
$$;

-- ============================================================
-- 0 結構與權限
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('0 結構', '改善單新增兩個欄位 last_reminded_at、reminder_count', '2',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns where table_schema = 'public'
      and table_name = 'improvement_tickets' and column_name in ('last_reminded_at', 'reminder_count')$q$));
  perform pg_temp.vr_eq('0 結構', '五個新函式都存在', '5',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('coached_pending','coached_pending_count','coached_pending_rows',
        'coached_reminder_content','coached_reminder_run')$q$));
  perform pg_temp.vr_eq('0 結構', '五個函式都是 security definer 且固定 search_path', '5',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname in ('coached_pending','coached_pending_count','coached_pending_rows',
        'coached_reminder_content','coached_reminder_run')
        and p.prosecdef and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')$q$));
  perform pg_temp.vr_eq('0 結構', 'authenticated 能執行 coached_pending／coached_pending_count', 'true/true',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.coached_pending()', 'execute')::text || '/' ||
      has_function_privilege('authenticated', 'public.coached_pending_count()', 'execute')::text$q$));
  perform pg_temp.vr_eq('0 結構', 'anon 不能執行 coached_pending／coached_pending_count', 'false/false',
    pg_temp.vr_q1($q$select has_function_privilege('anon', 'public.coached_pending()', 'execute')::text || '/' ||
      has_function_privilege('anon', 'public.coached_pending_count()', 'execute')::text$q$));
  perform pg_temp.vr_eq('0 結構', '內部三個函式 authenticated／anon 都不能執行', 'false/false/false/false/false/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.coached_pending_rows(timestamptz)', 'execute')::text || '/' ||
      has_function_privilege('authenticated', 'public.coached_reminder_run(timestamptz)', 'execute')::text || '/' ||
      has_function_privilege('authenticated', 'public.coached_reminder_content(uuid,text,text,int,text)', 'execute')::text || '/' ||
      has_function_privilege('anon', 'public.coached_pending_rows(timestamptz)', 'execute')::text || '/' ||
      has_function_privilege('anon', 'public.coached_reminder_run(timestamptz)', 'execute')::text || '/' ||
      has_function_privilege('anon', 'public.coached_reminder_content(uuid,text,text,int,text)', 'execute')::text$q$));
  perform pg_temp.vr_deny('0 結構', 'authenticated 直接呼叫 coached_reminder_run 被拒', 'authenticated', 'vr-cs1@2motor.tw',
    $q$select public.coached_reminder_run()$q$, '%permission denied%');
  perform pg_temp.vr_deny('0 結構', 'authenticated 直接呼叫 coached_pending_rows 被拒', 'authenticated', 'vr-cs1@2motor.tw',
    $q$select * from public.coached_pending_rows()$q$, '%permission denied%');
  perform pg_temp.vr_deny('0 結構', '客服部也不能直接改改善單的 last_reminded_at', 'authenticated', 'vr-cs1@2motor.tw',
    $q$update public.improvement_tickets set last_reminded_at = now()$q$, '%permission denied%');
  perform pg_temp.vr_deny('0 結構', 'anon 呼叫 coached_pending 被拒', 'anon', null,
    $q$select * from public.coached_pending()$q$, '%permission denied%');
  perform pg_temp.vr_deny('0 結構', '有登入但未開通帳號：coached_pending 沒有權限', 'authenticated', 'vr-nobody@2motor.tw',
    $q$select * from public.coached_pending()$q$, '%沒有權限%');
  perform pg_temp.vr_eq('0 結構', '有登入但未開通帳號：coached_pending_count 回 0（不報錯）', '0',
    pg_temp.vr_as('authenticated', 'vr-nobody@2motor.tw', $q$select public.coached_pending_count()::text$q$, true));
end
$$;

-- ============================================================
-- 1 尚未約考判斷與情況預填（擁有者身分，以固定時間 2026-11-12 09:00 計算天數）
-- ============================================================
do $$
declare
  v_now timestamptz := '2026-11-12 09:00:00+08';
begin
  perform pg_temp.vr_eq('1 判斷', '尚未約考的人員（只看假員工）', 'MI-9801,MI-9802,MI-9803,MI-9806,MI-9807,MI-9813,MI-9816,MI-9817',
    pg_temp.vr_q1(format($q$select string_agg(employee_id, ',' order by employee_id)
      from public.coached_pending_rows(%L::timestamptz) where employee_id between 'MI-9801' and 'MI-9899'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9804 已有待處理回報→不算尚未約考', '0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9804'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9805 已有已排定回報→不算尚未約考', '0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9805'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9806 只有被退回（已取消）的回報→仍是尚未約考', '1',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9806'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9807 只有已撤回的回報→仍是尚未約考', '1',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamp with time zone) where employee_id = 'MI-9807'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9808 待改善、9809 已結案、9810 已取消的改善單都不算', '0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id in ('MI-9808','MI-9809','MI-9810')$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9811 離職、9812 不納入考核不算', '0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id in ('MI-9811','MI-9812')$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9814 已有已完成回報不算；9815 退回後又有待處理不算', '0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id in ('MI-9814','MI-9815')$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '9801 開單前的舊已完成回報不影響（仍是尚未約考）', '1',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9801'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '預填 9801 需複訓→複檢', '複檢',
    pg_temp.vr_q1(format($q$select kind from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9801'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '預填 9802 不及格且在考核期→回考核期', '回考核期',
    pg_temp.vr_q1(format($q$select kind from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9802'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '預填 9803 不及格但不在考核期→空（判斷不了）', '(null)',
    pg_temp.vr_q1(format($q$select kind from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9803'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '預填 9817 來源成績單判定及格→空', '(null)',
    pg_temp.vr_q1(format($q$select kind from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9817'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '輔導 11-10 15:00、現在 11-12 09:00 → 已輔導 2 天（以台北日期差算）', '2',
    pg_temp.vr_q1(format($q$select coached_days::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9801'$q$, v_now)));
  perform pg_temp.vr_eq('1 判斷', '輔導當天 11-10 23:59 → 0 天', '0',
    pg_temp.vr_q1($q$select coached_days::text from public.coached_pending_rows('2026-11-10 23:59:00+08'::timestamptz) where employee_id = 'MI-9801'$q$));
  perform pg_temp.vr_eq('1 判斷', '備註：回報完成後（9801 補一筆待處理）就不算尚未約考', 'OK/0',
    pg_temp.vr_own($q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, status)
      values ('回考核期', 'MI-9801', '假員9801', 'ZZ-C1', 'vr-sm1@2motor.tw', '店長', array[current_date + 3], '待處理')$q$)
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9801'$q$, v_now)));
  -- 還原：刪掉剛補的那筆，後面的測試要用 9801
  delete from public.exam_requests where employee_id = 'MI-9801' and kind = '回考核期';
end
$$;

-- ============================================================
-- 2 各角色看得到的範圍
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('2 角色', '客服部看到全部尚未約考', 'MI-9801,MI-9802,MI-9803,MI-9806,MI-9807,MI-9813,MI-9816,MI-9817',
    pg_temp.vr_pend('vr-cs1@2motor.tw'));
  perform pg_temp.vr_eq('2 角色', '總公司主管看到全部', 'MI-9801,MI-9802,MI-9803,MI-9806,MI-9807,MI-9813,MI-9816,MI-9817',
    pg_temp.vr_pend('vr-hq@2motor.tw'));
  perform pg_temp.vr_eq('2 角色', '店長甲只看自己門市（ZZ-C1）', 'MI-9801,MI-9802,MI-9803,MI-9806,MI-9807,MI-9817',
    pg_temp.vr_pend('vr-sm1@2motor.tw'));
  perform pg_temp.vr_eq('2 角色', '店長乙只看自己門市（ZZ-C2）', 'MI-9813', pg_temp.vr_pend('vr-sm2@2motor.tw'));
  perform pg_temp.vr_eq('2 角色', '紅點數：店長甲＝自己門市尚未約考 6 人', '6',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select public.coached_pending_count()::text$q$, true));
  perform pg_temp.vr_eq('2 角色', '紅點數：店長乙 1 人', '1',
    pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', $q$select public.coached_pending_count()::text$q$, true));
  perform pg_temp.vr_eq('2 角色', '紅點數：客服部、主管不加（0）', '0/0',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw', $q$select public.coached_pending_count()::text$q$, true) || '/' ||
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select public.coached_pending_count()::text$q$, true));
  perform pg_temp.vr_eq('2 角色', '店長甲看不到 9801 以外門市的預填資料（9813 不在清單）', '0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select count(*)::text from public.coached_pending() where employee_id = 'MI-9813'$q$, true));
  perform pg_temp.vr_eq('2 角色', '預填內容店長看得到（9801 複檢、9802 回考核期、9803 空）', '複檢/回考核期/(null)',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select string_agg(coalesce(kind, '(null)'), '/' order by employee_id)
      from public.coached_pending() where employee_id in ('MI-9801','MI-9802','MI-9803')$q$, true));
  -- 既有紅點函式行為不變：店長＝自己門市 mgr_seen=false 的回報數，不受尚未約考影響
  perform pg_temp.vr_eq('2 角色', '既有 exam_req_badge 不變：店長甲（沒有未看回覆）仍是 0', '0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_own($q$update public.exam_requests set mgr_seen = false where employee_id = 'MI-9805'$q$);
  perform pg_temp.vr_eq('2 角色', '既有 exam_req_badge 不變：店長甲有 1 筆未看回覆→1', '1',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('2 角色', '既有 exam_req_badge 不變：客服部＝待處理總數', pg_temp.vr_q1($q$select count(*)::text from public.exam_requests where status = '待處理'$q$),
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('2 角色', '既有 exam_req_badge 不變：主管 0', '0',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_own($q$update public.exam_requests set mgr_seen = true where employee_id = 'MI-9805'$q$);
end
$$;

-- ============================================================
-- 3 提醒信到期邏輯（coached_reminder_run，模擬不同日期；輔導日 11-10）
-- 尚未約考者：9801、9802、9803、9806、9807（X1）；9813（X2）；9816（X3，沒有店長）；9817（X1）＝共 8 張
-- ============================================================
do $$
declare
  v_c text;
begin
  perform pg_temp.vr_eq('3 排程', '輔導當天（11-10）執行：0 封', '0', pg_temp.vr_run('2026-11-10'));
  perform pg_temp.vr_eq('3 排程', '第 1 天（11-11）執行：0 封', '0', pg_temp.vr_run('2026-11-11'));

  perform pg_temp.vr_eq('3 排程', '第 2 天（11-12）執行：8 封（每張尚未約考的改善單一封）', '8', pg_temp.vr_run('2026-11-12'));
  perform pg_temp.vr_eq('3 排程', '已約考者不寄：9804、9805、9814、9815 都 0 封', '0/0/0/0',
    pg_temp.vr_mails('MI-9804') || '/' || pg_temp.vr_mails('MI-9805') || '/' || pg_temp.vr_mails('MI-9814') || '/' || pg_temp.vr_mails('MI-9815'));
  perform pg_temp.vr_eq('3 排程', '非已輔導／離職／不納入者不寄：9808、9809、9810、9811、9812 都 0 封', '0/0/0/0/0',
    pg_temp.vr_mails('MI-9808') || '/' || pg_temp.vr_mails('MI-9809') || '/' || pg_temp.vr_mails('MI-9810') || '/' ||
    pg_temp.vr_mails('MI-9811') || '/' || pg_temp.vr_mails('MI-9812'));
  perform pg_temp.vr_eq('3 排程', '9801 各 1 封，記錄 reminder_count=1、last_reminded_at 有值', '1/1/true',
    pg_temp.vr_mails('MI-9801') || '/' || pg_temp.vr_tkf('MI-9801', 'reminder_count') || '/' ||
    pg_temp.vr_tkf('MI-9801', 'last_reminded_at is not null'));
  perform pg_temp.vr_eq('3 排程', '同一天再跑一次：0 封（當天不重複）', '0', pg_temp.vr_run('2026-11-12'));
  perform pg_temp.vr_eq('3 排程', '第 3 天（11-13）：0 封（每 2 天一封）', '0', pg_temp.vr_run('2026-11-13'));

  -- 第 2 天那批的內容與收件人
  perform pg_temp.vr_eq('3 排程', '9801 提醒信主旨', '【提醒】假員9801 已輔導完成 2 天，尚未預約考核',
    pg_temp.vr_q1(format($q$select subject from public.mail_outbox where kind = 'coached_reminder' and request_id = %L::uuid order by created_at limit 1$q$, pg_temp.vr_get('t9801'))));
  perform pg_temp.vr_eq('3 排程', '9801 收件人＝門市店長（vr-sm1）', '{vr-sm1@2motor.tw}',
    pg_temp.vr_q1(format($q$select to_emails::text from public.mail_outbox where kind = 'coached_reminder' and request_id = %L::uuid order by created_at limit 1$q$, pg_temp.vr_get('t9801'))));
  perform pg_temp.vr_eq('3 排程', '9813（X2）收件人＝店長乙（vr-sm2），不會寄到別間門市', '{vr-sm2@2motor.tw}',
    pg_temp.vr_q1(format($q$select to_emails::text from public.mail_outbox where kind = 'coached_reminder' and request_id = %L::uuid order by created_at limit 1$q$, pg_temp.vr_get('t9813'))));
  v_c := pg_temp.vr_q1(format($q$select body_html from public.mail_outbox where kind = 'coached_reminder' and request_id = %L::uuid order by created_at limit 1$q$, pg_temp.vr_get('t9801')));
  perform pg_temp.vr_rec('3 排程', '9801 信件內文：含門市、人員、（複檢）、已輔導完成 2 天、按鈕「前往預約考核」', '含全部',
    left(v_c, 120), v_c like '%ZZ測試門市甲的 <b>假員9801</b>（複檢） 已輔導完成 2 天，尚未預約考核。%' and v_c like '%前往預約考核</a>%');
  perform pg_temp.vr_rec('3 排程', '9801 按鈕連結帶 from_ticket=單號（不含姓名）且指向 requests.html', '含 requests.html?from_ticket=<單號>',
    substring(v_c from 'href="([^"]*)"'),
    v_c like ('%requests.html?from_ticket=' || pg_temp.vr_get('t9801') || '"%') and substring(v_c from 'href="([^"]*)"') not like '%假員%');
  perform pg_temp.vr_rec('3 排程', '信件不含「計時」「倒數」「監控」字眼', '都不含', 'n/a',
    v_c not like '%計時%' and v_c not like '%倒數%' and v_c not like '%監控%'
    and pg_temp.vr_q1(format($q$select subject from public.mail_outbox where request_id = %L::uuid limit 1$q$, pg_temp.vr_get('t9801'))) not similar to '%(計時|倒數|監控)%');
  v_c := pg_temp.vr_q1(format($q$select body_html from public.mail_outbox where kind = 'coached_reminder' and request_id = %L::uuid order by created_at limit 1$q$, pg_temp.vr_get('t9803')));
  perform pg_temp.vr_rec('3 排程', '9803（預填判斷不了）信件不寫括號情況', '無（複檢）（回考核期）', left(v_c, 120),
    v_c like '%<b>假員9803</b> 已輔導完成%' and v_c not like '%（複檢）%' and v_c not like '%（回考核期）%');
  perform pg_temp.vr_eq('3 排程', '9802 信件寫（回考核期）', 'true',
    (pg_temp.vr_q1(format($q$select body_html like '%%<b>假員9802</b>（回考核期） 已輔導完成 2 天%%' from public.mail_outbox where kind = 'coached_reminder' and request_id = %L::uuid limit 1$q$, pg_temp.vr_get('t9802'))))::text);
  perform pg_temp.vr_eq('3 排程', '信件狀態只可能是 queued 或 skipped（驗證時沒有真的寄出）', '0',
    pg_temp.vr_q1($q$select count(*)::text from public.mail_outbox where kind = 'coached_reminder' and status not in ('queued', 'skipped')$q$));
  perform pg_temp.vr_eq('3 排程', '9816（X3 沒有店長帳號）：留一筆 skipped 並寫明原因', 'skipped/true',
    pg_temp.vr_q1(format($q$select status || '/' || (last_error like '%%沒有可寄送的收件人%%')::text from public.mail_outbox
      where kind = 'coached_reminder' and request_id = %L::uuid limit 1$q$, pg_temp.vr_get('t9816'))));
  perform pg_temp.vr_eq('3 排程', '寄信紀錄：客服部看得到提醒信，且收件人欄位只含 2motor.tw 信箱', 'true',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select (count(*) >= 8 and bool_and(coalesce(array_to_string(to_emails, ',') ~ '^([a-z0-9._%+-]+@2motor\.tw(,|$))*$', false)))::text
         from public.mail_outbox where kind = 'coached_reminder'$q$, true));
  perform pg_temp.vr_eq('3 排程', '店長看不到寄信紀錄（只有客服部）', '0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select count(*)::text from public.mail_outbox$q$, true));

  -- 第 4 天
  perform pg_temp.vr_eq('3 排程', '第 4 天（11-14）：再寄 8 封', '8', pg_temp.vr_run('2026-11-14'));
  perform pg_temp.vr_eq('3 排程', '9801 累計 2 封、reminder_count=2；主旨寫 4 天', '2/2/true',
    pg_temp.vr_mails('MI-9801') || '/' || pg_temp.vr_tkf('MI-9801', 'reminder_count') || '/' ||
    (pg_temp.vr_q1(format($q$select bool_or(subject = '【提醒】假員9801 已輔導完成 4 天，尚未預約考核') from public.mail_outbox
      where kind = 'coached_reminder' and request_id = %L::uuid$q$, pg_temp.vr_get('t9801'))))::text);

  -- 第 5 天：沒有到期；第 6 天前先讓部分停止
  perform pg_temp.vr_eq('3 排程', '第 5 天（11-15）：0 封', '0', pg_temp.vr_run('2026-11-15'));
  -- 9801：店長送出待考回報（用函式真的送）→ 停止
  perform pg_temp.vr_eq('3 排程', '店長甲真的用 exam_req_create 替 9801 送出複檢回報', 'OK',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw',
      format($q$select public.exam_req_create('複檢', 'MI-9801', array[%L::date], null, '假備註', %L::uuid)::text$q$,
             (now() at time zone 'Asia/Taipei')::date + 3, pg_temp.vr_get('t9801')), false));
  -- 9802：客服部作廢（取消）改善單；9803：結案
  perform pg_temp.vr_eq('3 排程', '客服部取消 9802 的改善單、結案 9803 的改善單（直接改狀態模擬）', 'OK/OK',
    pg_temp.vr_own($q$update public.improvement_tickets set status = 'cancelled', cancelled_at = now(), cancel_reason = '假取消' where employee_id = 'MI-9802'$q$) || '/' ||
    pg_temp.vr_own($q$update public.improvement_tickets set status = 'closed', closed_at = now() where employee_id = 'MI-9803'$q$));
  -- 9806：店長重填輔導紀錄（coached_at 改成 11-15 10:00，比上次提醒新）
  perform pg_temp.vr_own($q$update public.improvement_tickets set coached_at = '2026-11-15 10:00:00+08', coached_on = '2026-11-15' where employee_id = 'MI-9806'$q$);

  perform pg_temp.vr_eq('3 排程', '第 6 天（11-16）：9807、9813、9816、9817 各再寄一封＝4 封（9801 已約考、9802 已取消、9803 已結案、9806 重算中都不寄）', '4',
    pg_temp.vr_run('2026-11-16'));
  perform pg_temp.vr_eq('3 排程', '9801 仍只有 2 封（已約考停止）', '2', pg_temp.vr_mails('MI-9801'));
  perform pg_temp.vr_eq('3 排程', '9802 仍只有 2 封（改善單取消後停止）', '2', pg_temp.vr_mails('MI-9802'));
  perform pg_temp.vr_eq('3 排程', '9803 仍只有 2 封（改善單結案後停止）', '2', pg_temp.vr_mails('MI-9803'));
  perform pg_temp.vr_eq('3 排程', '9806 輔導紀錄重填後才 1 天，仍只有 2 封', '2', pg_temp.vr_mails('MI-9806'));
  perform pg_temp.vr_eq('3 排程', '紅點／清單同步：9801 不在尚未約考清單、9806 仍在', '0/1',
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9801'$q$, pg_temp.vr_at('2026-11-16'))) || '/' ||
    pg_temp.vr_q1(format($q$select count(*)::text from public.coached_pending_rows(%L::timestamptz) where employee_id = 'MI-9806'$q$, pg_temp.vr_at('2026-11-16'))));

  perform pg_temp.vr_eq('3 排程', '9806 重填輔導紀錄後第 2 天（11-17）：寄 1 封（從新的輔導時間重新算）', '1', pg_temp.vr_run('2026-11-17'));
  perform pg_temp.vr_eq('3 排程', '9806 累計 3 封', '3', pg_temp.vr_mails('MI-9806'));

  -- 漏跑補寄：11-17 沒跑（模擬），直接 11-19 跑；9807 上次是 11-16，已相隔 3 天 → 補寄；其他剛寄過者 11-17 不算 9807
  perform pg_temp.vr_eq('3 排程', '漏跑補寄：11-19 執行，9807、9813、9816、9817（上次 11-16，已隔 3 天）各補一封、9806（上次 11-17）隔 2 天也寄＝5 封', '5',
    pg_temp.vr_run('2026-11-19'));

  -- 手動呼叫測試：預設參數（現在）可呼叫並回傳整數
  perform pg_temp.vr_eq('3 排程', '手動呼叫 coached_reminder_run()（預設現在）回傳整數', 'true',
    pg_temp.vr_q1($q$select (public.coached_reminder_run() >= 0)::text$q$));
end
$$;

-- ============================================================
-- 4 排程註冊
-- ============================================================
do $$
begin
  if to_regnamespace('cron') is null then
    perform pg_temp.vr_rec('4 排程註冊', '沒有 pg_cron：整份 schema 仍成功，略過排程註冊（符合設計）', '略過', '沒有 pg_cron', true);
  else
    perform pg_temp.vr_eq('4 排程註冊', '只有一個 coached_reminder_daily，每天 UTC 01:00（台北 09:00），呼叫 coached_reminder_run', '1/0 1 * * */true',
      pg_temp.vr_q1($q$select count(*)::text || '/' || max(schedule) || '/' || bool_and(command like '%coached_reminder_run%')::text
        from cron.job where jobname = 'coached_reminder_daily'$q$));
  end if;
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
    execute 'deallocate coachedrem_vr_out';
  exception when others then
    null;
  end;

  execute 'prepare coachedrem_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_ok = v_total then ''
                                   else '；第一個失敗（序號 ' || (select min(n)::text from pg_temp.vr where not pass) || '）：'
                                        || (select left(grp || '｜' || name || '｜實際：' || coalesce(actual, '(null)'), 300)
                                            from pg_temp.vr where not pass order by n limit 1)
                                        || '；全部未通過序號：' || (select string_agg(n::text, '、' order by n) from pg_temp.vr where not pass) end)
          || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  begin
    execute 'deallocate coachedrem_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare coachedrem_vr_out as select '
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
execute coachedrem_vr_out;
