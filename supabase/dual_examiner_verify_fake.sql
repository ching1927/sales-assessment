-- ============================================================
-- 業務考核系統：雙考官輪流考核（第一段：資料模型＋抽籤＋抽題）驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 dual_examiner_schema.sql 第一段）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-ex1、vr-ex2＝假考官，vr-cs3＝不在名單的客服部，vr-hq、vr-sm1），
--   把「考官名單」在交易內暫時換成兩位假考官（若已套用本機種子名單，真實考官在交易內暫時停用，rollback 後原樣還原），
--   用 set_config('request.jwt.claims', …) ＋ set local role 模擬各角色登入，真的呼叫 assess_start_dual、assess_my_drafts、
--   assess_draw、assess_pick、assess_start，把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果就是「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；
--   「通過」欄全是「通過」才算驗證成功。若畫面出現兩張一樣的表，看最後一張即可。
-- 驗證重點：抽題配額 3/2/1 與負責考官（基礎→1、進階與綜合→2）、同場題目不重複（含跨新輪）、抽籤兩種結果都出現、
--   鎖定、重複開考回傳既有草稿、題庫不足整體回復、非考官被拒、舊單人草稿衝突被拒、assess_draw／assess_pick 對雙考官草稿被拒、
--   assess_my_drafts 內容與權限、RLS、健檢與舊單人流程行為不變。
-- 【第二段（DB-2）驗證：區段 11～16；需先執行過 dual_examiner_schema.sql 的第二段】
--   擁有者改寫：他人題組不可寫、已交卷不可寫、自己題組可寫並更新 last_saved_at（評分／備註／面向備註／附圖）、
--   storage policy（insert／delete）、放棄各情境（考官A、考官B、第三位客服部、已有人交卷被拒、單人草稿不變）、
--   雙考官追加題被拒、舊 assess_start 守衛、單人／健檢／新人流程逐項不變。
--   假員工另外用到 MI-9934～MI-9940。
-- 【第三段（DB-3）驗證：區段 17～23；需先執行過 dual_examiner_schema.sql 的第三段】
--   各自交卷、撤回、完成收尾：單方交卷不完成、對方未交顯示 waiting_for_slot、雙方交卷才完成且只有一張成績單、
--   評分不完整被拒、撤回後可再改再交、完成後不可撤回／不可再存／不可放棄、新人通過轉已上線與待開通、新人備註把關整筆回復、
--   改善單與待考回報觸發器照常觸發（與單人對照）、非考官與單人／健檢草稿不可用雙考官交卷、單人 assess_submit 薄包裝行為不變。
--   假員工另外用到 MI-9956～MI-9966。
-- 假門市代碼 ZZ-D1／ZZ-D2、假員工編號 MI-9901～MI-9955、假信箱 vr-ex1／vr-ex2／vr-cs3／vr-hq／vr-sm1／vr-nobody@2motor.tw、
--   假題組分類「ZZ分類D」；若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
--   另外會在交易內暫時改 app_settings 的 exam_dual_quota 與題庫抽選狀態（drawn、category_last），rollback 後還原。
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


-- 組出七面向評分物件（三級制：優良／尚可／待加強）
create or replace function pg_temp.vr_top()
returns jsonb language sql immutable as $$
  select jsonb_build_object('資訊正確性', '優良', '預設訊息運用', '優良', '問題掌握', '優良', '主動引導', '優良',
                            '風險意識', '優良', '語氣與禮貌', '優良', '文字品質', '優良');
$$;

-- ---------- 本腳本專用工具 ----------
-- 開考（雙考官）：回傳 jsonb；失敗回 {"error": "..."}
create or replace function pg_temp.vr_sd(p_email text, p_emp text, p_override text default null)
returns jsonb language plpgsql as $$
declare
  v text;
begin
  v := pg_temp.vr_as('authenticated', p_email,
         format($q$select public.assess_start_dual(%L, %L)::text$q$, p_emp, p_override), true);
  if v like 'ERROR:%' then
    return jsonb_build_object('error', v);
  end if;
  return v::jsonb;
end $$;

-- 以客服身分執行單一值查詢（authenticated）
create or replace function pg_temp.vr_cs(p_email text, p_sql text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email, p_sql, true);
end $$;

-- 文字是否符合 like 樣式 → 'true'／'false'
create or replace function pg_temp.vr_lk(p_text text, p_pattern text)
returns text language sql as $$
  select (coalesce(p_text, '') like p_pattern)::text;
$$;

-- 某場雙考官的快照字串：題組數(基礎/進階/綜合)
create or replace function pg_temp.vr_cnt321(p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_q1(format($q$select count(*) filter (where category = '基礎')::text || '/'
        || count(*) filter (where category = '進階')::text || '/' || count(*) filter (where category = '綜合')::text
        from public.assessment_items where assessment_id = %L::uuid$q$, p_aid));
end $$;

-- 舊式單人流程完整走一次（員工已由 vr-cs3 開好草稿）：draw 一個分類→pick 另一分類→各存滿分→送出；回傳總分
create or replace function pg_temp.vr_legacy_full(p_emp text)
returns text language plpgsql as $$
declare
  v_aid uuid := (select id from public.assessments where employee_id = p_emp and status = 'draft' and not is_dual and kind = 'exam');
  v_q bigint := (select min(id) from public.questions where category = '基礎' and code like 'ZDB%');
  v_r text;
  r record;
begin
  v_r := pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select count(*)::text from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, v_aid));
  if v_r like 'ERROR%' then return v_r; end if;
  v_r := pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s::bigint])$q$, v_aid, v_q));
  if v_r like 'ERROR%' then return v_r; end if;
  for r in select id from public.assessment_items where assessment_id = v_aid loop
    v_r := pg_temp.vr_as('authenticated', 'vr-cs3@2motor.tw',
             format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註')::text$q$, r.id, pg_temp.vr_top()::text), true);
    if v_r like 'ERROR%' then return v_r; end if;
  end loop;
  return pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select total_score::text from public.assess_submit(%L::uuid)$q$, v_aid));
end $$;

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  i int;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values ('ZZ-D1', 'ZZ測試門市丁'), ('ZZ-D2', 'ZZ測試門市戊');

  -- MI-9901～9940：一般正式員工（到職 200 天）
  for i in 9901..9940 loop
    insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
    values ('MI-' || i, '假員' || i, 'ZZ-D1', '業務', v_today - 200, '在職', true);
  end loop;
  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment) values
    ('MI-9941', '假員9941', 'ZZ-D1', '業務', v_today - 30,  '在職', true),    -- 新人（到職 30 天）
    ('MI-9942', '假員9942', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 考核期（period_status）
    ('MI-9943', '假員9943', 'ZZ-D1', '業務', null,          '在職', true),    -- 未填到職日
    ('MI-9944', '假員9944', 'ZZ-D1', '業務', v_today - 200, '在職', false),   -- 不納入考核
    ('MI-9945', '假員9945', 'ZZ-D1', '業務', v_today - 200, '離職', true),    -- 離職
    ('MI-9946', '假員9946', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 舊單人草稿（別人開）
    ('MI-9947', '假員9947', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 舊單人草稿（考官本人開）
    ('MI-9948', '假員9948', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 健檢草稿＋雙考官
    ('MI-9949', '假員9949', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 題庫不足與配額設定
    ('MI-9950', '假員9950', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 跨新輪不重複
    ('MI-9951', '假員9951', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 名單設定錯誤
    ('MI-9952', '假員9952', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 名單設定錯誤（還原後成功）
    ('MI-9953', '假員9953', 'ZZ-D2', '業務', v_today - 200, '在職', true),    -- 連帶刪除
    ('MI-9954', '假員9954', 'ZZ-D1', '業務', v_today - 200, '在職', true),    -- 健檢草稿＋舊開考
    ('MI-9955', '假員9955', 'ZZ-D1', '業務', v_today - 200, '在職', true);    -- 舊單人流程回歸
  update public.employees set period_status = '考核期' where id = 'MI-9942';

  insert into public.app_users (email, role, store_code) values
    ('vr-ex1@2motor.tw', 'cs_admin',      null),
    ('vr-ex2@2motor.tw', 'cs_admin',      null),
    ('vr-cs3@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-D1');
  -- vr-nobody@2motor.tw 刻意不建立帳號（模擬有登入但未開通）

  -- 考官名單：若已有真實名單，在交易內暫時停用，換成兩位假考官（rollback 後原樣還原）
  update public.assess_examiner_pool set active = false;
  insert into public.assess_examiner_pool (email, display_name, active) values
    ('vr-ex1@2motor.tw', 'VX1', true),
    ('vr-ex2@2motor.tw', 'VX2', true);

  -- 假題組（基礎 8、進階 6、綜合 4、舊流程用 ZZ分類D 3）
  for i in 1..8 loop
    insert into public.questions (category, code, title, steps)
    values ('基礎', 'ZDB' || i, '假基礎題' || i, '[{"action":"動作1","point":"考點1"}]'::jsonb);
  end loop;
  for i in 1..6 loop
    insert into public.questions (category, code, title, steps)
    values ('進階', 'ZDA' || i, '假進階題' || i, '[{"action":"動作1","point":"考點1"}]'::jsonb);
  end loop;
  for i in 1..4 loop
    insert into public.questions (category, code, title, steps)
    values ('綜合', 'ZDC' || i, '假綜合題' || i, '[{"action":"動作1","point":"考點1"}]'::jsonb);
  end loop;
  for i in 1..3 loop
    insert into public.questions (category, code, title, steps)
    values ('ZZ分類D', 'ZDD' || i, '假舊流程題' || i, '[{"action":"動作1","point":"考點1"}]'::jsonb);
  end loop;

  -- 配額固定為預設 3/2/1（真實資料若被改過，這裡在交易內還原成預設）
  insert into public.app_settings (key, value) values ('exam_dual_quota', '{"基礎":3,"進階":2,"綜合":1}')
  on conflict (key) do update set value = excluded.value;
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 0：結構
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('0 結構','assessments 新欄位：is_dual boolean not null 預設 false、slot1_name、slot2_name','boolean/NO/false/text/text',
    pg_temp.vr_q1($q$select (select data_type || '/' || is_nullable || '/' || regexp_replace(column_default, '::.*$', '') from information_schema.columns where table_schema='public' and table_name='assessments' and column_name='is_dual')
      || '/' || (select data_type from information_schema.columns where table_schema='public' and table_name='assessments' and column_name='slot1_name')
      || '/' || (select data_type from information_schema.columns where table_schema='public' and table_name='assessments' and column_name='slot2_name')$q$));
  perform pg_temp.vr_eq('0 結構','assessment_items.examiner_slot smallint 可為空','smallint/YES',
    pg_temp.vr_q1($q$select data_type || '/' || is_nullable from information_schema.columns where table_schema='public' and table_name='assessment_items' and column_name='examiner_slot'$q$));
  perform pg_temp.vr_eq('0 結構','assessments_dual_kind 約束存在','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_constraint where conrelid='public.assessments'::regclass and conname='assessments_dual_kind'$q$));
  perform pg_temp.vr_eq('0 結構','新唯一索引：(employee_id) where draft 且 exam 且 is_dual','true',
    pg_temp.vr_q1($q$select (indexdef like '%UNIQUE%' and indexdef like '%(employee_id)%' and indexdef like '%is_dual%' and indexdef like '%draft%' and indexdef like '%exam%')::text
      from pg_indexes where schemaname='public' and indexname='assessments_one_dual_draft_per_employee'$q$));
  perform pg_temp.vr_eq('0 結構','assessment_items_one_core_per_category 加上 examiner_slot is null 條件','true',
    pg_temp.vr_q1($q$select (indexdef like '%UNIQUE%' and indexdef like '%examiner_slot IS NULL%' and indexdef like '%is_extra%')::text
      from pg_indexes where schemaname='public' and indexname='assessment_items_one_core_per_category'$q$));
  perform pg_temp.vr_eq('0 結構','舊單人草稿索引 assessments_one_draft_per_pair 沒被動（仍管 kind=exam）','true',
    pg_temp.vr_q1($q$select (indexdef like '%examiner_email, employee_id%' and indexdef like '%kind%' and indexdef not like '%is_dual%')::text
      from pg_indexes where schemaname='public' and indexname='assessments_one_draft_per_pair'$q$));
  perform pg_temp.vr_eq('0 結構','assessment_examiners 與 assess_examiner_pool 都存在且啟用 RLS','true/true',
    pg_temp.vr_q1($q$select (select relrowsecurity::text from pg_class where oid='public.assessment_examiners'::regclass)
      || '/' || (select relrowsecurity::text from pg_class where oid='public.assess_examiner_pool'::regclass)$q$));
  perform pg_temp.vr_eq('0 結構','考官名單表內有本腳本自建的兩位假考官（schema 本身不含任何名單資料）','VX1,VX2',
    pg_temp.vr_q1($q$select string_agg(display_name, ',' order by display_name) from public.assess_examiner_pool where email in ('vr-ex1@2motor.tw','vr-ex2@2motor.tw')$q$));
  perform pg_temp.vr_eq('0 結構','app_settings 有 exam_dual_quota','1',
    pg_temp.vr_q1($q$select count(*)::text from public.app_settings where key='exam_dual_quota'$q$));
  perform pg_temp.vr_eq('0 結構','assess_start_dual 簽名只有員工編號與新人／正式指定（前端沒有任何抽籤參數）','2/p_employee_id,p_tenure_override',
    pg_temp.vr_q1($q$select p.pronargs::text || '/' || array_to_string(p.proargnames, ',') from pg_proc p where p.oid='public.assess_start_dual(text, text)'::regprocedure$q$));
  perform pg_temp.vr_eq('0 結構','assess_start 簽名、回傳、security definer 沒被動（第二段只多一道雙考官守衛，守衛在區段 11、16 驗證）','2/uuid/true',
    pg_temp.vr_q1($q$select p.pronargs::text || '/' || pg_get_function_result(p.oid) || '/' || p.prosecdef::text from pg_proc p where p.oid='public.assess_start(text, text)'::regprocedure$q$));
  perform pg_temp.vr_eq('0 結構','assess_draw、assess_pick 都有雙考官守衛','2',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p where p.oid in ('public.assess_draw(uuid, text[])'::regprocedure,'public.assess_pick(uuid, bigint[])'::regprocedure) and p.prosrc like '%v_a.is_dual%'$q$));
  perform pg_temp.vr_eq('0 結構','assess_draw、assess_pick 簽名、回傳型別、security definer、search_path 不變','true/true/true/true',
    pg_temp.vr_q1($q$select (select (pg_get_function_result(p.oid) = 'TABLE(item_id uuid, category text, code text, title text, steps jsonb, repeated boolean, new_round boolean)')::text from pg_proc p where p.oid='public.assess_draw(uuid, text[])'::regprocedure)
      || '/' || (select (pg_get_function_result(p.oid) = 'TABLE(item_id uuid, category text, code text, title text, steps jsonb, repeated boolean, new_round boolean)')::text from pg_proc p where p.oid='public.assess_pick(uuid, bigint[])'::regprocedure)
      || '/' || (select (bool_and(p.prosecdef))::text from pg_proc p where p.oid in ('public.assess_draw(uuid, text[])'::regprocedure,'public.assess_pick(uuid, bigint[])'::regprocedure))
      || '/' || (select (bool_and(p.proconfig::text like '%search_path=public, pg_temp%'))::text from pg_proc p where p.oid in ('public.assess_draw(uuid, text[])'::regprocedure,'public.assess_pick(uuid, bigint[])'::regprocedure))$q$));
  perform pg_temp.vr_eq('0 結構','函式權限：start_dual／my_drafts／draw／pick 登入者可執行、anon 不可','true/false/true/false/true/false/true/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated','public.assess_start_dual(text, text)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_start_dual(text, text)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_my_drafts()','execute')::text
      || '/' || has_function_privilege('anon','public.assess_my_drafts()','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_draw(uuid, text[])','execute')::text
      || '/' || has_function_privilege('anon','public.assess_draw(uuid, text[])','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_pick(uuid, bigint[])','execute')::text
      || '/' || has_function_privilege('anon','public.assess_pick(uuid, bigint[])','execute')::text$q$));
  perform pg_temp.vr_eq('0 結構','內部函式（抽題、判斷身分、鎖定觸發器）登入者不可直接呼叫','false/false/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated','public.assess_draw_dual_items(uuid)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_resolve_tenure(public.employees, text)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_examiners_lock()','execute')::text$q$));
end
$$;

-- ============================================================
-- 區段 1：開考抽籤＋抽題（配額 3/2/1、負責考官、題目不重複、drawn／category_last／secrets）
-- ============================================================
do $$
declare
  j jsonb;
  a uuid;
  v_s1 int;
begin
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9901');
  a := (j ->> 'assessment_id')::uuid;
  perform pg_temp.vr_set('a1', a::text);
  perform pg_temp.vr_eq('1 開考','考官1 開考成功：回傳 assessment_id、existing=false','true/false',
    (j ? 'assessment_id')::text || '/' || coalesce(j ->> 'existing', '(無)'));
  perform pg_temp.vr_eq('1 開考','題組數：基礎 3／進階 2／綜合 1','3/2/1', pg_temp.vr_cnt321(a));
  perform pg_temp.vr_eq('1 開考','seq 依序：基礎×3、進階×2、綜合×1','基礎,基礎,基礎,進階,進階,綜合',
    pg_temp.vr_q1(format($q$select string_agg(category, ',' order by seq) from public.assessment_items where assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','負責考官：基礎→1、進階→2、綜合→2（各分類各只有一種）','1/2/2',
    pg_temp.vr_q1(format($q$select (select string_agg(distinct examiner_slot::text, ',') from public.assessment_items where assessment_id=%1$L::uuid and category='基礎')
      || '/' || (select string_agg(distinct examiner_slot::text, ',') from public.assessment_items where assessment_id=%1$L::uuid and category='進階')
      || '/' || (select string_agg(distinct examiner_slot::text, ',') from public.assessment_items where assessment_id=%1$L::uuid and category='綜合')$q$, a)));
  perform pg_temp.vr_eq('1 開考','examiner_slot 依 seq：1,1,1,2,2,2','1,1,1,2,2,2',
    pg_temp.vr_q1(format($q$select string_agg(examiner_slot::text, ',' order by seq) from public.assessment_items where assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','同場 6 題的題庫題號都不重複','6/6',
    pg_temp.vr_q1(format($q$select count(distinct sx.question_id)::text || '/' || count(*)::text
      from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id where i.assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','機密表寫入題組名稱與步驟、was_drawn_before 有值','6/6',
    pg_temp.vr_q1(format($q$select count(*) filter (where sx.title is not null and sx.steps is not null)::text || '/' || count(*) filter (where sx.was_drawn_before is not null)::text
      from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id where i.assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','6 題都寫進 drawn','6',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id
      where i.assessment_id=%L::uuid and exists (select 1 from public.drawn d where d.question_id=sx.question_id)$q$, a)));
  perform pg_temp.vr_eq('1 開考','category_last：三個分類各記該場該分類最後抽出的那一題','3',
    pg_temp.vr_q1(format($q$select count(*)::text from public.category_last l
      where l.category in ('基礎','進階','綜合')
        and l.question_id = (select sx.question_id from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id
                              where i.assessment_id=%L::uuid and i.category=l.category order by i.seq desc limit 1)$q$, a)));
  perform pg_temp.vr_eq('1 開考','成績單：draft／exam／雙考官／開考者','draft/exam/true/vr-ex1@2motor.tw',
    pg_temp.vr_q1(format($q$select status || '/' || kind || '/' || is_dual::text || '/' || examiner_email from public.assessments where id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','考官表：兩列，考官1＝基礎、考官2＝進階＋綜合','1:基礎,2:進階＋綜合',
    pg_temp.vr_q1(format($q$select string_agg(slot::text || ':' || scope, ',' order by slot) from public.assessment_examiners where assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','兩位考官就是名單內那兩位（信箱不同）','vr-ex1@2motor.tw,vr-ex2@2motor.tw',
    pg_temp.vr_q1(format($q$select string_agg(email, ',' order by email) from public.assessment_examiners where assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','暱稱快照 slot1_name／slot2_name 與考官表一致，且不是同一人','true/true',
    pg_temp.vr_q1(format($q$select (a.slot1_name = (select display_name from public.assessment_examiners where assessment_id=a.id and slot=1))::text
      || '/' || (a.slot2_name = (select display_name from public.assessment_examiners where assessment_id=a.id and slot=2) and a.slot1_name <> a.slot2_name)::text
      from public.assessments a where a.id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('1 開考','考官表的提交時間與最後暫存時間一開始都是空的','0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id=%L::uuid and (submitted_at is not null or last_saved_at is not null)$q$, a)));
  v_s1 := (select e.slot from public.assessment_examiners e where e.assessment_id = a and e.email = 'vr-ex1@2motor.tw');
  perform pg_temp.vr_eq('1 開考','回傳的 my_slot 等於考官表裡開考者的 slot','true', ((j ->> 'my_slot')::int = v_s1)::text);
  perform pg_temp.vr_eq('1 開考','回傳 slots 2 筆、不含任何信箱','2/true',
    jsonb_array_length(j -> 'slots')::text || '/' || (position('@' in j::text) = 0)::text);
  perform pg_temp.vr_eq('1 開考','回傳 items 6 筆且帶題組名稱與步驟','6/true',
    jsonb_array_length(j -> 'items')::text || '/' || ((j -> 'items' -> 0 ->> 'title') is not null and (j -> 'items' -> 0 -> 'steps') is not null)::text);
  perform pg_temp.vr_eq('1 開考','身分：到職 200 天＝正式／自動','正式/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id=%L::uuid$q$, a)));

  -- 新人／正式判斷（與 assess_start 同邏輯）
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9941', '正式');
  perform pg_temp.vr_eq('1 身分','到職 30 天（新人）：忽略手動指定，新人／自動','新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id=%L::uuid$q$, j ->> 'assessment_id')));
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9942');
  perform pg_temp.vr_eq('1 身分','考核期新人（period_status）：新人／自動','新人/自動',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id=%L::uuid$q$, j ->> 'assessment_id')));
  perform pg_temp.vr_eq('1 身分','未填到職日且沒指定：報錯、沒有新增草稿','true/0',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9943') ->> 'error', '%到職日空白%') || '/'
    || pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id='MI-9943'$q$));
  perform pg_temp.vr_eq('1 身分','未填到職日且指定值不合法：報錯','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9943', '亂填') ->> 'error', '%到職日空白%'));
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9943', '正式');
  perform pg_temp.vr_eq('1 身分','未填到職日且指定「正式」：正式／手動指定','正式/手動指定',
    pg_temp.vr_q1(format($q$select tenure || '/' || tenure_source from public.assessments where id=%L::uuid$q$, j ->> 'assessment_id')));
  perform pg_temp.vr_eq('1 身分','一般員工 hire_date_snapshot 與員工到職日一致、門市快照與暱稱快照正確','true/ZZ-D1/假員9901',
    pg_temp.vr_q1(format($q$select (a.hire_date_snapshot = e.hire_date)::text || '/' || a.store_code || '/' || a.employee_label
      from public.assessments a join public.employees e on e.id=a.employee_id where a.id=%L::uuid$q$, a)));
end
$$;

-- ============================================================
-- 區段 2：重複呼叫回傳既有草稿（不重抽籤、不重抽題）
-- ============================================================
do $$
declare
  a uuid := pg_temp.vr_get('a1')::uuid;
  j1 jsonb;
  j2 jsonb;
  v_d0 text;
  v_l0 text;
  v_items0 text;
begin
  v_d0 := pg_temp.vr_q1('select count(*)::text || string_agg(question_id::text || to_char(drawn_at, ''HH24MISSUS''), '','' order by question_id) from public.drawn');
  v_l0 := pg_temp.vr_q1($q$select string_agg(category || question_id::text, ',' order by category) from public.category_last$q$);
  v_items0 := pg_temp.vr_q1(format($q$select string_agg(id::text, ',' order by seq) from public.assessment_items where assessment_id=%L::uuid$q$, a));

  j1 := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9901');
  perform pg_temp.vr_eq('2 重複','開考者再呼叫：回傳同一張、existing=true','true/true',
    ((j1 ->> 'assessment_id')::uuid = a)::text || '/' || (j1 ->> 'existing'));
  j2 := pg_temp.vr_sd('vr-ex2@2motor.tw', 'MI-9901');
  perform pg_temp.vr_eq('2 重複','另一位考官呼叫：也是同一張、existing=true','true/true',
    ((j2 ->> 'assessment_id')::uuid = a)::text || '/' || (j2 ->> 'existing'));
  perform pg_temp.vr_eq('2 重複','另一位考官的 my_slot 與開考者不同、且等於考官表','true/true',
    ((j1 ->> 'my_slot') <> (j2 ->> 'my_slot'))::text || '/'
    || ((j2 ->> 'my_slot')::int = (select e.slot from public.assessment_examiners e where e.assessment_id = a and e.email = 'vr-ex2@2motor.tw'))::text);
  perform pg_temp.vr_eq('2 重複','兩次回傳的題組完全相同（沒有重抽題）','true',
    (j1 -> 'items' = j2 -> 'items')::text);
  perform pg_temp.vr_eq('2 重複','這位員工仍只有 1 張草稿、6 個題組、2 位考官；題組 id 與順序沒變','1/6/2/true',
    pg_temp.vr_q1(format($q$select (select count(*)::text from public.assessments where employee_id='MI-9901')
      || '/' || (select count(*)::text from public.assessment_items where assessment_id=%1$L::uuid)
      || '/' || (select count(*)::text from public.assessment_examiners where assessment_id=%1$L::uuid)
      || '/' || ((select string_agg(id::text, ',' order by seq) from public.assessment_items where assessment_id=%1$L::uuid) = %2$L)::text$q$, a, v_items0)));
  perform pg_temp.vr_eq('2 重複','題庫抽選狀態（drawn 內容與時間、category_last）完全沒被動','true/true',
    (pg_temp.vr_q1('select count(*)::text || string_agg(question_id::text || to_char(drawn_at, ''HH24MISSUS''), '','' order by question_id) from public.drawn') = v_d0)::text
    || '/' || (pg_temp.vr_q1($q$select string_agg(category || question_id::text, ',' order by category) from public.category_last$q$) = v_l0)::text);
end
$$;

-- ============================================================
-- 區段 3：抽籤兩種結果都會出現（固定亂數種子，結果可重現）；每場題目不重複
-- ============================================================
do $$
declare
  i int;
  j jsonb;
  v_s int;
  n1 int := 0;
  n2 int := 0;
  v_bad int := 0;
  v_dd text;
begin
  perform setseed(0.37);
  for i in 9910..9933 loop
    j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-' || i);
    if j ? 'error' then
      v_bad := v_bad + 1;
    else
      v_s := (j ->> 'my_slot')::int;
      if v_s = 1 then n1 := n1 + 1; else n2 := n2 + 1; end if;
    end if;
  end loop;
  perform pg_temp.vr_eq('3 抽籤','連續 24 位員工都開考成功（題庫輪替不會卡住）','0', v_bad::text);
  perform pg_temp.vr_rec('3 抽籤','開考者被抽到考官1 的次數 ≥ 3（共 24 次）','≥ 3', n1::text, n1 >= 3);
  perform pg_temp.vr_rec('3 抽籤','開考者被抽到考官2 的次數 ≥ 3（共 24 次）：開考者也可能是考官2','≥ 3', n2::text, n2 >= 3);
  perform pg_temp.vr_eq('3 抽籤','24 場每場：6 題、題號不重複、題數 3/2/1','0',
    pg_temp.vr_q1($q$select count(*)::text from (
        select i.assessment_id, count(*) c, count(distinct sx.question_id) d,
               count(*) filter (where i.category='基礎') b, count(*) filter (where i.category='進階') a, count(*) filter (where i.category='綜合') z
        from public.assessment_items i
        join public.assessment_item_secrets sx on sx.item_id=i.id
        join public.assessments x on x.id=i.assessment_id
        where x.is_dual and x.employee_id between 'MI-9910' and 'MI-9933'
        group by i.assessment_id) t
      where c <> 6 or d <> 6 or b <> 3 or a <> 2 or z <> 1$q$));
  perform pg_temp.vr_eq('3 抽籤','24 場每場的考官1、考官2 暱稱不同且兩位都在','0',
    pg_temp.vr_q1($q$select count(*)::text from public.assessments a
      where a.is_dual and a.employee_id between 'MI-9910' and 'MI-9933'
        and (a.slot1_name = a.slot2_name or a.slot1_name not in ('VX1','VX2') or a.slot2_name not in ('VX1','VX2'))$q$));
  -- 輪替：基礎只有 8 題，24 場×3 題=72 次挑題，抽選過程中 drawn 必須有被清掉重來（新一輪）而不是卡死
  perform pg_temp.vr_eq('3 抽籤','基礎分類每題都被抽到過（輪替有轉起來）','true',
    pg_temp.vr_q1($q$select (count(distinct sx.question_id) >= 8)::text from public.assessment_item_secrets sx
      join public.questions q on q.id = sx.question_id where q.category='基礎' and q.code like 'ZDB%'$q$));
end
$$;

-- ============================================================
-- 區段 4：鎖定、約束、索引、連帶刪除
-- ============================================================
do $$
declare
  a uuid := pg_temp.vr_get('a1')::uuid;
  v_aid53 uuid;
  j jsonb;
begin
  perform pg_temp.vr_ownerr('4 鎖定','不可改 slot（擁有者身分也不行）',
    format($q$update public.assessment_examiners set slot = 3 - slot where assessment_id=%L::uuid$q$, a), '%已鎖定%');
  perform pg_temp.vr_ownerr('4 鎖定','不可改 email',
    format($q$update public.assessment_examiners set email = 'vr-cs3@2motor.tw' where assessment_id=%L::uuid and slot=1$q$, a), '%已鎖定%');
  perform pg_temp.vr_ownerr('4 鎖定','不可改暱稱',
    format($q$update public.assessment_examiners set display_name = '偷改' where assessment_id=%L::uuid and slot=1$q$, a), '%已鎖定%');
  perform pg_temp.vr_ownerr('4 鎖定','不可改分工 scope',
    format($q$update public.assessment_examiners set scope = '基礎' where assessment_id=%L::uuid and slot=2$q$, a), '%已鎖定%');
  perform pg_temp.vr_ownerr('4 鎖定','不可直接刪考官列（考核還在）',
    format($q$delete from public.assessment_examiners where assessment_id=%L::uuid and slot=1$q$, a), '%已鎖定%');
  perform pg_temp.vr_eq('4 鎖定','submitted_at、last_saved_at 可以更新（之後交卷與暫存要用）','OK',
    pg_temp.vr_own(format($q$update public.assessment_examiners set submitted_at = null, last_saved_at = now() where assessment_id=%L::uuid and slot=1$q$, a)));
  perform pg_temp.vr_eq('4 鎖定','鎖定後 slot／email 都沒變：1＝基礎、兩人信箱不同','2/2',
    pg_temp.vr_q1(format($q$select count(distinct email)::text || '/' || count(distinct slot)::text from public.assessment_examiners where assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_ownerr('4 鎖定','同一張考核同一 slot 不可有兩位（主鍵）',
    format($q$insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope) values (%L::uuid, 1, 'vr-cs3@2motor.tw', 'X', '基礎')$q$, a), '%duplicate key%');
  perform pg_temp.vr_ownerr('4 鎖定','同一位考官不可在同一張考核佔兩個 slot（unique）',
    format($q$delete from public.assessment_examiners where false; insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope) select assessment_id, 2, email, 'X', '進階＋綜合' from public.assessment_examiners where assessment_id=%L::uuid and slot=1$q$, a), '%duplicate key%');
  perform pg_temp.vr_ownerr('4 約束','slot 只能是 1 或 2',
    format($q$insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope) values (%L::uuid, 3, 'vr-cs3@2motor.tw', 'X', '基礎')$q$, a), '%check%');
  perform pg_temp.vr_ownerr('4 約束','考官1 的分工必須是「基礎」',
    format($q$insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope) values (%L::uuid, 1, 'vr-cs3@2motor.tw', 'X', '進階＋綜合')$q$, a), '%check%');
  perform pg_temp.vr_ownerr('4 約束','雙考官只能是一般考核（kind=exam）：健檢＋is_dual 被擋',
    $q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind, checkup_year, checkup_quarter, is_dual, slot1_name, slot2_name)
       values ('MI-9944', 'x', 'ZZ-D1', 'vr-ex1@2motor.tw', 'draft', '正式', '自動', 'checkup', 2026, 1, true, 'a', 'b')$q$, '%assessments_dual_kind%');
  perform pg_temp.vr_ownerr('4 約束','is_dual 必須帶兩個暱稱；非雙考官不可帶暱稱',
    $q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, is_dual)
       values ('MI-9944', 'x', 'ZZ-D1', 'vr-ex1@2motor.tw', 'draft', '正式', '自動', true)$q$, '%assessments_dual_names%');
  perform pg_temp.vr_ownerr('4 約束','非雙考官草稿不可帶 slot 暱稱',
    $q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, slot1_name)
       values ('MI-9944', 'x', 'ZZ-D1', 'vr-ex1@2motor.tw', 'draft', '正式', '自動', 'a')$q$, '%assessments_dual_names%');
  perform pg_temp.vr_ownerr('4 索引','同一位員工不能有兩張雙考官草稿（新唯一索引）',
    $q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, is_dual, slot1_name, slot2_name)
       values ('MI-9901', 'x', 'ZZ-D1', 'vr-ex2@2motor.tw', 'draft', '正式', '自動', true, 'a', 'b')$q$, '%assessments_one_dual_draft_per_employee%');
  perform pg_temp.vr_eq('4 索引','雙考官草稿已完成後，同一員工可以再開（索引只管 draft）：作廢狀態不擋','OK',
    pg_temp.vr_own($q$insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, is_dual, slot1_name, slot2_name, total_score, verdict, pass_line, submitted_at, voided_at, voided_by, void_reason)
       values ('MI-9901', 'x', 'ZZ-D1', 'vr-ex2@2motor.tw', 'voided', '正式', '自動', true, 'a', 'b', 90, '及格', 85, now(), now(), 'x', 'x')$q$));
  perform pg_temp.vr_eq('4 索引','雙考官題組同一分類可以有多題（基礎 3 題）：第 4 題基礎（slot 1）也能插入','OK',
    pg_temp.vr_own(format($q$insert into public.assessment_items (assessment_id, seq, category, code, examiner_slot) values (%L::uuid, 7, '基礎', 'x', 1)$q$, a)));
  perform pg_temp.vr_eq('4 索引','（清掉剛才測試用的第 7 題）','1',
    pg_temp.vr_q1(format($q$with d as (delete from public.assessment_items where assessment_id=%L::uuid and seq=7 returning 1) select count(*)::text from d$q$, a)));

  -- 連帶刪除：刪考核（模擬 assess_abandon）時考官列跟著 cascade 刪除，不會被鎖定觸發器擋
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9953');
  v_aid53 := (j ->> 'assessment_id')::uuid;
  perform pg_temp.vr_eq('4 連帶刪除','MI-9953 開考成功，考官 2 列','2',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id=%L::uuid$q$, v_aid53)));
  perform pg_temp.vr_eq('4 連帶刪除','刪除該張考核：成功，考官列與題組一併消失','OK/0/0',
    pg_temp.vr_own(format($q$delete from public.assessments where id=%L::uuid$q$, v_aid53))
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id=%L::uuid$q$, v_aid53))
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where assessment_id=%L::uuid$q$, v_aid53)));
  perform pg_temp.vr_eq('4 連帶刪除','刪掉後同一員工可重新開考（新的一張）','true',
    ((pg_temp.vr_sd('vr-ex2@2motor.tw', 'MI-9953') ->> 'assessment_id')::uuid <> v_aid53)::text);

end
$$;

-- ============================================================
-- 區段 5：配額設定與題庫不足（整體回復）
-- ============================================================
do $$
declare
  v_b int := (select count(*) from public.questions where category = '基礎');
  v_a int := (select count(*) from public.questions where category = '進階');
  v_z int := (select count(*) from public.questions where category = '綜合');
  v_d0 text;
  v_l0 text;
  v_i0 text;
  v_a0 text;
  v_s0 text;
  v_err text;
  j jsonb;
begin
  v_d0 := pg_temp.vr_q1('select count(*)::text || string_agg(question_id::text, '','' order by question_id) from public.drawn');
  v_l0 := pg_temp.vr_q1($q$select string_agg(category || question_id::text, ',' order by category) from public.category_last$q$);
  v_i0 := pg_temp.vr_q1('select count(*)::text from public.assessment_items');
  v_a0 := pg_temp.vr_q1('select count(*)::text from public.assessments');
  v_s0 := pg_temp.vr_q1('select count(*)::text from public.assessment_item_secrets');

  -- 基礎要求比題庫多一題
  update public.app_settings set value = format('{"基礎":%s,"進階":2,"綜合":1}', v_b + 1) where key = 'exam_dual_quota';
  v_err := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error';
  perform pg_temp.vr_eq('5 題庫不足','基礎題數不足：報中文訊息，含需要與目前題數','true/true',
    pg_temp.vr_lk(v_err, '%題庫題數不足%補題%') || '/'
    || pg_temp.vr_lk(v_err, format('%%「基礎」需要 %s 題、目前只有 %s 題%%', v_b + 1, v_b)));
  perform pg_temp.vr_eq('5 題庫不足','不足時整體回復：沒有新增考核／題組／機密列、drawn 與 category_last 都沒被動','true/true/true/true/true',
    (pg_temp.vr_q1('select count(*)::text from public.assessments') = v_a0)::text
    || '/' || (pg_temp.vr_q1('select count(*)::text from public.assessment_items') = v_i0)::text
    || '/' || (pg_temp.vr_q1('select count(*)::text from public.assessment_item_secrets') = v_s0)::text
    || '/' || (pg_temp.vr_q1('select count(*)::text || string_agg(question_id::text, '','' order by question_id) from public.drawn') = v_d0)::text
    || '/' || (pg_temp.vr_q1($q$select string_agg(category || question_id::text, ',' order by category) from public.category_last$q$) = v_l0)::text);

  -- 基礎與綜合同時不足：兩個都要點名，進階不點名
  update public.app_settings set value = format('{"基礎":%s,"進階":2,"綜合":%s}', v_b + 1, v_z + 1) where key = 'exam_dual_quota';
  v_err := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error';
  perform pg_temp.vr_eq('5 題庫不足','多個分類不足：一次點名所有不足的分類（基礎、綜合），沒不足的（進階）不點名','true/true/false',
    pg_temp.vr_lk(v_err, '%「基礎」%') || '/' || pg_temp.vr_lk(v_err, '%「綜合」%') || '/' || pg_temp.vr_lk(v_err, '%「進階」%'));

  update public.app_settings set value = format('{"基礎":3,"進階":%s,"綜合":1}', v_a + 1) where key = 'exam_dual_quota';
  v_err := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error';
  perform pg_temp.vr_eq('5 題庫不足','進階題數不足也擋下','true', pg_temp.vr_lk(v_err, format('%%「進階」需要 %s 題、目前只有 %s 題%%', v_a + 1, v_a)));

  -- 設定格式錯誤
  update public.app_settings set value = 'xx' where key = 'exam_dual_quota';
  perform pg_temp.vr_eq('5 設定','配額設定不是 JSON：報格式不正確','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error', '%exam_dual_quota%格式不正確%'));
  update public.app_settings set value = '{"基礎":3}' where key = 'exam_dual_quota';
  perform pg_temp.vr_eq('5 設定','配額設定缺進階、綜合：報格式不正確','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error', '%格式不正確%'));
  update public.app_settings set value = '{"基礎":0,"進階":2,"綜合":1}' where key = 'exam_dual_quota';
  perform pg_temp.vr_eq('5 設定','配額為 0：報格式不正確','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error', '%格式不正確%'));
  update public.app_settings set value = '{"基礎":"3","進階":2,"綜合":1}' where key = 'exam_dual_quota';
  perform pg_temp.vr_eq('5 設定','配額寫成文字（"3"）：報格式不正確','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949') ->> 'error', '%格式不正確%'));
  perform pg_temp.vr_eq('5 設定','設定錯誤時同樣整體回復（沒有新增考核）','true',
    (pg_temp.vr_q1('select count(*)::text from public.assessments') = v_a0)::text);

  -- 設定空白：視為預設 3/2/1
  update public.app_settings set value = '' where key = 'exam_dual_quota';
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9949');
  perform pg_temp.vr_eq('5 設定','配額設定空白：用預設 3/2/1 開考成功','3/2/1',
    case when j ? 'error' then j ->> 'error' else pg_temp.vr_cnt321((j ->> 'assessment_id')::uuid) end);
  update public.app_settings set value = '{"基礎":3,"進階":2,"綜合":1}' where key = 'exam_dual_quota';
end
$$;

-- ============================================================
-- 區段 5b：跨新輪不重複（該分類全部題都被要求抽出；drawn 預先只剩 1 題未抽）
-- ============================================================
do $$
declare
  v_b int := (select count(*) from public.questions where category = '基礎');
  v_u bigint := (select min(id) from public.questions where category = '基礎');
  j jsonb;
  a uuid;
begin
  delete from public.drawn where question_id in (select id from public.questions where category = '基礎');
  insert into public.drawn (question_id) select id from public.questions where category = '基礎' and id <> v_u;
  update public.app_settings set value = format('{"基礎":%s,"進階":1,"綜合":1}', v_b) where key = 'exam_dual_quota';
  j := pg_temp.vr_sd('vr-ex2@2motor.tw', 'MI-9950');
  a := (j ->> 'assessment_id')::uuid;
  perform pg_temp.vr_eq('5b 跨新輪','把基礎全部題都抽進同一場：開考成功、題數為「全部基礎＋1＋1」','true',
    (not (j ? 'error') and (pg_temp.vr_cnt321(a) = v_b::text || '/1/1'))::text);
  perform pg_temp.vr_eq('5b 跨新輪','中途開了新一輪，但同場基礎題號完全不重複（全部不同）','true',
    pg_temp.vr_q1(format($q$select (count(distinct sx.question_id) = count(*) and count(*) = %s)::text
      from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id
      where i.assessment_id=%L::uuid and i.category='基礎'$q$, v_b, a)));
  perform pg_temp.vr_eq('5b 跨新輪','第一題抽到唯一未抽過的題；第二題起開新一輪，所以結束時 drawn 少 1 題（第一題被清掉）','true/true',
    pg_temp.vr_q1(format($q$select ((select count(*) from public.drawn d join public.questions q on q.id=d.question_id where q.category='基礎') = %s)::text
      || '/' || (not exists (select 1 from public.drawn where question_id = %s))::text$q$, v_b - 1, v_u)));
  perform pg_temp.vr_eq('5b 跨新輪','第一題（seq 1）正是那題唯一未抽過的題','true',
    pg_temp.vr_q1(format($q$select (sx.question_id = %s)::text from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id where i.assessment_id=%L::uuid and i.seq=1$q$, v_u, a)));
  perform pg_temp.vr_eq('5b 跨新輪','第一題 was_drawn_before=false；開新一輪之後抽出的題 was_drawn_before=false','0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items i join public.assessment_item_secrets sx on sx.item_id=i.id
      where i.assessment_id=%L::uuid and i.category='基礎' and sx.was_drawn_before$q$, a)));
  update public.app_settings set value = '{"基礎":3,"進階":2,"綜合":1}' where key = 'exam_dual_quota';
end
$$;

-- ============================================================
-- 區段 6：身分與考官名單檢查
-- ============================================================
do $$
declare
  v_a0 text := pg_temp.vr_q1('select count(*)::text from public.assessments');
  j jsonb;
begin
  perform pg_temp.vr_eq('6 身分','不在考官名單的客服部（vr-cs3）不可開考','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-cs3@2motor.tw', 'MI-9952') ->> 'error', '%只有考官名單內%'));
  perform pg_temp.vr_eq('6 身分','不在名單的客服部，即使該員工已有雙考官草稿也不能「開」（不回傳別人的草稿）','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-cs3@2motor.tw', 'MI-9901') ->> 'error', '%只有考官名單內%'));
  perform pg_temp.vr_deny('6 身分','總公司主管不可開考','authenticated', 'vr-hq@2motor.tw', $q$select public.assess_start_dual('MI-9952')$q$, '%沒有權限%');
  perform pg_temp.vr_deny('6 身分','店長不可開考','authenticated', 'vr-sm1@2motor.tw', $q$select public.assess_start_dual('MI-9952')$q$, '%沒有權限%');
  perform pg_temp.vr_deny('6 身分','有登入但未開通帳號不可開考','authenticated', 'vr-nobody@2motor.tw', $q$select public.assess_start_dual('MI-9952')$q$, '%沒有權限%');
  perform pg_temp.vr_deny('6 身分','未登入（anon）不可開考','anon', null, $q$select public.assess_start_dual('MI-9952')$q$, '%permission denied%');
  perform pg_temp.vr_eq('6 身分','被拒的開考都沒有新增任何考核','true', (pg_temp.vr_q1('select count(*)::text from public.assessments') = v_a0)::text);

  perform pg_temp.vr_eq('6 員工','不存在的員工：找不到員工','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-0000') ->> 'error', '%找不到員工%'));
  perform pg_temp.vr_eq('6 員工','不納入考核的員工：被拒','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9944') ->> 'error', '%不在考核名單%'));
  perform pg_temp.vr_eq('6 員工','離職員工：被拒','true', pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9945') ->> 'error', '%不在考核名單%'));

  -- 舊式單人草稿衝突
  j := jsonb_build_object('id', pg_temp.vr_cs('vr-cs3@2motor.tw', $q$select public.assess_start('MI-9946')::text$q$));
  perform pg_temp.vr_eq('6 舊單','（前置）vr-cs3 對 MI-9946 開了舊式單人草稿','true',
    (j ->> 'id' not like 'ERROR%')::text);
  perform pg_temp.vr_eq('6 舊單','員工已有別人開的舊式單人草稿：雙考官開考被拒並提示先處理','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9946') ->> 'error', '%舊式單人考核草稿%先完成或放棄%'));
  perform pg_temp.vr_cs('vr-ex1@2motor.tw', $q$select public.assess_start('MI-9947')::text$q$);
  perform pg_temp.vr_eq('6 舊單','考官自己開的舊式單人草稿也一樣擋','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9947') ->> 'error', '%舊式單人考核草稿%'));
  perform pg_temp.vr_eq('6 舊單','被擋時沒有建立雙考官考核','0',
    pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id in ('MI-9946','MI-9947') and is_dual$q$));
  -- 舊單人草稿放棄後（模擬：刪掉）可以開雙考官
  perform pg_temp.vr_own($q$delete from public.assessments where employee_id='MI-9947' and not is_dual$q$);
  perform pg_temp.vr_eq('6 舊單','舊單人草稿放棄（刪除）之後，可以開雙考官','true',
    (not (pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9947') ? 'error'))::text);
  perform pg_temp.vr_eq('6 舊單','已送出／作廢的舊成績單不影響雙考官開考（只看草稿）：作廢的 MI-9901 假成績單不擋','true',
    (select (count(*) = 2)::text from public.assessments where employee_id = 'MI-9901'));

  -- 考官名單設定錯誤
  update public.assess_examiner_pool set active = false where email = 'vr-ex1@2motor.tw';
  perform pg_temp.vr_eq('6 名單','開考者自己被停用（不在啟用名單）：被拒','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ->> 'error', '%只有考官名單內%'));
  update public.assess_examiner_pool set active = true where email = 'vr-ex1@2motor.tw';

  update public.assess_examiner_pool set active = false;
  perform pg_temp.vr_eq('6 名單','名單完全沒有啟用的考官（尚未設定）：顯示「尚未設定考官名單」','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ->> 'error', '%尚未設定考官名單%'));
  update public.assess_examiner_pool set active = true where email in ('vr-ex1@2motor.tw','vr-ex2@2motor.tw');

  update public.assess_examiner_pool set active = false where email = 'vr-ex2@2motor.tw';
  perform pg_temp.vr_eq('6 名單','名單只剩 1 位啟用：報名單設定不正確','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ->> 'error', '%考官名單設定不正確%恰好 2 位%'));
  update public.assess_examiner_pool set active = true where email = 'vr-ex2@2motor.tw';

  insert into public.assess_examiner_pool (email, display_name, active) values ('vr-cs3@2motor.tw', 'VX3', true);
  perform pg_temp.vr_eq('6 名單','名單有 3 位啟用：報名單設定不正確','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ->> 'error', '%考官名單設定不正確%'));
  delete from public.assess_examiner_pool where email = 'vr-cs3@2motor.tw';

  update public.assess_examiner_pool set email = 'vr-ghost@2motor.tw' where email = 'vr-ex2@2motor.tw';
  perform pg_temp.vr_eq('6 名單','名單裡有人在 app_users 沒有帳號（不是客服部）：報名單設定不正確','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ->> 'error', '%考官名單設定不正確%客服部帳號%'));
  update public.assess_examiner_pool set email = 'vr-ex2@2motor.tw' where email = 'vr-ghost@2motor.tw';

  insert into public.app_users (email, role, store_code) values ('vr-ghost@2motor.tw', 'hq_viewer', null);
  update public.assess_examiner_pool set email = 'vr-ghost@2motor.tw' where email = 'vr-ex2@2motor.tw';
  perform pg_temp.vr_eq('6 名單','名單裡有人在 app_users 是總公司主管（不是 cs_admin）：報名單設定不正確','true',
    pg_temp.vr_lk(pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ->> 'error', '%考官名單設定不正確%'));
  update public.assess_examiner_pool set email = 'vr-ex2@2motor.tw' where email = 'vr-ghost@2motor.tw';
  delete from public.app_users where email = 'vr-ghost@2motor.tw';

  perform pg_temp.vr_eq('6 名單','名單問題都排除後，MI-9952 開考成功（上面的錯誤都沒有留下半張考核）','true/0',
    (not (pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9952') ? 'error'))::text || '/'
    || pg_temp.vr_q1($q$select (count(*) - 1)::text from public.assessments where employee_id = 'MI-9952'$q$));
end
$$;

-- ============================================================
-- 區段 7：assess_draw／assess_pick 對雙考官草稿拒絕；舊單人流程行為不變
-- ============================================================
do $$
declare
  a uuid := pg_temp.vr_get('a1')::uuid;
  v_i0 text;
  v_d0 text;
  v_leg uuid;
  v_q1 bigint := (select min(id) from public.questions where category = 'ZZ分類D');
  v_q2 bigint := (select max(id) from public.questions where category = 'ZZ分類D');
  v_qb bigint := (select min(id) from public.questions where category = '基礎' and code like 'ZDB%');
begin
  v_i0 := pg_temp.vr_q1('select count(*)::text from public.assessment_items');
  v_d0 := pg_temp.vr_q1('select count(*)::text || string_agg(question_id::text, '','' order by question_id) from public.drawn');

  perform pg_temp.vr_deny('7 守衛','assess_draw：開考者對雙考官草稿被拒（中文訊息）','authenticated', 'vr-ex1@2motor.tw',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, a), '%雙考官考核的題組在開考時已自動抽好%抽題%');
  perform pg_temp.vr_deny('7 守衛','assess_draw：另一位考官也被拒','authenticated', 'vr-ex2@2motor.tw',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, a), '%雙考官考核的題組在開考時已自動抽好%');
  perform pg_temp.vr_deny('7 守衛','assess_draw：第三位客服部也被拒','authenticated', 'vr-cs3@2motor.tw',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, a), '%雙考官考核的題組在開考時已自動抽好%');
  perform pg_temp.vr_deny('7 守衛','assess_pick：開考者對雙考官草稿被拒（中文訊息）','authenticated', 'vr-ex1@2motor.tw',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s::bigint])$q$, a, v_q1), '%雙考官考核的題組在開考時已自動抽好%選題%');
  perform pg_temp.vr_deny('7 守衛','assess_pick：另一位考官也被拒','authenticated', 'vr-ex2@2motor.tw',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s::bigint])$q$, a, v_q1), '%雙考官考核的題組在開考時已自動抽好%');
  perform pg_temp.vr_eq('7 守衛','被拒後雙考官草稿的題組仍是 6 個、drawn 沒被動','6/true',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where assessment_id=%L::uuid$q$, a))
    || '/' || (pg_temp.vr_q1('select count(*)::text || string_agg(question_id::text, '','' order by question_id) from public.drawn') = v_d0)::text);
  perform pg_temp.vr_deny('7 守衛','不存在的考核：assess_draw 仍報「找不到考核」','authenticated', 'vr-ex1@2motor.tw',
    $q$select count(*) from public.assess_draw(gen_random_uuid(), array['ZZ分類D'])$q$, '%找不到考核%');
  perform pg_temp.vr_deny('7 守衛','不存在的考核：assess_pick 仍報「找不到考核」','authenticated', 'vr-ex1@2motor.tw',
    format($q$select count(*) from public.assess_pick(gen_random_uuid(), array[%s::bigint])$q$, v_q1), '%找不到考核%');

  -- 舊單人流程：vr-cs3 在 MI-9946 開的舊草稿
  v_leg := (select id from public.assessments where employee_id = 'MI-9946' and status = 'draft' and not is_dual);
  perform pg_temp.vr_eq('7 舊單','舊式草稿：is_dual=false、暱稱快照空、kind=exam','false/(null)/(null)/exam',
    pg_temp.vr_q1(format($q$select is_dual::text || '/' || coalesce(slot1_name, '(null)') || '/' || coalesce(slot2_name, '(null)') || '/' || kind from public.assessments where id=%L::uuid$q$, v_leg)));
  perform pg_temp.vr_eq('7 舊單','舊式 assess_start 再呼叫：回傳同一張（舊行為不變）','true',
    (pg_temp.vr_cs('vr-cs3@2motor.tw', $q$select public.assess_start('MI-9946')::text$q$) = v_leg::text)::text);
  perform pg_temp.vr_eq('7 舊單','舊式 assess_draw：建立者本人抽 1 個分類成功（回 1 列），examiner_slot 為空','1/(null)',
    pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select count(*)::text from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, v_leg))
    || '/' || pg_temp.vr_q1(format($q$select coalesce(max(examiner_slot)::text, '(null)') from public.assessment_items where assessment_id=%L::uuid$q$, v_leg)));
  -- 舊單人草稿（examiner_slot 空）：核心題組同分類仍只能一題；追加題與雙考官題組不受這條限制
  perform pg_temp.vr_eq('7 索引','舊單人草稿：同分類第二個核心題組（examiner_slot 空）仍被擋','ERROR/one_core',
    case when pg_temp.vr_own(format($q$insert into public.assessment_items (assessment_id, seq, category, code) select assessment_id, 9, category, 'x' from public.assessment_items where assessment_id=%L::uuid and seq=1$q$, v_leg)) like '%one_core_per_category%' then 'ERROR/one_core' else 'OK' end);
  perform pg_temp.vr_eq('7 索引','舊單人草稿：同分類追加題（is_extra）仍可插入（舊規則不變）','OK',
    pg_temp.vr_own(format($q$insert into public.assessment_items (assessment_id, seq, category, code, is_extra) select assessment_id, 10, category, 'x', true from public.assessment_items where assessment_id=%L::uuid and seq=1$q$, v_leg)));
  perform pg_temp.vr_eq('7 索引','（清掉測試插入的追加題）','1',
    pg_temp.vr_q1(format($q$with d as (delete from public.assessment_items where assessment_id=%L::uuid and seq=10 returning 1) select count(*)::text from d$q$, v_leg)));
  perform pg_temp.vr_deny('7 舊單','舊式 assess_draw：同分類再抽仍報「已抽過其中的分類」（訊息不變）','authenticated', 'vr-cs3@2motor.tw',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, v_leg), '%這場考核已抽過其中的分類%');
  perform pg_temp.vr_deny('7 舊單','舊式 assess_draw：非建立者仍報「只有建立者本人」（訊息不變）','authenticated', 'vr-ex1@2motor.tw',
    format($q$select count(*) from public.assess_draw(%L::uuid, array['基礎'])$q$, v_leg), '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_eq('7 舊單','舊式 assess_pick：選別的分類的題組成功（回 1 列），examiner_slot 為空','1/(null)',
    pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s::bigint])$q$, v_leg, v_qb))
    || '/' || pg_temp.vr_q1(format($q$select coalesce(max(examiner_slot)::text, '(null)') from public.assessment_items where assessment_id=%L::uuid and category='基礎'$q$, v_leg)));
  perform pg_temp.vr_deny('7 舊單','舊式 assess_pick：同分類再選仍報「已抽過其中的分類」（訊息不變）','authenticated', 'vr-cs3@2motor.tw',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s::bigint])$q$, v_leg, v_q2), '%這場考核已抽過其中的分類%');
  perform pg_temp.vr_deny('7 舊單','舊式 assess_pick：非建立者仍報「只有建立者本人」（訊息不變）','authenticated', 'vr-ex1@2motor.tw',
    format($q$select count(*) from public.assess_pick(%L::uuid, array[%s::bigint])$q$, v_leg, v_q2), '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_eq('7 舊單','舊式草稿 2 個核心題組（ZZ分類D、基礎），examiner_slot 都是空','2/0',
    pg_temp.vr_q1(format($q$select count(*)::text || '/' || count(examiner_slot)::text from public.assessment_items where assessment_id=%L::uuid$q$, v_leg)));

  -- 另一個舊單人流程：MI-9955 開考→兩個分類→評分暫存→送出（舊 assess_submit 不受影響）
  perform pg_temp.vr_cs('vr-cs3@2motor.tw', $q$select public.assess_start('MI-9955')::text$q$);
  perform pg_temp.vr_eq('7 舊單','舊流程完整走一次：start→draw→pick→save→submit 成功（總分 100）','100.0',
    (select pg_temp.vr_legacy_full('MI-9955')));
  perform pg_temp.vr_eq('7 舊單','全庫沒有「非雙考官卻有 examiner_slot」與「非 exam 卻是雙考官」的資料','0/0',
    pg_temp.vr_q1($q$select (select count(*)::text from public.assessment_items i join public.assessments a on a.id=i.assessment_id where not a.is_dual and i.examiner_slot is not null)
      || '/' || (select count(*)::text from public.assessments where is_dual and kind <> 'exam')$q$));
end
$$;

-- ============================================================
-- 區段 8：assess_my_drafts 內容與權限
-- ============================================================
do $$
declare
  a uuid := pg_temp.vr_get('a1')::uuid;
  v_s1 int;
  v_s2 int;
  j jsonb;
  k jsonb;
  v_it1 uuid;
  v_void uuid;
begin
  v_s1 := (select e.slot from public.assessment_examiners e where e.assessment_id = a and e.email = 'vr-ex1@2motor.tw');
  v_s2 := 3 - v_s1;

  -- 設定可預期的進度：ex1 的第 1 個題組評完（第 2 個只評一個面向，不算完成）；ex2 的 2 個題組評完且已交卷、最後暫存時間固定
  select i.id into v_it1 from public.assessment_items i where i.assessment_id = a and i.examiner_slot = v_s1 order by i.seq limit 1;
  update public.assessment_items set levels = pg_temp.vr_top() where id = v_it1;
  update public.assessment_items set levels = pg_temp.vr_top()
   where id in (select i.id from public.assessment_items i where i.assessment_id = a and i.examiner_slot = v_s2 order by i.seq limit 2);
  update public.assessment_items set levels = '{"資訊正確性":"優良"}'::jsonb
   where id = (select i.id from public.assessment_items i where i.assessment_id = a and i.examiner_slot = v_s1 order by i.seq offset 1 limit 1);
  update public.assessment_examiners set submitted_at = '2026-01-02 03:04:05+00', last_saved_at = '2026-01-02 03:04:05+00'
   where assessment_id = a and slot = v_s2;

  j := pg_temp.vr_cs('vr-ex1@2motor.tw', 'select public.assess_my_drafts()::text')::jsonb;
  select e into k from jsonb_array_elements(j) e where e ->> 'assessment_id' = a::text;

  perform pg_temp.vr_eq('8 草稿清單','回傳是陣列，筆數＝我是考官之一的雙考官草稿數（與資料表一致）','array/true',
    jsonb_typeof(j) || '/' || (jsonb_array_length(j) = (select count(*) from public.assessment_examiners e join public.assessments x on x.id = e.assessment_id
                                                          where e.email = 'vr-ex1@2motor.tw' and x.status = 'draft' and x.is_dual))::text);
  perform pg_temp.vr_eq('8 草稿清單','MI-9901 那張在清單內，員工與門市正確','MI-9901/假員9901/ZZ-D1',
    coalesce(k ->> 'employee_id', '(無)') || '/' || coalesce(k ->> 'employee_label', '(無)') || '/' || coalesce(k ->> 'store_code', '(無)'));
  perform pg_temp.vr_eq('8 草稿清單','my_slot、my_scope、opened_by_me 正確','true/true/true',
    ((k ->> 'my_slot')::int = v_s1)::text
    || '/' || ((k ->> 'my_scope') = case when v_s1 = 1 then '基礎' else '進階＋綜合' end)::text
    || '/' || (k ->> 'opened_by_me')::text);
  perform pg_temp.vr_eq('8 草稿清單','對方暱稱、對方 slot、對方分工正確（只給暱稱）','VX2/true/true',
    (k ->> 'other_name') || '/' || ((k ->> 'other_slot')::int = v_s2)::text
    || '/' || ((k ->> 'other_scope') = case when v_s2 = 1 then '基礎' else '進階＋綜合' end)::text);
  perform pg_temp.vr_eq('8 草稿清單','雙方進度：我評完 1／3；對方評完 2／3','1/3/2/3',
    (k -> 'my_progress' ->> 'done') || '/' || (k -> 'my_progress' ->> 'total')
    || '/' || (k -> 'other_progress' ->> 'done') || '/' || (k -> 'other_progress' ->> 'total'));
  perform pg_temp.vr_eq('8 草稿清單','對方已交卷、對方最後暫存時間正確；我自己還沒交卷','true/true/(null)',
    (k ->> 'other_submitted') || '/' || ((k ->> 'other_last_saved_at') like '2026-01-02%')::text || '/' || coalesce(k ->> 'my_submitted_at', '(null)'));
  perform pg_temp.vr_eq('8 草稿清單','整份回傳不含任何信箱（沒有 @）','true', (position('@' in j::text) = 0)::text);

  -- 另一位考官看同一張：視角對調
  j := pg_temp.vr_cs('vr-ex2@2motor.tw', 'select public.assess_my_drafts()::text')::jsonb;
  select e into k from jsonb_array_elements(j) e where e ->> 'assessment_id' = a::text;
  perform pg_temp.vr_eq('8 草稿清單','另一位考官：my_slot 對調、opened_by_me=false、對方暱稱是 VX1、我已交卷／對方未交卷','true/false/VX1/true/false',
    ((k ->> 'my_slot')::int = v_s2)::text || '/' || (k ->> 'opened_by_me') || '/' || (k ->> 'other_name')
    || '/' || ((k ->> 'my_submitted_at') is not null)::text || '/' || (k ->> 'other_submitted'));

  -- 非考官的客服部看不到別人的 slot 資訊
  perform pg_temp.vr_eq('8 草稿清單','不在考官名單的客服部（vr-cs3）：清單是空陣列','[]',
    pg_temp.vr_cs('vr-cs3@2motor.tw', 'select public.assess_my_drafts()::text'));
  perform pg_temp.vr_deny('8 草稿清單','總公司主管被拒','authenticated', 'vr-hq@2motor.tw', 'select public.assess_my_drafts()', '%沒有權限%');
  perform pg_temp.vr_deny('8 草稿清單','店長被拒','authenticated', 'vr-sm1@2motor.tw', 'select public.assess_my_drafts()', '%沒有權限%');
  perform pg_temp.vr_deny('8 草稿清單','有登入但未開通帳號被拒','authenticated', 'vr-nobody@2motor.tw', 'select public.assess_my_drafts()', '%沒有權限%');
  perform pg_temp.vr_deny('8 草稿清單','未登入（anon）被拒','anon', null, 'select public.assess_my_drafts()', '%permission denied%');

  -- 舊式單人草稿與已作廢的雙考官考核都不在清單內
  select id into v_void from public.assessments where employee_id = 'MI-9901' and status = 'voided' and is_dual;
  insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope) values
    (v_void, 1, 'vr-ex1@2motor.tw', 'VX1', '基礎'), (v_void, 2, 'vr-ex2@2motor.tw', 'VX2', '進階＋綜合');
  j := pg_temp.vr_cs('vr-ex1@2motor.tw', 'select public.assess_my_drafts()::text')::jsonb;
  perform pg_temp.vr_eq('8 草稿清單','已作廢的雙考官考核不在清單內；舊式單人草稿（MI-9946）也不在','0/0',
    (select count(*)::text from jsonb_array_elements(j) e where e ->> 'assessment_id' = v_void::text)
    || '/' || (select count(*)::text from jsonb_array_elements(j) e where e ->> 'employee_id' = 'MI-9946'));
end
$$;

-- ============================================================
-- 區段 9：RLS（店長、主管讀不到考官表；考官名單只有客服部）與直接寫入權限
-- ============================================================
do $$
declare
  a uuid := pg_temp.vr_get('a1')::uuid;
  v_all text := pg_temp.vr_q1('select count(*)::text from public.assessment_examiners');
  v_pool text := pg_temp.vr_q1('select count(*)::text from public.assess_examiner_pool');
begin
  perform pg_temp.vr_eq('9 RLS','客服部（考官）讀得到全部考官表','true',
    (pg_temp.vr_cs('vr-ex1@2motor.tw', 'select count(*)::text from public.assessment_examiners') = v_all and v_all::int > 0)::text);
  perform pg_temp.vr_eq('9 RLS','客服部（非考官 vr-cs3）也讀得到考官表（設計：只開 cs_admin select）','true',
    (pg_temp.vr_cs('vr-cs3@2motor.tw', 'select count(*)::text from public.assessment_examiners') = v_all)::text);
  perform pg_temp.vr_eq('9 RLS','店長讀不到考官表（0 列）','0', pg_temp.vr_cs('vr-sm1@2motor.tw', 'select count(*)::text from public.assessment_examiners'));
  perform pg_temp.vr_eq('9 RLS','總公司主管讀不到考官表（0 列）','0', pg_temp.vr_cs('vr-hq@2motor.tw', 'select count(*)::text from public.assessment_examiners'));
  perform pg_temp.vr_eq('9 RLS','有登入但未開通帳號讀不到考官表（0 列）','0', pg_temp.vr_cs('vr-nobody@2motor.tw', 'select count(*)::text from public.assessment_examiners'));
  perform pg_temp.vr_deny('9 RLS','未登入（anon）讀考官表被拒','anon', null, 'select count(*) from public.assessment_examiners', '%permission denied%');
  perform pg_temp.vr_deny('9 RLS','客服部不能直接新增考官列','authenticated', 'vr-ex1@2motor.tw',
    format($q$insert into public.assessment_examiners (assessment_id, slot, email, display_name, scope) values (%L::uuid, 1, 'x@2motor.tw', 'x', '基礎')$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('9 RLS','客服部不能直接修改考官列（抽籤結果、交卷時間都只能由函式改）','authenticated', 'vr-ex1@2motor.tw',
    format($q$update public.assessment_examiners set submitted_at = now() where assessment_id=%L::uuid$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('9 RLS','客服部不能直接刪除考官列','authenticated', 'vr-ex1@2motor.tw',
    format($q$delete from public.assessment_examiners where assessment_id=%L::uuid$q$, a), '%permission denied%');

  perform pg_temp.vr_eq('9 RLS','考官名單：客服部讀得到','true', (pg_temp.vr_cs('vr-cs3@2motor.tw', 'select count(*)::text from public.assess_examiner_pool') = v_pool)::text);
  perform pg_temp.vr_eq('9 RLS','考官名單：店長、主管、未開通帳號都讀不到（0 列）','0/0/0',
    pg_temp.vr_cs('vr-sm1@2motor.tw', 'select count(*)::text from public.assess_examiner_pool') || '/'
    || pg_temp.vr_cs('vr-hq@2motor.tw', 'select count(*)::text from public.assess_examiner_pool') || '/'
    || pg_temp.vr_cs('vr-nobody@2motor.tw', 'select count(*)::text from public.assess_examiner_pool'));
  perform pg_temp.vr_deny('9 RLS','考官名單：未登入（anon）被拒','anon', null, 'select count(*) from public.assess_examiner_pool', '%permission denied%');
  perform pg_temp.vr_deny('9 RLS','考官名單：客服部不能直接修改（只能在 SQL Editor 改）','authenticated', 'vr-ex1@2motor.tw',
    $q$update public.assess_examiner_pool set active = false$q$, '%permission denied%');
  perform pg_temp.vr_deny('9 RLS','考官名單：客服部不能直接新增','authenticated', 'vr-ex1@2motor.tw',
    $q$insert into public.assess_examiner_pool (email, display_name) values ('x@2motor.tw', 'x')$q$, '%permission denied%');

  perform pg_temp.vr_eq('9 RLS','雙考官草稿：店長、主管看不到那張考核與題組（草稿只有客服部）','0/0/0/0',
    pg_temp.vr_cs('vr-sm1@2motor.tw', format($q$select count(*)::text from public.assessments where id=%L::uuid$q$, a)) || '/'
    || pg_temp.vr_cs('vr-hq@2motor.tw', format($q$select count(*)::text from public.assessments where id=%L::uuid$q$, a)) || '/'
    || pg_temp.vr_cs('vr-sm1@2motor.tw', format($q$select count(*)::text from public.assessment_items where assessment_id=%L::uuid$q$, a)) || '/'
    || pg_temp.vr_cs('vr-hq@2motor.tw', format($q$select count(*)::text from public.assessment_items where assessment_id=%L::uuid$q$, a)));
  perform pg_temp.vr_eq('9 RLS','客服部讀得到新欄位：is_dual、slot 暱稱、examiner_slot（基礎 3 題屬考官1）','true/VX1,VX2/3',
    pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select is_dual::text || '/' || least(slot1_name, slot2_name) || ',' || greatest(slot1_name, slot2_name) from public.assessments where id=%L::uuid$q$, a))
    || '/' || pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select count(*)::text from public.assessment_items where assessment_id=%L::uuid and examiner_slot = 1$q$, a)));
  perform pg_temp.vr_deny('9 RLS','assess_draw_dual_items 內部函式：登入者不可直接呼叫（不能繞過開考）','authenticated', 'vr-ex1@2motor.tw',
    format($q$select public.assess_draw_dual_items(%L::uuid)$q$, a), '%permission denied%');
  perform pg_temp.vr_deny('9 RLS','assess_resolve_tenure 內部函式：登入者不可直接呼叫','authenticated', 'vr-ex1@2motor.tw',
    $q$select * from public.assess_resolve_tenure((select e from public.employees e where id='MI-9901'), null)$q$, '%permission denied%');
end
$$;

-- ============================================================
-- 區段 10：健檢（kind='checkup'）與舊單人開考行為不變
-- ============================================================
do $$
declare
  v_c48 uuid;
  v_c54 uuid;
  v_leg uuid;
  j jsonb;
begin
  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind, checkup_year, checkup_quarter)
  values ('MI-9948', '假員9948', 'ZZ-D1', 'vr-cs3@2motor.tw', 'draft', '正式', '自動', 'checkup', 2026, 2) returning id into v_c48;
  insert into public.assessments (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, kind, checkup_year, checkup_quarter)
  values ('MI-9954', '假員9954', 'ZZ-D1', 'vr-cs3@2motor.tw', 'draft', '正式', '自動', 'checkup', 2026, 2) returning id into v_c54;

  perform pg_temp.vr_eq('10 健檢','健檢草稿：is_dual=false、暱稱快照空','false/(null)/(null)',
    pg_temp.vr_q1(format($q$select is_dual::text || '/' || coalesce(slot1_name, '(null)') || '/' || coalesce(slot2_name, '(null)') from public.assessments where id=%L::uuid$q$, v_c48)));
  perform pg_temp.vr_eq('10 健檢','健檢草稿仍可用 assess_draw 抽題（守衛只擋雙考官），題組 examiner_slot 為空','1/(null)',
    pg_temp.vr_cs('vr-cs3@2motor.tw', format($q$select count(*)::text from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, v_c48))
    || '/' || pg_temp.vr_q1(format($q$select coalesce(max(examiner_slot)::text, '(null)') from public.assessment_items where assessment_id=%L::uuid$q$, v_c48)));
  j := pg_temp.vr_sd('vr-ex1@2motor.tw', 'MI-9948');
  perform pg_temp.vr_eq('10 健檢','員工有健檢草稿時，雙考官開考不受影響（健檢不算舊式單人草稿）','true',
    (not (j ? 'error'))::text);
  perform pg_temp.vr_eq('10 健檢','雙考官開考後健檢草稿原封不動：仍是 draft／checkup／非雙考官、題組 1 個','draft/checkup/false/1',
    pg_temp.vr_q1(format($q$select status || '/' || kind || '/' || is_dual::text || '/' || (select count(*)::text from public.assessment_items where assessment_id=a.id) from public.assessments a where a.id=%L::uuid$q$, v_c48)));
  perform pg_temp.vr_eq('10 健檢','同員工的健檢草稿與雙考官草稿並存（雙考官索引只管雙考官）','1/1',
    pg_temp.vr_q1($q$select (select count(*)::text from public.assessments where employee_id='MI-9948' and kind='checkup' and status='draft')
      || '/' || (select count(*)::text from public.assessments where employee_id='MI-9948' and is_dual and status='draft')$q$));

  -- 舊 assess_start：員工只有健檢草稿時，開出另一張一般考核（舊行為不變），再呼叫回傳同一張
  v_leg := pg_temp.vr_cs('vr-cs3@2motor.tw', $q$select public.assess_start('MI-9954')::text$q$)::uuid;
  perform pg_temp.vr_eq('10 舊單','舊 assess_start：不是健檢那張、kind=exam、非雙考官','true/exam/false',
    (v_leg <> v_c54)::text || '/' || pg_temp.vr_q1(format($q$select kind || '/' || is_dual::text from public.assessments where id=%L::uuid$q$, v_leg)));
  perform pg_temp.vr_eq('10 舊單','舊 assess_start 再呼叫：回傳同一張（冪等不變）','true',
    (pg_temp.vr_cs('vr-cs3@2motor.tw', $q$select public.assess_start('MI-9954')::text$q$) = v_leg::text)::text);
end
$$;

-- ============================================================
-- 第二段（DB-2）驗證：擁有者改寫＋放棄規則＋追加題拒絕＋assess_start 守衛（區段 11～16）
-- 假員工：MI-9934（主要流程）、MI-9935／9936／9937（放棄：考官A／考官B／第三位客服部）、MI-9938（已有人交卷的放棄）、
--         MI-9939（追加題被拒）、MI-9940（單人草稿放棄）；舊單人草稿用第一段建立的 MI-9946、健檢草稿用 MI-9948。
-- ============================================================

-- 本段專用工具
create or replace function pg_temp.vr_item(p_aid uuid, p_slot int, p_n int)
returns uuid language sql as $$
  select id from public.assessment_items where assessment_id = p_aid and examiner_slot = p_slot order by seq offset p_n - 1 limit 1;
$$;

create or replace function pg_temp.vr_slot(p_aid uuid, p_email text)
returns int language sql as $$
  select slot::int from public.assessment_examiners where assessment_id = p_aid and email = p_email;
$$;

-- 某位考官最後暫存時間（沒有值回 '(null)'）
create or replace function pg_temp.vr_ts(p_aid uuid, p_email text)
returns text language sql as $$
  select coalesce(last_saved_at::text, '(null)') from public.assessment_examiners where assessment_id = p_aid and email = p_email;
$$;

-- 把某位考官的最後暫存時間設成固定舊值（之後看有沒有被更新）
create or replace function pg_temp.vr_ts_reset(p_aid uuid)
returns void language sql as $$
  update public.assessment_examiners set last_saved_at = '2000-01-01 00:00:00+00' where assessment_id = p_aid;
$$;

-- 某位考官的最後暫存時間是否「被更新過」（晚於 2000-01-01）
create or replace function pg_temp.vr_ts_new(p_aid uuid, p_email text)
returns text language sql as $$
  select (last_saved_at > '2000-01-01 00:00:00+00')::text from public.assessment_examiners where assessment_id = p_aid and email = p_email;
$$;

-- 以某客服身分存七面向全優良；成功回 OK，失敗回 ERROR: 訊息
create or replace function pg_temp.vr_save(p_email text, p_item uuid, p_note text default '備註')
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, %L)$q$, p_item, pg_temp.vr_top()::text, p_note), false);
end $$;

-- 圖片路徑：{考核id}/{題組id}/{uuid}.jpg
create or replace function pg_temp.vr_stpath(p_item uuid)
returns text language sql as $$
  select i.assessment_id::text || '/' || i.id::text || '/' || gen_random_uuid()::text || '.jpg'
    from public.assessment_items i where i.id = p_item;
$$;

-- 以某客服身分新增圖片列；成功回圖片 id，失敗回 ERROR: 訊息
create or replace function pg_temp.vr_addimg(p_email text, p_item uuid, p_path text default null)
returns text language plpgsql as $$
begin
  return pg_temp.vr_cs(p_email,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)::text$q$, p_item, coalesce(p_path, pg_temp.vr_stpath(p_item))));
end $$;

-- 以某客服身分刪圖片列；成功回 storage_path，失敗回 ERROR: 訊息
create or replace function pg_temp.vr_rmimg(p_email text, p_img text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_cs(p_email, format($q$select public.assess_remove_image(%L::uuid)$q$, p_img));
end $$;

-- 以某客服身分刪 storage 物件（RLS 擋住時不報錯、刪 0 筆）；回刪除筆數
create or replace function pg_temp.vr_stdel(p_email text, p_name text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_cs(p_email,
    format($q$with d as (delete from storage.objects where bucket_id = 'assess-notes' and name = %L returning 1) select count(*)::text from d$q$, p_name));
end $$;

-- 以某客服身分新增 storage 物件；成功 OK，被擋回 ERROR: …row-level security…
create or replace function pg_temp.vr_stins(p_email text, p_name text)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, p_name), false);
end $$;

-- ============================================================
-- 區段 11：結構（簽名、安全屬性、權限）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('11 結構','assess_owns_item（內部）：登入者與 anon 都不可執行；assess_i_own_item（policy 用）：登入者可、anon 不可','false/false/true/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated','public.assess_owns_item(uuid, text)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_owns_item(uuid, text)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_i_own_item(uuid)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_i_own_item(uuid)','execute')::text$q$));
  perform pg_temp.vr_eq('11 結構','assess_owns_item、assess_i_own_item 都是 security definer、stable、search_path 固定','true/true',
    pg_temp.vr_q1($q$select (select (prosecdef and provolatile = 's' and proconfig::text like '%search_path=public, pg_temp%')::text from pg_proc where oid='public.assess_owns_item(uuid, text)'::regprocedure)
      || '/' || (select (prosecdef and provolatile = 's' and proconfig::text like '%search_path=public, pg_temp%')::text from pg_proc where oid='public.assess_i_own_item(uuid)'::regprocedure)$q$));
  perform pg_temp.vr_eq('11 結構','改寫的四個函式簽名與回傳型別不變','void|void|uuid|text',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_save_item(uuid, jsonb, text, text)'::regprocedure)
      || '|' || pg_get_function_result('public.assess_save_dim_notes(uuid, jsonb)'::regprocedure)
      || '|' || pg_get_function_result('public.assess_add_image(uuid, text, text, integer)'::regprocedure)
      || '|' || pg_get_function_result('public.assess_remove_image(uuid)'::regprocedure)$q$));
  perform pg_temp.vr_eq('11 結構','assess_save_item 仍是 4 參數（第 4 個有預設值）、沒有舊的 3 參數版本','4/1/0',
    pg_temp.vr_q1($q$select (select pronargs::text from pg_proc where oid='public.assess_save_item(uuid, jsonb, text, text)'::regprocedure)
      || '/' || (select pronargdefaults::text from pg_proc where oid='public.assess_save_item(uuid, jsonb, text, text)'::regprocedure)
      || '/' || (select count(*)::text from pg_proc where pronamespace='public'::regnamespace and proname='assess_save_item' and pronargs=3)$q$));
  perform pg_temp.vr_eq('11 結構','八個被改寫的函式都是 security definer、search_path 固定、登入者可執行、anon 不可','true/true/true',
    pg_temp.vr_q1($q$select (bool_and(p.prosecdef))::text
      || '/' || (bool_and(p.proconfig::text like '%search_path=public, pg_temp%'))::text
      || '/' || (bool_and(has_function_privilege('authenticated', p.oid, 'execute') and not has_function_privilege('anon', p.oid, 'execute')))::text
      from pg_proc p where p.pronamespace='public'::regnamespace
        and p.proname in ('assess_save_item','assess_save_dim_notes','assess_add_image','assess_remove_image','assess_abandon','assess_draft_weak','assess_add_extra','assess_start')$q$));
  perform pg_temp.vr_eq('11 結構','assess_abandon 回傳型別仍是 text[]','text[]',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_abandon(uuid)'::regprocedure)$q$));
  perform pg_temp.vr_eq('11 結構','四個寫入函式都改呼叫 assess_owns_item、雙考官取共享鎖、非雙考官仍保留 for update','4/4/4',
    pg_temp.vr_q1($q$select count(*) filter (where p.prosrc like '%assess_owns_item%')::text
      || '/' || count(*) filter (where p.prosrc like '%for share of a%')::text
      || '/' || count(*) filter (where p.prosrc like '%for update of a%')::text
      from pg_proc p where p.pronamespace='public'::regnamespace
        and p.proname in ('assess_save_item','assess_save_dim_notes','assess_add_image','assess_remove_image')$q$));
  perform pg_temp.vr_eq('11 結構','assess_start 只多一道雙考官守衛（內文 is_dual 恰好出現 1 次，簽名與回傳不變）','1/uuid',
    pg_temp.vr_q1($q$select ((length(prosrc) - length(replace(prosrc, 'is_dual', ''))) / 7)::text || '/' || pg_get_function_result(oid)
      from pg_proc where oid='public.assess_start(text, text)'::regprocedure$q$));
  perform pg_temp.vr_eq('11 結構','storage policy：assess_notes_* 仍恰好 3 條（DELETE、INSERT、SELECT）、都限 authenticated','3/DELETE,INSERT,SELECT/true',
    pg_temp.vr_q1($q$select count(*)::text || '/' || string_agg(cmd, ',' order by cmd) || '/' || (bool_and(roles::text = '{authenticated}'))::text
      from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'assess_notes_%'$q$));
  perform pg_temp.vr_eq('11 結構','storage insert／delete policy 內文改用 assess_i_own_item；select policy 沒動（不含 assess_i_own_item）','true/true/true',
    pg_temp.vr_q1($q$select (select (coalesce(with_check,'') like '%assess_i_own_item%')::text from pg_policies where schemaname='storage' and tablename='objects' and policyname='assess_notes_insert')
      || '/' || (select (coalesce(qual,'') like '%assess_i_own_item%')::text from pg_policies where schemaname='storage' and tablename='objects' and policyname='assess_notes_delete')
      || '/' || (select (coalesce(qual,'') not like '%assess_i_own_item%')::text from pg_policies where schemaname='storage' and tablename='objects' and policyname='assess_notes_select')$q$));
  perform pg_temp.vr_eq('11 結構','（取代第一段「assess_start 沒有被動」）所有內部函式登入者都不可直接呼叫','false/false/false/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated','public.assess_owns_item(uuid, text)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_draw_dual_items(uuid)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_resolve_tenure(public.employees, text)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_examiners_lock()','execute')::text$q$));
end
$$;

-- ============================================================
-- 區段 12：assess_owns_item／assess_i_own_item 本身
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  j jsonb;
  v_a uuid;
  s1 int;
  m1 uuid;
  o1 uuid;
  v_leg uuid;
  v_li uuid;
  v_ck uuid;
  v_ci uuid;
begin
  j := pg_temp.vr_sd(e1, 'MI-9934');
  v_a := (j ->> 'assessment_id')::uuid;
  perform pg_temp.vr_set('a34', v_a::text);
  s1 := pg_temp.vr_slot(v_a, e1);
  m1 := pg_temp.vr_item(v_a, s1, 1);
  o1 := pg_temp.vr_item(v_a, 3 - s1, 1);
  perform pg_temp.vr_eq('12 擁有者','（前置）MI-9934 開考成功；兩位考官各有 3 個題組','true/3/3',
    (not (j ? 'error'))::text || '/' || (select count(*)::text from public.assessment_items where assessment_id = v_a and examiner_slot = s1)
    || '/' || (select count(*)::text from public.assessment_items where assessment_id = v_a and examiner_slot = 3 - s1));

  perform pg_temp.vr_eq('12 擁有者','雙考官：自己的題組 true、對方的題組 false（兩個方向）、非考官客服部 false','true/false/true/false/false',
    pg_temp.vr_q1(format($q$select public.assess_owns_item(%1$L::uuid, %3$L)::text || '/' || public.assess_owns_item(%1$L::uuid, %4$L)::text
      || '/' || public.assess_owns_item(%2$L::uuid, %4$L)::text || '/' || public.assess_owns_item(%2$L::uuid, %3$L)::text
      || '/' || public.assess_owns_item(%1$L::uuid, %5$L)::text$q$, m1, o1, e1, e2, e3)));
  perform pg_temp.vr_eq('12 擁有者','不存在的題組、空白信箱：false','false/false',
    pg_temp.vr_q1(format($q$select public.assess_owns_item(gen_random_uuid(), %L)::text || '/' || public.assess_owns_item(%L::uuid, null)::text$q$, e1, m1)));

  -- 自己已交卷 → 不再擁有（對方仍擁有自己的）
  update public.assessment_examiners set submitted_at = now() where assessment_id = v_a and slot = s1;
  perform pg_temp.vr_eq('12 擁有者','自己的那一位考官已交卷：自己的題組變 false；對方的題組不受影響（仍 true）','false/true',
    pg_temp.vr_q1(format($q$select public.assess_owns_item(%L::uuid, %L)::text || '/' || public.assess_owns_item(%L::uuid, %L)::text$q$, m1, e1, o1, e2)));
  update public.assessment_examiners set submitted_at = null where assessment_id = v_a and slot = s1;
  perform pg_temp.vr_eq('12 擁有者','撤回（submitted_at 清空）後恢復 true','true',
    pg_temp.vr_q1(format($q$select public.assess_owns_item(%L::uuid, %L)::text$q$, m1, e1)));

  -- 非雙考官：舊單人草稿（建立者 vr-cs3）、健檢草稿（建立者 vr-cs3）
  select id into v_leg from public.assessments where employee_id = 'MI-9946' and status = 'draft' and not is_dual;
  select id into v_li from public.assessment_items where assessment_id = v_leg order by seq limit 1;
  select id into v_ck from public.assessments where employee_id = 'MI-9948' and kind = 'checkup' and status = 'draft';
  select id into v_ci from public.assessment_items where assessment_id = v_ck order by seq limit 1;
  perform pg_temp.vr_eq('12 擁有者','非雙考官（單人、健檢）：只有建立者是擁有者，題組沒有 examiner_slot 也一樣','true/false/true/false',
    pg_temp.vr_q1(format($q$select public.assess_owns_item(%1$L::uuid, %3$L)::text || '/' || public.assess_owns_item(%1$L::uuid, %4$L)::text
      || '/' || public.assess_owns_item(%2$L::uuid, %3$L)::text || '/' || public.assess_owns_item(%2$L::uuid, %4$L)::text$q$, v_li, v_ci, e3, e1)));

  -- 給 policy 用的包裝：只回答「我自己」
  perform pg_temp.vr_eq('12 擁有者','assess_i_own_item：考官1 看自己的題組 true、對方的 false；考官2 相反；非考官客服部 false','true/false/false/true/false',
    pg_temp.vr_cs(e1, format($q$select public.assess_i_own_item(%L::uuid)::text$q$, m1)) || '/'
    || pg_temp.vr_cs(e1, format($q$select public.assess_i_own_item(%L::uuid)::text$q$, o1)) || '/'
    || pg_temp.vr_cs(e2, format($q$select public.assess_i_own_item(%L::uuid)::text$q$, m1)) || '/'
    || pg_temp.vr_cs(e2, format($q$select public.assess_i_own_item(%L::uuid)::text$q$, o1)) || '/'
    || pg_temp.vr_cs(e3, format($q$select public.assess_i_own_item(%L::uuid)::text$q$, m1)));
  perform pg_temp.vr_deny('12 擁有者','assess_i_own_item：未登入（anon）被拒','anon', null,
    format($q$select public.assess_i_own_item(%L::uuid)$q$, m1), '%permission denied%');
  perform pg_temp.vr_deny('12 擁有者','assess_owns_item（內部）：登入者不可直接呼叫（不能拿來探查別人）','authenticated', e1,
    format($q$select public.assess_owns_item(%L::uuid, %L)$q$, o1, e2), '%permission denied%');
end
$$;

-- ============================================================
-- 區段 13：雙考官的暫存（評分／備註／面向備註／附圖）：他人題組、已交卷不可寫；自己可寫並更新 last_saved_at
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_a uuid := pg_temp.vr_get('a34')::uuid;
  s1 int;
  m1 uuid; m2 uuid;
  o1 uuid; o2 uuid;
  v_lv jsonb;
  v_img text;
  v_img_o text;
  v_p text;
  i int;
  r text;
begin
  s1 := pg_temp.vr_slot(v_a, e1);
  m1 := pg_temp.vr_item(v_a, s1, 1); m2 := pg_temp.vr_item(v_a, s1, 2);
  o1 := pg_temp.vr_item(v_a, 3 - s1, 1); o2 := pg_temp.vr_item(v_a, 3 - s1, 2);

  -- ===== assess_save_item =====
  perform pg_temp.vr_ts_reset(v_a);
  perform pg_temp.vr_eq('13 評分','考官1 存自己的題組：成功','OK', pg_temp.vr_save(e1, m1, 'A的備註'));
  perform pg_temp.vr_eq('13 評分','寫入七面向與備註；備註網址未帶則為空','7/A的備註/(null)',
    pg_temp.vr_q1(format($q$select (select count(*) from jsonb_object_keys(levels))::text || '/' || coalesce(note, '(null)') || '/' || coalesce(note_url, '(null)') from public.assessment_items where id=%L::uuid$q$, m1)));
  perform pg_temp.vr_eq('13 評分','自己的最後暫存時間被更新、對方的沒動','true/false',
    pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  perform pg_temp.vr_eq('13 評分','對方的題組沒被影響（評分仍是空的）','0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where assessment_id=%L::uuid and examiner_slot = %s and levels <> '{}'::jsonb$q$, v_a, 3 - s1)));

  perform pg_temp.vr_ts_reset(v_a);
  perform pg_temp.vr_deny('13 評分','考官1 存對方（考官2）的題組：被拒（中文訊息）','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, o1, pg_temp.vr_top()::text), '%這個題組不是你負責的%');
  perform pg_temp.vr_eq('13 評分','被拒後對方題組完全沒動、雙方最後暫存時間都沒被更新','0/false/false',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where id=%L::uuid and (levels <> '{}'::jsonb or note is not null)$q$, o1))
    || '/' || pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  perform pg_temp.vr_deny('13 評分','考官2 存考官1 的題組：被拒','authenticated', e2,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, m2, pg_temp.vr_top()::text), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 評分','不在考官名單的客服部（vr-cs3）存任何一邊：被拒','authenticated', e3,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, m2, pg_temp.vr_top()::text), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 評分','不在考官名單的客服部存對方那邊：被拒','authenticated', e3,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, o2, pg_temp.vr_top()::text), '%這個題組不是你負責的%');
  perform pg_temp.vr_denyset('13 評分','assess_save_item', format($q$select public.assess_save_item(%L::uuid, %L::jsonb, 'x')$q$, m2, pg_temp.vr_top()::text), 'hsna');
  perform pg_temp.vr_deny('13 評分','不存在的題組：找不到題組','authenticated', e1,
    format($q$select public.assess_save_item(gen_random_uuid(), %L::jsonb, 'x')$q$, pg_temp.vr_top()::text), '%找不到題組%');

  perform pg_temp.vr_eq('13 評分','考官2 存自己的題組：成功，且只更新自己的最後暫存時間','OK/true/false',
    pg_temp.vr_save(e2, o1, 'B的備註') || '/' || pg_temp.vr_ts_new(v_a, e2) || '/' || pg_temp.vr_ts_new(v_a, e1));
  perform pg_temp.vr_eq('13 評分','兩位考官各存各的題組，內容互不覆蓋（考官1 的備註仍是 A的備註）','A的備註/B的備註',
    pg_temp.vr_q1(format($q$select (select note from public.assessment_items where id=%L::uuid) || '/' || (select note from public.assessment_items where id=%L::uuid)$q$, m1, o1)));
  perform pg_temp.vr_eq('13 評分','備註網址參數（第 4 個）照常運作','OK/https://example.com/x',
    pg_temp.vr_as('authenticated', e1, format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註', 'https://example.com/x')$q$, m1, pg_temp.vr_top()::text), false)
    || '/' || pg_temp.vr_q1(format($q$select note_url from public.assessment_items where id=%L::uuid$q$, m1)));
  perform pg_temp.vr_deny('13 評分','備註網址格式錯誤：仍報原本的訊息（檢查順序不變）','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註', '不是網址')$q$, m1, pg_temp.vr_top()::text), '%備註網址格式不正確%');
  perform pg_temp.vr_deny('13 評分','舊制等級：仍被擋（等級檢查不變）','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, '{"資訊正確性":"良"}'::jsonb, '備註')$q$, m1), '%舊制等級%');

  -- ===== assess_save_dim_notes =====
  v_lv := pg_temp.vr_top() || '{"預設訊息運用":"尚可"}'::jsonb;
  perform pg_temp.vr_as('authenticated', e1, format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註')$q$, m1, v_lv::text), false);
  perform pg_temp.vr_ts_reset(v_a);
  perform pg_temp.vr_eq('13 面向備註','考官1 對自己的題組存面向備註：成功，並更新自己的最後暫存時間','OK/true/false',
    pg_temp.vr_as('authenticated', e1, format($q$select public.assess_save_dim_notes(%L::uuid, '{"預設訊息運用":"回覆太制式"}'::jsonb)$q$, m1), false)
    || '/' || pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  perform pg_temp.vr_eq('13 面向備註','面向備註寫進機密表','回覆太制式',
    pg_temp.vr_q1(format($q$select dim_notes ->> '預設訊息運用' from public.assessment_item_secrets where item_id=%L::uuid$q$, m1)));
  perform pg_temp.vr_ts_reset(v_a);
  perform pg_temp.vr_deny('13 面向備註','考官2 對考官1 的題組存面向備註：被拒','authenticated', e2,
    format($q$select public.assess_save_dim_notes(%L::uuid, '{"預設訊息運用":"偷改"}'::jsonb)$q$, m1), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 面向備註','不在名單的客服部存面向備註：被拒','authenticated', e3,
    format($q$select public.assess_save_dim_notes(%L::uuid, '{"預設訊息運用":"偷改"}'::jsonb)$q$, m1), '%這個題組不是你負責的%');
  perform pg_temp.vr_eq('13 面向備註','被拒後面向備註沒被改、最後暫存時間沒被更新','回覆太制式/false/false',
    pg_temp.vr_q1(format($q$select dim_notes ->> '預設訊息運用' from public.assessment_item_secrets where item_id=%L::uuid$q$, m1))
    || '/' || pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  perform pg_temp.vr_denyset('13 面向備註','assess_save_dim_notes', format($q$select public.assess_save_dim_notes(%L::uuid, '{}'::jsonb)$q$, m1), 'hsna');
  perform pg_temp.vr_deny('13 面向備註','不存在的題組：找不到題組','authenticated', e1,
    $q$select public.assess_save_dim_notes(gen_random_uuid(), '{}'::jsonb)$q$, '%找不到題組%');
  perform pg_temp.vr_deny('13 面向備註','格式不是物件：仍報原本的訊息','authenticated', e1,
    format($q$select public.assess_save_dim_notes(%L::uuid, '[]'::jsonb)$q$, m1), '%面向備註格式不正確%');

  -- ===== assess_add_image / assess_remove_image =====
  perform pg_temp.vr_ts_reset(v_a);
  v_img := pg_temp.vr_addimg(e1, m1);
  perform pg_temp.vr_eq('13 附圖','考官1 在自己的題組新增圖片：成功（回圖片 id），並更新自己的最後暫存時間','true/true/false',
    (v_img not like 'ERROR%')::text || '/' || pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  perform pg_temp.vr_ts_reset(v_a);
  perform pg_temp.vr_deny('13 附圖','考官2 在考官1 的題組新增圖片：被拒','authenticated', e2,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, m1, pg_temp.vr_stpath(m1)), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 附圖','不在名單的客服部新增圖片：被拒','authenticated', e3,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, m1, pg_temp.vr_stpath(m1)), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 附圖','考官1 在對方的題組新增圖片：被拒','authenticated', e1,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, o1, pg_temp.vr_stpath(o1)), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 附圖','考官2 刪考官1 的圖片：被拒','authenticated', e2,
    format($q$select public.assess_remove_image(%L::uuid)$q$, v_img), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 附圖','不在名單的客服部刪圖片：被拒','authenticated', e3,
    format($q$select public.assess_remove_image(%L::uuid)$q$, v_img), '%這個題組不是你負責的%');
  perform pg_temp.vr_eq('13 附圖','被拒後圖片還在、最後暫存時間沒被更新','1/false/false',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_item_images where item_id=%L::uuid$q$, m1))
    || '/' || pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  perform pg_temp.vr_deny('13 附圖','路徑前綴不是自己的題組：仍報原本的訊息（檢查順序不變）','authenticated', e1,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, m1, pg_temp.vr_stpath(o1)), '%圖片路徑必須以%');
  perform pg_temp.vr_deny('13 附圖','mime 不合：仍報原本的訊息','authenticated', e1,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/gif', 1000)$q$, m1, pg_temp.vr_stpath(m1)), '%jpeg、png、webp%');
  for i in 1..4 loop
    perform pg_temp.vr_addimg(e1, m1);
  end loop;
  perform pg_temp.vr_deny('13 附圖','第 6 張圖片：仍報「每個題組最多 5 張圖片」','authenticated', e1,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, m1, pg_temp.vr_stpath(m1)), '%最多 5 張%');
  perform pg_temp.vr_denyset('13 附圖','assess_add_image', format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, m1, pg_temp.vr_stpath(m1)), 'hsna');
  perform pg_temp.vr_denyset('13 附圖','assess_remove_image', format($q$select public.assess_remove_image(%L::uuid)$q$, v_img), 'hsna');
  perform pg_temp.vr_deny('13 附圖','不存在的圖片：找不到圖片','authenticated', e1,
    $q$select public.assess_remove_image(gen_random_uuid())$q$, '%找不到圖片%');
  perform pg_temp.vr_ts_reset(v_a);
  v_p := (select storage_path from public.assessment_item_images where id = v_img::uuid);
  perform pg_temp.vr_eq('13 附圖','考官1 刪自己的圖片：成功、回傳該圖路徑、更新自己的最後暫存時間','true/true/false',
    (pg_temp.vr_rmimg(e1, v_img) = v_p)::text || '/' || pg_temp.vr_ts_new(v_a, e1) || '/' || pg_temp.vr_ts_new(v_a, e2));
  v_img_o := pg_temp.vr_addimg(e2, o1);
  perform pg_temp.vr_eq('13 附圖','考官2 在自己的題組新增圖片成功；雙方圖片各在各的題組','true/4/1',
    (v_img_o not like 'ERROR%')::text || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_item_images where item_id=%L::uuid$q$, m1))
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_item_images where item_id=%L::uuid$q$, o1)));

  -- ===== 自己已交卷：自己的題組全部不可寫；對方不受影響 =====
  update public.assessment_examiners set submitted_at = now() where assessment_id = v_a and slot = s1;
  perform pg_temp.vr_ts_reset(v_a);
  perform pg_temp.vr_deny('13 已交卷','考官1 已交卷：存自己的題組被拒（提示先撤回送出）','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '交卷後偷改')$q$, m1, pg_temp.vr_top()::text), '%已送出自己的題組%撤回送出%');
  perform pg_temp.vr_deny('13 已交卷','考官1 已交卷：存面向備註被拒','authenticated', e1,
    format($q$select public.assess_save_dim_notes(%L::uuid, '{"預設訊息運用":"交卷後偷改"}'::jsonb)$q$, m1), '%已送出自己的題組%撤回送出%');
  perform pg_temp.vr_deny('13 已交卷','考官1 已交卷：新增圖片被拒','authenticated', e1,
    format($q$select public.assess_add_image(%L::uuid, %L, 'image/jpeg', 1000)$q$, m1, pg_temp.vr_stpath(m1)), '%已送出自己的題組%撤回送出%');
  perform pg_temp.vr_deny('13 已交卷','考官1 已交卷：刪除圖片被拒','authenticated', e1,
    format($q$select public.assess_remove_image(%L::uuid)$q$, (select id::text from public.assessment_item_images where item_id = m1 limit 1)), '%已送出自己的題組%撤回送出%');
  perform pg_temp.vr_eq('13 已交卷','被拒後備註、面向備註、圖片都沒變；最後暫存時間沒被更新','備註/回覆太制式/4/false',
    pg_temp.vr_q1(format($q$select (select note from public.assessment_items where id=%1$L::uuid) || '/' || (select dim_notes ->> '預設訊息運用' from public.assessment_item_secrets where item_id=%1$L::uuid)
      || '/' || (select count(*)::text from public.assessment_item_images where item_id=%1$L::uuid)$q$, m1))
    || '/' || pg_temp.vr_ts_new(v_a, e1));
  perform pg_temp.vr_eq('13 已交卷','考官1 已交卷後，考官2 照樣能存自己的題組、新增與刪除自己的圖片（只更新考官2 的時間）','OK/true/true/true/false',
    pg_temp.vr_save(e2, o2, 'B第二題') || '/' || pg_temp.vr_ts_new(v_a, e2)
    || '/' || (pg_temp.vr_addimg(e2, o2) not like 'ERROR%')::text
    || '/' || (pg_temp.vr_rmimg(e2, v_img_o) like '%/%')::text
    || '/' || pg_temp.vr_ts_new(v_a, e1));
  perform pg_temp.vr_deny('13 已交卷','考官1 已交卷後，考官2 仍不能碰考官1 的題組','authenticated', e2,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, m1, pg_temp.vr_top()::text), '%這個題組不是你負責的%');
  perform pg_temp.vr_deny('13 已交卷','考官1 已交卷後，也不能改對方的題組','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, o2, pg_temp.vr_top()::text), '%這個題組不是你負責的%');
  -- 撤回後恢復
  update public.assessment_examiners set submitted_at = null where assessment_id = v_a and slot = s1;
  perform pg_temp.vr_eq('13 已交卷','撤回送出（submitted_at 清空）後，考官1 又可以存自己的題組','OK',
    pg_temp.vr_save(e1, m1, '撤回後可改'));
end
$$;

-- ============================================================
-- 區段 14：storage policy（assess_notes_insert／assess_notes_delete）
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_a uuid := pg_temp.vr_get('a34')::uuid;
  s1 int;
  m1 uuid; o1 uuid;
  v_leg uuid; v_li uuid;
  p_m text; p_o text; p_m2 text; p_leg text; p_orph text; p_orph2 text;
begin
  s1 := pg_temp.vr_slot(v_a, e1);
  m1 := pg_temp.vr_item(v_a, s1, 1);
  o1 := pg_temp.vr_item(v_a, 3 - s1, 1);
  p_m := pg_temp.vr_stpath(m1);
  p_o := pg_temp.vr_stpath(o1);

  -- insert
  perform pg_temp.vr_eq('14 Storage','雙考官：考官1 上傳到自己的題組路徑：成功','OK', pg_temp.vr_stins(e1, p_m));
  perform pg_temp.vr_eq('14 Storage','雙考官：考官2 上傳到自己的題組路徑：成功','OK', pg_temp.vr_stins(e2, p_o));
  perform pg_temp.vr_eq('14 Storage','雙考官：考官1 上傳到對方題組路徑：被擋（RLS）','true',
    pg_temp.vr_lk(pg_temp.vr_stins(e1, pg_temp.vr_stpath(o1)), 'ERROR:%row-level security%'));
  perform pg_temp.vr_eq('14 Storage','雙考官：考官2 上傳到考官1 的題組路徑：被擋','true',
    pg_temp.vr_lk(pg_temp.vr_stins(e2, pg_temp.vr_stpath(m1)), 'ERROR:%row-level security%'));
  perform pg_temp.vr_eq('14 Storage','雙考官：不在名單的客服部上傳到任何一邊：被擋','true/true',
    pg_temp.vr_lk(pg_temp.vr_stins(e3, pg_temp.vr_stpath(m1)), 'ERROR:%row-level security%') || '/'
    || pg_temp.vr_lk(pg_temp.vr_stins(e3, pg_temp.vr_stpath(o1)), 'ERROR:%row-level security%'));
  perform pg_temp.vr_eq('14 Storage','雙考官：路徑第一段是別張考核（用 MI-9901 那張的考核 id＋自己題組 id）：被擋','true',
    pg_temp.vr_lk(pg_temp.vr_stins(e1, pg_temp.vr_get('a1') || '/' || m1::text || '/' || gen_random_uuid()::text || '.jpg'), 'ERROR:%row-level security%'));
  perform pg_temp.vr_eq('14 Storage','路徑格式不合（副檔名 gif）：仍被擋（格式檢查沒動）','true',
    pg_temp.vr_lk(pg_temp.vr_stins(e1, v_a::text || '/' || m1::text || '/' || gen_random_uuid()::text || '.gif'), 'ERROR:%row-level security%'));

  -- delete（RLS 擋住時刪 0 筆）
  perform pg_temp.vr_eq('14 Storage','雙考官：考官2、非考官客服部刪考官1 題組的檔案：刪 0 筆（刪不掉）','0/0',
    pg_temp.vr_stdel(e2, p_m) || '/' || pg_temp.vr_stdel(e3, p_m));
  perform pg_temp.vr_eq('14 Storage','雙考官：考官1 刪對方題組的檔案：刪 0 筆','0', pg_temp.vr_stdel(e1, p_o));

  -- 已交卷：自己不再能上傳／刪除
  update public.assessment_examiners set submitted_at = now() where assessment_id = v_a and slot = s1;
  perform pg_temp.vr_eq('14 Storage','雙考官：考官1 已交卷：上傳自己題組路徑被擋、刪自己的檔案刪 0 筆','true/0',
    pg_temp.vr_lk(pg_temp.vr_stins(e1, pg_temp.vr_stpath(m1)), 'ERROR:%row-level security%') || '/' || pg_temp.vr_stdel(e1, p_m));
  perform pg_temp.vr_eq('14 Storage','雙考官：考官1 已交卷時，考官2 仍可上傳自己題組','OK', pg_temp.vr_stins(e2, pg_temp.vr_stpath(o1)));
  update public.assessment_examiners set submitted_at = null where assessment_id = v_a and slot = s1;
  perform pg_temp.vr_eq('14 Storage','雙考官：撤回後考官1 刪自己的檔案：刪 1 筆','1', pg_temp.vr_stdel(e1, p_m));
  perform pg_temp.vr_eq('14 Storage','雙考官：考官2 刪自己的檔案：刪 1 筆','1', pg_temp.vr_stdel(e2, p_o));

  -- 孤兒檔：考核已不存在時，任何客服部都能清（保留原本那一支）
  p_orph := gen_random_uuid()::text || '/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg';
  p_orph2 := gen_random_uuid()::text || '/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg';
  insert into storage.objects (bucket_id, name) values ('assess-notes', p_orph), ('assess-notes', p_orph2);
  perform pg_temp.vr_eq('14 Storage','孤兒檔（考核已不存在）：任何客服部都可刪（考官、非考官各刪一個）','1/1',
    pg_temp.vr_stdel(e1, p_orph) || '/' || pg_temp.vr_stdel(e3, p_orph2));
  perform pg_temp.vr_eq('14 Storage','店長、主管、未開通帳號刪不掉任何檔案（0 筆）','0/0/0',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw', format($q$with d as (delete from storage.objects where bucket_id='assess-notes' and name=%L returning 1) select count(*)::text from d$q$, p_m), true) || '/'
    || pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw', format($q$with d as (delete from storage.objects where bucket_id='assess-notes' and name=%L returning 1) select count(*)::text from d$q$, p_m), true) || '/'
    || pg_temp.vr_as('authenticated', 'vr-nobody@2motor.tw', format($q$with d as (delete from storage.objects where bucket_id='assess-notes' and name=%L returning 1) select count(*)::text from d$q$, p_m), true));

  -- 舊單人草稿（建立者 vr-cs3）：行為不變
  select id into v_leg from public.assessments where employee_id = 'MI-9946' and status = 'draft' and not is_dual;
  select id into v_li from public.assessment_items where assessment_id = v_leg order by seq limit 1;
  p_leg := pg_temp.vr_stpath(v_li);
  perform pg_temp.vr_eq('14 Storage','單人草稿：建立者上傳成功；其他客服部（含考官）上傳被擋','OK/true',
    pg_temp.vr_stins(e3, p_leg) || '/' || pg_temp.vr_lk(pg_temp.vr_stins(e1, pg_temp.vr_stpath(v_li)), 'ERROR:%row-level security%'));
  perform pg_temp.vr_eq('14 Storage','單人草稿：其他客服部刪不掉（0 筆）；建立者刪得掉（1 筆）','0/1',
    pg_temp.vr_stdel(e1, p_leg) || '/' || pg_temp.vr_stdel(e3, p_leg));
  perform pg_temp.vr_eq('14 Storage','policy 仍是 3 條','3',
    pg_temp.vr_q1($q$select count(*)::text from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'assess_notes_%'$q$));
end
$$;

-- ============================================================
-- 區段 15：放棄（assess_abandon）
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_a uuid; v_b uuid; v_c uuid; v_d uuid;
  sa int;
  ma uuid; oa uuid;
  v_img text;
  v_path text;
  v_res text;
  v_qf bigint;   -- was_drawn_before=false 的題
  v_qt bigint;   -- was_drawn_before=true 的題
  v_its text;
  v_single uuid; v_si uuid; v_sq bigint; v_swas boolean;
begin
  -- ===== 考官A（開考者 vr-ex1）放棄 MI-9935：回傳圖片路徑、歸還題池 =====
  v_a := (pg_temp.vr_sd(e1, 'MI-9935') ->> 'assessment_id')::uuid;
  sa := pg_temp.vr_slot(v_a, e1);
  ma := pg_temp.vr_item(v_a, sa, 1);
  oa := pg_temp.vr_item(v_a, 3 - sa, 1);
  v_img := pg_temp.vr_addimg(e1, ma);
  v_path := (select storage_path from public.assessment_item_images where id = v_img::uuid);
  -- 讓兩種情況都有：ma 的題標成「抽之前就在 drawn」（要保留），oa 的題標成「抽之前不在」（要歸還）
  update public.assessment_item_secrets set was_drawn_before = true where item_id = ma;
  update public.assessment_item_secrets set was_drawn_before = false where item_id = oa;
  select question_id into v_qt from public.assessment_item_secrets where item_id = ma;
  select question_id into v_qf from public.assessment_item_secrets where item_id = oa;
  v_its := (select string_agg(id::text, ',') from public.assessment_items where assessment_id = v_a);
  insert into public.drawn (question_id) values (v_qt), (v_qf) on conflict (question_id) do nothing;
  perform pg_temp.vr_eq('15 放棄','（前置）放棄前：6 題組、2 位考官、該題都在 drawn','6/2/true/true',
    (select count(*)::text from public.assessment_items where assessment_id = v_a) || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = v_a)
    || '/' || exists (select 1 from public.drawn where question_id = v_qt)::text || '/' || exists (select 1 from public.drawn where question_id = v_qf)::text);
  v_res := pg_temp.vr_cs(e1, format($q$select public.assess_abandon(%L::uuid)::text$q$, v_a));
  perform pg_temp.vr_eq('15 放棄','考官A（開考者）放棄雙考官草稿：成功，回傳該草稿所有圖片路徑','{' || v_path || '}', v_res);
  perform pg_temp.vr_eq('15 放棄','整張刪除：考核、考官表、題組、機密、圖片列全部消失','0/0/0/0/0',
    (select count(*)::text from public.assessments where id = v_a) || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = v_a)
    || '/' || (select count(*)::text from public.assessment_items where assessment_id = v_a)
    || '/' || (select count(*)::text from public.assessment_item_secrets where question_id in (v_qt, v_qf) and item_id = any(string_to_array(v_its, ',')::uuid[]))
    || '/' || (select count(*)::text from public.assessment_item_images where id = v_img::uuid));
  perform pg_temp.vr_eq('15 放棄','歸還題池：was_drawn_before=false 的題離開 drawn；=true 的題留著','false/true',
    exists (select 1 from public.drawn where question_id = v_qf)::text || '/' || exists (select 1 from public.drawn where question_id = v_qt)::text);
  perform pg_temp.vr_eq('15 放棄','放棄後同一位員工可以重新開雙考官考核','true',
    (not (pg_temp.vr_sd(e2, 'MI-9935') ? 'error'))::text);

  -- ===== 考官B（不是開考者）放棄 MI-9936 =====
  v_b := (pg_temp.vr_sd(e1, 'MI-9936') ->> 'assessment_id')::uuid;
  v_res := pg_temp.vr_cs(e2, format($q$select public.assess_abandon(%L::uuid)::text$q$, v_b));
  perform pg_temp.vr_eq('15 放棄','考官B（不是開考者的那位）放棄：成功（空圖片陣列）、整張消失','{}/0/0',
    v_res || '/' || (select count(*)::text from public.assessments where id = v_b) || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = v_b));

  -- ===== 第三位客服部（不在考官名單的 cs_admin）放棄 MI-9937 =====
  v_c := (pg_temp.vr_sd(e2, 'MI-9937') ->> 'assessment_id')::uuid;
  v_res := pg_temp.vr_cs(e3, format($q$select public.assess_abandon(%L::uuid)::text$q$, v_c));
  perform pg_temp.vr_eq('15 放棄','第三位客服部（非考官）放棄：成功、整張消失','{}/0/0/0',
    v_res || '/' || (select count(*)::text from public.assessments where id = v_c) || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = v_c)
    || '/' || (select count(*)::text from public.assessment_items where assessment_id = v_c));

  -- ===== 已有考官交卷：任何人都不能放棄，請先撤回送出 =====
  v_d := (pg_temp.vr_sd(e1, 'MI-9938') ->> 'assessment_id')::uuid;
  update public.assessment_examiners set submitted_at = now() where assessment_id = v_d and email = e2;
  perform pg_temp.vr_deny('15 放棄','只有對方交卷：開考者（考官1/2 之一）放棄被拒，提示請先撤回送出','authenticated', e1,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_d), '%請先撤回送出%');
  perform pg_temp.vr_deny('15 放棄','已交卷的考官自己放棄也被拒','authenticated', e2,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_d), '%請先撤回送出%');
  perform pg_temp.vr_deny('15 放棄','第三位客服部放棄也被拒','authenticated', e3,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_d), '%請先撤回送出%');
  update public.assessment_examiners set submitted_at = now() where assessment_id = v_d and email = e1;
  perform pg_temp.vr_deny('15 放棄','兩位都交卷：仍被拒','authenticated', e3,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_d), '%請先撤回送出%');
  perform pg_temp.vr_eq('15 放棄','被拒後草稿完整保留（6 題組、2 位考官、狀態 draft）','6/2/draft',
    (select count(*)::text from public.assessment_items where assessment_id = v_d) || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = v_d)
    || '/' || (select status from public.assessments where id = v_d));
  update public.assessment_examiners set submitted_at = null where assessment_id = v_d and email = e1;
  perform pg_temp.vr_deny('15 放棄','只剩對方還交著卷（我已撤回）：仍被拒（任一位已交卷就拒絕）','authenticated', e1,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_d), '%請先撤回送出%');
  update public.assessment_examiners set submitted_at = null where assessment_id = v_d and email = e2;
  v_res := pg_temp.vr_cs(e3, format($q$select public.assess_abandon(%L::uuid)::text$q$, v_d));
  perform pg_temp.vr_eq('15 放棄','兩位都撤回後：第三位客服部可以放棄','{}/0',
    v_res || '/' || (select count(*)::text from public.assessments where id = v_d));

  -- ===== 權限 =====
  perform pg_temp.vr_denyset('15 放棄','assess_abandon（雙考官草稿 MI-9934）', format($q$select public.assess_abandon(%L::uuid)$q$, pg_temp.vr_get('a34')::uuid), 'hsna');
  perform pg_temp.vr_deny('15 放棄','不存在的考核：找不到考核','authenticated', e1, $q$select public.assess_abandon(gen_random_uuid())$q$, '%找不到考核%');
  perform pg_temp.vr_eq('15 放棄','被拒的放棄都沒動 MI-9934 那張（仍在、6 題組、2 位考官）','1/6/2',
    (select count(*)::text from public.assessments where id = pg_temp.vr_get('a34')::uuid)
    || '/' || (select count(*)::text from public.assessment_items where assessment_id = pg_temp.vr_get('a34')::uuid)
    || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = pg_temp.vr_get('a34')::uuid));

  -- ===== 單人草稿：行為逐行不變（任一客服部都可放棄、回傳圖片路徑、歸還題池）=====
  v_single := pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9940')::text$q$)::uuid;
  perform pg_temp.vr_cs(e3, format($q$select count(*)::text from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, v_single));
  select i.id into v_si from public.assessment_items i where i.assessment_id = v_single limit 1;
  select sx.question_id, sx.was_drawn_before into v_sq, v_swas from public.assessment_item_secrets sx where sx.item_id = v_si;
  v_img := pg_temp.vr_addimg(e3, v_si);
  v_path := (select storage_path from public.assessment_item_images where id = v_img::uuid);
  perform pg_temp.vr_eq('15 單人','（前置）單人草稿：1 個題組、1 張圖、沒有考官表資料','1/1/0',
    (select count(*)::text from public.assessment_items where assessment_id = v_single) || '/' || (select count(*)::text from public.assessment_item_images where item_id = v_si)
    || '/' || (select count(*)::text from public.assessment_examiners where assessment_id = v_single));
  perform pg_temp.vr_eq('15 單人','單人草稿由另一位客服部（vr-ex2）放棄：成功並回傳圖片路徑','{' || v_path || '}',
    pg_temp.vr_cs(e2, format($q$select public.assess_abandon(%L::uuid)::text$q$, v_single)));
  perform pg_temp.vr_eq('15 單人','單人草稿放棄後：考核與題組消失；was_drawn_before=false 才歸還題池（與舊行為一致）','0/0/true',
    (select count(*)::text from public.assessments where id = v_single) || '/' || (select count(*)::text from public.assessment_items where assessment_id = v_single)
    || '/' || (exists (select 1 from public.drawn where question_id = v_sq) = v_swas)::text);
  perform pg_temp.vr_denyset('15 單人','assess_abandon（單人）', format($q$select public.assess_abandon(%L::uuid)$q$, (select id from public.assessments where employee_id = 'MI-9946' and status = 'draft' and not is_dual)), 'hsna');
end
$$;

-- ============================================================
-- 區段 16：追加題拒絕、assess_start 守衛、單人／健檢／新人流程不受影響
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_w uuid;
  v_a uuid := pg_temp.vr_get('a34')::uuid;
  v_leg uuid; v_li uuid; v_ck uuid; v_ci uuid; v_n41 uuid; v_ni uuid;
  v_q bigint := (select min(id) from public.questions where category = '基礎' and code like 'ZDB%');
  s1 int;
  v_cnt0 text;
  v_id text;
  v_img text;
  v_lv jsonb;
begin
  -- ===== 追加題（規則5）=====
  v_w := (pg_temp.vr_sd(e1, 'MI-9939') ->> 'assessment_id')::uuid;
  perform pg_temp.vr_deny('16 追加題','assess_draft_weak：雙考官草稿被拒（開考者）','authenticated', e1,
    format($q$select public.assess_draft_weak(%L::uuid)$q$, v_w), '%雙考官考核不支援弱項追加題%');
  perform pg_temp.vr_deny('16 追加題','assess_draft_weak：另一位考官也被拒','authenticated', e2,
    format($q$select public.assess_draft_weak(%L::uuid)$q$, v_w), '%雙考官考核不支援弱項追加題%');
  perform pg_temp.vr_deny('16 追加題','assess_draft_weak：第三位客服部也被拒','authenticated', e3,
    format($q$select public.assess_draft_weak(%L::uuid)$q$, v_w), '%雙考官考核不支援弱項追加題%');
  perform pg_temp.vr_deny('16 追加題','assess_add_extra：雙考官草稿被拒（開考者）','authenticated', e1,
    format($q$select count(*) from public.assess_add_extra(%L::uuid, array[%s::bigint])$q$, v_w, v_q), '%雙考官考核不支援弱項追加題%');
  perform pg_temp.vr_deny('16 追加題','assess_add_extra：另一位考官也被拒','authenticated', e2,
    format($q$select count(*) from public.assess_add_extra(%L::uuid, array[%s::bigint])$q$, v_w, v_q), '%雙考官考核不支援弱項追加題%');
  perform pg_temp.vr_deny('16 追加題','assess_add_extra：第三位客服部也被拒','authenticated', e3,
    format($q$select count(*) from public.assess_add_extra(%L::uuid, array[%s::bigint])$q$, v_w, v_q), '%雙考官考核不支援弱項追加題%');
  perform pg_temp.vr_eq('16 追加題','被拒後沒有追加題、extra_started_at 沒被寫','0/(null)',
    pg_temp.vr_q1(format($q$select (select count(*)::text from public.assessment_items where assessment_id=%1$L::uuid and is_extra) || '/' || (select coalesce(extra_started_at::text, '(null)') from public.assessments where id=%1$L::uuid)$q$, v_w)));
  perform pg_temp.vr_denyset('16 追加題','assess_draft_weak', format($q$select public.assess_draft_weak(%L::uuid)$q$, v_w), 'hsna');
  perform pg_temp.vr_denyset('16 追加題','assess_add_extra', format($q$select count(*) from public.assess_add_extra(%L::uuid, array[%s::bigint])$q$, v_w, v_q), 'hsna');
  perform pg_temp.vr_deny('16 追加題','不存在的考核：assess_draft_weak 仍報「找不到考核」','authenticated', e1,
    $q$select public.assess_draft_weak(gen_random_uuid())$q$, '%找不到考核%');
  perform pg_temp.vr_deny('16 追加題','不存在的考核：assess_add_extra 仍報「找不到考核」','authenticated', e1,
    format($q$select count(*) from public.assess_add_extra(gen_random_uuid(), array[%s::bigint])$q$, v_q), '%找不到考核%');

  -- 單人草稿（vr-cs3 建立，MI-9946）：兩個函式行為不變（訊息不變）
  select id into v_leg from public.assessments where employee_id = 'MI-9946' and status = 'draft' and not is_dual;
  perform pg_temp.vr_deny('16 單人','單人草稿：非建立者 assess_draft_weak 仍報「只有建立者本人」','authenticated', e1,
    format($q$select public.assess_draft_weak(%L::uuid)$q$, v_leg), '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_deny('16 單人','單人草稿：非建立者 assess_add_extra 仍報「只有建立者本人」','authenticated', e1,
    format($q$select count(*) from public.assess_add_extra(%L::uuid, array[%s::bigint])$q$, v_leg, v_q), '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_deny('16 單人','單人草稿：建立者 assess_draft_weak 照舊進入評分檢查（題組尚未評完），不是被雙考官守衛擋','authenticated', e3,
    format($q$select public.assess_draft_weak(%L::uuid)$q$, v_leg), '%尚未評完或評分不正確%');
  perform pg_temp.vr_deny('16 單人','單人草稿：建立者 assess_add_extra 照舊進入評分檢查（核心題組尚未評完）','authenticated', e3,
    format($q$select count(*) from public.assess_add_extra(%L::uuid, array[%s::bigint])$q$, v_leg, v_q), '%核心題組尚未評完%');

  -- ===== assess_start 守衛 =====
  v_cnt0 := pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id = 'MI-9934'$q$);
  perform pg_temp.vr_deny('16 開考守衛','舊 assess_start：員工已有進行中的雙考官草稿（考官本人呼叫）被拒（中文訊息）','authenticated', e1,
    $q$select public.assess_start('MI-9934')$q$, '%這位考生已有進行中的雙考官考核，請從草稿清單進入%');
  perform pg_temp.vr_deny('16 開考守衛','舊 assess_start：另一位考官呼叫也被拒（不會建出單人草稿）','authenticated', e2,
    $q$select public.assess_start('MI-9934')$q$, '%這位考生已有進行中的雙考官考核%');
  perform pg_temp.vr_deny('16 開考守衛','舊 assess_start：第三位客服部呼叫也被拒','authenticated', e3,
    $q$select public.assess_start('MI-9934')$q$, '%這位考生已有進行中的雙考官考核%');
  perform pg_temp.vr_eq('16 開考守衛','被拒後沒有新增任何考核（這位員工仍只有那一張）','true',
    (pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id = 'MI-9934'$q$) = v_cnt0)::text);
  perform pg_temp.vr_denyset('16 開考守衛','assess_start', $q$select public.assess_start('MI-9934')$q$, 'hsna');
  perform pg_temp.vr_deny('16 開考守衛','不存在的員工：仍報「找不到員工」（守衛排在員工檢查之後）','authenticated', e1,
    $q$select public.assess_start('MI-0000')$q$, '%找不到員工%');
  perform pg_temp.vr_deny('16 開考守衛','不納入考核的員工：仍報「不在考核名單」','authenticated', e1,
    $q$select public.assess_start('MI-9944')$q$, '%不在考核名單%');
  -- MI-9936 的雙考官草稿已在區段 15 被放棄 → 舊 assess_start 恢復可用，且冪等
  v_id := pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9936')::text$q$);
  perform pg_temp.vr_eq('16 開考守衛','雙考官草稿放棄之後：舊 assess_start 可用（回傳 uuid、單人草稿、非雙考官）','true/false/exam',
    (v_id not like 'ERROR%')::text || '/' || pg_temp.vr_q1(format($q$select is_dual::text || '/' || kind from public.assessments where id=%L::uuid$q$, v_id)) );
  perform pg_temp.vr_eq('16 開考守衛','…且重複呼叫回傳同一張（舊的冪等行為不變）','true',
    (pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9936')::text$q$) = v_id)::text);
  perform pg_temp.vr_eq('16 開考守衛','舊 assess_start 開了單人草稿之後，雙考官開考仍被擋（第一段規則）','true',
    pg_temp.vr_lk(pg_temp.vr_sd(e1, 'MI-9936') ->> 'error', '%舊式單人考核草稿%'));
  perform pg_temp.vr_eq('16 開考守衛','健檢草稿員工（MI-9954）：舊 assess_start 行為不變（同員工另一張一般考核可建、冪等）','true',
    (pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9954')::text$q$) like '________-____-____-____-____________')::text);

  -- ===== 單人草稿（MI-9946，建立者 vr-cs3）：評分、備註、面向備註、附圖逐項不變 =====
  select id into v_li from public.assessment_items where assessment_id = v_leg order by seq limit 1;
  perform pg_temp.vr_eq('16 單人','單人草稿：建立者存評分成功（七面向＋備註）','OK/7/單人備註',
    pg_temp.vr_save(e3, v_li, '單人備註') || '/' || pg_temp.vr_q1(format($q$select (select count(*) from jsonb_object_keys(levels))::text || '/' || note from public.assessment_items where id=%L::uuid$q$, v_li)));
  perform pg_temp.vr_deny('16 單人','單人草稿：其他客服部（含考官）存評分仍報「只有建立者本人」（訊息不變）','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, v_li, pg_temp.vr_top()::text), '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_eq('16 單人','單人草稿：不會寫考官表（沒有任何 assessment_examiners 列）','0',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id=%L::uuid$q$, v_leg)));
  v_lv := pg_temp.vr_top() || '{"問題掌握":"待加強"}'::jsonb;
  perform pg_temp.vr_as('authenticated', e3, format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '單人備註')$q$, v_li, v_lv::text), false);
  perform pg_temp.vr_eq('16 單人','單人草稿：建立者存面向備註成功；其他客服部仍報「只有建立者本人」','OK/true/只有建立者',
    pg_temp.vr_as('authenticated', e3, format($q$select public.assess_save_dim_notes(%L::uuid, '{"問題掌握":"沒抓到重點"}'::jsonb)$q$, v_li), false)
    || '/' || (pg_temp.vr_q1(format($q$select dim_notes ->> '問題掌握' from public.assessment_item_secrets where item_id=%L::uuid$q$, v_li)) = '沒抓到重點')::text
    || '/' || case when pg_temp.vr_as('authenticated', e1, format($q$select public.assess_save_dim_notes(%L::uuid, '{}'::jsonb)$q$, v_li), false) like '%只有建立者本人可以操作這張考核' then '只有建立者' else '其他' end);
  v_img := pg_temp.vr_addimg(e3, v_li);
  perform pg_temp.vr_eq('16 單人','單人草稿：建立者新增圖片成功；其他客服部新增／刪除仍報「只有建立者本人」','true/true/true',
    (v_img not like 'ERROR%')::text
    || '/' || (pg_temp.vr_addimg(e1, v_li) like '%只有建立者本人可以操作這張考核')::text
    || '/' || (pg_temp.vr_rmimg(e1, v_img) like '%只有建立者本人可以操作這張考核')::text);
  perform pg_temp.vr_eq('16 單人','單人草稿：建立者刪除自己的圖片成功（回傳路徑）','true',
    (pg_temp.vr_rmimg(e3, v_img) like '%/%')::text);

  -- ===== 健檢草稿（MI-9948，建立者 vr-cs3）=====
  select id into v_ck from public.assessments where employee_id = 'MI-9948' and kind = 'checkup' and status = 'draft';
  select id into v_ci from public.assessment_items where assessment_id = v_ck order by seq limit 1;
  perform pg_temp.vr_eq('16 健檢','健檢草稿：建立者存評分成功；其他客服部被拒（只有建立者本人）','OK/true',
    pg_temp.vr_save(e3, v_ci) || '/' || (pg_temp.vr_save(e1, v_ci) like '%只有建立者本人可以操作這張考核')::text);
  perform pg_temp.vr_eq('16 健檢','健檢草稿：附圖新增／刪除同樣只有建立者','true/true',
    (pg_temp.vr_addimg(e3, v_ci) not like 'ERROR%')::text || '/' || (pg_temp.vr_addimg(e1, v_ci) like '%只有建立者本人可以操作這張考核')::text);

  -- ===== 新人身分的雙考官草稿（MI-9941，第一段建立）：擁有者規則與一般相同 =====
  select id into v_n41 from public.assessments where employee_id = 'MI-9941' and is_dual and status = 'draft';
  s1 := pg_temp.vr_slot(v_n41, e1);
  v_ni := pg_temp.vr_item(v_n41, s1, 1);
  perform pg_temp.vr_eq('16 新人','新人身分的雙考官草稿：自己的題組可存、對方的不可（身分不影響擁有者判斷）','新人/OK/true',
    pg_temp.vr_q1(format($q$select tenure from public.assessments where id=%L::uuid$q$, v_n41)) || '/' || pg_temp.vr_save(e1, v_ni, '新人備註')
    || '/' || (pg_temp.vr_save(e2, v_ni) like '%這個題組不是你負責的%')::text);
end
$$;

-- ============================================================
-- 第三段（DB-3）驗證：各自交卷、撤回、完成收尾（區段 17～23；需先執行過 dual_examiner_schema.sql 的第三段）
-- 假員工：MI-9956（主流程）、MI-9957（新人通過）、MI-9958（改善單＋待考回報）、MI-9959（新人備註把關）、
--         MI-9960（單人對照）、MI-9961（雙考官對照）、MI-9962（新人未通過）、MI-9963（單人改善單對照）、
--         MI-9964（單人驗證訊息）、MI-9965（權限與撤回後放棄）、MI-9966（單人新人通過對照）。
-- ============================================================

-- 本段專用工具
-- 一組七面向全部同一等級
create or replace function pg_temp.vr_all(p_level text)
returns jsonb language sql stable as $$
  select jsonb_object_agg(d, p_level) from unnest(public.assess_dim_order()) as d;
$$;

-- 以某客服身分，把「自己負責的題組」（雙考官）或「全部題組」（單人）依序存成給定評分（jsonb 陣列，依序輪流套用）；
-- p_notes＝true 時，每個題組另外替七個面向都寫備註。成功回 OK，失敗回第一個錯誤。
create or replace function pg_temp.vr_fill(p_email text, p_aid uuid, p_lvs jsonb, p_notes boolean default false)
returns text language plpgsql as $$
declare
  r record;
  v text;
  v_n int := 0;
  v_len int := jsonb_array_length(p_lvs);
  v_dual boolean := (select is_dual from public.assessments where id = p_aid);
  v_slot smallint := (select slot from public.assessment_examiners where assessment_id = p_aid and email = p_email);
  v_notes text := (select jsonb_object_agg(d, '備註')::text from unnest(public.assess_dim_order()) as d);
begin
  for r in
    select i.id from public.assessment_items i
    where i.assessment_id = p_aid and (not v_dual or i.examiner_slot = v_slot)
    order by i.seq
  loop
    v := pg_temp.vr_as('authenticated', p_email,
           format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註')$q$, r.id, (p_lvs -> (v_n % v_len))::text), false);
    if v <> 'OK' then return v; end if;
    if p_notes then
      v := pg_temp.vr_as('authenticated', p_email,
             format($q$select public.assess_save_dim_notes(%L::uuid, %L::jsonb)$q$, r.id, v_notes), false);
      if v <> 'OK' then return v; end if;
    end if;
    v_n := v_n + 1;
  end loop;
  return 'OK';
end $$;

-- 送出我的題組；成功回 jsonb 文字，失敗回 ERROR: 訊息
create or replace function pg_temp.vr_part(p_email text, p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_cs(p_email, format($q$select public.assess_submit_part(%L::uuid)::text$q$, p_aid));
end $$;

-- 把 vr_part 的結果轉成 done/waiting_for_slot（錯誤原樣回傳）
create or replace function pg_temp.vr_pj(p text)
returns text language sql stable as $$
  select case when p like 'ERROR%' then p
              else (p::jsonb ->> 'done') || '/' || coalesce(p::jsonb ->> 'waiting_for_slot', 'null') end;
$$;

-- 撤回我的送出；成功回 OK，失敗回 ERROR: 訊息
create or replace function pg_temp.vr_unpart(p_email text, p_aid uuid)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as('authenticated', p_email, format($q$select public.assess_unsubmit_part(%L::uuid)$q$, p_aid), false);
end $$;

-- 成績單目前狀態摘要
create or replace function pg_temp.vr_st(p_aid uuid)
returns text language sql as $$
  select status || '/' || coalesce(total_score::text, '(null)') || '/' || coalesce(verdict, '(null)') || '/' || coalesce(submitted_at::text, '(null)')
    from public.assessments where id = p_aid;
$$;

-- 兩位考官交卷狀態：slot1 有無／slot2 有無（1＝已交卷）
create or replace function pg_temp.vr_subs(p_aid uuid)
returns text language sql as $$
  select string_agg((submitted_at is not null)::int::text, '/' order by slot) from public.assessment_examiners where assessment_id = p_aid;
$$;

-- 依各題組目前的評分，用「單人流程同一組計分函式」算出應有的 總分/判定/合格線/最弱面向
create or replace function pg_temp.vr_exp(p_aid uuid)
returns text language sql as $$
  select s.total_score::text || '/' || v.verdict || '/' || v.pass_line::text || '/' || coalesce(array_to_string(s.weakest_dims, ','), '')
    from (select jsonb_agg(i.levels order by i.seq) as l from public.assessment_items i where i.assessment_id = p_aid and not i.is_extra) x
    cross join lateral public.assess_score_session(x.l) s
    cross join lateral public.assess_verdict(s.total_score, (select tenure from public.assessments where id = p_aid)) v;
$$;

-- 成績單實際的 總分/判定/合格線/最弱面向
create or replace function pg_temp.vr_act(p_aid uuid)
returns text language sql as $$
  select total_score::text || '/' || verdict || '/' || pass_line::text || '/' || coalesce(array_to_string(weakest_dims, ','), '')
    from public.assessments where id = p_aid;
$$;

-- ============================================================
-- 區段 17：結構（簽名、安全屬性、權限、內文）＋建立本段用的假員工
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  i int;
begin
  perform set_config('request.jwt.claims', '', true);
  for i in 9956..9966 loop
    insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
    values ('MI-' || i, '假員' || i, 'ZZ-D1', '業務', v_today - 200, '在職', true);
  end loop;
  update public.employees set period_status = '考核期' where id in ('MI-9957', 'MI-9959', 'MI-9962', 'MI-9966');

  perform pg_temp.vr_eq('17 結構','回傳型別：submit_part＝jsonb、unsubmit_part＝void、finalize 與 assess_submit 相同、assess_submit 不變',
    'jsonb|void|true|TABLE(total_score numeric, verdict text, pass_line integer, weakest_dims text[], tenure text, item_count integer)',
    pg_temp.vr_q1($q$select pg_get_function_result('public.assess_submit_part(uuid)'::regprocedure)
      || '|' || pg_get_function_result('public.assess_unsubmit_part(uuid)'::regprocedure)
      || '|' || (pg_get_function_result('public.assess_finalize(uuid)'::regprocedure) = pg_get_function_result('public.assess_submit(uuid)'::regprocedure))::text
      || '|' || pg_get_function_result('public.assess_submit(uuid)'::regprocedure)$q$));
  perform pg_temp.vr_eq('17 結構','四個函式都是 security definer、search_path 固定、參數只有 uuid 一個','true/true/true',
    pg_temp.vr_q1($q$select (bool_and(p.prosecdef))::text
      || '/' || (bool_and(p.proconfig::text like '%search_path=public, pg_temp%'))::text
      || '/' || (bool_and(p.pronargs = 1 and p.proargtypes::text = (select oid::text from pg_type where typname = 'uuid')))::text
      from pg_proc p where p.pronamespace = 'public'::regnamespace
        and p.proname in ('assess_submit', 'assess_finalize', 'assess_submit_part', 'assess_unsubmit_part')$q$));
  perform pg_temp.vr_eq('17 權限','登入者：submit_part／unsubmit_part／assess_submit 可執行、assess_finalize 不可；anon 四個都不可','true/true/true/false/false/false/false/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated','public.assess_submit_part(uuid)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_unsubmit_part(uuid)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_submit(uuid)','execute')::text
      || '/' || has_function_privilege('authenticated','public.assess_finalize(uuid)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_submit_part(uuid)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_unsubmit_part(uuid)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_submit(uuid)','execute')::text
      || '/' || has_function_privilege('anon','public.assess_finalize(uuid)','execute')::text$q$));
  perform pg_temp.vr_deny('17 權限','assess_finalize：登入者不可直接呼叫（不能繞過交卷驗證）','authenticated','vr-ex1@2motor.tw',
    $q$select * from public.assess_finalize(gen_random_uuid())$q$, '%permission denied%');
  perform pg_temp.vr_eq('17 內文','assess_submit 是薄包裝（呼叫 assess_finalize、有雙考官守衛，且自己不再算分）','true/true/false',
    pg_temp.vr_q1($q$select (prosrc like '%assess_finalize%')::text || '/' || (prosrc like '%請用雙考官交卷%')::text
      || '/' || (prosrc like '%assess_score_session%')::text from pg_proc where oid = 'public.assess_submit(uuid)'::regprocedure$q$));
  perform pg_temp.vr_eq('17 內文','「update public.assessments」只出現在 assess_finalize（1 次）；submit／submit_part／unsubmit_part 都是 0 次（同一交易唯一一次 update）','1/0/0/0',
    pg_temp.vr_q1($q$select (select ((length(prosrc) - length(replace(prosrc, 'update public.assessments', ''))) / 25)::text from pg_proc where oid = 'public.assess_finalize(uuid)'::regprocedure)
      || '/' || (select ((length(prosrc) - length(replace(prosrc, 'update public.assessments', ''))) / 25)::text from pg_proc where oid = 'public.assess_submit(uuid)'::regprocedure)
      || '/' || (select ((length(prosrc) - length(replace(prosrc, 'update public.assessments', ''))) / 25)::text from pg_proc where oid = 'public.assess_submit_part(uuid)'::regprocedure)
      || '/' || (select ((length(prosrc) - length(replace(prosrc, 'update public.assessments', ''))) / 25)::text from pg_proc where oid = 'public.assess_unsubmit_part(uuid)'::regprocedure)$q$));
  perform pg_temp.vr_eq('17 內文','assess_finalize 與 assess_submit 都不碰 spot_probations、不含備註欄位（note）字樣','false/false/false/false',
    pg_temp.vr_q1($q$select (select (prosrc like '%spot_probations%')::text from pg_proc where oid = 'public.assess_finalize(uuid)'::regprocedure)
      || '/' || (select (prosrc like '%spot_probations%')::text from pg_proc where oid = 'public.assess_submit(uuid)'::regprocedure)
      || '/' || (select (prosrc ~ '\mnote\M')::text from pg_proc where oid = 'public.assess_finalize(uuid)'::regprocedure)
      || '/' || (select (prosrc ~ '\mnote\M')::text from pg_proc where oid = 'public.assess_submit(uuid)'::regprocedure)$q$));
  perform pg_temp.vr_eq('17 內文','assess_finalize 含完整收尾邏輯（算分、判定、完成、新人轉已上線、待開通）','true',
    pg_temp.vr_q1($q$select (prosrc like '%assess_score_session%' and prosrc like '%assess_verdict%' and prosrc like '%''submitted''%'
      and prosrc like '%已上線%' and prosrc like '%reply_activations%' and prosrc like '%至少要有 1 個題組%')::text
      from pg_proc where oid = 'public.assess_finalize(uuid)'::regprocedure$q$));
exception when others then
  perform pg_temp.vr_rec('區段 17','建立假資料或結構檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 18：主流程（MI-9956，正式）：單方交卷不完成、對方未交顯示等待、撤回後可再改再交、雙方交卷才完成、完成後不可撤回
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  j jsonb;
  v_a uuid;
  s1 int;
  s2 int;
  v_lvs jsonb := jsonb_build_array(pg_temp.vr_top() || '{"預設訊息運用":"尚可"}'::jsonb,
                                   pg_temp.vr_top() || '{"問題掌握":"待加強","文字品質":"不適用"}'::jsonb,
                                   pg_temp.vr_top());
  v_ts text;
  v_r text;
begin
  j := pg_temp.vr_sd(e1, 'MI-9956');
  v_a := (j ->> 'assessment_id')::uuid;
  perform pg_temp.vr_set('a56', v_a::text);
  s1 := pg_temp.vr_slot(v_a, e1);
  s2 := 3 - s1;
  perform pg_temp.vr_eq('18 主流程','（前置）開考成功、兩位都還沒交卷','true/0/0', (not (j ? 'error'))::text || '/' || pg_temp.vr_subs(v_a));

  -- 完全沒評就送出 → 被拒，什麼都沒寫
  perform pg_temp.vr_eq('18 主流程','考官1（開考者）一題都沒評就送出：被拒（第 N 題組評分不完整），沒有寫入交卷時間','true/0/0',
    (pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)) like '%題組評分不完整或不正確%')::text || '/' || pg_temp.vr_subs(v_a));
  -- 只評一半也不行
  perform pg_temp.vr_as('authenticated', e1, format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註')$q$, pg_temp.vr_item(v_a, s1, 1), (v_lvs -> 0)::text), false);
  perform pg_temp.vr_eq('18 主流程','只評了第一個題組就送出：仍被拒（缺的那題報錯）','true/0/0',
    (pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)) like '%題組評分不完整或不正確%')::text || '/' || pg_temp.vr_subs(v_a));
  -- 七面向沒評滿也不行（缺一個面向）
  perform pg_temp.vr_as('authenticated', e1, format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註')$q$, pg_temp.vr_item(v_a, s1, 2), (v_lvs -> 1)::text), false);
  update public.assessment_items set levels = '{"資訊正確性":"優良"}'::jsonb where id = pg_temp.vr_item(v_a, s1, 3);
  perform pg_temp.vr_eq('18 主流程','考官只有存兩題（第 3 題七面向沒評滿）：被拒','true/0/0',
    (pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)) like '%題組評分不完整或不正確%')::text || '/' || pg_temp.vr_subs(v_a));

  -- 考官1（開考者）評完自己的 3 題、送出
  perform pg_temp.vr_eq('18 主流程','考官1 評完自己的 3 個題組','OK', pg_temp.vr_fill(e1, v_a, v_lvs));
  perform pg_temp.vr_eq('18 主流程','考官1 送出我的題組：done=false、waiting_for_slot＝對方的 slot','false/' || s2,
    pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)));
  v_ts := (select submitted_at::text from public.assessment_examiners where assessment_id = v_a and email = e1);
  perform pg_temp.vr_eq('18 主流程','單方交卷不完成：成績單仍是草稿、沒有總分、判定、完成時間','draft/(null)/(null)/(null)', pg_temp.vr_st(v_a));
  perform pg_temp.vr_eq('18 主流程','只寫了自己的交卷時間（開考者那位有、對方沒有）',
    case when s1 = 1 then '1/0' else '0/1' end, pg_temp.vr_subs(v_a));
  perform pg_temp.vr_eq('18 主流程','單方交卷後沒有產生第二張成績單、也沒有改善單','1/0',
    pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id = 'MI-9956'$q$) || '/'
    || pg_temp.vr_q1(format($q$select count(*)::text from public.improvement_tickets where assessment_id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_eq('18 主流程','重複送出：明確報錯（不是冪等）、交卷時間不變','true/true',
    (pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)) like '%你已經送出自己的題組了%')::text || '/'
    || ((select submitted_at::text from public.assessment_examiners where assessment_id = v_a and email = e1) = v_ts)::text);
  perform pg_temp.vr_eq('18 主流程','送出後自己不能再存自己的題組（要先撤回）','true',
    (pg_temp.vr_save(e1, pg_temp.vr_item(v_a, s1, 1), '偷改') like '%已送出自己的題組%撤回送出%')::text);
  perform pg_temp.vr_eq('18 主流程','assess_my_drafts：對方（考官2）看到「對方已交卷」；我自己的送出時間有值','true/true',
    pg_temp.vr_cs(e2, format($q$select (select (x ->> 'other_submitted') from jsonb_array_elements(public.assess_my_drafts()) x where x ->> 'assessment_id' = %L)$q$, v_a))
    || '/' || (pg_temp.vr_cs(e1, format($q$select (select (x ->> 'my_submitted_at') from jsonb_array_elements(public.assess_my_drafts()) x where x ->> 'assessment_id' = %L)$q$, v_a)) <> '(null)')::text);

  -- 不是考官／一般交卷
  perform pg_temp.vr_deny('18 主流程','不在考官名單的客服部送出：被拒','authenticated', e3,
    format($q$select public.assess_submit_part(%L::uuid)$q$, v_a), '%只有這張考核的考官可以送出題組%');
  perform pg_temp.vr_deny('18 主流程','開考者用一般 assess_submit：被拒（請用雙考官交卷）','authenticated', e1,
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_a), '%請用雙考官交卷%');
  perform pg_temp.vr_deny('18 主流程','另一位考官用一般 assess_submit：被拒（請用雙考官交卷）','authenticated', e2,
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_a), '%請用雙考官交卷%');
  perform pg_temp.vr_deny('18 主流程','第三位客服部用一般 assess_submit：同樣被拒（請用雙考官交卷）','authenticated', e3,
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_a), '%請用雙考官交卷%');
  perform pg_temp.vr_deny('18 主流程','不在考官名單的客服部撤回：被拒','authenticated', e3,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_a), '%只有這張考核的考官可以撤回送出%');
  perform pg_temp.vr_deny('18 主流程','對方（考官2）還沒送出就撤回：報「你還沒有送出」，且不影響考官1 的送出','authenticated', e2,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_a), '%你還沒有送出自己的題組，不需要撤回%');
  perform pg_temp.vr_eq('18 主流程','…考官1 的送出狀態沒被動','true',
    ((select submitted_at::text from public.assessment_examiners where assessment_id = v_a and email = e1) = v_ts)::text);

  -- 考官1 撤回、再改、再送出
  perform pg_temp.vr_eq('18 撤回','考官1 撤回送出：成功，交卷時間清空（對方不受影響）','OK/0/0', pg_temp.vr_unpart(e1, v_a) || '/' || pg_temp.vr_subs(v_a));
  perform pg_temp.vr_eq('18 撤回','撤回後 assess_my_drafts：對方看到「對方未交卷」','false',
    pg_temp.vr_cs(e2, format($q$select (select (x ->> 'other_submitted') from jsonb_array_elements(public.assess_my_drafts()) x where x ->> 'assessment_id' = %L)$q$, v_a)));
  perform pg_temp.vr_deny('18 撤回','撤回後再撤回：報「你還沒有送出」','authenticated', e1,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_a), '%你還沒有送出自己的題組，不需要撤回%');
  perform pg_temp.vr_eq('18 撤回','撤回後可以再改自己的題組','OK', pg_temp.vr_save(e1, pg_temp.vr_item(v_a, s1, 1), '撤回後改'));
  perform pg_temp.vr_eq('18 撤回','…並且改完可以再送出：done=false、等對方','false/' || s2, pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)));
  perform pg_temp.vr_eq('18 撤回','撤回再送出後成績單仍是草稿','draft/(null)/(null)/(null)', pg_temp.vr_st(v_a));

  -- 考官2 先評不完整就送出 → 被拒，考官1 的送出不受影響
  perform pg_temp.vr_as('authenticated', e2, format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '備註')$q$, pg_temp.vr_item(v_a, s2, 1), (v_lvs -> 0)::text), false);
  perform pg_temp.vr_eq('18 主流程','考官2 只評 1 題就送出：被拒，成績單仍是草稿、考官1 的送出還在','true/draft/' || case when s1 = 1 then '1/0' else '0/1' end,
    (pg_temp.vr_pj(pg_temp.vr_part(e2, v_a)) like '%題組評分不完整或不正確%')::text || '/' || split_part(pg_temp.vr_st(v_a), '/', 1) || '/' || pg_temp.vr_subs(v_a));

  -- 考官2 評完、送出 → 完成
  perform pg_temp.vr_eq('18 主流程','考官2 評完自己的 3 個題組','OK', pg_temp.vr_fill(e2, v_a, v_lvs));
  v_r := pg_temp.vr_part(e2, v_a);
  perform pg_temp.vr_eq('18 完成','考官2 送出：done=true、waiting_for_slot 為空','true/null', pg_temp.vr_pj(v_r));
  perform pg_temp.vr_eq('18 完成','成績單完成：status=submitted，總分、判定、完成時間都有值','submitted/true/true/true',
    (select status || '/' || (total_score is not null)::text || '/' || (verdict is not null)::text || '/' || (submitted_at is not null)::text
       from public.assessments where id = v_a));
  perform pg_temp.vr_eq('18 完成','總分／判定／合格線／最弱面向＝依 6 個題組評分用同一組計分函式算出的值','true',
    (pg_temp.vr_act(v_a) = pg_temp.vr_exp(v_a))::text);
  perform pg_temp.vr_eq('18 完成','6 個題組分數都已寫入且等於 assess_score_item 的結果','6',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items i
        cross join lateral public.assess_score_item(i.levels) s
       where i.assessment_id = %L::uuid and i.item_score = s.item_score and i.dim_points = s.dim_points
         and i.na_dims = s.na_dims and i.weakest_dims = s.weakest_dims$q$, v_a)));
  perform pg_temp.vr_eq('18 完成','只有一張成績單、兩位考官的交卷時間都有值、6 個題組','1/2/1/6',
    pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id = 'MI-9956'$q$) || '/'
    || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id = %L::uuid and submitted_at is not null$q$, v_a)) || '/'
    || pg_temp.vr_q1($q$select count(*)::text from public.assessments where employee_id = 'MI-9956' and status = 'submitted'$q$) || '/'
    || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where assessment_id = %L::uuid$q$, v_a)) );
  perform pg_temp.vr_eq('18 完成','成績單身分／種類／開考者沒被動：正式／exam／雙考官／開考者','正式/exam/true/' || e1,
    (select tenure || '/' || kind || '/' || is_dual::text || '/' || examiner_email from public.assessments where id = v_a));
  -- 完成後
  perform pg_temp.vr_deny('18 完成後','完成後考官1 撤回：被拒（已經完成）','authenticated', e1,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_a), '%已經完成%不能撤回送出%');
  perform pg_temp.vr_deny('18 完成後','完成後考官2 撤回：被拒','authenticated', e2,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_a), '%已經完成%不能撤回送出%');
  perform pg_temp.vr_deny('18 完成後','完成後再送出：被拒（只有草稿可以送出）','authenticated', e1,
    format($q$select public.assess_submit_part(%L::uuid)$q$, v_a), '%只有草稿可以送出%');
  perform pg_temp.vr_deny('18 完成後','完成後不可再存評分','authenticated', e1,
    format($q$select public.assess_save_item(%L::uuid, %L::jsonb, '偷改')$q$, pg_temp.vr_item(v_a, s1, 1), pg_temp.vr_top()::text), '%只有草稿可以暫存評分%');
  perform pg_temp.vr_deny('18 完成後','完成後不可放棄','authenticated', e3,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_a), '%只有草稿可以放棄%');
  perform pg_temp.vr_eq('18 完成後','完成後的結果沒被這些被拒的操作改動','true/1/1',
    (pg_temp.vr_act(v_a) = pg_temp.vr_exp(v_a))::text || '/' || pg_temp.vr_subs(v_a));
exception when others then
  perform pg_temp.vr_rec('區段 18','主流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 19：與單人流程在相同分數下一致（單人 MI-9960 與雙考官 MI-9961，七面向評分完全相同）
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_lvs jsonb := jsonb_build_array(pg_temp.vr_top() || '{"問題掌握":"待加強","文字品質":"不適用","預設訊息運用":"尚可"}'::jsonb);
  v_q1 bigint := (select min(id) from public.questions where category = '基礎' and code like 'ZDB%');
  v_q2 bigint := (select min(id) from public.questions where category = '進階' and code like 'ZDA%');
  v_q3 bigint := (select min(id) from public.questions where category = '綜合' and code like 'ZDC%');
  v_s text;
  v_d uuid;
  v_sr text;
  s1 int;
  v_cmp_s text;
  v_cmp_d text;
  v_p1 text;
  v_p2 text;
begin
  -- 單人
  v_s := pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9960')::text$q$);
  perform pg_temp.vr_eq('19 對照','（前置）單人開考成功、挑 3 個題組','true/3',
    (v_s not like 'ERROR%')::text || '/' || pg_temp.vr_cs(e3, format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s, %s, %s]::bigint[])$q$, v_s, v_q1, v_q2, v_q3)));
  perform pg_temp.vr_eq('19 對照','單人：3 個題組存成同一組評分','OK', pg_temp.vr_fill(e3, v_s::uuid, v_lvs, true));
  v_sr := pg_temp.vr_cs(e3, format($q$select total_score::text || '/' || verdict || '/' || pass_line::text || '/' || array_to_string(weakest_dims, ',') || '/' || tenure || '/' || item_count::text from public.assess_submit(%L::uuid)$q$, v_s));
  perform pg_temp.vr_set('single_ret', v_sr);
  perform pg_temp.vr_eq('19 對照','單人 assess_submit 回傳列：總分／判定／合格線／最弱面向／身分／題組數 都有值（題組數 3）','true/3',
    (v_sr not like 'ERROR%')::text || '/' || split_part(v_sr, '/', 6));
  -- 雙考官
  v_d := (pg_temp.vr_sd(e1, 'MI-9961') ->> 'assessment_id')::uuid;
  perform pg_temp.vr_eq('19 對照','雙考官：兩位各把自己的 3 題存成與單人完全相同的評分','OK/OK',
    pg_temp.vr_fill(e1, v_d, v_lvs, true) || '/' || pg_temp.vr_fill(e2, v_d, v_lvs, true));
  v_p1 := pg_temp.vr_pj(pg_temp.vr_part(e1, v_d));
  v_p2 := pg_temp.vr_pj(pg_temp.vr_part(e2, v_d));
  perform pg_temp.vr_eq('19 對照','雙考官兩位送出：先送的 done=false（等對方）、後送的 done=true','false/' || (3 - pg_temp.vr_slot(v_d, e1)) || '→true/null', v_p1 || '→' || v_p2);
  v_cmp_s := pg_temp.vr_q1(format($q$select total_score::text || '/' || verdict || '/' || pass_line::text || '/' || array_to_string(weakest_dims, ',') || '/' || tenure || '/' || status || '/' || kind from public.assessments where id = %L::uuid$q$, v_s));
  v_cmp_d := pg_temp.vr_q1(format($q$select total_score::text || '/' || verdict || '/' || pass_line::text || '/' || array_to_string(weakest_dims, ',') || '/' || tenure || '/' || status || '/' || kind from public.assessments where id = %L::uuid$q$, v_d));
  perform pg_temp.vr_eq('19 對照','雙考官成績單的 總分／判定／合格線／最弱面向／身分／狀態／種類 與單人完全一致', v_cmp_s, v_cmp_d);
  perform pg_temp.vr_eq('19 對照','單人 assess_submit 回傳列的前四欄也與雙考官成績單一致', split_part(v_sr, '/', 1) || '/' || split_part(v_sr, '/', 2) || '/' || split_part(v_sr, '/', 3) || '/' || split_part(v_sr, '/', 4),
    split_part(v_cmp_d, '/', 1) || '/' || split_part(v_cmp_d, '/', 2) || '/' || split_part(v_cmp_d, '/', 3) || '/' || split_part(v_cmp_d, '/', 4));
  perform pg_temp.vr_eq('19 對照','每個題組的 分數／各面向得分／不適用面向／最弱面向 與單人完全一致（兩邊各自只有一種值）',
    pg_temp.vr_q1(format($q$select string_agg(distinct item_score::text || '|' || dim_points::text || '|' || array_to_string(na_dims, ',') || '|' || array_to_string(weakest_dims, ','), ';') from public.assessment_items where assessment_id = %L::uuid$q$, v_s)),
    pg_temp.vr_q1(format($q$select string_agg(distinct item_score::text || '|' || dim_points::text || '|' || array_to_string(na_dims, ',') || '|' || array_to_string(weakest_dims, ','), ';') from public.assessment_items where assessment_id = %L::uuid$q$, v_d)));
  perform pg_temp.vr_eq('19 對照','總分是整數題組分數的平均（用 assess_score_session 的公式）：與直接計算一致','true/true',
    (pg_temp.vr_act(v_s::uuid) = pg_temp.vr_exp(v_s::uuid))::text || '/' || (pg_temp.vr_act(v_d) = pg_temp.vr_exp(v_d))::text);
exception when others then
  perform pg_temp.vr_rec('區段 19','對照意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 20：新人通過 → 已上線＋待開通（雙考官 vs 單人對照）；新人備註把關；新人未通過不轉
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_s text;
  v_q1 bigint := (select min(id) from public.questions where category = '基礎' and code like 'ZDB%');
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_r text;
begin
  -- ===== MI-9957：新人全優良 → 通過 =====
  v_a := (pg_temp.vr_sd(e1, 'MI-9957') ->> 'assessment_id')::uuid;
  perform pg_temp.vr_eq('20 新人通過','（前置）MI-9957 是新人（考核期），開考成功','新人/考核期', (select tenure from public.assessments where id = v_a) || '/' || (select period_status from public.employees where id = 'MI-9957'));
  perform pg_temp.vr_fill(e1, v_a, jsonb_build_array(pg_temp.vr_top()));
  perform pg_temp.vr_fill(e2, v_a, jsonb_build_array(pg_temp.vr_top()));
  perform pg_temp.vr_part(e1, v_a);
  perform pg_temp.vr_eq('20 新人通過','只有一位送出時：員工仍是考核期、沒有待開通紀錄','考核期/0',
    (select period_status from public.employees where id = 'MI-9957') || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.reply_activations where assessment_id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_eq('20 新人通過','第二位送出、完成：done=true','true/null', pg_temp.vr_pj(pg_temp.vr_part(e2, v_a)));
  perform pg_temp.vr_eq('20 新人通過','新人通過：員工轉已上線、記通過日（今天）','已上線/true',
    (select period_status || '/' || (passed_on = v_today)::text from public.employees where id = 'MI-9957'));
  perform pg_temp.vr_eq('20 新人通過','新增一筆待開通（綁這張成績單、門市與暱稱快照正確）','1/待開通/ZZ-D1/假員9957',
    pg_temp.vr_q1(format($q$select count(*)::text || '/' || min(status) || '/' || min(store_code) || '/' || min(employee_label) from public.reply_activations where assessment_id = %L::uuid$q$, v_a)));
  perform pg_temp.vr_eq('20 新人通過','成績單：新人／優秀（100 分）／合格線 70','新人/優秀/70',
    (select tenure || '/' || verdict || '/' || pass_line::text from public.assessments where id = v_a));

  -- ===== MI-9966：單人新人全優良 → 同樣通過（對照）=====
  v_s := pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9966')::text$q$);
  perform pg_temp.vr_cs(e3, format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_s, v_q1));
  perform pg_temp.vr_fill(e3, v_s::uuid, jsonb_build_array(pg_temp.vr_top()));
  perform pg_temp.vr_cs(e3, format($q$select total_score::text from public.assess_submit(%L::uuid)$q$, v_s));
  perform pg_temp.vr_eq('20 新人通過','（對照）單人新人全優良：同樣轉已上線、記通過日、新增待開通','已上線/true/1/待開通',
    (select period_status || '/' || (passed_on = v_today)::text from public.employees where id = 'MI-9966') || '/'
    || pg_temp.vr_q1(format($q$select count(*)::text || '/' || min(status) from public.reply_activations where assessment_id = %L::uuid$q$, v_s)));

  -- ===== MI-9959：新人有「尚可」卻沒寫備註 → 完成那一刻被把關擋下，整筆回復 =====
  v_b := (pg_temp.vr_sd(e1, 'MI-9959') ->> 'assessment_id')::uuid;
  perform pg_temp.vr_fill(e2, v_b, jsonb_build_array(pg_temp.vr_top()));
  perform pg_temp.vr_fill(e1, v_b, jsonb_build_array(pg_temp.vr_top() || '{"預設訊息運用":"尚可"}'::jsonb));
  perform pg_temp.vr_eq('20 備註把關','考官2 先送出（全優良）：等考官1','false/' || pg_temp.vr_slot(v_b, e1), pg_temp.vr_pj(pg_temp.vr_part(e2, v_b)));
  v_r := pg_temp.vr_part(e1, v_b);
  perform pg_temp.vr_eq('20 備註把關','考官1 評了「尚可」卻沒寫備註就送出：完成時被新人備註把關擋下','true',
    (v_r like 'ERROR%必須寫下備註才能送出%')::text);
  perform pg_temp.vr_eq('20 備註把關','被擋後整筆回復：考官1 沒有被記成已交卷、考官2 的送出還在、成績單仍是草稿、員工仍是考核期、沒有待開通',
    case when pg_temp.vr_slot(v_b, e1) = 1 then '0/1' else '1/0' end || '/draft/考核期/0',
    pg_temp.vr_subs(v_b) || '/' || split_part(pg_temp.vr_st(v_b), '/', 1) || '/' || (select period_status from public.employees where id = 'MI-9959')
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.reply_activations where assessment_id = %L::uuid$q$, v_b)));
  v_r := pg_temp.vr_fill(e1, v_b, jsonb_build_array(pg_temp.vr_top() || '{"預設訊息運用":"尚可"}'::jsonb), true);
  v_r := v_r || '/' || pg_temp.vr_pj(pg_temp.vr_part(e1, v_b));
  perform pg_temp.vr_eq('20 備註把關','考官1 補寫備註後再送出：成功完成（done=true）','OK/true/null', v_r);
  perform pg_temp.vr_eq('20 備註把關','補寫後完成：成績單已送出、員工轉已上線（分數仍 ≥ 70）','submitted/已上線',
    split_part(pg_temp.vr_st(v_b), '/', 1) || '/' || (select period_status from public.employees where id = 'MI-9959'));

  -- ===== MI-9962：新人全待加強（備註齊全）→ 不及格、不轉已上線 =====
  v_c := (pg_temp.vr_sd(e1, 'MI-9962') ->> 'assessment_id')::uuid;
  perform pg_temp.vr_fill(e1, v_c, jsonb_build_array(pg_temp.vr_all('待加強')), true);
  perform pg_temp.vr_fill(e2, v_c, jsonb_build_array(pg_temp.vr_all('待加強')), true);
  perform pg_temp.vr_part(e2, v_c);
  v_r := pg_temp.vr_pj(pg_temp.vr_part(e1, v_c));
  perform pg_temp.vr_eq('20 新人未過','兩位送出完成；新人不及格','true/不及格/70',
    (v_r = 'true/null')::text || '/' || (select verdict || '/' || pass_line::text from public.assessments where id = v_c));
  perform pg_temp.vr_eq('20 新人未過','分數不到 70：員工仍是考核期、沒有通過日、沒有待開通','考核期/(null)/0',
    (select period_status || '/' || coalesce(passed_on::text, '(null)') from public.employees where id = 'MI-9962') || '/'
    || pg_temp.vr_q1(format($q$select count(*)::text from public.reply_activations where assessment_id = %L::uuid$q$, v_c)));
  perform pg_temp.vr_eq('20 新人未過','不及格自動開一張改善單（與單人相同）','1',
    pg_temp.vr_q1(format($q$select count(*)::text from public.improvement_tickets where assessment_id = %L::uuid$q$, v_c)));
exception when others then
  perform pg_temp.vr_rec('區段 20','新人流程意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 21：改善單與待考回報觸發器照常觸發（雙考官 MI-9958 vs 單人 MI-9963，同樣全待加強）
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_a uuid;
  v_s text;
  v_q1 bigint := (select min(id) from public.questions where category = '基礎' and code like 'ZDB%');
  v_cmp_d text;
  v_cmp_s text;
  v_rq_d text;
  v_rq_s text;
begin
  insert into public.exam_requests (kind, employee_id, employee_label, store_code, requested_by, requested_role, desired_dates)
  values ('回考核期', 'MI-9958', 'x', 'ZZ-D1', 'vr-sm1@2motor.tw', '店長', array[current_date]),
         ('回考核期', 'MI-9963', 'x', 'ZZ-D1', 'vr-sm1@2motor.tw', '店長', array[current_date]);

  -- 雙考官：考官2 先交、考官1 後交（與區段 18 順序顛倒）
  v_a := (pg_temp.vr_sd(e1, 'MI-9958') ->> 'assessment_id')::uuid;
  perform pg_temp.vr_fill(e1, v_a, jsonb_build_array(pg_temp.vr_all('待加強')));
  perform pg_temp.vr_fill(e2, v_a, jsonb_build_array(pg_temp.vr_all('待加強')));
  perform pg_temp.vr_part(e2, v_a);
  perform pg_temp.vr_eq('21 觸發器','只有一位送出：沒有改善單、待考回報仍是待處理','0/待處理',
    pg_temp.vr_q1(format($q$select count(*)::text from public.improvement_tickets where assessment_id = %L::uuid$q$, v_a))
    || '/' || (select status from public.exam_requests where employee_id = 'MI-9958'));
  perform pg_temp.vr_eq('21 觸發器','考官1 送出完成：done=true','true/null', pg_temp.vr_pj(pg_temp.vr_part(e1, v_a)));
  perform pg_temp.vr_eq('21 觸發器','完成後判定不是及格以上（會自動開改善單）','true',
    ((select verdict from public.assessments where id = v_a) in ('需複訓', '不及格'))::text);
  v_cmp_d := pg_temp.vr_q1(format($q$select count(*)::text || '/' || min(t.status) || '/' || (min(t.due_date) = (now() at time zone 'Asia/Taipei')::date + 14)::text
      || '/' || bool_and(t.target_dims = a.weakest_dims)::text from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where t.assessment_id = %L::uuid$q$, v_a));
  perform pg_temp.vr_eq('21 觸發器','自動開 1 張改善單：待改善（open）、14 天後到期、目標面向＝成績單最弱面向','1/open/true/true', v_cmp_d);
  v_rq_d := (select status || '/' || (assessment_id = v_a)::text || '/' || mgr_seen::text from public.exam_requests where employee_id = 'MI-9958');
  perform pg_temp.vr_eq('21 觸發器','待考回報自動完成：已完成、綁這張成績單、mgr_seen=false（讓店長看到）','已完成/true/false', v_rq_d);

  -- 單人對照
  v_s := pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9963')::text$q$);
  perform pg_temp.vr_cs(e3, format($q$select count(*)::text from public.assess_pick(%L::uuid, array[%s]::bigint[])$q$, v_s, v_q1));
  perform pg_temp.vr_fill(e3, v_s::uuid, jsonb_build_array(pg_temp.vr_all('待加強')));
  perform pg_temp.vr_cs(e3, format($q$select total_score::text from public.assess_submit(%L::uuid)$q$, v_s));
  v_cmp_s := pg_temp.vr_q1(format($q$select count(*)::text || '/' || min(t.status) || '/' || (min(t.due_date) = (now() at time zone 'Asia/Taipei')::date + 14)::text
      || '/' || bool_and(t.target_dims = a.weakest_dims)::text from public.improvement_tickets t join public.assessments a on a.id = t.assessment_id where t.assessment_id = %L::uuid$q$, v_s));
  v_rq_s := (select status || '/' || (assessment_id = v_s::uuid)::text || '/' || mgr_seen::text from public.exam_requests where employee_id = 'MI-9963');
  perform pg_temp.vr_eq('21 觸發器','（對照）單人流程的改善單與待考回報結果與雙考官完全一致', v_cmp_s || '|' || v_rq_s, v_cmp_d || '|' || v_rq_d);
exception when others then
  perform pg_temp.vr_rec('區段 21','觸發器意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 22：權限邊界、內部防線、撤回後才能放棄（MI-9965）
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_a uuid;
  s1 int;
  v_leg uuid;
  v_ck uuid;
begin
  v_a := (pg_temp.vr_sd(e1, 'MI-9965') ->> 'assessment_id')::uuid;
  s1 := pg_temp.vr_slot(v_a, e1);
  perform pg_temp.vr_denyset('22 權限','assess_submit_part', format($q$select public.assess_submit_part(%L::uuid)$q$, v_a), 'hsna');
  perform pg_temp.vr_denyset('22 權限','assess_unsubmit_part', format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_a), 'hsna');
  perform pg_temp.vr_deny('22 權限','不存在的考核：submit_part 報「找不到考核」','authenticated', e1,
    $q$select public.assess_submit_part(gen_random_uuid())$q$, '%找不到考核%');
  perform pg_temp.vr_deny('22 權限','不存在的考核：unsubmit_part 報「找不到考核」','authenticated', e1,
    $q$select public.assess_unsubmit_part(gen_random_uuid())$q$, '%找不到考核%');

  -- 舊單人草稿、健檢草稿：不可用雙考官交卷／撤回
  select id into v_leg from public.assessments where employee_id = 'MI-9946' and status = 'draft' and not is_dual;
  select id into v_ck from public.assessments where employee_id = 'MI-9948' and kind = 'checkup' and status = 'draft';
  perform pg_temp.vr_deny('22 單人','單人草稿：建立者呼叫 assess_submit_part 被拒（不是雙考官）','authenticated', e3,
    format($q$select public.assess_submit_part(%L::uuid)$q$, v_leg), '%這不是雙考官考核%');
  perform pg_temp.vr_deny('22 單人','單人草稿：assess_unsubmit_part 被拒（不是雙考官）','authenticated', e3,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_leg), '%這不是雙考官考核%');
  perform pg_temp.vr_deny('22 健檢','健檢草稿：assess_submit_part 被拒','authenticated', e3,
    format($q$select public.assess_submit_part(%L::uuid)$q$, v_ck), '%這不是雙考官考核%');
  perform pg_temp.vr_deny('22 健檢','健檢草稿：assess_unsubmit_part 被拒','authenticated', e3,
    format($q$select public.assess_unsubmit_part(%L::uuid)$q$, v_ck), '%這不是雙考官考核%');
  perform pg_temp.vr_eq('22 單人','被拒後單人與健檢草稿都沒被動（仍是草稿、沒有考官表）','draft/draft/0',
    (select status from public.assessments where id = v_leg) || '/' || (select status from public.assessments where id = v_ck)
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id in (%L::uuid, %L::uuid)$q$, v_leg, v_ck)));

  -- 內部防線：一位沒交卷時，直接呼叫 assess_finalize 也不能完成（擁有者身分才呼叫得到）
  perform pg_temp.vr_fill(e1, v_a, jsonb_build_array(pg_temp.vr_top()));
  perform pg_temp.vr_fill(e2, v_a, jsonb_build_array(pg_temp.vr_top()));
  perform pg_temp.vr_part(e1, v_a);
  perform pg_temp.vr_ownerr('22 內部防線','assess_finalize：只有一位考官送出時直接呼叫也被擋','select * from public.assess_finalize(''' || v_a::text || '''::uuid)', '%必須兩位考官都送出自己的題組%');
  perform pg_temp.vr_eq('22 內部防線','被擋後成績單仍是草稿、題組分數沒被寫入','draft/0',
    split_part(pg_temp.vr_st(v_a), '/', 1) || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where assessment_id = %L::uuid and item_score is not null$q$, v_a)));

  -- 已有人交卷：放棄被拒；撤回後才能放棄（規則 6）
  perform pg_temp.vr_deny('22 放棄','考官1 已交卷：第三位客服部放棄被拒（請先撤回送出）','authenticated', e3,
    format($q$select public.assess_abandon(%L::uuid)$q$, v_a), '%請先撤回送出%');
  perform pg_temp.vr_eq('22 放棄','考官1 撤回送出成功','OK', pg_temp.vr_unpart(e1, v_a));
  perform pg_temp.vr_eq('22 放棄','撤回後第三位客服部可以放棄整張（草稿與考官表一併消失）','OK/0/0',
    pg_temp.vr_as('authenticated', e3, format($q$select public.assess_abandon(%L::uuid)$q$, v_a), false)
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessments where id = %L::uuid$q$, v_a))
    || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id = %L::uuid$q$, v_a)));
exception when others then
  perform pg_temp.vr_rec('區段 22','權限邊界意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 23：單人 assess_submit（薄包裝）行為逐項不變：訊息、順序、權限、回傳、不碰考官表
-- ============================================================
do $$
declare
  e1 constant text := 'vr-ex1@2motor.tw';
  e2 constant text := 'vr-ex2@2motor.tw';
  e3 constant text := 'vr-cs3@2motor.tw';
  v_s text;
  v_done uuid;
begin
  -- MI-9964：單人草稿，只抽 1 題、沒評分
  v_s := pg_temp.vr_cs(e3, $q$select public.assess_start('MI-9964')::text$q$);
  perform pg_temp.vr_cs(e3, format($q$select count(*)::text from public.assess_draw(%L::uuid, array['ZZ分類D'])$q$, v_s));
  perform pg_temp.vr_deny('23 單人送出','非建立者（考官）送出：仍報「只有建立者本人」（訊息不變）','authenticated', e1,
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_s), '%只有建立者本人可以操作這張考核%');
  perform pg_temp.vr_deny('23 單人送出','建立者但題組沒評：仍報「第 1 題組評分不完整或不正確」（訊息不變）','authenticated', e3,
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_s), '%第 1 題組評分不完整或不正確%');
  perform pg_temp.vr_deny('23 單人送出','不存在的考核：仍報「找不到考核」','authenticated', e3,
    $q$select * from public.assess_submit(gen_random_uuid())$q$, '%找不到考核%');
  perform pg_temp.vr_denyset('23 單人送出','assess_submit', format($q$select * from public.assess_submit(%L::uuid)$q$, v_s), 'hsna');
  perform pg_temp.vr_eq('23 單人送出','被拒後草稿沒被動（仍是草稿、題組分數沒寫入）','draft/0',
    split_part(pg_temp.vr_st(v_s::uuid), '/', 1) || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_items where assessment_id = %L::uuid and item_score is not null$q$, v_s)));
  -- 已完成的單人（區段 19 的 MI-9960）再送出
  select id into v_done from public.assessments where employee_id = 'MI-9960' and status = 'submitted';
  perform pg_temp.vr_deny('23 單人送出','已送出的單人考核再送出：仍報「只有草稿可以送出」','authenticated', e3,
    format($q$select * from public.assess_submit(%L::uuid)$q$, v_done), '%只有草稿可以送出%');
  perform pg_temp.vr_eq('23 單人送出','單人完成後：沒有任何考官表資料、examiner_email 仍是建立者、不是雙考官','0/' || e3 || '/false',
    pg_temp.vr_q1(format($q$select count(*)::text from public.assessment_examiners where assessment_id = %L::uuid$q$, v_done))
    || '/' || (select examiner_email || '/' || is_dual::text from public.assessments where id = v_done));
  perform pg_temp.vr_eq('23 單人送出','單人完成後：回傳列的 pass_line／身分與成績單一致（正式／85）','正式/85',
    split_part(pg_temp.vr_get('single_ret'), '/', 5) || '/' || split_part(pg_temp.vr_get('single_ret'), '/', 3));
exception when others then
  perform pg_temp.vr_rec('區段 23','單人送出意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate dual_examiner_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare dual_examiner_vr_out as select * from (values (0, '
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
    execute 'deallocate dual_examiner_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare dual_examiner_vr_out as select '
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
execute dual_examiner_vr_out;
