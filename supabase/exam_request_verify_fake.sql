-- ============================================================
-- 業務考核系統：待考回報驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 exam_request_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw）／假題庫／假改善單，
--   用 set_config('request.jwt.claims', …) ＋ set local role 模擬各角色登入，真的呼叫 exam_req_* 與
--   mail_outbox_sync、assess_start／assess_draw／assess_save_item／assess_submit／assess_void，
--   把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
-- 寄信相關的處理：
--   * 第 1 區（先跑）用「真的」pg_net 與設定路徑：有 pg_net → 驗證 queued 並記 net_request_id；
--     沒有 pg_net → 驗證記為 skipped。因為整段會 rollback，pg_net 的請求不會真的送出去。
--   * 之後把三個 pg_net 小工具函式（exam_req_net_ready／exam_req_net_post／exam_req_net_result）
--     「在這個交易內」暫時換成假的實作（rollback 後自動還原），才能測 queued／例外 failed／
--     200、302、399、400、500、逾時、錯誤訊息的同步結果。
--   * 開頭會在交易內清掉 mail_relay_url／mail_relay_token（rollback 後老闆填的值會原樣還在）。
-- 怎麼看結果：
--   * SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     所以腳本在 rollback 之前把結果表存成「預備陳述式 examreq_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- 假門市代碼 ZZ-X1／ZZ-X2、假員工編號 MI-9701～MI-9777、假信箱 vr-cs1／vr-cs2／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 並發保護（兩個連線同時回報同一個人）無法在單一連線的腳本內實測，
--   只以「唯一部分索引」直接寫入重複資料被拒、以及函式內含 for update 鎖定做靜態確認。
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
  if to_regclass('public.improvement_tickets') is null then
    raise exception '請先執行 backoffice_schema.sql';
  end if;
  if to_regclass('public.exam_requests') is null
     or to_regclass('public.mail_outbox') is null
     or to_regclass('public.app_settings') is null
     or to_regprocedure('public.exam_req_create(text, text, date[], boolean, text, uuid)') is null then
    raise exception '請先執行 exam_request_schema.sql';
  end if;
  if to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is null then
    raise exception '請先執行 url_patch.sql（assess_save_item 需為四參數版本）';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status')
     or to_regclass('public.reply_activations') is null then
    raise exception '請先執行 phase1_schema.sql（新人資格改用 employees.period_status）';
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

-- 一次測多個角色被拒：c＝客服部（vr-cs1）、h＝總公司主管、s＝店長（vr-sm1）、n＝有登入但沒帳號、a＝未登入（anon）
create or replace function pg_temp.vr_denyset(p_grp text, p_label text, p_sql text, p_who text)
returns void language plpgsql as $$
begin
  if position('c' in p_who) > 0 then
    perform pg_temp.vr_deny(p_grp, p_label || '：客服部被拒', 'authenticated', 'vr-cs1@2motor.tw', p_sql, '%沒有權限%');
  end if;
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

create or replace function pg_temp.vr_today()
returns date language sql as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

-- 日期陣列的 SQL 運算式：vr_darr(1, 3) ＝ 今天+1、今天+3
create or replace function pg_temp.vr_darr(variadic p_offs int[])
returns text language sql as $$
  select 'array[' || string_agg(quote_literal((pg_temp.vr_today() + o)::text), ',' order by ord) || ']::date[]'
  from unnest(p_offs) with ordinality as t(o, ord);
$$;

-- 新增回報（任一角色），回傳新回報 id 的文字或 'ERROR: …'
create or replace function pg_temp.vr_cr(p_email text, p_kind text, p_emp text, p_dates text default null,
                                          p_video text default 'null', p_note text default null, p_ticket text default null)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select public.exam_req_create(%L, %L, %s, %s, %L, %L::uuid)::text$q$,
           p_kind, p_emp, coalesce(p_dates, pg_temp.vr_darr(1)), p_video, p_note, p_ticket),
    true);
end $$;

-- 預期新增成功：結果必須是 uuid，並把 id 存進 ctx
create or replace function pg_temp.vr_okid(p_grp text, p_name text, p_key text, p_email text, p_kind text, p_emp text,
                                            p_dates text default null, p_video text default 'null',
                                            p_note text default null, p_ticket text default null)
returns void language plpgsql as $$
declare
  v_r text := pg_temp.vr_cr(p_email, p_kind, p_emp, p_dates, p_video, p_note, p_ticket);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '成功並回傳 uuid', v_r,
                         v_r ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  if v_r not like 'ERROR:%' then
    perform pg_temp.vr_set(p_key, v_r);
  end if;
end $$;

-- 預期新增被拒，訊息符合 like 樣式
create or replace function pg_temp.vr_crerr(p_grp text, p_name text, p_pattern text, p_email text, p_kind text, p_emp text,
                                             p_dates text default null, p_video text default 'null',
                                             p_note text default null, p_ticket text default null)
returns void language plpgsql as $$
declare
  v_r text := pg_temp.vr_cr(p_email, p_kind, p_emp, p_dates, p_video, p_note, p_ticket);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r,
                         v_r like 'ERROR: ' || p_pattern);
end $$;

-- 回報某欄位（擁有者身分）
create or replace function pg_temp.vr_f(p_key text, p_col text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select %s::text from public.exam_requests where id = %L::uuid', p_col, pg_temp.vr_get(p_key)));
end $$;

-- 某回報、某種信的筆數／某欄位（擁有者身分）
create or replace function pg_temp.vr_mc(p_key text, p_kind text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select count(*)::text from public.mail_outbox where request_id = %L::uuid and kind = %L',
                              pg_temp.vr_get(p_key), p_kind));
end $$;

create or replace function pg_temp.vr_mf(p_key text, p_kind text, p_col text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select %s::text from public.mail_outbox where request_id = %L::uuid and kind = %L limit 1',
                              p_col, pg_temp.vr_get(p_key), p_kind));
end $$;

-- 以某身分用函式排定／退回／撤回
create or replace function pg_temp.vr_sched(p_email text, p_key text, p_at text, p_note text default null)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select public.exam_req_schedule(%L::uuid, %s, %L)::text$q$, pg_temp.vr_get(p_key), p_at, p_note), true);
end $$;

create or replace function pg_temp.vr_ret(p_email text, p_key text, p_reason text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select public.exam_req_return(%L::uuid, %L)::text$q$, pg_temp.vr_get(p_key), p_reason), true);
end $$;

create or replace function pg_temp.vr_wd(p_email text, p_key text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select public.exam_req_withdraw(%L::uuid)::text$q$, pg_temp.vr_get(p_key)), true);
end $$;

-- 候選名單（只看 MI-9701～9719 這批資格測試用的假人員）：員工編號串
create or replace function pg_temp.vr_cand(p_email text, p_kind text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select coalesce(string_agg(employee_id, ',' order by employee_id, ticket_note), '(空)')
              from public.exam_req_candidates(%L) where employee_id between 'MI-9701' and 'MI-9719'$q$, p_kind), true);
end $$;

-- 真實考核流程：客服部 assess_start → assess_draw → assess_save_item，回傳考核 id；失敗丟例外
create or replace function pg_temp.vr_flow(p_emp text, p_levels jsonb)
returns uuid language plpgsql as $$
declare
  v_r text;
  v_aid uuid;
  v_item uuid;
begin
  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.assess_start(%L, null)::text$q$, p_emp), true);
  if v_r like 'ERROR%' then raise exception 'assess_start：%', v_r; end if;
  v_aid := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select item_id::text from public.assess_draw(%L::uuid, array['ZZ分類X'])$q$, v_aid), true);
  if v_r like 'ERROR%' then raise exception 'assess_draw：%', v_r; end if;
  v_item := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '假備註')$q$, v_item, p_levels::text), false);
  if v_r like 'ERROR%' then raise exception 'assess_save_item：%', v_r; end if;
  return v_aid;
end $$;

create or replace function pg_temp.vr_mk(a text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('資訊正確性', a, '預設訊息運用', a, '問題掌握', a, '主動引導', a,
                            '風險意識', a, '語氣與禮貌', a, '文字品質', a);
$$;

create or replace function pg_temp.vr_submit(p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select total_score::text || '/' || verdict from public.assess_submit(%L::uuid)$q$, p_aid), true);
end $$;

-- 造一張「已輔導／其他狀態」的改善單（含來源成績單），擁有者身分；回傳改善單 id
create or replace function pg_temp.vr_tk(p_emp text, p_store text, p_status text, p_note text)
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
     50, '不及格', 70, now())
  returning id into v_a;
  insert into public.improvement_tickets
    (assessment_id, employee_id, store_code, status, due_date, coached_on, coach_note)
  values
    (v_a, p_emp, p_store, p_status, pg_temp.vr_today() + 14,
     case when p_status = 'coached' then pg_temp.vr_today() else null end,
     p_note)
  returning id into v_t;
  return v_t;
end $$;

-- 把所有假帳號「今天」的回報計數移到昨天（每日頻率限制每人每天 20 筆，驗證腳本單一帳號會建立很多筆）
create or replace function pg_temp.vr_rewind()
returns void language plpgsql as $$
begin
  update public.exam_requests set created_at = created_at - interval '1 day' where requested_by like 'vr-%';
end $$;

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- X1＝ZZ-X1（店長 vr-sm1）、X2＝ZZ-X2（店長 vr-sm2）
-- 9701 正式  9702 未填到職日  9703 新人  9704 到職滿 90 天（仍是新人）  9705 到職 91 天（正式）
-- 9706 不納入考核  9707 離職  9708 考核期  9709 X2 新人  9710 新人且考核期  9711 離職且考核期
-- 9712 不納入且考核期  9713 未填到職日且考核期  9714 兩張已輔導改善單  9715 待改善／已結案／已取消改善單
-- 9716 X2 已輔導改善單  9717 離職＋已輔導改善單  9718 不納入考核＋已輔導改善單  9770 複檢完成流程  9771～9777 各測項專用  9730～9769 X1 新人（各測項專用，見各區段註解）
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  i int;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values
    ('ZZ-X1', 'ZZ測試門市甲'), ('ZZ-X2', 'ZZ測試門市乙');

  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, probation_since)
  values
    ('MI-9701', '假員9701', 'ZZ-X1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9702', '假員9702', 'ZZ-X1', '業務', null,          '在職', true,  null),
    ('MI-9703', '假員9703', 'ZZ-X1', '業務', v_today - 30,  '在職', true,  null),
    ('MI-9704', '假員9704', 'ZZ-X1', '業務', v_today - 90,  '在職', true,  null),
    ('MI-9705', '假員9705', 'ZZ-X1', '業務', v_today - 91,  '在職', true,  null),
    ('MI-9706', '假員9706', 'ZZ-X1', '業務', v_today - 30,  '在職', false, null),
    ('MI-9707', '假員9707', 'ZZ-X1', '業務', v_today - 30,  '離職', true,  null),
    ('MI-9708', '假員9708', 'ZZ-X1', '業務', v_today - 200, '在職', true,  v_today),
    ('MI-9709', '假員9709', 'ZZ-X2', '業務', v_today - 10,  '在職', true,  null),
    ('MI-9710', '假員9710', 'ZZ-X1', '業務', v_today - 30,  '在職', true,  v_today),
    ('MI-9711', '假員9711', 'ZZ-X1', '業務', v_today - 200, '離職', true,  v_today),
    ('MI-9712', '假員9712', 'ZZ-X1', '業務', v_today - 200, '在職', false, v_today),
    ('MI-9713', '假員9713', 'ZZ-X1', '業務', null,          '在職', true,  v_today),
    ('MI-9714', '假員9714', 'ZZ-X1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9715', '假員9715', 'ZZ-X1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9716', '假員9716', 'ZZ-X2', '業務', v_today - 200, '在職', true,  null),
    ('MI-9717', '假員9717', 'ZZ-X1', '業務', v_today - 200, '離職', true,  null),
    ('MI-9718', '假員9718', 'ZZ-X1', '業務', v_today - 200, '在職', false, null),
    ('MI-9770', '假員9770', 'ZZ-X1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9773', '假員9773', 'ZZ-X2', '業務', v_today - 10,  '在職', true,  null),
    ('MI-9774', '假員9774', 'ZZ-X2', '業務', v_today - 10,  '在職', true,  null),
    ('MI-9775', '假員9775', 'ZZ-X1', '業務', v_today - 10,  '在職', true,  null),
    ('MI-9776', '假員9776', 'ZZ-X1', '業務', v_today - 10,  '在職', true,  null),
    ('MI-9771', '假員9771', 'ZZ-X1', '業務', v_today - 10,  '在職', true,  null),
    ('MI-9777', '假員9777', 'ZZ-X1', '業務', v_today - 10,  '在職', true,  null);

  for i in 30 .. 69 loop
    insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
    values ('MI-97' || i::text, '假員97' || i::text, 'ZZ-X1', '業務', v_today - 10, '在職', true);
  end loop;

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-cs2@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-X1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-X2');
  -- 第一期（phase1）新人規則：新人回報＝period_status = '考核期' 且 probation_since 為空，不再看到職 90 天。
  --   所以到職 90 天內的假新人在建立時就設成考核期；9778（到職 10 天但已上線）專門用來測「已上線的新人標籤者不可報新人」。
  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, probation_since)
  values ('MI-9778', '假員9778', 'ZZ-X1', '業務', v_today - 10, '在職', true, null);
  update public.employees set period_status = '考核期'
   where id like 'MI-97%' and id <> 'MI-9778' and probation_since is null and hire_date is not null and hire_date >= v_today - 90;

  -- 注意：真實資料庫有 accounts_email_domain_check 觸發器，app_users 只收 @2motor.tw 信箱，
  --   所以「收件人過濾」不寫入不合格帳號，改直接以字面值呼叫內部函式 exam_req_enqueue 測（見區段 11）。
  -- vr-nobody@2motor.tw 刻意不建立帳號（模擬有登入但未開通）

  insert into public.questions (category, code, title, steps) values
    ('ZZ分類X', 'X1', '假題組X1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類X', 'X2', '假題組X2', '[{"action":"動作1","point":"考點1"}]'::jsonb);

  -- 假改善單（直接寫入，含來源成績單）
  perform pg_temp.vr_set('tkA',      pg_temp.vr_tk('MI-9714', 'ZZ-X1', 'coached',   '輔導A')::text);
  perform pg_temp.vr_set('tkB',      pg_temp.vr_tk('MI-9714', 'ZZ-X1', 'coached',   '輔導B')::text);
  perform pg_temp.vr_set('tkOpen',   pg_temp.vr_tk('MI-9715', 'ZZ-X1', 'open',      '待改善單')::text);
  perform pg_temp.vr_set('tkClosed', pg_temp.vr_tk('MI-9715', 'ZZ-X1', 'closed',    '已結案單')::text);
  perform pg_temp.vr_set('tkCancel', pg_temp.vr_tk('MI-9715', 'ZZ-X1', 'cancelled', '已取消單')::text);
  perform pg_temp.vr_set('tkX2',     pg_temp.vr_tk('MI-9716', 'ZZ-X2', 'coached',   '輔導X2')::text);
  perform pg_temp.vr_set('tkLeft',   pg_temp.vr_tk('MI-9717', 'ZZ-X1', 'coached',   '離職者單')::text);
  perform pg_temp.vr_set('tkNoinc',  pg_temp.vr_tk('MI-9718', 'ZZ-X1', 'coached',   '不納入單')::text);
  perform pg_temp.vr_set('tkDone',   pg_temp.vr_tk('MI-9770', 'ZZ-X1', 'coached',   '複檢完成單')::text);

  -- 清掉老闆可能已填的寄信設定（交易內；rollback 後原樣還在）
  delete from public.app_settings where key in ('mail_relay_url', 'mail_relay_token');
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 0：結構（資料表、RLS、索引、觸發器、函式、權限）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('0 結構','三張新表都存在且開了 RLS','3',
    pg_temp.vr_q1($q$select count(*)::text from pg_class c
                     where c.oid in ('public.exam_requests'::regclass, 'public.mail_outbox'::regclass,
                                     'public.app_settings'::regclass)
                       and c.relrowsecurity$q$));

  perform pg_temp.vr_eq('0 結構','app_settings 沒有任何 policy','0',
    pg_temp.vr_q1($q$select count(*)::text from pg_policies where schemaname = 'public' and tablename = 'app_settings'$q$));

  perform pg_temp.vr_eq('0 結構','exam_requests 與 mail_outbox 各只有一條 select policy','2',
    pg_temp.vr_q1($q$select count(*)::text from pg_policies
                     where schemaname = 'public' and tablename in ('exam_requests', 'mail_outbox') and cmd = 'SELECT'$q$));

  perform pg_temp.vr_eq('0 結構','兩條唯一部分索引存在（防重複）','2',
    pg_temp.vr_q1($q$select count(*)::text from pg_indexes
                     where schemaname = 'public' and tablename = 'exam_requests'
                       and indexname in ('exam_requests_open_emp_kind_uq', 'exam_requests_open_ticket_uq')
                       and indexdef like '%UNIQUE%' and indexdef like '%WHERE%'$q$));

  perform pg_temp.vr_eq('0 結構','authenticated 對三張表沒有任何直接寫入權限（insert／update／delete／truncate）','0',
    pg_temp.vr_q1($q$select count(*)::text from unnest(array['public.exam_requests','public.mail_outbox','public.app_settings']) t(tbl),
                          unnest(array['insert','update','delete','truncate']) p(priv)
                     where has_table_privilege('authenticated', t.tbl, p.priv)$q$));

  perform pg_temp.vr_eq('0 結構','anon 對三張表沒有任何權限','0',
    pg_temp.vr_q1($q$select count(*)::text from unnest(array['public.exam_requests','public.mail_outbox','public.app_settings']) t(tbl),
                          unnest(array['select','insert','update','delete','truncate']) p(priv)
                     where has_table_privilege('anon', t.tbl, p.priv)$q$));

  perform pg_temp.vr_eq('0 結構','authenticated 對 app_settings 連 select 都沒有；對另兩張有 select','false/true/true',
    pg_temp.vr_q1($q$select has_table_privilege('authenticated', 'public.app_settings', 'select')::text || '/' ||
                            has_table_privilege('authenticated', 'public.exam_requests', 'select')::text || '/' ||
                            has_table_privilege('authenticated', 'public.mail_outbox', 'select')::text$q$));

  perform pg_temp.vr_eq('0 結構','八個對外函式都存在','8',
    pg_temp.vr_q1($q$select count(to_regprocedure(s))::text from unnest(array[
        'public.exam_req_candidates(text)',
        'public.exam_req_create(text, text, date[], boolean, text, uuid)',
        'public.exam_req_withdraw(uuid)',
        'public.exam_req_schedule(uuid, timestamptz, text)',
        'public.exam_req_return(uuid, text)',
        'public.exam_req_mark_seen()',
        'public.exam_req_badge()',
        'public.mail_outbox_sync()']) as s$q$));

  perform pg_temp.vr_eq('0 結構','八個對外函式都是 security definer 且固定 search_path','8',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.proname in ('exam_req_candidates','exam_req_create','exam_req_withdraw','exam_req_schedule',
                                         'exam_req_return','exam_req_mark_seen','exam_req_badge','mail_outbox_sync')
                       and p.prosecdef
                       and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')$q$));

  perform pg_temp.vr_eq('0 結構','authenticated 對八個對外函式都有 execute；anon 都沒有','8/0',
    pg_temp.vr_q1($q$select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/' ||
                            count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
                     from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.proname in ('exam_req_candidates','exam_req_create','exam_req_withdraw','exam_req_schedule',
                                         'exam_req_return','exam_req_mark_seen','exam_req_badge','mail_outbox_sync')$q$));

  perform pg_temp.vr_eq('0 結構','十三個內部函式（小工具、信件、觸發器函式）都不開放給 authenticated 與 anon','13/0',
    pg_temp.vr_q1($q$select count(*)::text || '/' ||
                            count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute')
                                                or has_function_privilege('anon', p.oid, 'execute'))::text
                     from pg_proc p
                     where p.pronamespace = 'public'::regnamespace
                       and p.proname in ('exam_req_status_open','exam_req_label','exam_req_esc','exam_req_setting','exam_req_link',
                                         'exam_req_net_ready','exam_req_net_post','exam_req_net_result','exam_req_mail_content',
                                         'exam_req_enqueue','exam_req_notify','mail_outbox_dispatch','exam_req_auto_complete')$q$));

  perform pg_temp.vr_eq('0 結構','觸發器：assessments 上有新的自動完成觸發器，mail_outbox 上有寄信觸發器','1/1',
    pg_temp.vr_q1($q$select (select count(*) from pg_trigger where tgname = 'exam_req_auto_complete_trg'
                                and tgrelid = 'public.assessments'::regclass and not tgisinternal)::text || '/' ||
                            (select count(*) from pg_trigger where tgname = 'mail_outbox_dispatch_trg'
                                and tgrelid = 'public.mail_outbox'::regclass and not tgisinternal)::text$q$));

  perform pg_temp.vr_eq('0 結構','既有觸發器仍在：improvement_auto_open_trg、improvement_auto_cancel_trg','2',
    pg_temp.vr_q1($q$select count(*)::text from pg_trigger
                     where tgrelid = 'public.assessments'::regclass and not tgisinternal
                       and tgname in ('improvement_auto_open_trg', 'improvement_auto_cancel_trg')$q$));

  perform pg_temp.vr_eq('0 結構','site_url 預設值存在（https 開頭）','true',
    pg_temp.vr_q1($q$select (coalesce((select value from public.app_settings where key = 'site_url'), '') like 'https://%')::text$q$));

  perform pg_temp.vr_eq('0 結構','create 函式含 for update 鎖定（靜態確認：並發回報在人員那列排隊）','true',
    pg_temp.vr_q1($q$select (prosrc like '%from public.employees%for update%')::text
                     from pg_proc where proname = 'exam_req_create' and pronamespace = 'public'::regnamespace$q$));

  perform pg_temp.vr_eq('0 結構','三張表的 check 約束：新人必須 video_done = true、非新人必須 null','OK/OK/ERROR',
    pg_temp.vr_own($q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
                      values ('新人', 'MI-9759', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長', array[current_date], true)$q$) || '/' ||
    pg_temp.vr_own($q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
                      values ('回考核期', 'MI-9759', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長', array[current_date], null)$q$) || '/' ||
    split_part(pg_temp.vr_own($q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
                      values ('複檢', 'MI-9759', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長', array[current_date], true)$q$), ':', 1));
  perform pg_temp.vr_own($q$delete from public.exam_requests where requested_by = 'vr-zz@2motor.tw'$q$);

  perform pg_temp.vr_ownerr('0 結構','直接寫入 4 個希望日期被資料庫拒絕（check）',
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
       values ('回考核期', 'MI-9759', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長',
               array[current_date, current_date+1, current_date+2, current_date+3], null)$q$,
    '%exam_requests_desired_dates_check%');

  perform pg_temp.vr_ownerr('0 結構','直接寫入 501 字備註被資料庫拒絕（check）',
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, note)
       values ('回考核期', 'MI-9759', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長', array[current_date], repeat('字', 501))$q$,
    '%exam_requests_note_check%');
exception when others then
  perform pg_temp.vr_rec('區段 0','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：寄信路徑（真實 pg_net 與設定）——此時三個 pg_net 小工具還是正式版
--   有 pg_net：填好設定 → queued 並記 net_request_id（rollback 後不會真的送出）
--   沒有 pg_net：一律 skipped
-- ============================================================
do $$
declare
  v_ready boolean := (select public.exam_req_net_ready());
  v_id text;
begin
  perform pg_temp.vr_rec('1 真實寄信路徑','pg_net 狀態（資訊）','記錄', case when v_ready then '已啟用' else '未啟用' end, true);

  -- 沒設定
  v_id := pg_temp.vr_cr('vr-sm1@2motor.tw', '新人', 'MI-9757', null, 'true', null);
  perform pg_temp.vr_set('b1', v_id);
  perform pg_temp.vr_eq('1 真實寄信路徑','完全沒設定：新回報成功、信件記 skipped 並說明原因','skipped/true',
    pg_temp.vr_mf('b1','new','status') || '/' ||
    (pg_temp.vr_mf('b1','new','last_error') like '尚未%')::text);
  perform pg_temp.vr_eq('1 真實寄信路徑','完全沒設定：沒有 net_request_id','(null)', pg_temp.vr_mf('b1','new','net_request_id'));

  -- 只有網址、沒有密碼
  insert into public.app_settings (key, value) values ('mail_relay_url', 'https://example.invalid/exec');
  v_id := pg_temp.vr_cr('vr-sm1@2motor.tw', '新人', 'MI-9758', null, 'true', null);
  perform pg_temp.vr_set('b2', v_id);
  perform pg_temp.vr_eq('1 真實寄信路徑','只填網址沒填密碼：skipped','skipped', pg_temp.vr_mf('b2','new','status'));

  -- 設定完整
  insert into public.app_settings (key, value) values ('mail_relay_token', 'vr-token-not-real');
  v_id := pg_temp.vr_cr('vr-sm1@2motor.tw', '新人', 'MI-9759', null, 'true', null);
  perform pg_temp.vr_set('b3', v_id);
  perform pg_temp.vr_eq('1 真實寄信路徑','設定完整：有 pg_net → queued 並記 net_request_id；沒有 pg_net → skipped',
    case when v_ready then 'queued/true' else 'skipped/false' end,
    pg_temp.vr_mf('b3','new','status') || '/' || (pg_temp.vr_mf('b3','new','net_request_id') <> '(null)')::text);
  perform pg_temp.vr_eq('1 真實寄信路徑','設定完整：回報本身成功建立（待處理）','待處理', pg_temp.vr_f('b3','status'));

  -- 空白值視為沒設定
  update public.app_settings set value = '   ' where key = 'mail_relay_token';
  v_id := pg_temp.vr_cr('vr-cs1@2motor.tw', '新人', 'MI-9756', null, 'true', null);
  perform pg_temp.vr_set('b4', v_id);
  perform pg_temp.vr_eq('1 真實寄信路徑','密碼只有空白：視為沒設定，skipped','skipped', pg_temp.vr_mf('b4','new','status'));

  delete from public.app_settings where key in ('mail_relay_url', 'mail_relay_token');
exception when others then
  perform pg_temp.vr_rec('區段 1','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 換成假的 pg_net 小工具（只在這個交易內有效；rollback 後正式版自動還原）
-- ============================================================
-- 假請求編號從很大的數字開始，避免和真實 pg_net 已有的請求編號撞號
create temp sequence vr_net_seq start 900000000000;
create temp table vr_net_calls (id bigint primary key, url text, body jsonb, headers jsonb, timeout_ms int);
create temp table vr_net_resp (id bigint, status_code int, timed_out boolean, error_msg text, content text);
create temp table vr_net_cfg (ready boolean);
insert into vr_net_cfg values (true);

create or replace function public.exam_req_net_ready()
returns boolean language plpgsql stable security definer set search_path = public, pg_temp
as $$ begin return (select c.ready from pg_temp.vr_net_cfg c limit 1); end $$;

create or replace function public.exam_req_net_post(p_url text, p_body jsonb, p_headers jsonb, p_timeout_ms int)
returns bigint language plpgsql security definer set search_path = public, pg_temp
as $$
declare v bigint;
begin
  if p_url like '%throw%' then
    raise exception '假 http_post 丟例外';
  end if;
  v := nextval('pg_temp.vr_net_seq');
  insert into pg_temp.vr_net_calls values (v, p_url, p_body, p_headers, p_timeout_ms);
  return v;
end $$;

create or replace function public.exam_req_net_result(p_request_id bigint)
returns table(status_code int, timed_out boolean, error_msg text, content text)
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  return query select r.status_code, r.timed_out, r.error_msg, r.content
               from pg_temp.vr_net_resp r where r.id = p_request_id;
end $$;

-- ============================================================
-- 區段 2：候選名單（依第一節規則）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('2 候選名單','新人（客服部）：只有 9703、9704（剛好 90 天）、9709；未填到職日、91 天、不納入、離職、考核期者都不列',
    'MI-9703,MI-9704,MI-9709', pg_temp.vr_cand('vr-cs1@2motor.tw', '新人'));
  perform pg_temp.vr_eq('2 候選名單','新人（店長甲）：只列自己門市','MI-9703,MI-9704', pg_temp.vr_cand('vr-sm1@2motor.tw', '新人'));
  perform pg_temp.vr_eq('2 候選名單','新人（店長乙）：只列自己門市','MI-9709', pg_temp.vr_cand('vr-sm2@2motor.tw', '新人'));
  perform pg_temp.vr_eq('2 候選名單','回考核期（客服部）：9708、9710（新人且考核期）、9713（未填到職日且考核期）；離職、不納入者不列',
    'MI-9708,MI-9710,MI-9713', pg_temp.vr_cand('vr-cs1@2motor.tw', '回考核期'));
  perform pg_temp.vr_eq('2 候選名單','回考核期（店長乙）：沒有','(空)', pg_temp.vr_cand('vr-sm2@2motor.tw', '回考核期'));
  perform pg_temp.vr_eq('2 候選名單','複檢（客服部）：只列「已輔導」的改善單，9714 兩張各一列、9716 一張；待改善／已結案／已取消不列',
    'MI-9714,MI-9714,MI-9716', pg_temp.vr_cand('vr-cs1@2motor.tw', '複檢'));
  perform pg_temp.vr_eq('2 候選名單','複檢（店長甲）：只列自己門市','MI-9714,MI-9714', pg_temp.vr_cand('vr-sm1@2motor.tw', '複檢'));
  perform pg_temp.vr_eq('2 候選名單','複檢（店長乙）：只列自己門市','MI-9716', pg_temp.vr_cand('vr-sm2@2motor.tw', '複檢'));

  perform pg_temp.vr_eq('2 候選名單','複檢每列帶 ticket_id 與輔導備註（輔導A、輔導B、輔導X2）','3/輔導A,輔導B,輔導X2',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select count(ticket_id)::text || '/' || string_agg(ticket_note, ',' order by ticket_note)
         from public.exam_req_candidates('複檢') where employee_id between 'MI-9701' and 'MI-9719'$q$, true));
  perform pg_temp.vr_eq('2 候選名單','新人與回考核期的 ticket_id 與 ticket_note 為空','0/0',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select count(ticket_id)::text || '/' || count(ticket_note)::text
         from public.exam_req_candidates('新人') where employee_id like 'MI-97%'$q$, true));
  perform pg_temp.vr_eq('2 候選名單','label 用暱稱（假員9703）','假員9703',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw',
      $q$select label from public.exam_req_candidates('新人') where employee_id = 'MI-9703'$q$, true));
  perform pg_temp.vr_eq('2 候選名單','label 暱稱空白時改用姓名','真名甲',
    pg_temp.vr_q1($q$select public.exam_req_label('  ', '真名甲')$q$));

  perform pg_temp.vr_deny('2 候選名單','情況不合法（亂填）被拒','authenticated','vr-cs1@2motor.tw',
    $q$select * from public.exam_req_candidates('亂填')$q$, '%情況必須是%');
  perform pg_temp.vr_deny('2 候選名單','情況為空被拒','authenticated','vr-cs1@2motor.tw',
    $q$select * from public.exam_req_candidates(null)$q$, '%情況必須是%');
exception when others then
  perform pg_temp.vr_rec('區段 2','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：新增回報（成功與各種驗證）
-- ============================================================
do $$
declare
  v_t date := (now() at time zone 'Asia/Taipei')::date;
  v_a text := pg_temp.vr_get('tkA');
begin
  -- 成功案例
  perform pg_temp.vr_okid('3 新增','店長甲替 9703 回報「新人」（影片已看、2 個日期、有備註）','r_n1','vr-sm1@2motor.tw','新人','MI-9703',
                          pg_temp.vr_darr(1,3), 'true', '備註一');
  perform pg_temp.vr_eq('3 新增','欄位：kind／人員快照／門市快照','新人/假員9703/ZZ-X1',
    pg_temp.vr_f('r_n1','kind') || '/' || pg_temp.vr_f('r_n1','employee_label') || '/' || pg_temp.vr_f('r_n1','store_code'));
  perform pg_temp.vr_eq('3 新增','欄位：requested_by／requested_role／status','vr-sm1@2motor.tw/店長/待處理',
    pg_temp.vr_f('r_n1','requested_by') || '/' || pg_temp.vr_f('r_n1','requested_role') || '/' || pg_temp.vr_f('r_n1','status'));
  perform pg_temp.vr_eq('3 新增','欄位：video_done＝true、mgr_seen＝true（預設）、備註原樣','true/true/備註一',
    pg_temp.vr_f('r_n1','video_done') || '/' || pg_temp.vr_f('r_n1','mgr_seen') || '/' || pg_temp.vr_f('r_n1','note'));
  perform pg_temp.vr_eq('3 新增','欄位：希望日期照填','{' || (v_t + 1)::text || ',' || (v_t + 3)::text || '}', pg_temp.vr_f('r_n1','desired_dates'));
  perform pg_temp.vr_eq('3 新增','欄位：未排定、無改善單、無成績單','(null)/(null)/(null)',
    pg_temp.vr_f('r_n1','scheduled_at') || '/' || pg_temp.vr_f('r_n1','improvement_ticket_id') || '/' || pg_temp.vr_f('r_n1','assessment_id'));

  perform pg_temp.vr_okid('3 新增','客服部代 9704（到職剛好 90 天）回報「新人」','r_n2','vr-cs1@2motor.tw','新人','MI-9704',
                          pg_temp.vr_darr(2), 'true');
  perform pg_temp.vr_eq('3 新增','客服部代報：requested_role＝客服部','客服部', pg_temp.vr_f('r_n2','requested_role'));

  perform pg_temp.vr_okid('3 新增','客服部替 9708 回報「回考核期」（帶 video＝true 也可，存 null）','r_p1','vr-cs1@2motor.tw','回考核期','MI-9708',
                          pg_temp.vr_darr(1), 'true');
  perform pg_temp.vr_eq('3 新增','回考核期的 video_done 存 null','(null)', pg_temp.vr_f('r_p1','video_done'));

  perform pg_temp.vr_okid('3 新增','店長甲替 9714 回報「複檢」（指定改善單 A）','r_t1','vr-sm1@2motor.tw','複檢','MI-9714',
                          pg_temp.vr_darr(1), 'null', null, v_a);
  perform pg_temp.vr_eq('3 新增','複檢：存改善單 id、video_done 為 null','true/(null)',
    (pg_temp.vr_f('r_t1','improvement_ticket_id') = v_a)::text || '/' || pg_temp.vr_f('r_t1','video_done'));

  perform pg_temp.vr_okid('3 新增','日期可以是今天（9710 回考核期）','r_p2','vr-cs1@2motor.tw','回考核期','MI-9710', pg_temp.vr_darr(0));
  perform pg_temp.vr_okid('3 新增','未填到職日但在考核期者可回報「回考核期」（9713）','r_p3','vr-cs1@2motor.tw','回考核期','MI-9713',
                          pg_temp.vr_darr(1,2,3));

  perform pg_temp.vr_okid('3 新增','備註剛好 500 字可以（9730）','r_n500','vr-sm1@2motor.tw','新人','MI-9730',
                          pg_temp.vr_darr(1), 'true', repeat('字', 500));
  perform pg_temp.vr_eq('3 新增','備註 500 字完整保存','500', pg_temp.vr_f('r_n500','char_length(note)'));
  perform pg_temp.vr_okid('3 新增','備註全是空白 → 存 null（9731）','r_nb','vr-sm1@2motor.tw','新人','MI-9731',
                          pg_temp.vr_darr(1), 'true', E'  \n　 ');
  perform pg_temp.vr_eq('3 新增','空白備註存 null','(null)', pg_temp.vr_f('r_nb','note'));

  -- 資格：被拒
  perform pg_temp.vr_crerr('3 新增','店長甲替別間門市的 9709 回報被拒（通用訊息）','%找不到這位人員或沒有權限%','vr-sm1@2motor.tw','新人','MI-9709','array[current_date+1]');
  perform pg_temp.vr_eq('3 新增','店長：別間門市與不存在的人員，錯誤訊息完全相同（不洩漏）','true',
    (pg_temp.vr_cr('vr-sm1@2motor.tw','新人','MI-9709') = pg_temp.vr_cr('vr-sm1@2motor.tw','新人','MI-0000'))::text);
  perform pg_temp.vr_crerr('3 新增','客服部對不存在的人員被拒','%找不到這位人員%','vr-cs1@2motor.tw','新人','MI-0000');
  perform pg_temp.vr_crerr('3 新增','離職者（9707）被拒','%已離職%','vr-cs1@2motor.tw','新人','MI-9707');
  perform pg_temp.vr_crerr('3 新增','離職且考核期（9711）回考核期被拒','%已離職%','vr-cs1@2motor.tw','回考核期','MI-9711');
  perform pg_temp.vr_crerr('3 新增','不納入考核（9706）新人被拒','%未納入考核%','vr-cs1@2motor.tw','新人','MI-9706');
  perform pg_temp.vr_crerr('3 新增','不納入考核（9712）回考核期被拒','%未納入考核%','vr-cs1@2motor.tw','回考核期','MI-9712');
  perform pg_temp.vr_crerr('3 新增','正式（9701）不能報「新人」','%不是新人%','vr-cs1@2motor.tw','新人','MI-9701', null, 'true');
  perform pg_temp.vr_crerr('3 新增','未填到職日者（9702）視為正式，不能報「新人」','%不是新人%','vr-cs1@2motor.tw','新人','MI-9702', null, 'true');
  perform pg_temp.vr_crerr('3 新增','到職 91 天（9705）不能報「新人」','%不是新人%','vr-cs1@2motor.tw','新人','MI-9705', null, 'true');
  perform pg_temp.vr_crerr('3 新增','已上線的新人標籤者（9778，到職 10 天）不能報「新人」（新規則）','%不是新人%','vr-cs1@2motor.tw','新人','MI-9778', null, 'true');
  perform pg_temp.vr_crerr('3 新增','考核期者（9708）只能報回考核期，不能報「新人」','%只能以「回考核期」回報%','vr-cs1@2motor.tw','新人','MI-9708', null, 'true');
  perform pg_temp.vr_crerr('3 新增','新人且考核期（9710）也只能報回考核期','%只能以「回考核期」回報%','vr-cs1@2motor.tw','新人','MI-9710', null, 'true');
  perform pg_temp.vr_crerr('3 新增','不在考核期者（9703）不能報「回考核期」','%不在考核期%','vr-cs1@2motor.tw','回考核期','MI-9703');
  perform pg_temp.vr_crerr('3 新增','正式（9701）不能報「回考核期」','%不在考核期%','vr-cs1@2motor.tw','回考核期','MI-9701');
  perform pg_temp.vr_crerr('3 新增','複檢沒指定改善單被拒','%複檢必須指定改善單%','vr-cs1@2motor.tw','複檢','MI-9714');
  perform pg_temp.vr_crerr('3 新增','複檢指定別人的改善單被拒（9701＋改善單 A）','%找不到這位人員的這張改善單%','vr-cs1@2motor.tw','複檢','MI-9701', null, 'null', null, v_a);
  perform pg_temp.vr_crerr('3 新增','複檢指定不存在的改善單被拒','%找不到這位人員的這張改善單%','vr-cs1@2motor.tw','複檢','MI-9714', null, 'null', null, '00000000-0000-0000-0000-000000000000');
  perform pg_temp.vr_crerr('3 新增','複檢：改善單是「待改善」不能報','%還不能回報複檢%','vr-cs1@2motor.tw','複檢','MI-9715', null, 'null', null, pg_temp.vr_get('tkOpen'));
  perform pg_temp.vr_crerr('3 新增','複檢：改善單是「已結案」不能報','%還不能回報複檢%','vr-cs1@2motor.tw','複檢','MI-9715', null, 'null', null, pg_temp.vr_get('tkClosed'));
  perform pg_temp.vr_crerr('3 新增','複檢：改善單是「已取消」不能報','%還不能回報複檢%','vr-cs1@2motor.tw','複檢','MI-9715', null, 'null', null, pg_temp.vr_get('tkCancel'));
  perform pg_temp.vr_crerr('3 新增','店長甲不能替別間門市的複檢（9716）回報','%找不到這位人員或沒有權限%','vr-sm1@2motor.tw','複檢','MI-9716', null, 'null', null, pg_temp.vr_get('tkX2'));
  perform pg_temp.vr_crerr('3 新增','情況亂填被拒','%情況必須是%','vr-cs1@2motor.tw','亂填','MI-9703');

  -- 日期驗證
  perform pg_temp.vr_crerr('3 新增','日期 0 個被拒','%1 到 3 個%','vr-cs1@2motor.tw','新人','MI-9732', $q$'{}'::date[]$q$, 'true');
  perform pg_temp.vr_crerr('3 新增','日期 4 個被拒','%1 到 3 個%','vr-cs1@2motor.tw','新人','MI-9732', pg_temp.vr_darr(1,2,3,4), 'true');
  perform pg_temp.vr_crerr('3 新增','日期為 null 被拒','%1 到 3 個%','vr-cs1@2motor.tw','新人','MI-9732', 'null::date[]', 'true');
  perform pg_temp.vr_crerr('3 新增','日期重複被拒','%不可重複%','vr-cs1@2motor.tw','新人','MI-9732', pg_temp.vr_darr(1,1), 'true');
  perform pg_temp.vr_crerr('3 新增','日期含過去（昨天）被拒','%不可早於今天%','vr-cs1@2motor.tw','新人','MI-9732', pg_temp.vr_darr(-1), 'true');
  perform pg_temp.vr_crerr('3 新增','日期三個裡只要一個是過去就被拒','%不可早於今天%','vr-cs1@2motor.tw','新人','MI-9732', pg_temp.vr_darr(1,-3,2), 'true');
  perform pg_temp.vr_crerr('3 新增','日期含空值被拒','%不可空白%','vr-cs1@2motor.tw','新人','MI-9732', $q$array['2099-01-01', null]::date[]$q$, 'true');
  perform pg_temp.vr_okid('3 新增','三個日期可以（9732）','r_d3','vr-cs1@2motor.tw','新人','MI-9732', pg_temp.vr_darr(1,2,3), 'true');
  perform pg_temp.vr_eq('3 新增','三個日期都存進去','3', pg_temp.vr_f('r_d3','cardinality(desired_dates)'));

  -- 影片
  perform pg_temp.vr_crerr('3 新增','新人沒勾影片（false）被拒','%新人必須勾選%','vr-cs1@2motor.tw','新人','MI-9733', null, 'false');
  perform pg_temp.vr_crerr('3 新增','新人沒帶影片欄位（null）被拒','%新人必須勾選%','vr-cs1@2motor.tw','新人','MI-9733', null, 'null');
  perform pg_temp.vr_eq('3 新增','影片被拒後沒有留下回報','0',
    pg_temp.vr_q1($q$select count(*)::text from public.exam_requests where employee_id = 'MI-9733'$q$));

  -- 備註
  perform pg_temp.vr_crerr('3 新增','備註 501 字被拒','%備註最多 500 字%','vr-cs1@2motor.tw','新人','MI-9733', null, 'true', repeat('字', 501));
  perform pg_temp.vr_crerr('3 新增','備註 501 字（頭尾加空白不算數）被拒','%備註最多 500 字%','vr-cs1@2motor.tw','新人','MI-9733', null, 'true', '  ' || repeat('字', 501) || '  ');
  perform pg_temp.vr_okid('3 新增','備註 500 字前後加空白可以（去空白後 500）（9733）','r_n501','vr-cs1@2motor.tw','新人','MI-9733', null, 'true', '  ' || repeat('字', 500) || '  ');
exception when others then
  perform pg_temp.vr_rec('區段 3','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：防重複
-- ============================================================
do $$
declare
  v_a text := pg_temp.vr_get('tkA');
  v_b text := pg_temp.vr_get('tkB');
begin
  perform pg_temp.vr_crerr('4 防重複','同一人同一情況（新人 9703）已有待處理，店長不能再報','%已有一筆「新人」回報在處理中%','vr-sm1@2motor.tw','新人','MI-9703', null, 'true');
  perform pg_temp.vr_crerr('4 防重複','客服部也不能再報（9703）','%已有一筆「新人」回報在處理中%','vr-cs1@2motor.tw','新人','MI-9703', null, 'true');
  perform pg_temp.vr_crerr('4 防重複','回考核期 9708 已有待處理，不能再報','%已有一筆「回考核期」回報在處理中%','vr-cs1@2motor.tw','回考核期','MI-9708');
  perform pg_temp.vr_crerr('4 防重複','複檢以改善單為單位：改善單 A 已有回報，不能再報','%這張改善單已有複檢回報在處理中%','vr-sm1@2motor.tw','複檢','MI-9714', null, 'null', null, v_a);
  perform pg_temp.vr_okid('4 防重複','同一人的另一張改善單 B 可以另外報複檢','r_t2','vr-sm1@2motor.tw','複檢','MI-9714', null, 'null', null, v_b);

  perform pg_temp.vr_eq('4 防重複','複檢兩張都報之後，名單裡 9714 不再出現（只剩 9716）','MI-9716', pg_temp.vr_cand('vr-cs1@2motor.tw', '複檢'));
  perform pg_temp.vr_eq('4 防重複','已報的 9703 不再出現在新人名單','MI-9709', pg_temp.vr_cand('vr-cs1@2motor.tw', '新人'));
  perform pg_temp.vr_eq('4 防重複','已報的 9708、9710、9713 不再出現在回考核期名單','(空)', pg_temp.vr_cand('vr-cs1@2motor.tw', '回考核期'));

  -- 資料庫索引是最後防線：直接以擁有者身分寫入重複資料
  perform pg_temp.vr_ownerr('4 防重複','索引：同一人同一情況（新人）未結案重複寫入被拒',
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
       values ('新人', 'MI-9703', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長', array[current_date], true)$q$,
    '%exam_requests_open_emp_kind_uq%');
  perform pg_temp.vr_ownerr('4 防重複','索引：同一張改善單未結案重複寫入被拒',
    format($q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, improvement_ticket_id)
              values ('複檢', 'MI-9714', 'x', 'ZZ-X1', 'vr-zz@2motor.tw', '店長', array[current_date], %L::uuid)$q$, v_a),
    '%exam_requests_open_ticket_uq%');
exception when others then
  perform pg_temp.vr_rec('區段 4','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：撤回
-- ============================================================
do $$
begin
  perform pg_temp.vr_rewind();
  perform pg_temp.vr_okid('5 撤回','（備料）店長甲替 9734 回報','w1','vr-sm1@2motor.tw','新人','MI-9734', null, 'true');
  perform pg_temp.vr_eq('5 撤回','店長甲撤回自己門市待處理的回報','OK', case when pg_temp.vr_wd('vr-sm1@2motor.tw','w1') like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('5 撤回','撤回後：已取消／cancel_by 店長／原因「回報人撤回」','已取消/店長/回報人撤回',
    pg_temp.vr_f('w1','status') || '/' || pg_temp.vr_f('w1','cancel_by') || '/' || pg_temp.vr_f('w1','cancel_reason'));
  perform pg_temp.vr_eq('5 撤回','撤回不排信（沒有 scheduled／returned 信件）','0/0', pg_temp.vr_mc('w1','scheduled') || '/' || pg_temp.vr_mc('w1','returned'));
  perform pg_temp.vr_okid('5 撤回','撤回後同一人可以重新回報（9734）','w1b','vr-sm1@2motor.tw','新人','MI-9734', null, 'true');

  perform pg_temp.vr_okid('5 撤回','（備料）客服部替 9735 代報','w2','vr-cs1@2motor.tw','新人','MI-9735', null, 'true');
  perform pg_temp.vr_eq('5 撤回','店長甲可以撤回客服部代報、自己門市、待處理的回報','OK', case when pg_temp.vr_wd('vr-sm1@2motor.tw','w2') like 'ERROR%' then 'x' else 'OK' end);

  perform pg_temp.vr_okid('5 撤回','（備料）店長甲替 9736 回報','w3','vr-sm1@2motor.tw','新人','MI-9736', null, 'true');
  perform pg_temp.vr_deny('5 撤回','店長乙撤回別間門市的回報被拒（通用訊息）','authenticated','vr-sm2@2motor.tw',
    format($q$select public.exam_req_withdraw(%L::uuid)$q$, pg_temp.vr_get('w3')), '%找不到這筆回報或沒有權限%');
  perform pg_temp.vr_eq('5 撤回','店長乙對不存在的回報也是同一句','true',
    (pg_temp.vr_as('authenticated','vr-sm2@2motor.tw', $q$select public.exam_req_withdraw('00000000-0000-0000-0000-000000000000'::uuid)$q$, false)
     = pg_temp.vr_as('authenticated','vr-sm2@2motor.tw', format($q$select public.exam_req_withdraw(%L::uuid)$q$, pg_temp.vr_get('w3')), false))::text);
  perform pg_temp.vr_eq('5 撤回','客服部對不存在的回報：找不到回報','true',
    (pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.exam_req_withdraw('00000000-0000-0000-0000-000000000000'::uuid)$q$, false)
     like 'ERROR: 找不到回報')::text);
  perform pg_temp.vr_eq('5 撤回','別人撤回失敗後，原回報仍是待處理','待處理', pg_temp.vr_f('w3','status'));

  -- 已排定：店長不可、客服部可
  perform pg_temp.vr_eq('5 撤回','（備料）客服部排定 w3','OK', case when pg_temp.vr_sched('vr-cs1@2motor.tw','w3', $q$now() + interval '1 day'$q$) like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('5 撤回','店長甲不能撤回已排定的回報','true',
    (pg_temp.vr_wd('vr-sm1@2motor.tw','w3') like 'ERROR: 只有「待處理」的回報可以撤回（目前：已排定）')::text);
  perform pg_temp.vr_eq('5 撤回','客服部可以撤回已排定的回報','OK', case when pg_temp.vr_wd('vr-cs1@2motor.tw','w3') like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('5 撤回','客服部撤回別人（店長）的回報：已取消／客服部／原因「客服部撤回」／mgr_seen＝false','已取消/客服部/客服部撤回/false',
    pg_temp.vr_f('w3','status') || '/' || pg_temp.vr_f('w3','cancel_by') || '/' || pg_temp.vr_f('w3','cancel_reason') || '/' || pg_temp.vr_f('w3','mgr_seen'));
  perform pg_temp.vr_eq('5 撤回','店長自己撤回（w1）不設 mgr_seen＝false（維持 true）、原因「回報人撤回」','true/回報人撤回',
    pg_temp.vr_f('w1','mgr_seen') || '/' || pg_temp.vr_f('w1','cancel_reason'));
  perform pg_temp.vr_eq('5 撤回','店長撤回客服部代報的回報（w2）：原因「回報人撤回」、mgr_seen 維持 true','true/回報人撤回/店長',
    pg_temp.vr_f('w2','mgr_seen') || '/' || pg_temp.vr_f('w2','cancel_reason') || '/' || pg_temp.vr_f('w2','cancel_by'));
  perform pg_temp.vr_okid('5 撤回','（備料）客服部替 9771 代報後自己撤回','w5','vr-cs1@2motor.tw','新人','MI-9771', null, 'true');
  perform pg_temp.vr_eq('5 撤回','客服部撤回自己建立的回報：原因仍是「回報人撤回」、mgr_seen 維持 true','OK/已取消/客服部/回報人撤回/true',
    case when pg_temp.vr_wd('vr-cs1@2motor.tw','w5') like 'ERROR%' then 'x' else 'OK' end || '/' ||
    pg_temp.vr_f('w5','status') || '/' || pg_temp.vr_f('w5','cancel_by') || '/' || pg_temp.vr_f('w5','cancel_reason') || '/' || pg_temp.vr_f('w5','mgr_seen'));

  -- 已取消、已完成：都不能再撤回
  perform pg_temp.vr_eq('5 撤回','已取消的回報客服部不能再撤回','true',
    (pg_temp.vr_wd('vr-cs1@2motor.tw','w3') like 'ERROR: 只有「待處理」或「已排定」的回報可以撤回（目前：已取消）')::text);
  perform pg_temp.vr_eq('5 撤回','已取消的回報店長不能撤回','true',
    (pg_temp.vr_wd('vr-sm1@2motor.tw','w3') like 'ERROR: 只有「待處理」的回報可以撤回（目前：已取消）')::text);
  perform pg_temp.vr_okid('5 撤回','（備料）9737 回報後直接改成已完成','w4','vr-cs1@2motor.tw','新人','MI-9737', null, 'true');
  perform pg_temp.vr_own(format($q$update public.exam_requests set status = '已完成' where id = %L::uuid$q$, pg_temp.vr_get('w4')));
  perform pg_temp.vr_eq('5 撤回','已完成的回報客服部不能撤回','true',
    (pg_temp.vr_wd('vr-cs1@2motor.tw','w4') like 'ERROR: 只有「待處理」或「已排定」的回報可以撤回（目前：已完成）')::text);
  perform pg_temp.vr_eq('5 撤回','已完成後同一人可再回報（9737）','true',
    (pg_temp.vr_cr('vr-cs1@2motor.tw','新人','MI-9737', null, 'true') ~ '^[0-9a-f-]{36}$')::text);
exception when others then
  perform pg_temp.vr_rec('區段 5','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：排定
-- ============================================================
do $$
declare
  v_r text;
begin
  perform pg_temp.vr_okid('6 排定','（備料）店長甲替 9738 回報','s1','vr-sm1@2motor.tw','新人','MI-9738', null, 'true');

  perform pg_temp.vr_eq('6 排定','客服部排定待處理的回報','OK',
    case when pg_temp.vr_sched('vr-cs1@2motor.tw','s1', $q$'2099-06-01 10:30+08'::timestamptz$q$, '請帶筆電') like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('6 排定','排定後：已排定／排定時間／備註／處理人','已排定/2099-06-01 10:30/請帶筆電/vr-cs1@2motor.tw',
    pg_temp.vr_f('s1','status') || '/' ||
    pg_temp.vr_q1(format($q$select to_char(scheduled_at at time zone 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') from public.exam_requests where id = %L::uuid$q$, pg_temp.vr_get('s1'))) || '/' ||
    pg_temp.vr_f('s1','reply_note') || '/' || pg_temp.vr_f('s1','handled_by'));
  perform pg_temp.vr_eq('6 排定','排定後 mgr_seen＝false','false', pg_temp.vr_f('s1','mgr_seen'));

  -- 店長看過之後再重新排定 → mgr_seen 又變 false、處理人換人
  perform pg_temp.vr_own(format($q$update public.exam_requests set mgr_seen = true where id = %L::uuid$q$, pg_temp.vr_get('s1')));
  perform pg_temp.vr_eq('6 排定','可重新排定（已排定 → 已排定），改由另一位客服部處理','OK',
    case when pg_temp.vr_sched('vr-cs2@2motor.tw','s1', $q$'2099-06-02 14:00+08'::timestamptz$q$, null) like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('6 排定','重新排定後：仍已排定、新時間、備註清空、處理人換、mgr_seen 又變 false','已排定/2099-06-02 14:00/(null)/vr-cs2@2motor.tw/false',
    pg_temp.vr_f('s1','status') || '/' ||
    pg_temp.vr_q1(format($q$select to_char(scheduled_at at time zone 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') from public.exam_requests where id = %L::uuid$q$, pg_temp.vr_get('s1'))) || '/' ||
    pg_temp.vr_f('s1','reply_note') || '/' || pg_temp.vr_f('s1','handled_by') || '/' || pg_temp.vr_f('s1','mgr_seen'));
  perform pg_temp.vr_eq('6 排定','每次排定各排一封信（排定信共 2 封）','2', pg_temp.vr_mc('s1','scheduled'));

  -- 時間邊界
  perform pg_temp.vr_okid('6 排定','（備料）客服部替 9739 回報','s2','vr-cs1@2motor.tw','新人','MI-9739', null, 'true');
  perform pg_temp.vr_eq('6 排定','排定時間早於現在 2 小時被拒','true',
    (pg_temp.vr_sched('vr-cs1@2motor.tw','s2', $q$now() - interval '2 hours'$q$) like 'ERROR: 考核時間不可早於現在往前 1 小時')::text);
  perform pg_temp.vr_eq('6 排定','排定時間早於現在 61 分鐘被拒','true',
    (pg_temp.vr_sched('vr-cs1@2motor.tw','s2', $q$now() - interval '61 minutes'$q$) like 'ERROR: 考核時間不可早於現在往前 1 小時')::text);
  perform pg_temp.vr_eq('6 排定','排定時間剛好現在往前 1 小時可以（邊界）','OK',
    case when pg_temp.vr_sched('vr-cs1@2motor.tw','s2', $q$now() - interval '1 hour'$q$) like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('6 排定','排定時間空值被拒','true',
    (pg_temp.vr_sched('vr-cs1@2motor.tw','s2', 'null::timestamptz') like 'ERROR: 請填寫考核日期時間')::text);
  perform pg_temp.vr_eq('6 排定','過去時間被拒後，原排定不變（仍是邊界那一筆、已排定）','已排定', pg_temp.vr_f('s2','status'));

  perform pg_temp.vr_eq('6 排定','備註全空白 → 存 null','OK/(null)',
    case when pg_temp.vr_sched('vr-cs1@2motor.tw','s2', $q$now() + interval '2 days'$q$, E'  \n ') like 'ERROR%' then 'x' else 'OK' end
    || '/' || pg_temp.vr_f('s2','reply_note'));

  -- 狀態限制
  perform pg_temp.vr_own(format($q$update public.exam_requests set status = '已完成' where id = %L::uuid$q$, pg_temp.vr_get('s2')));
  perform pg_temp.vr_eq('6 排定','已完成的不能再排定','true',
    (pg_temp.vr_sched('vr-cs1@2motor.tw','s2', $q$now() + interval '1 day'$q$) like 'ERROR: 只有「待處理」或「已排定」的回報可以排定（目前：已完成）')::text);
  perform pg_temp.vr_eq('6 排定','已取消的不能排定（9734 的舊回報 w1）','true',
    (pg_temp.vr_sched('vr-cs1@2motor.tw','w1', $q$now() + interval '1 day'$q$) like 'ERROR: 只有「待處理」或「已排定」的回報可以排定（目前：已取消）')::text);
  perform pg_temp.vr_eq('6 排定','排定不存在的回報：找不到回報','true',
    (pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.exam_req_schedule('00000000-0000-0000-0000-000000000000'::uuid, now(), null)$q$, false)
     like 'ERROR: 找不到回報')::text);
exception when others then
  perform pg_temp.vr_rec('區段 6','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：退回
-- ============================================================
do $$
begin
  perform pg_temp.vr_okid('7 退回','（備料）店長甲替 9740 回報','x1','vr-sm1@2motor.tw','新人','MI-9740', null, 'true');
  perform pg_temp.vr_eq('7 退回','退回原因為空被拒','true',
    (pg_temp.vr_ret('vr-cs1@2motor.tw','x1','') like 'ERROR: 退回原因不可空白')::text);
  perform pg_temp.vr_eq('7 退回','退回原因全空白被拒','true',
    (pg_temp.vr_ret('vr-cs1@2motor.tw','x1', E' \n　') like 'ERROR: 退回原因不可空白')::text);
  perform pg_temp.vr_eq('7 退回','退回原因 null 被拒','true',
    (pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', format($q$select public.exam_req_return(%L::uuid, null)$q$, pg_temp.vr_get('x1')), false)
     like 'ERROR: 退回原因不可空白')::text);
  perform pg_temp.vr_eq('7 退回','被拒後回報仍是待處理','待處理', pg_temp.vr_f('x1','status'));

  perform pg_temp.vr_eq('7 退回','客服部退回待處理的回報','OK', case when pg_temp.vr_ret('vr-cs1@2motor.tw','x1','影片請重看') like 'ERROR%' then 'x' else 'OK' end);
  perform pg_temp.vr_eq('7 退回','退回後：已取消／cancel_by 客服部／原因／處理人／mgr_seen＝false','已取消/客服部/影片請重看/vr-cs1@2motor.tw/false',
    pg_temp.vr_f('x1','status') || '/' || pg_temp.vr_f('x1','cancel_by') || '/' || pg_temp.vr_f('x1','cancel_reason') || '/' ||
    pg_temp.vr_f('x1','handled_by') || '/' || pg_temp.vr_f('x1','mgr_seen'));
  perform pg_temp.vr_eq('7 退回','退回後同一人可重新回報（9740）','true',
    (pg_temp.vr_cr('vr-sm1@2motor.tw','新人','MI-9740', null, 'true') ~ '^[0-9a-f-]{36}$')::text);

  -- 已排定也能退回
  perform pg_temp.vr_okid('7 退回','（備料）客服部替 9741 回報並排定','x2','vr-cs1@2motor.tw','新人','MI-9741', null, 'true');
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','x2', $q$now() + interval '1 day'$q$);
  perform pg_temp.vr_eq('7 退回','客服部退回已排定的回報','OK/已取消', case when pg_temp.vr_ret('vr-cs1@2motor.tw','x2','改期') like 'ERROR%' then 'x' else 'OK' end || '/' || pg_temp.vr_f('x2','status'));

  -- 已取消、已完成不能退回
  perform pg_temp.vr_eq('7 退回','已取消的不能再退回','true',
    (pg_temp.vr_ret('vr-cs1@2motor.tw','x2','再退') like 'ERROR: 只有「待處理」或「已排定」的回報可以退回（目前：已取消）')::text);
  perform pg_temp.vr_okid('7 退回','（備料）9742 回報後改成已完成','x3','vr-cs1@2motor.tw','新人','MI-9742', null, 'true');
  perform pg_temp.vr_own(format($q$update public.exam_requests set status = '已完成' where id = %L::uuid$q$, pg_temp.vr_get('x3')));
  perform pg_temp.vr_eq('7 退回','已完成的不能退回','true',
    (pg_temp.vr_ret('vr-cs1@2motor.tw','x3','再退') like 'ERROR: 只有「待處理」或「已排定」的回報可以退回（目前：已完成）')::text);
  perform pg_temp.vr_eq('7 退回','退回不存在的回報：找不到回報','true',
    (pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.exam_req_return('00000000-0000-0000-0000-000000000000'::uuid, '原因')$q$, false)
     like 'ERROR: 找不到回報')::text);
exception when others then
  perform pg_temp.vr_rec('區段 7','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 8：mark_seen 與紅點數字
-- ============================================================
do $$
declare
  v_b1 int;
  v_c1 int;
begin
  perform pg_temp.vr_rewind();
  -- 先把甲店現有未看的清乾淨，建立乾淨基準
  perform pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_mark_seen()$q$, false);
  perform pg_temp.vr_as('authenticated','vr-sm2@2motor.tw', $q$select public.exam_req_mark_seen()$q$, false);
  perform pg_temp.vr_eq('8 紅點','店長甲標記已看後，自己門市沒有 mgr_seen＝false 的回報','0',
    pg_temp.vr_q1($q$select count(*)::text from public.exam_requests where store_code = 'ZZ-X1' and mgr_seen = false$q$));
  perform pg_temp.vr_eq('8 紅點','店長甲 badge ＝ 0','0', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));

  -- 乙店有一筆客服部排定、尚未看
  perform pg_temp.vr_okid('8 紅點','（備料）店長乙替 9709 回報','b1','vr-sm2@2motor.tw','新人','MI-9709', null, 'true');
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','b1', $q$now() + interval '1 day'$q$);
  -- 甲店有兩筆客服部回覆未看：一筆排定、一筆退回
  perform pg_temp.vr_okid('8 紅點','（備料）店長甲替 9743 回報','b2','vr-sm1@2motor.tw','新人','MI-9743', null, 'true');
  perform pg_temp.vr_okid('8 紅點','（備料）店長甲替 9744 回報','b3','vr-sm1@2motor.tw','新人','MI-9744', null, 'true');
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','b2', $q$now() + interval '1 day'$q$);
  perform pg_temp.vr_ret('vr-cs1@2motor.tw','b3','測試退回');

  perform pg_temp.vr_eq('8 紅點','店長甲 badge ＝ 2（排定＋退回，未看過）','2', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('8 紅點','店長乙 badge ＝ 1（只算自己門市）','1', pg_temp.vr_as('authenticated','vr-sm2@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_cmp('8 紅點','店長甲 badge 與資料表實際筆數一致','authenticated','vr-sm1@2motor.tw',
    $q$select public.exam_req_badge()::text$q$, $q$select count(*)::text from public.exam_requests where store_code = 'ZZ-X1' and mgr_seen = false$q$);
  perform pg_temp.vr_eq('8 紅點','總公司主管 badge ＝ 0','0', pg_temp.vr_as('authenticated','vr-hq@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_cmp('8 紅點','客服部 badge ＝ 全部待處理數','authenticated','vr-cs1@2motor.tw',
    $q$select public.exam_req_badge()::text$q$, $q$select count(*)::text from public.exam_requests where status = '待處理'$q$);

  -- 客服部 badge 隨新回報加一、隨排定減一
  v_c1 := pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true);
  perform pg_temp.vr_okid('8 紅點','（備料）店長甲替 9745 回報','b4','vr-sm1@2motor.tw','新人','MI-9745', null, 'true');
  perform pg_temp.vr_eq('8 紅點','新回報後客服部 badge ＋1', (v_c1 + 1)::text, pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('8 紅點','新回報（待處理）不會讓店長 badge 增加（仍是 2）','2', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','b4', $q$now() + interval '1 day'$q$);
  perform pg_temp.vr_eq('8 紅點','排定後客服部 badge 回到原數', v_c1::text, pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('8 紅點','排定後店長甲 badge ＝ 3','3', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));

  -- mark_seen：只動自己門市
  perform pg_temp.vr_ok('8 紅點','店長甲 mark_seen 成功','vr-sm1@2motor.tw', $q$select public.exam_req_mark_seen()$q$);
  perform pg_temp.vr_eq('8 紅點','mark_seen 後店長甲 badge ＝ 0','0', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('8 紅點','mark_seen 不影響別間門市：店長乙仍是 1','1', pg_temp.vr_as('authenticated','vr-sm2@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('8 紅點','乙店那筆 mgr_seen 仍是 false','false', pg_temp.vr_f('b1','mgr_seen'));
  perform pg_temp.vr_eq('8 紅點','甲店三筆 mgr_seen 都變 true','true/true/true',
    pg_temp.vr_f('b2','mgr_seen') || '/' || pg_temp.vr_f('b3','mgr_seen') || '/' || pg_temp.vr_f('b4','mgr_seen'));
  perform pg_temp.vr_ok('8 紅點','店長乙 mark_seen 成功','vr-sm2@2motor.tw', $q$select public.exam_req_mark_seen()$q$);
  perform pg_temp.vr_eq('8 紅點','店長乙 mark_seen 後 badge ＝ 0，乙店那筆變 true','0/true',
    pg_temp.vr_as('authenticated','vr-sm2@2motor.tw', $q$select public.exam_req_badge()::text$q$, true) || '/' || pg_temp.vr_f('b1','mgr_seen'));
exception when others then
  perform pg_temp.vr_rec('區段 8','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 9：可見範圍（RLS）與角色權限矩陣
-- ============================================================
do $$
declare
  v_any text := '00000000-0000-0000-0000-000000000000';
begin
  -- exam_requests 看得到誰
  perform pg_temp.vr_cmp('9 權限','客服部看得到全部回報','authenticated','vr-cs1@2motor.tw',
    $q$select count(*)::text from public.exam_requests$q$, $q$select count(*)::text from public.exam_requests$q$);
  perform pg_temp.vr_cmp('9 權限','總公司主管看得到全部回報','authenticated','vr-hq@2motor.tw',
    $q$select count(*)::text from public.exam_requests$q$, $q$select count(*)::text from public.exam_requests$q$);
  perform pg_temp.vr_cmp('9 權限','店長甲只看到甲店的回報','authenticated','vr-sm1@2motor.tw',
    $q$select count(*)::text from public.exam_requests$q$, $q$select count(*)::text from public.exam_requests where store_code = 'ZZ-X1'$q$);
  perform pg_temp.vr_cmp('9 權限','店長乙只看到乙店的回報','authenticated','vr-sm2@2motor.tw',
    $q$select count(*)::text from public.exam_requests$q$, $q$select count(*)::text from public.exam_requests where store_code = 'ZZ-X2'$q$);
  perform pg_temp.vr_eq('9 權限','店長甲看不到乙店的任何一筆','0',
    pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select count(*)::text from public.exam_requests where store_code = 'ZZ-X2'$q$, true));
  perform pg_temp.vr_eq('9 權限','未開通帳號看到 0 筆回報','0',
    pg_temp.vr_as('authenticated','vr-nobody@2motor.tw', $q$select count(*)::text from public.exam_requests$q$, true));
  perform pg_temp.vr_deny('9 權限','未登入（anon）讀回報被拒','anon', null, $q$select count(*) from public.exam_requests$q$, '%permission denied%');

  -- mail_outbox 只有客服部
  perform pg_temp.vr_cmp('9 權限','客服部看得到全部寄信紀錄','authenticated','vr-cs1@2motor.tw',
    $q$select count(*)::text from public.mail_outbox$q$, $q$select count(*)::text from public.mail_outbox$q$);
  perform pg_temp.vr_eq('9 權限','總公司主管看不到寄信紀錄（0 筆）','0', pg_temp.vr_as('authenticated','vr-hq@2motor.tw', $q$select count(*)::text from public.mail_outbox$q$, true));
  perform pg_temp.vr_eq('9 權限','店長看不到寄信紀錄（0 筆）','0', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select count(*)::text from public.mail_outbox$q$, true));
  perform pg_temp.vr_eq('9 權限','未開通帳號看不到寄信紀錄（0 筆）','0', pg_temp.vr_as('authenticated','vr-nobody@2motor.tw', $q$select count(*)::text from public.mail_outbox$q$, true));
  perform pg_temp.vr_deny('9 權限','未登入（anon）讀寄信紀錄被拒','anon', null, $q$select count(*) from public.mail_outbox$q$, '%permission denied%');

  -- app_settings：任何角色都讀不到（含客服部）
  perform pg_temp.vr_deny('9 權限','客服部直接 select app_settings 被拒','authenticated','vr-cs1@2motor.tw', $q$select * from public.app_settings$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','總公司主管 select app_settings 被拒','authenticated','vr-hq@2motor.tw', $q$select * from public.app_settings$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','店長 select app_settings 被拒','authenticated','vr-sm1@2motor.tw', $q$select * from public.app_settings$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','未開通帳號 select app_settings 被拒','authenticated','vr-nobody@2motor.tw', $q$select * from public.app_settings$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','未登入（anon）select app_settings 被拒','anon', null, $q$select * from public.app_settings$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接寫 app_settings（insert）','authenticated','vr-cs1@2motor.tw',
    $q$insert into public.app_settings (key, value) values ('mail_relay_token', 'x')$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接改 app_settings（update）','authenticated','vr-cs1@2motor.tw',
    $q$update public.app_settings set value = 'x'$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接刪 app_settings（delete）','authenticated','vr-cs1@2motor.tw',
    $q$delete from public.app_settings$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接呼叫讀設定的內部函式','authenticated','vr-cs1@2motor.tw',
    $q$select public.exam_req_setting('mail_relay_token')$q$, '%permission denied%');

  -- 直接寫入一律被拒（客服部、店長、主管）
  perform pg_temp.vr_deny('9 權限','客服部不能直接 insert exam_requests','authenticated','vr-cs1@2motor.tw',
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
       values ('新人', 'MI-9703', 'x', 'ZZ-X1', 'vr-cs1@2motor.tw', '客服部', array[current_date], true)$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接 update exam_requests','authenticated','vr-cs1@2motor.tw',
    $q$update public.exam_requests set status = '已完成'$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接 delete exam_requests','authenticated','vr-cs1@2motor.tw',
    $q$delete from public.exam_requests$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','店長不能直接 update exam_requests（偷改狀態）','authenticated','vr-sm1@2motor.tw',
    $q$update public.exam_requests set status = '已完成'$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','店長不能直接 delete exam_requests','authenticated','vr-sm1@2motor.tw',
    $q$delete from public.exam_requests$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','店長不能直接 insert exam_requests','authenticated','vr-sm1@2motor.tw',
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
       values ('新人', 'MI-9703', 'x', 'ZZ-X1', 'vr-sm1@2motor.tw', '店長', array[current_date], true)$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','主管不能直接 update exam_requests','authenticated','vr-hq@2motor.tw',
    $q$update public.exam_requests set status = '已完成'$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','主管不能直接 insert exam_requests','authenticated','vr-hq@2motor.tw',
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
       values ('新人', 'MI-9703', 'x', 'ZZ-X1', 'vr-hq@2motor.tw', '店長', array[current_date], true)$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','未登入（anon）不能 insert exam_requests','anon', null,
    $q$insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, video_done)
       values ('新人', 'MI-9703', 'x', 'ZZ-X1', 'x@2motor.tw', '店長', array[current_date], true)$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接寫 mail_outbox（insert）','authenticated','vr-cs1@2motor.tw',
    $q$insert into public.mail_outbox (to_emails, subject, body_html) values ('{a@2motor.tw}', 's', 'b')$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接改 mail_outbox（update 狀態）','authenticated','vr-cs1@2motor.tw',
    $q$update public.mail_outbox set status = 'sent'$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','客服部不能直接刪 mail_outbox（delete）','authenticated','vr-cs1@2motor.tw',
    $q$delete from public.mail_outbox$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 權限','店長不能直接寫 mail_outbox','authenticated','vr-sm1@2motor.tw',
    $q$insert into public.mail_outbox (to_emails, subject, body_html) values ('{a@2motor.tw}', 's', 'b')$q$, '%permission denied%');

  -- 函式角色矩陣
  perform pg_temp.vr_denyset('9 權限','exam_req_candidates', $q$select * from public.exam_req_candidates('新人')$q$, 'hna');
  perform pg_temp.vr_denyset('9 權限','exam_req_create',
    $q$select public.exam_req_create('回考核期', 'MI-9708', array[current_date+1], null, null, null)$q$, 'hna');
  perform pg_temp.vr_denyset('9 權限','exam_req_withdraw', format($q$select public.exam_req_withdraw(%L::uuid)$q$, v_any), 'hna');
  perform pg_temp.vr_denyset('9 權限','exam_req_schedule', format($q$select public.exam_req_schedule(%L::uuid, now(), null)$q$, v_any), 'shna');
  perform pg_temp.vr_denyset('9 權限','exam_req_return', format($q$select public.exam_req_return(%L::uuid, '原因')$q$, v_any), 'shna');
  perform pg_temp.vr_denyset('9 權限','exam_req_mark_seen', $q$select public.exam_req_mark_seen()$q$, 'chna');
  perform pg_temp.vr_denyset('9 權限','exam_req_badge', $q$select public.exam_req_badge()$q$, 'na');
  perform pg_temp.vr_denyset('9 權限','mail_outbox_sync', $q$select public.mail_outbox_sync()$q$, 'shna');

  -- 被拒的主管／未開通帳號不能偷偷寫入回報（確認沒有留下資料）
  perform pg_temp.vr_eq('9 權限','主管與未開通帳號的 create 都沒有留下回報（9708 只有客服部那一筆）','1',
    pg_temp.vr_q1($q$select count(*)::text from public.exam_requests where employee_id = 'MI-9708'$q$));

  -- 允許的角色都能呼叫
  perform pg_temp.vr_ok('9 權限','客服部可呼叫 candidates','vr-cs1@2motor.tw', $q$select * from public.exam_req_candidates('新人')$q$);
  perform pg_temp.vr_ok('9 權限','店長可呼叫 candidates','vr-sm1@2motor.tw', $q$select * from public.exam_req_candidates('新人')$q$);
  perform pg_temp.vr_ok('9 權限','客服部可呼叫 mail_outbox_sync','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()$q$);
exception when others then
  perform pg_temp.vr_rec('區段 9','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 10：成績單送出 → 回報自動完成（真實考核流程，不改 assess_submit）
-- 9751 新人單筆流程＋作廢  9752 兩筆未結案＋一筆已取消  9753 旁觀者  9754 不及格（既有自動開改善單仍運作）
-- ============================================================
do $$
declare
  v_aid uuid;
  v_aid2 uuid;
  v_aid3 uuid;
  v_r text;
begin
  perform pg_temp.vr_rewind();
  -- 9751：已排定的回報；草稿不觸發
  perform pg_temp.vr_okid('10 自動完成','（備料）店長甲替 9751 回報','a1','vr-sm1@2motor.tw','新人','MI-9751', null, 'true');
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','a1', $q$now() + interval '1 day'$q$);
  perform pg_temp.vr_okid('10 自動完成','（備料）店長甲替 9753（旁觀者）回報','a3','vr-sm1@2motor.tw','新人','MI-9753', null, 'true');
  perform pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_mark_seen()$q$, false);

  v_aid := pg_temp.vr_flow('MI-9751', pg_temp.vr_mk('優'));
  perform pg_temp.vr_eq('10 自動完成','成績單還是草稿：回報維持已排定','已排定', pg_temp.vr_f('a1','status'));
  v_r := pg_temp.vr_submit(v_aid);
  perform pg_temp.vr_eq('10 自動完成','（真實 assess_submit）全優送出成功','100.0/優秀', v_r);
  perform pg_temp.vr_eq('10 自動完成','送出後：該員工的回報變已完成','已完成', pg_temp.vr_f('a1','status'));
  perform pg_temp.vr_eq('10 自動完成','送出後：記下成績單 id','true', (pg_temp.vr_f('a1','assessment_id') = v_aid::text)::text);
  perform pg_temp.vr_eq('10 自動完成','送出後：mgr_seen ＝ false（店長會看到）','false', pg_temp.vr_f('a1','mgr_seen'));
  perform pg_temp.vr_eq('10 自動完成','送出後：店長甲 badge ＝ 1','1', pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select public.exam_req_badge()::text$q$, true));
  perform pg_temp.vr_eq('10 自動完成','別的員工（9753）的回報不受影響','待處理', pg_temp.vr_f('a3','status'));
  perform pg_temp.vr_eq('10 自動完成','全優沒有開改善單（既有觸發器行為不變）','0',
    pg_temp.vr_q1($q$select count(*)::text from public.improvement_tickets where employee_id = 'MI-9751'$q$));
  -- 第一期新規則：全優通過 → 轉已上線；已上線者不可再以「新人」回報（原本是「同一人可再回報」）
  perform pg_temp.vr_eq('10 自動完成','全優通過後轉已上線（period_status）','已上線',
    pg_temp.vr_q1($q$select period_status from public.employees where id = 'MI-9751'$q$));
  perform pg_temp.vr_eq('10 自動完成','完成後不再佔位（沒有未結案回報），但已上線，不可再以「新人」回報（新規則）','0/true',
    pg_temp.vr_q1($q$select count(*) filter (where status in ('待處理','已排定'))::text from public.exam_requests where employee_id = 'MI-9751'$q$)
    || '/' || (pg_temp.vr_cr('vr-sm1@2motor.tw','新人','MI-9751', null, 'true') like '%不是新人%')::text);

  -- 作廢不倒回
  v_r := pg_temp.vr_as('authenticated','vr-cs1@2motor.tw',
           format($q$select public.assess_void(%L::uuid, '測試作廢')::text$q$, v_aid), true);
  perform pg_temp.vr_eq('10 自動完成','（真實 assess_void）作廢成功','成功', case when v_r like 'ERROR%' then v_r else '成功' end);
  perform pg_temp.vr_eq('10 自動完成','作廢成績單後：回報維持已完成、成績單連結不變','已完成/true',
    pg_temp.vr_f('a1','status') || '/' || (pg_temp.vr_f('a1','assessment_id') = v_aid::text)::text);

  -- 9752：兩筆未結案 + 一筆已取消
  perform pg_temp.vr_okid('10 自動完成','（備料）9752 新人回報（之後撤回）','a2c','vr-cs1@2motor.tw','新人','MI-9752', null, 'true');
  perform pg_temp.vr_wd('vr-cs1@2motor.tw','a2c');
  perform pg_temp.vr_okid('10 自動完成','（備料）9752 再報新人','a2n','vr-cs1@2motor.tw','新人','MI-9752', null, 'true');
  perform pg_temp.vr_own($q$update public.employees set probation_since = (now() at time zone 'Asia/Taipei')::date where id = 'MI-9752'$q$);
  perform pg_temp.vr_okid('10 自動完成','（備料）9752 變成考核期後再報回考核期','a2p','vr-cs1@2motor.tw','回考核期','MI-9752');
  v_aid2 := pg_temp.vr_flow('MI-9752', pg_temp.vr_mk('優'));
  perform pg_temp.vr_submit(v_aid2);
  perform pg_temp.vr_eq('10 自動完成','同一員工兩筆未結案（新人、回考核期）一次全部完成','已完成/已完成',
    pg_temp.vr_f('a2n','status') || '/' || pg_temp.vr_f('a2p','status'));
  perform pg_temp.vr_eq('10 自動完成','兩筆都連到同一張成績單','true',
    ((pg_temp.vr_f('a2n','assessment_id') = v_aid2::text) and (pg_temp.vr_f('a2p','assessment_id') = v_aid2::text))::text);
  perform pg_temp.vr_eq('10 自動完成','之前已取消的那筆不受影響（仍已取消、無成績單）','已取消/(null)',
    pg_temp.vr_f('a2c','status') || '/' || pg_temp.vr_f('a2c','assessment_id'));

  -- 9754：不及格 → 既有自動開改善單仍運作，回報也完成
  perform pg_temp.vr_okid('10 自動完成','（備料）9754 新人回報','a4','vr-cs1@2motor.tw','新人','MI-9754', null, 'true');
  v_aid3 := pg_temp.vr_flow('MI-9754', pg_temp.vr_mk('不及格'));
  v_r := pg_temp.vr_submit(v_aid3);
  perform pg_temp.vr_eq('10 自動完成','不及格的成績單送出成功（總分 0）','true', (v_r like '0.0/%')::text);
  perform pg_temp.vr_eq('10 自動完成','不及格：回報完成且連到成績單','已完成/true',
    pg_temp.vr_f('a4','status') || '/' || (pg_temp.vr_f('a4','assessment_id') = v_aid3::text)::text);
  perform pg_temp.vr_eq('10 自動完成','不及格：既有的自動開改善單觸發器照常運作（開了 1 張待改善單）','1/open',
    pg_temp.vr_q1($q$select count(*)::text || '/' || min(status) from public.improvement_tickets where employee_id = 'MI-9754'$q$));

  -- 自動完成觸發器吞例外：暫時加一條讓「改成已完成」必定失敗的約束，成績單仍必須能送出
  perform pg_temp.vr_okid('10 自動完成','（備料）店長甲替 9777 回報（用來模擬觸發器內部出錯）','c1','vr-sm1@2motor.tw','新人','MI-9777', null, 'true');
  perform pg_temp.vr_own($q$alter table public.exam_requests add constraint vr_block_done check (status <> '已完成') not valid$q$);
  v_aid := pg_temp.vr_flow('MI-9777', pg_temp.vr_mk('優'));
  v_r := pg_temp.vr_submit(v_aid);
  perform pg_temp.vr_eq('10 自動完成','觸發器內部更新失敗時：成績單照樣送出成功（不丟例外）','100.0/優秀', v_r);
  perform pg_temp.vr_eq('10 自動完成','成績單確實是已送出狀態','submitted',
    pg_temp.vr_q1(format($q$select status from public.assessments where id = %L::uuid$q$, v_aid)));
  perform pg_temp.vr_eq('10 自動完成','漏標的回報維持待處理（由客服部手動處理）','待處理', pg_temp.vr_f('c1','status'));
  perform pg_temp.vr_own($q$alter table public.exam_requests drop constraint vr_block_done$q$);
  perform pg_temp.vr_eq('10 自動完成','（還原）約束已移除','0',
    pg_temp.vr_q1($q$select count(*)::text from pg_constraint where conname = 'vr_block_done'$q$));

  -- 直接以擁有者身分把草稿改回草稿狀態相關不測；改以靜態確認「草稿不觸發」的條件
  perform pg_temp.vr_eq('10 自動完成','觸發條件靜態確認：只在 submitted 且舊狀態不是 submitted 時作用','true',
    pg_temp.vr_q1($q$select (pg_get_triggerdef(t.oid) like '%UPDATE OF status%'
                             and pg_get_triggerdef(t.oid) like '%submitted%')::text
                     from pg_trigger t where t.tgname = 'exam_req_auto_complete_trg'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 10','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 10b：複檢的資格（已完成複檢不再列／不可再報；成績單作廢後可重報；離職、不納入考核者不列也不可報）
-- 9770 已輔導改善單 tkDone  9717 離職＋已輔導改善單  9718 不納入考核＋已輔導改善單
-- ============================================================
do $$
declare
  v_aid uuid;
  v_cnt text := $q$select count(*)::text from public.exam_req_candidates('複檢') where employee_id = 'MI-9770'$q$;
begin
  perform pg_temp.vr_eq('10b 複檢資格','複檢回報前：9770 的改善單在客服部名單裡','1', pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', v_cnt, true));
  perform pg_temp.vr_okid('10b 複檢資格','客服部替 9770 回報複檢','rc1','vr-cs1@2motor.tw','複檢','MI-9770', null, 'null', null, pg_temp.vr_get('tkDone'));
  perform pg_temp.vr_eq('10b 複檢資格','回報後（待處理）名單不再列','0', pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', v_cnt, true));

  v_aid := pg_temp.vr_flow('MI-9770', pg_temp.vr_mk('優'));
  perform pg_temp.vr_submit(v_aid);
  perform pg_temp.vr_eq('10b 複檢資格','複檢成績單送出後：該複檢回報已完成並連到成績單','已完成/true',
    pg_temp.vr_f('rc1','status') || '/' || (pg_temp.vr_f('rc1','assessment_id') = v_aid::text)::text);
  perform pg_temp.vr_eq('10b 複檢資格','已完成的複檢（成績單仍有效）：名單不再列同一張改善單','0', pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', v_cnt, true));
  perform pg_temp.vr_crerr('10b 複檢資格','已完成的複檢（成績單仍有效）：不可再報同一張改善單','%這張改善單的複檢已經完成%','vr-cs1@2motor.tw','複檢','MI-9770', null, 'null', null, pg_temp.vr_get('tkDone'));

  -- 成績單作廢 → 可重報
  perform pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', format($q$select public.assess_void(%L::uuid, '測試作廢')::text$q$, v_aid), true);
  perform pg_temp.vr_eq('10b 複檢資格','複檢成績單作廢後：名單又列出這張改善單','1', pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', v_cnt, true));
  perform pg_temp.vr_okid('10b 複檢資格','複檢成績單作廢後：可以重報','rc2','vr-cs1@2motor.tw','複檢','MI-9770', null, 'null', null, pg_temp.vr_get('tkDone'));
  perform pg_temp.vr_eq('10b 複檢資格','重報後舊的已完成回報仍保留（共 2 筆複檢紀錄）','2',
    pg_temp.vr_q1(format($q$select count(*)::text from public.exam_requests where improvement_ticket_id = %L::uuid$q$, pg_temp.vr_get('tkDone'))));

  -- 離職、不納入考核
  perform pg_temp.vr_eq('10b 複檢資格','離職者（9717）有已輔導改善單也不在名單；不納入考核者（9718）同樣不在名單','0/0',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select count(*) filter (where employee_id = 'MI-9717')::text || '/' || count(*) filter (where employee_id = 'MI-9718')::text
                                                          from public.exam_req_candidates('複檢')$q$, true));
  perform pg_temp.vr_crerr('10b 複檢資格','離職者（9717）不可報複檢','%已離職%','vr-cs1@2motor.tw','複檢','MI-9717', null, 'null', null, pg_temp.vr_get('tkLeft'));
  perform pg_temp.vr_crerr('10b 複檢資格','不納入考核者（9718）不可報複檢','%未納入考核%','vr-cs1@2motor.tw','複檢','MI-9718', null, 'null', null, pg_temp.vr_get('tkNoinc'));
exception when others then
  perform pg_temp.vr_rec('區段 10b','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 11：信件內容與收件人
-- ============================================================
do $$
declare
  v_t date := (now() at time zone 'Asia/Taipei')::date;
  v_evil text := '<script>alert("x")</script> & ''q''';
  v_body text;
  v_subj text;
  v_to_expected text;
  v_long text := repeat('甲', 100);
begin
  perform pg_temp.vr_rewind();
  -- 準備：危險暱稱、危險網址
  perform pg_temp.vr_own($q$update public.employees set nickname = '<i>邪&"''' where id = 'MI-9746'$q$);
  perform pg_temp.vr_own($q$insert into public.app_settings (key, value) values ('site_url', 'https://example.test/app/')
                            on conflict (key) do update set value = excluded.value$q$);

  -- 新回報
  perform pg_temp.vr_okid('11 信件','新人回報（備註含 script 與引號、人員暱稱含標籤）','m1','vr-sm1@2motor.tw','新人','MI-9746',
                          pg_temp.vr_darr(1,2), 'true', v_evil);
  v_to_expected := pg_temp.vr_q1($q$select coalesce(array_agg(email order by email), '{}')::text
                                    from (select u.email from public.app_users u
                                          where u.role = 'cs_admin' and u.email ~ '^[a-z0-9._%+-]+@2motor\.tw$') s$q$);
  perform pg_temp.vr_eq('11 信件','新回報排 1 封信（kind＝new）','1', pg_temp.vr_mc('m1','new'));
  perform pg_temp.vr_eq('11 信件','收件人＝所有客服部帳號中 @2motor.tw 的信箱','true',
    (pg_temp.vr_mf('m1','new','to_emails') = v_to_expected)::text);
  perform pg_temp.vr_eq('11 信件','收件人含 vr-cs1 與 vr-cs2','true',
    (pg_temp.vr_mf('m1','new','to_emails') like '%vr-cs1@2motor.tw%' and pg_temp.vr_mf('m1','new','to_emails') like '%vr-cs2@2motor.tw%')::text);
  -- 收件人過濾（直接呼叫內部函式，字面值；不寫入 app_users）
  perform pg_temp.vr_set('f1', pg_temp.vr_q1($q$select public.exam_req_enqueue(
        array['vr-ext@example.com', 'vr-evil@2motor.tw.example.com', 'x@2motor.twx', 'vr-ghost@2motor.tw', null, ' VR-CS1@2MOTOR.TW ', 'vr-cs1@2motor.tw'],
        's', 'b', 'filter-test', null)::text$q$));
  perform pg_temp.vr_set('f2', pg_temp.vr_q1($q$select public.exam_req_enqueue(array['vr-ext@example.com'], 's', 'b', 'filter-test', null)::text$q$));
  perform pg_temp.vr_set('f3', pg_temp.vr_q1($q$select public.exam_req_enqueue(null, 's', 'b', 'filter-test', null)::text$q$));
  perform pg_temp.vr_eq('11 信件','過濾：外部網域、2motor.tw 當子網域、不在 app_users、空值、大小寫與空白、重複 → 只剩 vr-cs1','{vr-cs1@2motor.tw}',
    pg_temp.vr_q1(format($q$select to_emails::text from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('f1'))));
  perform pg_temp.vr_eq('11 信件','過濾：全部不合格 → skipped、收件人為空、說明原因','skipped/{}/true',
    pg_temp.vr_q1(format($q$select status || '/' || to_emails::text || '/' || (last_error like '沒有可寄送的收件人%%')::text
                           from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('f2'))));
  perform pg_temp.vr_eq('11 信件','過濾：收件人是 null 陣列 → skipped','skipped',
    pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('f3'))));
  perform pg_temp.vr_eq('11 信件','新回報信不寄給回報人（店長）','false', (pg_temp.vr_mf('m1','new','to_emails') like '%vr-sm1%')::text);

  v_body := pg_temp.vr_mf('m1','new','body_html');
  v_subj := pg_temp.vr_mf('m1','new','subject');
  perform pg_temp.vr_eq('11 信件','主旨含門市、人員、情況（【待考回報】）','true',
    (v_subj like '【待考回報】%ZZ測試門市甲%' and v_subj like '%（新人）')::text);
  perform pg_temp.vr_eq('11 信件','備註 script 被 escape（&lt;script&gt;）、本文沒有原始 <script','true',
    (v_body like '%&lt;script&gt;%' and v_body not like '%<script%')::text);
  perform pg_temp.vr_eq('11 信件','備註的雙引號、單引號、& 都被 escape','true',
    (v_body like '%&quot;x&quot;%' and v_body like '%&#39;q&#39;%' and v_body like '%&amp; %')::text);
  perform pg_temp.vr_eq('11 信件','人員暱稱的標籤也被 escape，本文沒有原始 <i>','true',
    (v_body like '%&lt;i&gt;邪&amp;&quot;&#39;%' and v_body not like '%<i>%')::text);
  perform pg_temp.vr_eq('11 信件','新人信件註明影片已看完','true', (v_body like '%已看完線上回覆實戰全攻略影片%')::text);
  perform pg_temp.vr_eq('11 信件','新回報信不含「請同仁準時上線」','false', (v_body like '%請同仁準時上線%')::text);
  perform pg_temp.vr_eq('11 信件','信件含希望日期','true',
    (v_body like '%' || (v_t + 1)::text || '、' || (v_t + 2)::text || '%')::text);
  perform pg_temp.vr_eq('11 信件','登入連結＝site_url（結尾有斜線）+ requests.html','true',
    (v_body like '%href="https://example.test/app/requests.html"%')::text);
  perform pg_temp.vr_eq('11 信件','信件長度遠小於 Apps Script 上限（20000）','true', (length(v_body) < 20000)::text);
  perform pg_temp.vr_eq('11 信件','主旨沒有換行字元','false', (v_subj ~ '[\r\n]')::text);


  -- 複檢信：備註只取前 80 字、連結（site_url 結尾沒有斜線時補斜線）
  perform pg_temp.vr_own($q$insert into public.app_settings (key, value) values ('site_url', 'https://example.test/app')
                            on conflict (key) do update set value = excluded.value$q$);
  perform pg_temp.vr_okid('11 信件','客服部替 9716 回報複檢（備註 100 字）','m2','vr-cs1@2motor.tw','複檢','MI-9716',
                          pg_temp.vr_darr(1), 'null', v_long, pg_temp.vr_get('tkX2'));
  v_body := pg_temp.vr_mf('m2','new','body_html');
  perform pg_temp.vr_eq('11 信件','複檢信：備註只取前 80 字並加「…」（有 80 字＋…、沒有 81 字）','true/false',
    (v_body like '%' || repeat('甲', 80) || '…%')::text || '/' || (v_body like '%' || repeat('甲', 81) || '%')::text);
  perform pg_temp.vr_eq('11 信件','site_url 結尾沒有斜線：自動補成 /requests.html','true',
    (v_body like '%href="https://example.test/app/requests.html"%')::text);
  perform pg_temp.vr_eq('11 信件','複檢信不寫影片那一句（只有新人才寫）','false', (v_body like '%影片%')::text);
  perform pg_temp.vr_eq('11 信件','複檢信的情況欄是「複檢」','true', (v_body like '%複檢%')::text);

  -- 連結含引號 → escape；備註空白 → 不出現備註列
  perform pg_temp.vr_own($q$update public.app_settings set value = 'https://example.test/a"b' where key = 'site_url'$q$);
  perform pg_temp.vr_okid('11 信件','客服部替 9747 回報新人（沒有備註；site_url 含引號）','m3','vr-cs1@2motor.tw','新人','MI-9747',
                          pg_temp.vr_darr(1), 'true', null);
  v_body := pg_temp.vr_mf('m3','new','body_html');
  perform pg_temp.vr_eq('11 信件','連結裡的雙引號被 escape（不會截斷 href）','true',
    (v_body like '%href="https://example.test/a&quot;b/requests.html"%')::text);
  perform pg_temp.vr_eq('11 信件','備註空白時信件沒有「備註」列','false', (v_body like '%備註%')::text);

  -- 排定信（寄回報人；請同仁準時上線；備註 escape）
  perform pg_temp.vr_own($q$update public.app_settings set value = 'https://example.test/app/' where key = 'site_url'$q$);
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','m3', $q$'2099-07-01 09:15+08'::timestamptz$q$, v_evil);
  v_body := pg_temp.vr_mf('m3','scheduled','body_html');
  perform pg_temp.vr_eq('11 信件','排定信 1 封，收件人＝當初回報的人（vr-cs1）','1/{vr-cs1@2motor.tw}',
    pg_temp.vr_mc('m3','scheduled') || '/' || pg_temp.vr_mf('m3','scheduled','to_emails'));
  perform pg_temp.vr_eq('11 信件','排定信主旨（【考核已排定】＋門市＋人員＋情況）','true',
    (pg_temp.vr_mf('m3','scheduled','subject') like '【考核已排定】ZZ測試門市甲 假員9747（新人）')::text);
  perform pg_temp.vr_eq('11 信件','排定信寫「請同仁準時上線」','true', (v_body like '%請同仁準時上線%')::text);
  perform pg_temp.vr_eq('11 信件','排定信寫排定時間（台北時間）','true', (v_body like '%2099-07-01 09:15%')::text);
  perform pg_temp.vr_eq('11 信件','排定信的備註 script 被 escape','true',
    (v_body like '%&lt;script&gt;%' and v_body not like '%<script%' and v_body like '%&#39;q&#39;%')::text);
  perform pg_temp.vr_eq('11 信件','排定信帶登入連結','true', (v_body like '%href="https://example.test/app/requests.html"%')::text);

  -- 退回信（寄回報人；原因 escape；不含準時上線）
  perform pg_temp.vr_okid('11 信件','店長甲替 9749 回報新人','m4','vr-sm1@2motor.tw','新人','MI-9749', pg_temp.vr_darr(1,2), 'true', null);
  perform pg_temp.vr_ret('vr-cs1@2motor.tw','m4', v_evil);
  v_body := pg_temp.vr_mf('m4','returned','body_html');
  perform pg_temp.vr_eq('11 信件','退回信 1 封，收件人＝當初回報的店長（vr-sm1）','1/{vr-sm1@2motor.tw}',
    pg_temp.vr_mc('m4','returned') || '/' || pg_temp.vr_mf('m4','returned','to_emails'));
  perform pg_temp.vr_eq('11 信件','退回信主旨以【待考回報已退回】開頭','true',
    (pg_temp.vr_mf('m4','returned','subject') like '【待考回報已退回】%')::text);
  perform pg_temp.vr_eq('11 信件','退回信帶退回原因（script 被 escape）','true',
    (v_body like '%退回原因%' and v_body like '%&lt;script&gt;%' and v_body not like '%<script%')::text);
  perform pg_temp.vr_eq('11 信件','退回信帶希望日期、不含「請同仁準時上線」','true/false',
    (v_body like '%' || (v_t + 1)::text || '%')::text || '/' || (v_body like '%請同仁準時上線%')::text);
  perform pg_temp.vr_eq('11 信件','每種信各只有自己那種（m4 只有 new 與 returned，沒有 scheduled）','1/1/0',
    pg_temp.vr_mc('m4','new') || '/' || pg_temp.vr_mc('m4','returned') || '/' || pg_temp.vr_mc('m4','scheduled'));

  -- 收件人過濾：回報人信箱不是 @2motor.tw、或不在 app_users → 不寄，留 skipped 紀錄
  perform pg_temp.vr_okid('11 信件','店長甲替 9750 回報新人（之後把回報人信箱改成外部）','m5','vr-sm1@2motor.tw','新人','MI-9750', null, 'true');
  perform pg_temp.vr_own(format($q$update public.exam_requests set requested_by = 'vr-ext@example.com' where id = %L::uuid$q$, pg_temp.vr_get('m5')));
  perform pg_temp.vr_sched('vr-cs1@2motor.tw','m5', $q$now() + interval '1 day'$q$);
  perform pg_temp.vr_eq('11 信件','回報人信箱不是 @2motor.tw：不寄（skipped、收件人為空、說明原因）','skipped/{}/true',
    pg_temp.vr_mf('m5','scheduled','status') || '/' || pg_temp.vr_mf('m5','scheduled','to_emails') || '/' ||
    (pg_temp.vr_mf('m5','scheduled','last_error') like '沒有可寄送的收件人%')::text);
  perform pg_temp.vr_okid('11 信件','店長甲替 9755 回報新人（之後把回報人改成不在 app_users 的 2motor 信箱）','m6','vr-sm1@2motor.tw','新人','MI-9755', null, 'true');
  perform pg_temp.vr_own(format($q$update public.exam_requests set requested_by = 'vr-ghost@2motor.tw' where id = %L::uuid$q$, pg_temp.vr_get('m6')));
  perform pg_temp.vr_ret('vr-cs1@2motor.tw','m6','測試');
  perform pg_temp.vr_eq('11 信件','回報人不在 app_users：不寄（skipped、收件人為空）','skipped/{}',
    pg_temp.vr_mf('m6','returned','status') || '/' || pg_temp.vr_mf('m6','returned','to_emails'));
  perform pg_temp.vr_eq('11 信件','收件人過濾不影響排定／退回本身（m5 仍是已排定、m6 已取消）','已排定/已取消',
    pg_temp.vr_f('m5','status') || '/' || pg_temp.vr_f('m6','status'));
exception when others then
  perform pg_temp.vr_rec('區段 11','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 12：寄信路徑（假 pg_net）
-- ============================================================
do $$
declare
  v_ok text;
begin
  perform pg_temp.vr_own($q$insert into public.app_settings (key, value) values
                              ('mail_relay_url', 'https://relay.test/exec'), ('mail_relay_token', 'vr-token-A')
                            on conflict (key) do update set value = excluded.value$q$);

  perform pg_temp.vr_rewind();
  -- 有設定且 pg_net 在 → queued，記 net_request_id，送出的 JSON 格式正確
  perform pg_temp.vr_okid('12 寄信路徑','有設定＋有 pg_net：店長甲回報 9760','p1','vr-sm1@2motor.tw','新人','MI-9760', null, 'true', '備註 <b>');
  perform pg_temp.vr_eq('12 寄信路徑','信件狀態 queued、記下 net_request_id','queued/true',
    pg_temp.vr_mf('p1','new','status') || '/' || (pg_temp.vr_mf('p1','new','net_request_id') <> '(null)')::text);
  perform pg_temp.vr_eq('12 寄信路徑','送出的請求：網址、token、to、subject、html、Content-Type、逾時 10 秒都正確','true',
    pg_temp.vr_q1(format($q$select (c.url = 'https://relay.test/exec'
                                and c.body ->> 'token' = 'vr-token-A'
                                and c.body -> 'to' = to_jsonb(m.to_emails)
                                and c.body ->> 'subject' = m.subject
                                and c.body ->> 'html' = m.body_html
                                and c.headers ->> 'Content-Type' = 'application/json'
                                and c.timeout_ms = 10000)::text
                           from public.mail_outbox m join pg_temp.vr_net_calls c on c.id = m.net_request_id
                           where m.request_id = %L::uuid and m.kind = 'new'$q$, pg_temp.vr_get('p1'))));
  perform pg_temp.vr_eq('12 寄信路徑','JSON 本文只有 token、to、subject、html 四個鍵','html,subject,to,token',
    pg_temp.vr_q1(format($q$select string_agg(k, ',' order by k)
                           from public.mail_outbox m join pg_temp.vr_net_calls c on c.id = m.net_request_id,
                                jsonb_object_keys(c.body) k
                           where m.request_id = %L::uuid and m.kind = 'new'$q$, pg_temp.vr_get('p1'))));
  perform pg_temp.vr_eq('12 寄信路徑','回報本身成功（待處理）','待處理', pg_temp.vr_f('p1','status'));

  -- http_post 丟例外 → failed，主交易仍成功
  perform pg_temp.vr_own($q$update public.app_settings set value = 'https://relay.test/throw' where key = 'mail_relay_url'$q$);
  perform pg_temp.vr_okid('12 寄信路徑','http_post 丟例外：新增回報仍成功（9761）','p2','vr-sm1@2motor.tw','新人','MI-9761', null, 'true');
  perform pg_temp.vr_eq('12 寄信路徑','例外：信件 failed、last_error 記下原因、沒有 net_request_id','failed/true/(null)',
    pg_temp.vr_mf('p2','new','status') || '/' || (pg_temp.vr_mf('p2','new','last_error') like '%假 http_post 丟例外%')::text || '/' ||
    pg_temp.vr_mf('p2','new','net_request_id'));
  perform pg_temp.vr_eq('12 寄信路徑','例外：回報本身仍是待處理（主交易沒失敗）','待處理', pg_temp.vr_f('p2','status'));
  v_ok := pg_temp.vr_sched('vr-cs1@2motor.tw','p2', $q$now() + interval '1 day'$q$);
  perform pg_temp.vr_eq('12 寄信路徑','例外：排定一樣成功，排定信 failed','OK/failed',
    case when v_ok like 'ERROR%' then v_ok else 'OK' end || '/' || pg_temp.vr_mf('p2','scheduled','status'));
  v_ok := pg_temp.vr_ret('vr-cs1@2motor.tw','p2','測試');
  perform pg_temp.vr_eq('12 寄信路徑','例外：退回一樣成功，退回信 failed','OK/已取消/failed',
    case when v_ok like 'ERROR%' then v_ok else 'OK' end || '/' || pg_temp.vr_f('p2','status') || '/' || pg_temp.vr_mf('p2','returned','status'));

  -- 寄信觸發器本身也要吞例外：直接寫 mail_outbox（繞過 notify 的保護）仍不能讓 insert 失敗
  perform pg_temp.vr_eq('12 寄信路徑','觸發器本身吞例外：直接 insert mail_outbox 遇到 http_post 例外，insert 成功、該列 failed','OK/failed/true',
    pg_temp.vr_own($q$insert into public.mail_outbox (to_emails, subject, body_html, kind)
                      values (array['vr-cs1@2motor.tw'], '直接寫入', 'b', 'direct-throw')$q$) || '/' ||
    pg_temp.vr_q1($q$select status from public.mail_outbox where kind = 'direct-throw'$q$) || '/' ||
    (pg_temp.vr_q1($q$select last_error from public.mail_outbox where kind = 'direct-throw'$q$) like '%假 http_post 丟例外%')::text);

  -- 沒有 pg_net（假環境切成未安裝）→ skipped
  perform pg_temp.vr_own($q$update public.app_settings set value = 'https://relay.test/exec' where key = 'mail_relay_url'$q$);
  update pg_temp.vr_net_cfg set ready = false;
  perform pg_temp.vr_okid('12 寄信路徑','沒有 pg_net（切成未安裝）：回報仍成功（9762）','p3','vr-sm1@2motor.tw','新人','MI-9762', null, 'true');
  perform pg_temp.vr_eq('12 寄信路徑','沒有 pg_net：信件 skipped、說明尚未啟用 pg_net','skipped/true',
    pg_temp.vr_mf('p3','new','status') || '/' || (pg_temp.vr_mf('p3','new','last_error') like '%pg_net%')::text);
  update pg_temp.vr_net_cfg set ready = true;

  -- 信件產生失敗不會讓回報失敗：直接以擁有者身分呼叫 notify，用不存在的信件種類／回報
  perform pg_temp.vr_eq('12 寄信路徑','信件產生失敗（不認識的種類）：notify 不丟例外、留一筆 failed 紀錄','OK/1/true',
    pg_temp.vr_own(format($q$select public.exam_req_notify('bogus', %L::uuid)$q$, pg_temp.vr_get('p1'))) || '/' ||
    pg_temp.vr_q1(format($q$select count(*)::text from public.mail_outbox where request_id = %L::uuid and kind = 'bogus' and status = 'failed'$q$, pg_temp.vr_get('p1'))) || '/' ||
    (pg_temp.vr_q1(format($q$select last_error from public.mail_outbox where request_id = %L::uuid and kind = 'bogus'$q$, pg_temp.vr_get('p1'))) like '排信失敗：%')::text);
  perform pg_temp.vr_eq('12 寄信路徑','信件產生失敗（找不到回報）：notify 不丟例外','OK',
    pg_temp.vr_own($q$select public.exam_req_notify('new', '00000000-0000-0000-0000-000000000000'::uuid)$q$));
exception when others then
  perform pg_temp.vr_rec('區段 12','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 13：mail_outbox_sync（依 net._http_response 更新狀態）
--   sy1 200  sy2 302  sy3 399  sy4 400  sy5 500  sy6 逾時  sy7 錯誤訊息  sy8 尚無回應  sy9 200 但有錯誤訊息  sy10 已是 failed
-- ============================================================
do $$
declare
  i int;
  v_id uuid;
  v_sql text;
begin
  for i in 1 .. 9 loop
    insert into public.mail_outbox (to_emails, subject, body_html, kind)
    values (array['vr-cs1@2motor.tw'], '同步測試' || i::text, 'b', 'sync-test')
    returning id into v_id;
    perform pg_temp.vr_set('sy' || i::text, v_id::text);
  end loop;
  insert into public.mail_outbox (to_emails, subject, body_html, kind, status, net_request_id)
  values (array['vr-cs1@2motor.tw'], '同步測試10', 'b', 'sync-test', 'failed',
          (select net_request_id from public.mail_outbox where id = pg_temp.vr_get('sy1')::uuid))
  returning id into v_id;
  perform pg_temp.vr_set('sy10', v_id::text);

  perform pg_temp.vr_eq('13 同步','（備料）九封信都 queued 且都有 net_request_id','9',
    pg_temp.vr_q1($q$select count(*)::text from public.mail_outbox where kind = 'sync-test' and status = 'queued' and net_request_id is not null$q$));

  perform pg_temp.vr_eq('13 同步','還沒有任何回應：sync 回傳 0、全部維持 queued','0/9',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()::text$q$, true) || '/' ||
    pg_temp.vr_q1($q$select count(*)::text from public.mail_outbox where kind = 'sync-test' and status = 'queued'$q$));

  -- 假回應（sy8 故意沒有）
  v_sql := $q$insert into pg_temp.vr_net_resp (id, status_code, timed_out, error_msg, content)
               select m.net_request_id, x.sc, x.t, x.e, x.c
               from (values ('sy1', 200, false, null, 'ok'),
                            ('sy2', 302, false, null, '<html>moved</html>'),
                            ('sy3', 399, false, null, null),
                            ('sy4', 400, false, null, 'bad request'),
                            ('sy5', 500, false, null, 'oops'),
                            ('sy6', null, true, 'Timeout of 10000 ms reached', null),
                            ('sy7', null, false, 'Could not resolve host', null),
                            ('sy9', 200, false, 'SSL error', 'ok')) as x(k, sc, t, e, c)
               join public.mail_outbox m on m.id = (select v from pg_temp.vr_ctx where k = x.k)::uuid$q$;
  execute v_sql;

  -- 沒有 pg_net 時什麼都不做
  update pg_temp.vr_net_cfg set ready = false;
  perform pg_temp.vr_eq('13 同步','沒有 pg_net：sync 什麼都不做（回傳 0、狀態不變）','0/9',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()::text$q$, true) || '/' ||
    pg_temp.vr_q1($q$select count(*)::text from public.mail_outbox where kind = 'sync-test' and status = 'queued'$q$));
  update pg_temp.vr_net_cfg set ready = true;

  perform pg_temp.vr_eq('13 同步','有 pg_net：sync 更新 8 筆（sy8 沒有回應所以不動）','8',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()::text$q$, true));

  perform pg_temp.vr_eq('13 同步','200 → sent（last_error 空）','sent/(null)', pg_temp.vr_q1(format($q$select status || '/' || coalesce(last_error, '(null)') from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy1'))));
  perform pg_temp.vr_eq('13 同步','302（Apps Script 轉址）→ sent','sent', pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy2'))));
  perform pg_temp.vr_eq('13 同步','399（3xx 上界）→ sent','sent', pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy3'))));
  perform pg_temp.vr_eq('13 同步','400 → failed，last_error 記 HTTP 400 與回應','failed/HTTP 400：bad request',
    pg_temp.vr_q1(format($q$select status || '/' || last_error from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy4'))));
  perform pg_temp.vr_eq('13 同步','500 → failed，last_error 記 HTTP 500 與回應','failed/HTTP 500：oops',
    pg_temp.vr_q1(format($q$select status || '/' || last_error from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy5'))));
  perform pg_temp.vr_eq('13 同步','逾時（timed_out）→ failed，last_error 以「逾時」開頭','failed/true',
    pg_temp.vr_q1(format($q$select status || '/' || (last_error like '逾時%%')::text from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy6'))));
  perform pg_temp.vr_eq('13 同步','有錯誤訊息（沒有狀態碼）→ failed，原因寫進 last_error','failed/Could not resolve host',
    pg_temp.vr_q1(format($q$select status || '/' || last_error from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy7'))));
  perform pg_temp.vr_eq('13 同步','狀態碼 200 但有錯誤訊息 → failed（錯誤優先）','failed/SSL error',
    pg_temp.vr_q1(format($q$select status || '/' || last_error from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy9'))));
  perform pg_temp.vr_eq('13 同步','還沒有回應的維持 queued','queued', pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy8'))));
  perform pg_temp.vr_eq('13 同步','原本就不是 queued 的（sy10 failed）不被改動','failed/(null)',
    pg_temp.vr_q1(format($q$select status || '/' || coalesce(last_error, '(null)') from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy10'))));

  perform pg_temp.vr_eq('13 同步','再跑一次 sync：回傳 0、狀態不變（可重複按）','0',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()::text$q$, true));

  -- 回應是 2xx／3xx 但內容明說 ok:false → failed
  for i in 11 .. 16 loop
    insert into public.mail_outbox (to_emails, subject, body_html, kind)
    values (array['vr-cs1@2motor.tw'], '同步測試' || i::text, 'b', 'sync-test2')
    returning id into v_id;
    perform pg_temp.vr_set('sy' || i::text, v_id::text);
  end loop;
  v_sql := $q$insert into pg_temp.vr_net_resp (id, status_code, timed_out, error_msg, content)
               select m.net_request_id, x.sc, false, null, x.c
               from (values ('sy11', 200, '{"ok": false, "error":"密碼不正確"}'),
                            ('sy12', 302, '{"ok":false}'),
                            ('sy13', 200, '{ "ok" : true }'),
                            ('sy14', 200, '{"OK":   false}'),
                            ('sy15', 200, '{"ok":"false"}'),
                            ('sy16', 200, '{"ok":false,"x":"' || repeat('字', 300) || '"}')) as x(k, sc, c)
               join public.mail_outbox m on m.id = (select v from pg_temp.vr_ctx where k = x.k)::uuid$q$;
  execute v_sql;
  perform pg_temp.vr_eq('13 同步','sync 更新 6 筆（五筆內容檢查＋一筆正常）','6',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()::text$q$, true));
  perform pg_temp.vr_eq('13 同步','200 但內容含 "ok": false（有空白）→ failed，last_error 記內容','failed/{"ok": false, "error":"密碼不正確"}',
    pg_temp.vr_q1(format($q$select status || '/' || last_error from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy11'))));
  perform pg_temp.vr_eq('13 同步','302 但內容含 "ok":false → failed','failed/{"ok":false}',
    pg_temp.vr_q1(format($q$select status || '/' || last_error from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy12'))));
  perform pg_temp.vr_eq('13 同步','200 且 "ok" : true → sent','sent/(null)',
    pg_temp.vr_q1(format($q$select status || '/' || coalesce(last_error, '(null)') from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy13'))));
  perform pg_temp.vr_eq('13 同步','"OK":   false（大小寫與空白不拘）→ failed','failed',
    pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy14'))));
  perform pg_temp.vr_eq('13 同步','"ok":"false"（字串，不是布林）不算 → sent','sent',
    pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy15'))));
  perform pg_temp.vr_eq('13 同步','內容很長時 last_error 只存前 200 字','failed/200',
    pg_temp.vr_q1(format($q$select status || '/' || char_length(last_error)::text from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy16'))));

  -- 晚到的回應
  insert into pg_temp.vr_net_resp (id, status_code, timed_out, error_msg, content)
  select m.net_request_id, 302, false, null, null from public.mail_outbox m where m.id = pg_temp.vr_get('sy8')::uuid;
  perform pg_temp.vr_eq('13 同步','晚到的回應下次 sync 就會更新（sy8 → sent，回傳 1）','1/sent',
    pg_temp.vr_as('authenticated','vr-cs1@2motor.tw', $q$select public.mail_outbox_sync()::text$q$, true) || '/' ||
    pg_temp.vr_q1(format($q$select status from public.mail_outbox where id = %L::uuid$q$, pg_temp.vr_get('sy8'))));

  -- 區段 12 的那封 queued（p1）沒有回應，這裡一併確認仍是 queued
  perform pg_temp.vr_eq('13 同步','區段 12 那封 queued（沒有回應）維持 queued','queued', pg_temp.vr_mf('p1','new','status'));
exception when others then
  perform pg_temp.vr_rec('區段 13','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 14：既有功能不變
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('14 既有功能','assess_submit 仍是抽查版（含 probation_since），且沒被本功能改動（不含 exam_req）','true/false',
    pg_temp.vr_q1($q$select (prosrc like '%probation_since%')::text || '/' || (strpos(prosrc, 'exam_req') > 0)::text
                     from pg_proc where proname = 'assess_submit' and pronamespace = 'public'::regnamespace$q$));
  perform pg_temp.vr_eq('14 既有功能','improve_* 四個函式與 assess_void、assess_start、assess_draw、assess_save_item 都不含 exam_req（沒被改動）','0',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc
                     where pronamespace = 'public'::regnamespace
                       and proname in ('improve_update_plan','improve_mark_coached','improve_close','improve_cancel',
                                       'assess_void','assess_start','assess_draw','assess_save_item')
                       and strpos(prosrc, 'exam_req') > 0$q$));
  perform pg_temp.vr_eq('14 既有功能','employees_with_tenure 仍有 tenure_group 與 probation_since 欄位','2',
    pg_temp.vr_q1($q$select count(*)::text from information_schema.columns
                     where table_schema = 'public' and table_name = 'employees_with_tenure'
                       and column_name in ('tenure_group', 'probation_since')$q$));
  perform pg_temp.vr_ok('14 既有功能','抽查名單 spot_candidates 客服部仍可呼叫','vr-cs1@2motor.tw', $q$select * from public.spot_candidates()$q$);
  perform pg_temp.vr_ok('14 既有功能','考核名單 assess_candidates 客服部仍可呼叫','vr-cs1@2motor.tw', $q$select * from public.assess_candidates()$q$);
  perform pg_temp.vr_eq('14 既有功能','改善單 RLS 不變：店長甲看不到乙店改善單','0',
    pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select count(*)::text from public.improvement_tickets where store_code = 'ZZ-X2'$q$, true));
  perform pg_temp.vr_eq('14 既有功能','名冊 RLS 不變：店長甲看不到乙店人員','0',
    pg_temp.vr_as('authenticated','vr-sm1@2motor.tw', $q$select count(*)::text from public.employees where store_code = 'ZZ-X2'$q$, true));
exception when others then
  perform pg_temp.vr_rec('區段 14','完整性意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 15：每日頻率限制（同一回報人當天〔台北日期〕已建立 20 筆含已取消就拒絕）
-- ============================================================
do $$
declare
  v_n int;
  v_msg text := 'ERROR: 今天回報次數已達上限（20 筆），請明天再試或聯絡客服部';
  v_sm2_today text := $q$select count(*)::text from public.exam_requests
                         where requested_by = 'vr-sm2@2motor.tw' and (created_at at time zone 'Asia/Taipei')::date = pg_temp.vr_today()$q$;
begin
  -- 其他人先把今天的計數移到昨天，避免干擾
  perform pg_temp.vr_rewind();
  -- 讓店長乙今天剛好有 19 筆（用已取消的填充列，不佔唯一索引）
  select count(*) into v_n from public.exam_requests
   where requested_by = 'vr-sm2@2motor.tw' and (created_at at time zone 'Asia/Taipei')::date = pg_temp.vr_today();
  insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role,
                                    desired_dates, status, cancel_by, cancel_reason)
  select '回考核期', 'MI-9709', 'x', 'ZZ-X2', 'vr-sm2@2motor.tw', '店長', array[current_date], '已取消', '店長', '填充'
  from generate_series(1, 19 - v_n);
  perform pg_temp.vr_eq('15 頻率限制','（備料）店長乙今天已有 19 筆（含已取消）','19', pg_temp.vr_q1(v_sm2_today));

  perform pg_temp.vr_okid('15 頻率限制','第 20 筆還可以（9773）','l20','vr-sm2@2motor.tw','新人','MI-9773', null, 'true');
  perform pg_temp.vr_eq('15 頻率限制','店長乙今天累計 20 筆','20', pg_temp.vr_q1(v_sm2_today));
  perform pg_temp.vr_eq('15 頻率限制','第 21 筆被拒，訊息正確','true',
    (pg_temp.vr_cr('vr-sm2@2motor.tw','新人','MI-9774', null, 'true') = v_msg)::text);
  perform pg_temp.vr_eq('15 頻率限制','被拒的那一筆沒有留下資料','0',
    pg_temp.vr_q1($q$select count(*)::text from public.exam_requests where employee_id = 'MI-9774'$q$));

  -- 不同人不互相影響
  perform pg_temp.vr_okid('15 頻率限制','店長甲不受影響（9775）','l_sm1','vr-sm1@2motor.tw','新人','MI-9775', null, 'true');
  perform pg_temp.vr_okid('15 頻率限制','客服部不受影響（9776）','l_cs','vr-cs1@2motor.tw','新人','MI-9776', null, 'true');

  -- 隔天重新計算：把店長乙的紀錄全部移到昨天
  perform pg_temp.vr_own($q$update public.exam_requests set created_at = created_at - interval '1 day' where requested_by = 'vr-sm2@2motor.tw'$q$);
  perform pg_temp.vr_eq('15 頻率限制','隔天：今天的計數歸零','0', pg_temp.vr_q1(v_sm2_today));
  perform pg_temp.vr_okid('15 頻率限制','隔天又可以回報（9774）','l_next','vr-sm2@2motor.tw','新人','MI-9774', null, 'true');
exception when others then
  perform pg_temp.vr_rec('區段 15','完整性意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate examreq_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare examreq_vr_out as select * from (values (0, '
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
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate examreq_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare examreq_vr_out as select '
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
execute examreq_vr_out;
