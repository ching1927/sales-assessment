-- ============================================================
-- 業務考核系統：停用紅單與回考核期 驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 noredticket_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw），用 set_config('request.jwt.claims', …) ＋
--   set local role 模擬各角色登入，真的呼叫 spot_register_dims（新）與舊 spot_register、spot_void_ticket、spot_coach、
--   assess_start、assess_submit、exam_req_create，把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果就是「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；
--   「通過」欄全是「通過」才算驗證成功。若畫面出現兩張一樣的表，看最後一張即可。
-- 驗證重點：登記 6 次待加強回覆（同月）→ 只有 6 張黃單、0 張紅單、0 筆回考核期；優良回覆不開黃單；作廢與輔導回填照常；
--   既有紅單／回考核期資料（預先寫入）仍可讀；assess_start／assess_submit 不再有回考核期身分與 85 分覆寫；
--   待考回報不能再以「回考核期」回報，舊的「回考核期」回報仍可讀。
-- 假門市代碼 ZZ-N1／ZZ-N2、假員工編號 MI-9801～MI-9813、假信箱 vr-cs1／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regprocedure('public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])') is null then
    raise exception '請先執行 spotdims_schema.sql 與 noredticket_schema.sql';
  end if;
  if exists (select 1 from pg_proc p where p.oid = 'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])'::regprocedure
             and p.prosrc like '%spot_probations%') then
    raise exception '請先執行 noredticket_schema.sql（目前登記函式還會開紅單與回考核期）';
  end if;
  if to_regclass('storage.objects') is null then
    raise exception '找不到 storage.objects';
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

create or replace function pg_temp.vr_today()
returns date language sql as $$
  select (now() at time zone 'Asia/Taipei')::date;
$$;

-- 組出七面向評分物件（只給「舊紀錄」假資料用）
create or replace function pg_temp.vr_mk(a text, b text, c text, d text, e text, f text, g text)
returns jsonb language sql immutable as $$
  select jsonb_build_object('資訊正確性', a, '預設訊息運用', b, '問題掌握', c, '主動引導', d,
                            '風險意識', e, '語氣與禮貌', f, '文字品質', g);
$$;

-- 假的已上傳截圖：在 storage.objects 放一列（資料庫擁有者身分），回傳路徑。p_reg＝抽查 id
create or replace function pg_temp.vr_obj(p_reg uuid)
returns text language plpgsql as $$
declare
  v_path text := 'spot/' || p_reg::text || '/' || gen_random_uuid()::text || '.jpg';
begin
  insert into storage.objects (bucket_id, name) values ('assess-notes', v_path);
  return v_path;
end $$;

-- 呼叫 spot_register_dims（客服部身分，預設登記今天）；回傳 jsonb，失敗回 {"error": "..."}
-- p_dims／p_shots 傳 null 代表不帶；p_id 傳 null 代表不帶抽查 id
create or replace function pg_temp.vr_regd(p_emp text, p_verdict text, p_reason text default null,
                                            p_dims text[] default null, p_note text default null,
                                            p_shots text[] default null, p_id uuid default null,
                                            p_url text default 'https://line.me/R/ti/p/test-1',
                                            p_email text default 'vr-cs1@2motor.tw')
returns jsonb language plpgsql as $$
declare
  v text;
begin
  v := pg_temp.vr_as('authenticated', p_email,
         format($q$select public.spot_register_dims(%L::uuid, %L, %L::date, %L, %L, %L, %L::text[], %L, %L::text[])::text$q$,
                p_id, p_emp, pg_temp.vr_today()::text, p_url, p_verdict, p_reason, p_dims, p_note, p_shots),
         true);
  if v like 'ERROR:%' then
    return jsonb_build_object('error', v);
  end if;
  return v::jsonb;
end $$;

-- 同上，但回傳文字（成功回 'OK'；失敗回 'ERROR: …'），方便比對錯誤訊息
create or replace function pg_temp.vr_regd_t(p_emp text, p_verdict text, p_reason text default null,
                                              p_dims text[] default null, p_note text default null,
                                              p_shots text[] default null, p_id uuid default null,
                                              p_url text default 'https://line.me/R/ti/p/test-1')
returns text language plpgsql as $$
declare
  j jsonb := pg_temp.vr_regd(p_emp, p_verdict, p_reason, p_dims, p_note, p_shots, p_id, p_url);
begin
  if j ? 'error' then return j ->> 'error'; end if;
  return 'OK';
end $$;

create or replace function pg_temp.vr_has(j jsonb, k text)
returns text language sql as $$
  select case when j ->> k is null then '無' else '有' end;
$$;

-- 某人某種單據的張數（預設只算有效）
create or replace function pg_temp.vr_tc(p_emp text, p_kind text, p_status text default '有效')
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format(
    'select count(*)::text from public.spot_tickets where employee_id = %L and kind = %L and status = %L',
    p_emp, p_kind, p_status));
end $$;

-- 某人的抽查筆數
create or replace function pg_temp.vr_ic(p_emp text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select count(*)::text from public.spot_inspections where employee_id = %L', p_emp));
end $$;

-- ---------- 本腳本專用工具 ----------

-- 全部「最高等級」的七面向（自動對應舊制或三級制用字）
create or replace function pg_temp.vr_top()
returns jsonb language plpgsql as $$
declare
  w text := case when public.assess_level_pct('優良') is not null then '優良' else '優' end;
begin
  return pg_temp.vr_mk(w, w, w, w, w, w, w);
end $$;

-- 人員抽查狀態：本月黃單／本季紅單（舊欄位，只為確認舊資料仍可讀）／進行中回考核期狀態
create or replace function pg_temp.vr_st(p_emp text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select yellow_month::text || '/' || red_quarter::text || '/' || coalesce(probation_status, '無')
              from public.spot_status() where employee_id = %L$q$, p_emp), true);
end $$;

-- 舊 spot_register（七面向等級版）：客服部身分；成功回 jsonb，失敗回 {"error": "..."}
create or replace function pg_temp.vr_regold(p_emp text, p_verdict text, p_reason text default null)
returns jsonb language plpgsql as $$
declare
  v text;
begin
  v := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
         format($q$select public.spot_register(%L, %L::date, 'https://line.me/R/ti/p/test-1', %L::jsonb, %L, %L)::text$q$,
                p_emp, pg_temp.vr_today()::text, pg_temp.vr_top()::text, p_verdict, p_reason),
         true);
  if v like 'ERROR:%' then return jsonb_build_object('error', v); end if;
  return v::jsonb;
end $$;

-- 直接寫入一張黃單（含它的抽查），以擁有者身分；p_created 決定先後
create or replace function pg_temp.vr_old_y(p_emp text, p_store text, p_issued date, p_created timestamptz)
returns uuid language plpgsql as $$
declare
  v_i uuid;
  v_t uuid;
  v_lv jsonb := pg_temp.vr_top();
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

-- 真實考核流程：客服部 assess_start → assess_draw → assess_save_item，回傳考核 id；失敗丟例外
create or replace function pg_temp.vr_flow(p_emp text, p_override text)
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
           format($q$select item_id::text from public.assess_draw(%L::uuid, array['ZZ分類N'])$q$, v_aid), true);
  if v_r like 'ERROR%' then raise exception 'assess_draw：%', v_r; end if;
  v_item := v_r::uuid;

  v_r := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
           format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '假備註')$q$, v_item, pg_temp.vr_top()::text), false);
  if v_r like 'ERROR%' then raise exception 'assess_save_item：%', v_r; end if;
  return v_aid;
end $$;

create or replace function pg_temp.vr_submit(p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select total_score::text || '/' || verdict || '/' || pass_line::text
              from public.assess_submit(%L::uuid)$q$, p_aid), true);
end $$;

-- 某考核的身分／來源
create or replace function pg_temp.vr_tn(p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format('select tenure || ''/'' || tenure_source from public.assessments where id = %L::uuid', p_aid));
end $$;

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- N1＝ZZ-N1（店長 vr-sm1）、N2＝ZZ-N2（店長 vr-sm2）
-- 9801 新登記連續 6 次待加強  9802 優良回覆  9803 舊登記連續 6 次  9804 作廢與輔導  9805 跨月
-- 9806 既有紅單與已通過的回考核期紀錄（舊資料）  9807 probation_since 有值、正式（舊資料）
-- 9808 probation_since 有值、到職 30 天  9809 新人考核期（period_status）  9810 一般正式
-- 9811 未填到職日  9812 未填到職日且 probation_since 有值（舊資料）  9813 N2 正式
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-N1', 'ZZ測試門市甲'), ('ZZ-N2', 'ZZ測試門市乙');

  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, probation_since)
  values
    ('MI-9801', '假員9801', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9802', '假員9802', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9803', '假員9803', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9804', '假員9804', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9805', '假員9805', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9806', '假員9806', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9807', '假員9807', 'ZZ-N1', '業務', v_today - 200, '在職', true, v_today),
    ('MI-9808', '假員9808', 'ZZ-N1', '業務', v_today - 30,  '在職', true, v_today),
    ('MI-9809', '假員9809', 'ZZ-N1', '業務', v_today - 30,  '在職', true, null),
    ('MI-9810', '假員9810', 'ZZ-N1', '業務', v_today - 200, '在職', true, null),
    ('MI-9811', '假員9811', 'ZZ-N1', '業務', null,          '在職', true, null),
    ('MI-9812', '假員9812', 'ZZ-N1', '業務', null,          '在職', true, v_today),
    ('MI-9813', '假員9813', 'ZZ-N2', '業務', v_today - 200, '在職', true, null);
  update public.employees set period_status = '考核期' where id = 'MI-9809';

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-N1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-N2');
  -- vr-nobody@2motor.tw 刻意不建立帳號（模擬有登入但未開通）

  insert into public.questions (category, code, title, steps) values
    ('ZZ分類N', 'N1', '假題組N1', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類N', 'N2', '假題組N2', '[{"action":"動作1","point":"考點1"}]'::jsonb),
    ('ZZ分類N', 'N3', '假題組N3', '[{"action":"動作1","point":"考點1"}]'::jsonb);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 0：結構（資料表、欄位都還在；函式不再碰紅單與回考核期）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('0 結構','登記函式（新、舊）內文不再碰 spot_probations、不再開紅單、不再設 probation_since','0',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
      where p.oid in ('public.spot_register(text, date, text, jsonb, text, text)'::regprocedure,
                      'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])'::regprocedure)
        and (p.prosrc like '%spot_probations%' or p.prosrc like '%''紅''%' or p.prosrc like '%probation_since = v_today%')$q$));
  perform pg_temp.vr_eq('0 結構','assess_start 不再依 probation_since 改身分','0',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p where p.oid = 'public.assess_start(text, text)'::regprocedure
                       and p.prosrc like '%v_emp.probation_since%'$q$));
  perform pg_temp.vr_eq('0 結構','assess_submit 不再處理 spot_probations','0',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p where p.oid = 'public.assess_submit(uuid)'::regprocedure
                       and p.prosrc like '%spot_probations%'$q$));
  perform pg_temp.vr_eq('0 結構','spot_probations 資料表與 employees.probation_since 欄位都還在（沒有 drop）','有/有',
    pg_temp.vr_q1($q$select case when to_regclass('public.spot_probations') is not null then '有' else '無' end || '/'
                          || case when exists (select 1 from information_schema.columns where table_schema='public'
                                 and table_name='employees' and column_name='probation_since') then '有' else '無' end$q$));
  perform pg_temp.vr_eq('0 結構','舊函式簽名都還在（不 drop）：spot_status／spot_mark_executed／spot_cancel_probation','3',
    pg_temp.vr_q1($q$select count(to_regprocedure(s))::text from unnest(array['public.spot_status()',
      'public.spot_mark_executed(uuid)','public.spot_cancel_probation(uuid, text)']) as s$q$));
  perform pg_temp.vr_eq('0 結構','spot_tickets 仍允許種類「紅」（舊資料相容）','true',
    pg_temp.vr_q1($q$select (pg_get_constraintdef(c.oid) like '%紅%')::text from pg_constraint c
                      where c.conrelid = 'public.spot_tickets'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%kind%' limit 1$q$));
  perform pg_temp.vr_eq('0 結構','登記函式權限：登入者可執行、未登入（anon）不可','true/false/true/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])', 'execute')::text
      || '/' || has_function_privilege('anon', 'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])', 'execute')::text
      || '/' || has_function_privilege('authenticated', 'public.spot_register(text, date, text, jsonb, text, text)', 'execute')::text
      || '/' || has_function_privilege('anon', 'public.spot_register(text, date, text, jsonb, text, text)', 'execute')::text$q$));
end
$$;

-- ============================================================
-- 區段 1：新登記（spot_register_dims）連續 6 次待加強回覆（同月）→ 只有 6 張黃單
-- ============================================================
do $$
declare
  j jsonb;
  i int;
  v_ids text := '';
begin
  for i in 1..6 loop
    j := pg_temp.vr_regd('MI-9801', '不適當', '第' || i || '次原因', array['問題掌握'], null, null, gen_random_uuid());
    v_ids := v_ids || pg_temp.vr_has(j, 'yellow_id') || pg_temp.vr_has(j, 'red_id') || pg_temp.vr_has(j, 'probation_id') || ',';
  end loop;
  perform pg_temp.vr_eq('1 新登記','6 次登記的回傳：每次都有黃單、沒有紅單、沒有回考核期（紅單與回考核期的鍵仍在、值為 null）',
    '有無無,有無無,有無無,有無無,有無無,有無無,', v_ids);
  perform pg_temp.vr_eq('1 新登記','6 次後：黃單 6 張（有效）','6', pg_temp.vr_tc('MI-9801', '黃'));
  perform pg_temp.vr_eq('1 新登記','6 次後：紅單 0 張（含作廢）','0/0', pg_temp.vr_tc('MI-9801', '紅') || '/' || pg_temp.vr_tc('MI-9801', '紅', '作廢'));
  perform pg_temp.vr_eq('1 新登記','6 次後：回考核期紀錄 0 筆','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_probations where employee_id = 'MI-9801'$q$));
  perform pg_temp.vr_eq('1 新登記','6 次後：probation_since 仍為空、period_status 仍是已上線','(null)/已上線',
    pg_temp.vr_q1($q$select coalesce(probation_since::text, '(null)') || '/' || period_status from public.employees where id = 'MI-9801'$q$));
  perform pg_temp.vr_eq('1 新登記','6 次後：抽查紀錄 6 筆','6', pg_temp.vr_ic('MI-9801'));
  perform pg_temp.vr_eq('1 新登記','6 次後仍可繼續抽查（沒有被拉回考核期）：第 7 次成功並開第 7 張黃單','OK/7',
    pg_temp.vr_regd_t('MI-9801', '不適當', '第7次原因', array['問題掌握'], null, null, gen_random_uuid()) || '/' || pg_temp.vr_tc('MI-9801', '黃'));
  perform pg_temp.vr_eq('1 新登記','人員抽查狀態：本月黃單 7 張、沒有進行中的回考核期','7/0/無', pg_temp.vr_st('MI-9801'));
  perform pg_temp.vr_eq('1 新登記','黃單原因與抽查連結照常寫入','第1次原因/true',
    pg_temp.vr_q1($q$select (select reason from public.spot_tickets where employee_id = 'MI-9801' and kind = '黃' order by created_at limit 1)
                          || '/' || (select bool_and(inspection_id is not null)::text from public.spot_tickets where employee_id = 'MI-9801')$q$));
end
$$;

-- ============================================================
-- 區段 2：優良回覆不開黃單；待加強回覆必填原因（照舊）
-- ============================================================
do $$
declare
  j jsonb;
begin
  j := pg_temp.vr_regd('MI-9802', '適當', null, array['問題掌握', '風險意識'], '很好', null, gen_random_uuid());
  perform pg_temp.vr_eq('2 優良','優良回覆：不開黃單、沒有紅單與回考核期','無/無/無',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  j := pg_temp.vr_regd('MI-9802', '適當', null, null, null, null, gen_random_uuid());
  j := pg_temp.vr_regd('MI-9802', '適當', null, null, null, null, gen_random_uuid());
  perform pg_temp.vr_eq('2 優良','連續 3 次優良回覆：抽查 3 筆、黃單 0、紅單 0、回考核期 0','3/0/0/0',
    pg_temp.vr_ic('MI-9802') || '/' || pg_temp.vr_tc('MI-9802', '黃') || '/' || pg_temp.vr_tc('MI-9802', '紅') ||
    '/' || pg_temp.vr_q1($q$select count(*)::text from public.spot_probations where employee_id = 'MI-9802'$q$));
  perform pg_temp.vr_eq('2 優良','待加強回覆沒寫原因：照舊被擋','ERROR: 判定待加強回覆時，原因不可空白',
    pg_temp.vr_regd_t('MI-9802', '不適當', '', null, null, null, gen_random_uuid()));
  perform pg_temp.vr_eq('2 優良','被擋之後沒有留下抽查或黃單','3/0', pg_temp.vr_ic('MI-9802') || '/' || pg_temp.vr_tc('MI-9802', '黃'));
  perform pg_temp.vr_eq('2 優良','人員抽查狀態：優良回覆的人本月黃單 0','0/0/無', pg_temp.vr_st('MI-9802'));
  perform pg_temp.vr_denyset('2 優良', '登記', format($q$select public.spot_register_dims(null, 'MI-9802', %L::date, 'https://line.me/R/ti/p/test-1', '適當', null, null, null, null)$q$, pg_temp.vr_today()::text), 'hsna');
end
$$;

-- ============================================================
-- 區段 3：舊登記 spot_register（七面向等級版）也不再開紅單與回考核期
-- ============================================================
do $$
declare
  j jsonb;
  i int;
  v_ids text := '';
begin
  for i in 1..6 loop
    j := pg_temp.vr_regold('MI-9803', '不適當', '舊路徑原因' || i);
    v_ids := v_ids || pg_temp.vr_has(j, 'yellow_id') || pg_temp.vr_has(j, 'red_id') || pg_temp.vr_has(j, 'probation_id') || ',';
  end loop;
  perform pg_temp.vr_eq('3 舊登記','舊 spot_register 6 次：每次只有黃單', '有無無,有無無,有無無,有無無,有無無,有無無,', v_ids);
  perform pg_temp.vr_eq('3 舊登記','6 次後：黃單 6、紅單 0、回考核期 0、probation_since 為空','6/0/0/(null)',
    pg_temp.vr_tc('MI-9803', '黃') || '/' || pg_temp.vr_tc('MI-9803', '紅') ||
    '/' || pg_temp.vr_q1($q$select count(*)::text from public.spot_probations where employee_id = 'MI-9803'$q$) ||
    '/' || pg_temp.vr_q1($q$select coalesce(probation_since::text, '(null)') from public.employees where id = 'MI-9803'$q$));
  perform pg_temp.vr_eq('3 舊登記','舊登記優良回覆：不開黃單','無',
    pg_temp.vr_has(pg_temp.vr_regold('MI-9803', '適當', null), 'yellow_id'));
  perform pg_temp.vr_eq('3 舊登記','舊登記的回傳仍帶 total_score（舊網頁相容）','有',
    pg_temp.vr_has(pg_temp.vr_regold('MI-9803', '適當', null), 'total_score'));
end
$$;

-- ============================================================
-- 區段 4：黃單作廢、店長輔導回填照常；跨月不算本月
-- ============================================================
do $$
declare
  t1 uuid; t2 uuid; t3 uuid;
  v_cs text := 'vr-cs1@2motor.tw';
  y_old uuid;
begin
  perform pg_temp.vr_regd('MI-9804', '不適當', 'A', null, null, null, gen_random_uuid());
  perform pg_temp.vr_regd('MI-9804', '不適當', 'B', null, null, null, gen_random_uuid());
  perform pg_temp.vr_regd('MI-9804', '不適當', 'C', null, null, null, gen_random_uuid());
  select id into t1 from public.spot_tickets where employee_id = 'MI-9804' and reason = 'A';
  select id into t2 from public.spot_tickets where employee_id = 'MI-9804' and reason = 'B';
  select id into t3 from public.spot_tickets where employee_id = 'MI-9804' and reason = 'C';

  perform pg_temp.vr_eq('4 作廢輔導','登記 3 次：人員抽查狀態本月黃單 3','3/0/無', pg_temp.vr_st('MI-9804'));
  perform pg_temp.vr_deny('4 作廢輔導','作廢原因必填','authenticated', v_cs,
    format($q$select public.spot_void_ticket(%L::uuid, '  ')$q$, t1), '%原因%');
  perform pg_temp.vr_ok('4 作廢輔導','客服部作廢一張黃單（寫原因）', v_cs, format($q$select public.spot_void_ticket(%L::uuid, '評錯了')$q$, t1));
  perform pg_temp.vr_eq('4 作廢輔導','作廢後：該單狀態作廢、原因與作廢人都在、單據沒被刪','作廢/評錯了/true',
    pg_temp.vr_q1(format($q$select status || '/' || void_reason || '/' || (voided_by is not null)::text from public.spot_tickets where id = %L::uuid$q$, t1)));
  perform pg_temp.vr_eq('4 作廢輔導','作廢後本月黃單少算 1 張（3 變 2）','2/0/無', pg_temp.vr_st('MI-9804'));
  perform pg_temp.vr_deny('4 作廢輔導','已作廢的單不能再作廢','authenticated', v_cs,
    format($q$select public.spot_void_ticket(%L::uuid, '再作廢')$q$, t1), '%作廢%');
  perform pg_temp.vr_denyset('4 作廢輔導', '作廢', format($q$select public.spot_void_ticket(%L::uuid, '亂作廢')$q$, t2), 'hsna');

  perform pg_temp.vr_ok('4 作廢輔導','本店店長可回填輔導（日期＋備註）', 'vr-sm1@2motor.tw',
    format($q$select public.spot_coach(%L::uuid, %L::date, '已當面提醒')$q$, t2, pg_temp.vr_today()::text));
  perform pg_temp.vr_eq('4 作廢輔導','輔導回填內容寫入','已當面提醒/vr-sm1@2motor.tw',
    pg_temp.vr_q1(format('select coach_note || ''/'' || coached_by from public.spot_tickets where id = %L::uuid', t2)));
  perform pg_temp.vr_deny('4 作廢輔導','別間門市店長不能回填','authenticated', 'vr-sm2@2motor.tw',
    format($q$select public.spot_coach(%L::uuid, %L::date, '越權')$q$, t3, pg_temp.vr_today()::text), '%');
  perform pg_temp.vr_deny('4 作廢輔導','總公司主管不能回填','authenticated', 'vr-hq@2motor.tw',
    format($q$select public.spot_coach(%L::uuid, %L::date, '越權')$q$, t3, pg_temp.vr_today()::text), '%');
  perform pg_temp.vr_deny('4 作廢輔導','輔導備註必填','authenticated', v_cs,
    format($q$select public.spot_coach(%L::uuid, %L::date, '')$q$, t3, pg_temp.vr_today()::text), '%');
  perform pg_temp.vr_deny('4 作廢輔導','已作廢的單不能回填輔導','authenticated', v_cs,
    format($q$select public.spot_coach(%L::uuid, %L::date, '補填')$q$, t1, pg_temp.vr_today()::text), '%');

  -- 跨月：上個月的黃單不算本月
  y_old := pg_temp.vr_old_y('MI-9805', 'ZZ-N1', (date_trunc('month', pg_temp.vr_today()::timestamp) - interval '1 day')::date, now() - interval '40 days');
  perform pg_temp.vr_regd('MI-9805', '不適當', '本月', null, null, null, gen_random_uuid());
  perform pg_temp.vr_eq('4 作廢輔導','上個月 1 張＋本月 1 張：本月黃單只算 1','1/0/無', pg_temp.vr_st('MI-9805'));
end
$$;

-- ============================================================
-- 區段 5：既有紅單、回考核期紀錄（舊資料）仍可讀、不影響新登記
-- ============================================================
do $$
declare
  v_cs text := 'vr-cs1@2motor.tw';
  v_today date := pg_temp.vr_today();
  y1 uuid; y2 uuid; y3 uuid; r1 uuid;
  v_proc uuid;
begin
  y1 := pg_temp.vr_old_y('MI-9806', 'ZZ-N1', v_today, now() - interval '3 hours');
  y2 := pg_temp.vr_old_y('MI-9806', 'ZZ-N1', v_today, now() - interval '2 hours');
  insert into public.spot_tickets (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on, created_at)
  values ('紅', 'MI-9806', '假員9806', 'ZZ-N1', array[y1, y2], '舊紅單', v_today, now() - interval '1 hour')
  returning id into r1;
  y3 := pg_temp.vr_old_y('MI-9806', 'ZZ-N1', v_today, now() - interval '30 minutes');
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status, created_at)
  values ('MI-9806', '假員9806', 'ZZ-N1', array[r1], v_today - 10, '已通過', now() - interval '5 hours')
  returning id into v_proc;

  perform pg_temp.vr_eq('5 舊資料','客服部讀得到舊紅單','1',
    pg_temp.vr_as('authenticated', v_cs, $q$select count(*)::text from public.spot_tickets where employee_id = 'MI-9806' and kind = '紅'$q$, true));
  perform pg_temp.vr_eq('5 舊資料','總公司主管讀得到舊紅單','1',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', $q$select count(*)::text from public.spot_tickets where employee_id = 'MI-9806' and kind = '紅'$q$, true));
  perform pg_temp.vr_eq('5 舊資料','本店店長讀得到舊紅單、別間門市店長看不到','1/0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select count(*)::text from public.spot_tickets where employee_id = 'MI-9806' and kind = '紅'$q$, true)
    || '/' || pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', $q$select count(*)::text from public.spot_tickets where employee_id = 'MI-9806' and kind = '紅'$q$, true));
  perform pg_temp.vr_eq('5 舊資料','客服部讀得到舊回考核期紀錄（已通過）','已通過',
    pg_temp.vr_as('authenticated', v_cs, $q$select status from public.spot_probations where employee_id = 'MI-9806'$q$, true));
  perform pg_temp.vr_eq('5 舊資料','spot_status 不報錯：本月黃單 3（不再以紅單切段）／舊欄位本季紅單仍讀得到 1／沒有進行中回考核期','3/1/無',
    pg_temp.vr_st('MI-9806'));
  perform pg_temp.vr_eq('5 舊資料','有舊紅單的人再登記待加強回覆：只開黃單，不再開紅單','OK/4/1/0',
    pg_temp.vr_regd_t('MI-9806', '不適當', '新黃單', null, null, null, gen_random_uuid()) || '/' || pg_temp.vr_tc('MI-9806', '黃') ||
    '/' || pg_temp.vr_tc('MI-9806', '紅') ||
    '/' || pg_temp.vr_q1($q$select count(*)::text from public.spot_probations where employee_id = 'MI-9806' and status in ('待執行', '已執行')$q$));
  perform pg_temp.vr_eq('5 舊資料','舊紅單可照舊作廢','OK/作廢',
    pg_temp.vr_as('authenticated', v_cs, format($q$select public.spot_void_ticket(%L::uuid, '舊紅單作廢')$q$, r1), false)
    || '/' || pg_temp.vr_q1(format('select status from public.spot_tickets where id = %L::uuid', r1)));
  perform pg_temp.vr_eq('5 舊資料','舊紅單、舊回考核期紀錄都沒有被刪','1/1',
    pg_temp.vr_q1($q$select (select count(*)::text from public.spot_tickets where employee_id = 'MI-9806' and kind = '紅')
                         || '/' || (select count(*)::text from public.spot_probations where employee_id = 'MI-9806')$q$));
end
$$;

-- ============================================================
-- 區段 6：考核流程不再有「回考核期」身分（assess_start／assess_submit）
-- ============================================================
do $$
declare
  v_cs text := 'vr-cs1@2motor.tw';
  v_today date := pg_temp.vr_today();
  a uuid;
  v_r text;
begin
  -- 舊資料：probation_since 有值的人，身分只看到職日
  a := pg_temp.vr_flow('MI-9807', null);
  perform pg_temp.vr_eq('6 考核','probation_since 有值、到職滿 200 天：身分「正式」、來源「自動」（不再是「考核期」）','正式/自動', pg_temp.vr_tn(a));
  a := pg_temp.vr_flow('MI-9808', null);
  perform pg_temp.vr_eq('6 考核','probation_since 有值、到職 30 天：身分「新人」、來源「自動」（不再被改成正式）','新人/自動', pg_temp.vr_tn(a));
  perform pg_temp.vr_eq('6 考核','probation_since 有值、未填到職日：不再被豁免，必須手動指定','ERROR: 到職日空白，請手動指定「新人」或「正式」',
    pg_temp.vr_as('authenticated', v_cs, $q$select public.assess_start('MI-9812', null)::text$q$, true));
  perform pg_temp.vr_eq('6 考核','probation_since 有值、未填到職日、手動指定正式：來源「手動指定」','正式/手動指定',
    pg_temp.vr_tn(pg_temp.vr_as('authenticated', v_cs, $q$select public.assess_start('MI-9812', '正式')::text$q$, true)::uuid));

  -- 既有行為不變
  perform pg_temp.vr_eq('6 既有','一般正式員工：assess_start 仍是「正式／自動」','正式/自動',
    pg_temp.vr_tn(pg_temp.vr_as('authenticated', v_cs, $q$select public.assess_start('MI-9810', null)::text$q$, true)::uuid));
  perform pg_temp.vr_eq('6 既有','新人考核期（period_status）：身分「新人」、來源「自動」','新人/自動',
    pg_temp.vr_tn(pg_temp.vr_as('authenticated', v_cs, $q$select public.assess_start('MI-9809', null)::text$q$, true)::uuid));
  perform pg_temp.vr_eq('6 既有','未填到職日、沒有指定：照舊被擋','ERROR: 到職日空白，請手動指定「新人」或「正式」',
    pg_temp.vr_as('authenticated', v_cs, $q$select public.assess_start('MI-9811', null)::text$q$, true));
  perform pg_temp.vr_eq('6 既有','未填到職日、指定新人：來源「手動指定」','新人/手動指定',
    pg_temp.vr_tn(pg_temp.vr_as('authenticated', v_cs, $q$select public.assess_start('MI-9811', '新人')::text$q$, true)::uuid));
  perform pg_temp.vr_denyset('6 既有','assess_start', $q$select public.assess_start('MI-9810', null)$q$, 'hsna');
end
$$;

do $$
declare
  v_cs text := 'vr-cs1@2motor.tw';
  v_today date := pg_temp.vr_today();
  a uuid;
begin
  -- 舊資料：9807 仍有一筆進行中的回考核期紀錄與 probation_since；偽造一張舊的「考核期」成績單草稿（模擬停用前開的草稿）
  insert into public.spot_probations (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
  values ('MI-9807', '假員9807', 'ZZ-N1', '{}'::uuid[], v_today, '待執行');
  select id into a from public.assessments where employee_id = 'MI-9807' and status = 'draft' and examiner_email = v_cs;
  update public.assessments set tenure = '正式', tenure_source = '考核期' where id = a;

  perform pg_temp.vr_eq('6 考核','舊「考核期」草稿送出滿分：成績單照常送出（不報錯）','100.0/優秀/85', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('6 考核','送出後 probation_since 不再被清除','true',
    pg_temp.vr_q1($q$select (probation_since is not null)::text from public.employees where id = 'MI-9807'$q$));
  perform pg_temp.vr_eq('6 考核','送出後回考核期紀錄不再被改成「已通過」（仍是待執行）','待執行',
    pg_temp.vr_q1($q$select status from public.spot_probations where employee_id = 'MI-9807'$q$));
  perform pg_temp.vr_eq('6 考核','送出後不新增待開通','0',
    pg_temp.vr_q1($q$select count(*)::text from public.reply_activations where employee_id = 'MI-9807'$q$));
  perform pg_temp.vr_eq('6 舊資料','舊成績單的「考核期」標記仍可讀（成績單檢視帶出來源）','考核期/正式',
    pg_temp.vr_as('authenticated', v_cs, format($q$select tenure_source || '/' || tenure from public.assessment_summaries where id = %L::uuid$q$, a), true));
end
$$;

do $$
declare
  v_cs text := 'vr-cs1@2motor.tw';
  a uuid;
begin
  -- 既有行為：新人考核期通過（70 分）轉已上線、記通過日、新增待開通
  a := pg_temp.vr_flow('MI-9809', null);
  perform pg_temp.vr_eq('6 既有','新人（考核期）送出滿分：判定優秀、合格線 70','100.0/優秀/70', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('6 既有','新人通過：period_status 轉已上線、記通過日','已上線/true',
    pg_temp.vr_q1($q$select period_status || '/' || (passed_on is not null)::text from public.employees where id = 'MI-9809'$q$));
  perform pg_temp.vr_eq('6 既有','新人通過：新增 1 筆待開通','1/待開通',
    pg_temp.vr_q1($q$select count(*)::text || '/' || min(status) from public.reply_activations where employee_id = 'MI-9809'$q$));
  -- 一般正式員工送出：不處理考核期，也不動 employees
  a := pg_temp.vr_flow('MI-9810', null);
  perform pg_temp.vr_eq('6 既有','一般正式員工送出滿分：判定優秀、合格線 85','100.0/優秀/85', pg_temp.vr_submit(a));
  perform pg_temp.vr_eq('6 既有','一般正式員工送出：不新增待開通、period_status 不變','0/已上線',
    pg_temp.vr_q1($q$select (select count(*)::text from public.reply_activations where employee_id = 'MI-9810')
                          || '/' || (select period_status from public.employees where id = 'MI-9810')$q$));
end
$$;

-- ============================================================
-- 區段 7：待考回報不能再以「回考核期」回報；舊的「回考核期」回報仍可讀
-- ============================================================
do $$
declare
  v_today date := pg_temp.vr_today();
begin
  insert into public.exam_requests
    (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates, status)
  values
    ('回考核期', 'MI-9806', '假員9806', 'ZZ-N1', 'vr-sm1@2motor.tw', '店長', array[v_today + 3], '待處理');

  perform pg_temp.vr_eq('7 待考回報','舊的「回考核期」回報：客服部讀得到','1',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw', $q$select count(*)::text from public.exam_requests where kind = '回考核期' and employee_id = 'MI-9806'$q$, true));
  perform pg_temp.vr_eq('7 待考回報','舊的「回考核期」回報：本店店長讀得到、別間門市店長看不到','1/0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', $q$select count(*)::text from public.exam_requests where kind = '回考核期' and employee_id = 'MI-9806'$q$, true)
    || '/' || pg_temp.vr_as('authenticated', 'vr-sm2@2motor.tw', $q$select count(*)::text from public.exam_requests where kind = '回考核期' and employee_id = 'MI-9806'$q$, true));
  perform pg_temp.vr_deny('7 待考回報','店長不能再新增「回考核期」回報（人員不在考核期）','authenticated', 'vr-sm1@2motor.tw',
    format($q$select public.exam_req_create('回考核期', 'MI-9810', array[%L::date], null, null)$q$, (v_today + 2)::text), '%不在考核期%');
  perform pg_temp.vr_deny('7 待考回報','客服部也不能再新增「回考核期」回報','authenticated', 'vr-cs1@2motor.tw',
    format($q$select public.exam_req_create('回考核期', 'MI-9810', array[%L::date], null, null)$q$, (v_today + 2)::text), '%不在考核期%');
  perform pg_temp.vr_eq('7 待考回報','「回考核期」候選名單是空的（沒有人在回考核期）','0',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw', $q$select count(*)::text from public.exam_req_candidates('回考核期') where employee_id in ('MI-9801','MI-9802','MI-9803','MI-9804','MI-9805','MI-9806','MI-9810')$q$, true));
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
    execute 'deallocate noredticket_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare noredticket_vr_out as select * from (values (0, '
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
    execute 'deallocate noredticket_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare noredticket_vr_out as select '
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
execute noredticket_vr_out;
