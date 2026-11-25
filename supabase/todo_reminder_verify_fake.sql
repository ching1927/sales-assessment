-- ============================================================
-- 業務考核系統：「該填未填」紅點提醒驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 todo_reminder_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-T1／ZZ-T2、假人員 MI-9901～MI-9910、假帳號（td-xxx＋公司網域，網域用拼接產生），
--   用 set local role ＋ request.jwt.claims 模擬各角色登入，驗證 improve_badge、spot_badge、todo_unreported_rows、
--   exam_req_badge 與每週彙整信 todo_digest_run；每項斷言記在暫存表，最後 rollback。
-- 怎麼看結果：最後一個結果＝「序號／群組／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過。
-- 彙整信的假收件人只用 example.test 網域；測試時間用「未來 60 天後的某個週一」，不會碰到真實已寄出的彙整信。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regprocedure('public.spot_badge()') is null then
    raise exception '請先執行 todo_reminder_schema.sql';
  end if;
end
$$;

create temp table vr (
  n int generated always as identity primary key,
  grp text, name text, expected text, actual text, pass boolean
);

create or replace function pg_temp.vr_eq(p_grp text, p_name text, p_expected text, p_actual text)
returns void language plpgsql as $$
begin
  insert into pg_temp.vr (grp, name, expected, actual, pass)
  values (p_grp, p_name, p_expected, coalesce(p_actual, '(null)'), p_expected is not distinct from p_actual);
end $$;

-- 以指定資料庫角色＋email 執行單一值查詢；失敗回 'ERROR: 訊息'；p_email 為 null＝沒有登入者
create or replace function pg_temp.vr_as(p_role text, p_email text, p_sql text)
returns text language plpgsql as $$
declare v_res text;
begin
  perform set_config('request.jwt.claims',
    case when p_email is null then '' else json_build_object('email', p_email, 'role', p_role)::text end, true);
  begin
    execute format('set local role %I', p_role);
    execute p_sql into v_res;
    reset role;
    return coalesce(v_res, '(null)');
  exception when others then
    reset role;
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

-- 假帳號網域（app_users 規定只能用公司網域；這裡用拼接，避免檔案裡出現真實信箱字串）
create or replace function pg_temp.dom() returns text language sql immutable as $$ select '@' || '2motor' || '.tw' $$;

create or replace function pg_temp.vr_u(p_email text, p_sql text) returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_email, p_sql) $$;
create or replace function pg_temp.vr_im(p_email text) returns text language sql as $$
  select pg_temp.vr_u(p_email, 'select public.improve_badge()::text') $$;
create or replace function pg_temp.vr_sp(p_email text) returns text language sql as $$
  select pg_temp.vr_u(p_email, 'select public.spot_badge()::text') $$;
create or replace function pg_temp.vr_ex(p_email text) returns text language sql as $$
  select pg_temp.vr_u(p_email, 'select public.exam_req_badge()::text') $$;
-- 只看假門市（ZZ-T%）的未回報清單：「人員:原因」逗號串
create or replace function pg_temp.vr_rows(p_email text) returns text language sql as $$
  select pg_temp.vr_u(p_email,
    $q$select coalesce(string_agg(employee_id || ':' || reason, ',' order by employee_id), '(空)')
         from public.todo_unreported_rows() where store_code like 'ZZ-T%'$q$) $$;

-- 一張改善單（含來源成績單），擁有者身分；回傳改善單 id
create or replace function pg_temp.vr_tk(p_emp text, p_store text, p_status text)
returns uuid language plpgsql as $$
declare v_a uuid; v_t uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
     total_score, verdict, pass_line, submitted_at)
  values (p_emp, '假員' || right(p_emp, 4), p_store, ('td-cs' || pg_temp.dom()), 'submitted', '正式', '自動', 50, '不及格', 70, now())
  returning id into v_a;
  insert into public.improvement_tickets (assessment_id, employee_id, store_code, status, due_date)
  values (v_a, p_emp, p_store, p_status, current_date + 14)
  returning id into v_t;
  return v_t;
end $$;

-- 一張異常回覆單（黃單，含來源抽查）；p_coached＝true 表示已回填輔導；回傳黃單 id
create or replace function pg_temp.vr_yl(p_emp text, p_store text, p_issued date, p_status text, p_coached boolean)
returns uuid language plpgsql as $$
declare v_i uuid; v_t uuid;
begin
  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels, total_score, verdict, reason, examiner_email)
  values (p_emp, '假員' || right(p_emp, 4), p_store, p_issued, 'https://example.test/line', '{}'::jsonb, 50, '不適當', '假原因', ('td-cs' || pg_temp.dom()))
  returning id into v_i;
  insert into public.spot_tickets
    (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on, status,
     void_reason, voided_by, voided_at, coached_on, coach_note, coached_by, coached_at)
  values ('黃', p_emp, '假員' || right(p_emp, 4), p_store, v_i, '假', p_issued, p_status,
          case when p_status = '作廢' then '假作廢' end,
          case when p_status = '作廢' then ('td-cs' || pg_temp.dom()) end,
          case when p_status = '作廢' then now() end,
          case when p_coached then p_issued end,
          case when p_coached then '假輔導' end,
          case when p_coached then ('td-sm1' || pg_temp.dom()) end,
          case when p_coached then now() end)
  returning id into v_t;
  return v_t;
end $$;

-- ---------- 建立假資料 ----------
do $$
begin
  insert into public.stores (code, name) values ('ZZ-T1', 'ZZ待填甲店'), ('ZZ-T2', 'ZZ待填乙店');
  insert into public.app_users (email, role, store_code) values
    (('td-cs' || pg_temp.dom()), 'cs_admin', null),
    (('td-hq' || pg_temp.dom()), 'hq_viewer', null),
    (('td-sm1' || pg_temp.dom()), 'store_manager', 'ZZ-T1'),
    (('td-sm2' || pg_temp.dom()), 'store_manager', 'ZZ-T2');
end $$;

-- 客服部基準數（資料庫裡若已有真實資料，客服部只看「增減量」）
create temp table vr_base as
  select pg_temp.vr_im(('td-cs' || pg_temp.dom()))::int as im,
         pg_temp.vr_sp(('td-cs' || pg_temp.dom()))::int as sp,
         pg_temp.vr_ex(('td-cs' || pg_temp.dom()))::int as ex;

-- 人員
--   甲店：9901 新人（考核期，無單）／9902 考核期＋待改善單／9904 已上線＋待改善單／
--         9905 離職＋考核期＋待改善單／9907 考核期但不納入考核
--   乙店：9906 新人（考核期）／9908 已上線＋待改善單
insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status) values
  ('MI-9901', '假員9901', 'ZZ-T1', '業務', current_date - 3, '在職', true, '考核期'),
  ('MI-9902', '假員9902', 'ZZ-T1', '業務', current_date - 30, '在職', true, '考核期'),
  ('MI-9904', '假員9904', 'ZZ-T1', '業務', current_date - 300, '在職', true, '已上線'),
  ('MI-9905', '假員9905', 'ZZ-T1', '業務', current_date - 30, '離職', true, '考核期'),
  ('MI-9907', '假員9907', 'ZZ-T1', '業務', current_date - 30, '在職', false, '考核期'),
  ('MI-9906', '假員9906', 'ZZ-T2', '業務', current_date - 3, '在職', true, '考核期'),
  ('MI-9908', '假員9908', 'ZZ-T2', '業務', current_date - 300, '在職', true, '已上線');

create temp table vr_ids (k text primary key, id uuid);
insert into vr_ids values
  ('tk2', pg_temp.vr_tk('MI-9902', 'ZZ-T1', 'open')),
  ('tk4', pg_temp.vr_tk('MI-9904', 'ZZ-T1', 'open')),
  ('tk5', pg_temp.vr_tk('MI-9905', 'ZZ-T1', 'open')),
  ('tk8', pg_temp.vr_tk('MI-9908', 'ZZ-T2', 'open'));

-- 黃單：y1 有效未輔導（甲）、y2 作廢（甲）、y3 有效未輔導（乙）、y4 已輔導（甲）
insert into vr_ids values
  ('y1', pg_temp.vr_yl('MI-9901', 'ZZ-T1', current_date - 2, '有效', false)),
  ('y2', pg_temp.vr_yl('MI-9902', 'ZZ-T1', current_date - 2, '作廢', false)),
  ('y3', pg_temp.vr_yl('MI-9906', 'ZZ-T2', current_date - 2, '有效', false)),
  ('y4', pg_temp.vr_yl('MI-9904', 'ZZ-T1', current_date - 2, '有效', true));

-- ============================================================
-- 一、improve_badge：只算 open
-- ============================================================
select pg_temp.vr_eq('一 改善單紅點', '甲店店長：9902、9904 兩張 open（離職的不算）＝2', '2', pg_temp.vr_im(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('一 改善單紅點', '乙店店長只看自己門市＝1', '1', pg_temp.vr_im(('td-sm2' || pg_temp.dom())));
select pg_temp.vr_eq('一 改善單紅點', '客服部＝全部（比基準多 3）', '3',
  (pg_temp.vr_im(('td-cs' || pg_temp.dom()))::int - (select im from vr_base))::text);
select pg_temp.vr_eq('一 改善單紅點', '主管 0', '0', pg_temp.vr_im(('td-hq' || pg_temp.dom())));
select pg_temp.vr_eq('一 改善單紅點', '沒開通帳號被拒', 'ERROR: 沒有權限', pg_temp.vr_im(('td-nobody' || pg_temp.dom())));
select pg_temp.vr_eq('一 改善單紅點', '匿名被拒', 'true',
  (pg_temp.vr_as('anon', null, 'select public.improve_badge()::text') like 'ERROR:%')::text);

-- ============================================================
-- 二、spot_badge：黃單有效且未輔導
-- ============================================================
select pg_temp.vr_eq('二 異常回覆單紅點', '甲店店長：y1 有效未輔導＝1（y2 作廢、y4 已輔導不算）', '1', pg_temp.vr_sp(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('二 異常回覆單紅點', '乙店店長＝1（y3）', '1', pg_temp.vr_sp(('td-sm2' || pg_temp.dom())));
select pg_temp.vr_eq('二 異常回覆單紅點', '客服部＝全部（比基準多 2）', '2',
  (pg_temp.vr_sp(('td-cs' || pg_temp.dom()))::int - (select sp from vr_base))::text);
select pg_temp.vr_eq('二 異常回覆單紅點', '主管 0', '0', pg_temp.vr_sp(('td-hq' || pg_temp.dom())));
select pg_temp.vr_eq('二 異常回覆單紅點', '沒開通帳號被拒', 'ERROR: 沒有權限', pg_temp.vr_sp(('td-nobody' || pg_temp.dom())));
select pg_temp.vr_eq('二 異常回覆單紅點', '匿名被拒', 'true',
  (pg_temp.vr_as('anon', null, 'select public.spot_badge()::text') like 'ERROR:%')::text);

-- 人員離職或不納入考核的黃單不算
select pg_temp.vr_eq('二 異常回覆單紅點', '新增 9907（不納入考核）黃單', 'true', (pg_temp.vr_yl('MI-9907', 'ZZ-T1', current_date - 1, '有效', false) is not null)::text);
select pg_temp.vr_eq('二 異常回覆單紅點', '加入 9907 黃單後甲店仍是 1', '1', pg_temp.vr_sp(('td-sm1' || pg_temp.dom())));

-- ============================================================
-- 三、todo_unreported_rows / exam_req_badge
-- ============================================================
select pg_temp.vr_eq('三 未回報清單', '甲店店長清單', 'MI-9901:新人', pg_temp.vr_rows(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('三 未回報清單', '乙店店長只看自己門市', 'MI-9906:新人', pg_temp.vr_rows(('td-sm2' || pg_temp.dom())));
select pg_temp.vr_eq('三 未回報清單', '客服部看全部假門市', 'MI-9901:新人,MI-9906:新人', pg_temp.vr_rows(('td-cs' || pg_temp.dom())));
select pg_temp.vr_eq('三 未回報清單', '主管回空', '(空)', pg_temp.vr_rows(('td-hq' || pg_temp.dom())));
select pg_temp.vr_eq('三 未回報清單', '沒開通帳號被拒', 'ERROR: 沒有權限', pg_temp.vr_rows(('td-nobody' || pg_temp.dom())));
select pg_temp.vr_eq('三 未回報清單', '匿名被拒', 'true',
  (pg_temp.vr_as('anon', null, 'select count(*)::text from public.todo_unreported_rows()') like 'ERROR:%')::text);
select pg_temp.vr_eq('三 未回報清單', '9901 的 since_on＝到職日', to_char(current_date - 3, 'YYYY-MM-DD'),
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()), $q$select to_char(since_on, 'YYYY-MM-DD') from public.todo_unreported_rows() where employee_id = 'MI-9901'$q$));
select pg_temp.vr_eq('三 未回報清單', '名稱欄位顯示暱稱', '假員9901',
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()), $q$select employee_label from public.todo_unreported_rows() where employee_id = 'MI-9901'$q$));
select pg_temp.vr_eq('三 紅點', '甲店店長 exam_req_badge＝清單筆數 1', '1', pg_temp.vr_ex(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('三 紅點', '乙店店長 exam_req_badge＝1', '1', pg_temp.vr_ex(('td-sm2' || pg_temp.dom())));
select pg_temp.vr_eq('三 紅點', '客服部分支不變：不因新人增加', '0',
  (pg_temp.vr_ex(('td-cs' || pg_temp.dom()))::int - (select ex from vr_base))::text);
select pg_temp.vr_eq('三 紅點', '主管 0', '0', pg_temp.vr_ex(('td-hq' || pg_temp.dom())));
select pg_temp.vr_eq('三 紅點', '沒開通帳號被拒', 'ERROR: 沒有權限', pg_temp.vr_ex(('td-nobody' || pg_temp.dom())));

-- ============================================================
-- 四、流程：open → coached → 送出待考回報 → 撤回
-- ============================================================
select pg_temp.vr_eq('四 流程', '店長回填 9902 輔導紀錄成功', '',
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()),
    format($q$select public.improve_mark_coached(%L::uuid, (now() at time zone 'Asia/Taipei')::date, '假輔導')::text$q$,
           (select id from vr_ids where k = 'tk2'))));
select pg_temp.vr_eq('四 流程', 'open→coached：甲店改善單紅點 2→1', '1', pg_temp.vr_im(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('四 流程', '甲店清單多出 9902「已輔導未約考」', 'MI-9901:新人,MI-9902:已輔導未約考', pg_temp.vr_rows(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('四 流程', '9902 的 since_on＝輔導日（今天台北日期）', to_char((now() at time zone 'Asia/Taipei')::date, 'YYYY-MM-DD'),
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()), $q$select to_char(since_on, 'YYYY-MM-DD') from public.todo_unreported_rows() where employee_id = 'MI-9902'$q$));
select pg_temp.vr_eq('四 流程', '待考回報紅點含已輔導未約考 ＝2', '2', pg_temp.vr_ex(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('四 流程', '乙店不受影響', 'MI-9906:新人', pg_temp.vr_rows(('td-sm2' || pg_temp.dom())));

select pg_temp.vr_eq('四 流程', '店長送出 9901「新人」待考回報成功', 'true',
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()),
    $q$select (public.exam_req_create('新人', 'MI-9901', array[current_date + 3], true, null, null) is not null)::text$q$));
select pg_temp.vr_eq('四 流程', '送出後 9901 從清單消失', 'MI-9902:已輔導未約考', pg_temp.vr_rows(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('四 流程', '紅點 2→1', '1', pg_temp.vr_ex(('td-sm1' || pg_temp.dom())));

select pg_temp.vr_eq('四 流程', '店長對 9902 送出「複檢」待考回報成功', 'true',
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()),
    format($q$select (public.exam_req_create('複檢', 'MI-9902', array[current_date + 3], null, null, %L::uuid) is not null)::text$q$,
           (select id from vr_ids where k = 'tk2'))));
select pg_temp.vr_eq('四 流程', '兩人都回報後甲店清單為空', '(空)', pg_temp.vr_rows(('td-sm1' || pg_temp.dom())));
select pg_temp.vr_eq('四 流程', '紅點 0', '0', pg_temp.vr_ex(('td-sm1' || pg_temp.dom())));

select pg_temp.vr_eq('四 流程', '撤回 9901 的待考回報成功', '',
  pg_temp.vr_u(('td-sm1' || pg_temp.dom()),
    $q$select public.exam_req_withdraw((select id from public.exam_requests where employee_id = 'MI-9901' and status = '待處理'))::text$q$));
select pg_temp.vr_eq('四 流程', '撤回後 9901 回到清單', 'MI-9901:新人', pg_temp.vr_rows(('td-sm1' || pg_temp.dom())));

-- 黃單回填輔導後紅點消；作廢者不算；人員離職不算
update public.spot_tickets
   set coached_on = current_date, coach_note = '假輔導', coached_by = ('td-sm1' || pg_temp.dom()), coached_at = now()
 where id = (select id from vr_ids where k = 'y1');
select pg_temp.vr_eq('四 流程', '黃單回填輔導後甲店 spot_badge 1→0', '0', pg_temp.vr_sp(('td-sm1' || pg_temp.dom())));
update public.employees set status = '離職' where id = 'MI-9904';
select pg_temp.vr_eq('四 流程', '人員離職後其改善單不計（甲店 1→0）', '0', pg_temp.vr_im(('td-sm1' || pg_temp.dom())));
update public.employees set status = '在職' where id = 'MI-9904';

-- ============================================================
-- 五、每週彙整信 todo_digest_run
-- ============================================================
create temp table vr_t as
  select ((date_trunc('week', (now() + interval '60 days') at time zone 'Asia/Taipei') + interval '9 hours')
          at time zone 'Asia/Taipei') as now_ts;
create temp table vr_td as select (now_ts at time zone 'Asia/Taipei')::date as d from vr_t;

-- 整備天數：改善單 tk4（甲）10 天；tk8（乙）2 天；黃單 y3（乙）9 天；新增甲店黃單 y5（9904）3 天
update public.improvement_tickets set created_at = (select now_ts from vr_t) - interval '10 days'
 where id = (select id from vr_ids where k = 'tk4');
update public.improvement_tickets set created_at = (select now_ts from vr_t) - interval '2 days'
 where id = (select id from vr_ids where k = 'tk8');
update public.spot_tickets set issued_on = (select d from vr_td) - 9
 where id = (select id from vr_ids where k = 'y3');
insert into vr_ids values ('y5', pg_temp.vr_yl('MI-9904', 'ZZ-T1', (select d from vr_td) - 3, '有效', false));

-- 沒設收件人 → 0 封
delete from public.app_settings where key = 'todo_digest_recipients';
select pg_temp.vr_eq('五 彙整信', '沒設收件人：回 0', '0', (select public.todo_digest_run((select now_ts from vr_t))::text));
select pg_temp.vr_eq('五 彙整信', '沒設收件人：mail_outbox 沒有彙整信', '0',
  (select count(*)::text from public.mail_outbox where kind = 'todo_digest'));
insert into public.app_settings (key, value) values ('todo_digest_recipients', '   ');
select pg_temp.vr_eq('五 彙整信', '收件人是空白：回 0', '0', (select public.todo_digest_run((select now_ts from vr_t))::text));
update public.app_settings set value = 'not-an-email, 另一個壞值' where key = 'todo_digest_recipients';
select pg_temp.vr_eq('五 彙整信', '收件人全是壞格式：回 0', '0', (select public.todo_digest_run((select now_ts from vr_t))::text));

-- 設好收件人 → 1 封
update public.app_settings set value = ' A@Example.test , b@example.test,not-an-email,a@example.test' where key = 'todo_digest_recipients';
select pg_temp.vr_eq('五 彙整信', '有設收件人：回 1', '1', (select public.todo_digest_run((select now_ts from vr_t))::text));
select pg_temp.vr_eq('五 彙整信', 'mail_outbox 有 1 封 todo_digest', '1',
  (select count(*)::text from public.mail_outbox where kind = 'todo_digest'));
select pg_temp.vr_eq('五 彙整信', '收件人：小寫、去重、剔除壞格式', '{a@example.test,b@example.test}',
  (select to_emails::text from public.mail_outbox where kind = 'todo_digest' order by created_at desc limit 1));
select pg_temp.vr_eq('五 彙整信', '信件只有一封（收件人都在同一封）', '1',
  (select count(*)::text from public.mail_outbox where kind = 'todo_digest' and cardinality(to_emails) = 2));
select pg_temp.vr_eq('五 彙整信', '主旨含「尚未回填的輔導紀錄」', 'true',
  (select (subject like '%尚未回填的輔導紀錄%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '內文有甲店名稱', 'true',
  (select (body_html like '%ZZ待填甲店%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '內文有乙店名稱', 'true',
  (select (body_html like '%ZZ待填乙店%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '甲店最久 10 天', 'true',
  (select (body_html like '%ZZ待填甲店</td><td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center">1</td><td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center">1</td><td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center">10 天</td>%')::text
     from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '甲店超過 7 天名單：9904（10 天）', 'true',
  (select (body_html like '%假員9904（10 天）%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '乙店超過 7 天名單：9906（9 天，黃單）', 'true',
  (select (body_html like '%假員9906（9 天）%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '乙店 9908（2 天）不在超過 7 天名單', 'true',
  (select (body_html not like '%假員9908（%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '已作廢、已輔導、離職的不出現（9902、9905、9907）', 'true',
  (select (body_html not like '%假員9902%' and body_html not like '%假員9905%' and body_html not like '%假員9907%')::text
     from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '用詞：寫「回填輔導紀錄」', 'true',
  (select (body_html like '%回填輔導紀錄%')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '用詞：不出現「改善單」「計時」「倒數」「監控」', 'true',
  (select ((subject || body_html) !~ '改善單|計時|倒數|監控')::text from public.mail_outbox where kind = 'todo_digest' limit 1));
select pg_temp.vr_eq('五 彙整信', '寄信狀態有被寄信觸發器處理（沒設中繼站＝skipped，或 queued）', 'true',
  (select (status in ('queued', 'skipped', 'sent'))::text from public.mail_outbox where kind = 'todo_digest' limit 1));

-- 同週不重複
select pg_temp.vr_eq('五 彙整信', '同一週第二次：回 0', '0', (select public.todo_digest_run((select now_ts from vr_t))::text));
select pg_temp.vr_eq('五 彙整信', '同一週隔天（週二）：回 0', '0',
  (select public.todo_digest_run((select now_ts from vr_t) + interval '1 day')::text));
select pg_temp.vr_eq('五 彙整信', '同一週週日：回 0', '0',
  (select public.todo_digest_run((select now_ts from vr_t) + interval '6 days')::text));
select pg_temp.vr_eq('五 彙整信', '仍只有 1 封', '1', (select count(*)::text from public.mail_outbox where kind = 'todo_digest'));
select pg_temp.vr_eq('五 彙整信', '下一週（隔 7 天）：再寄 1 封', '1',
  (select public.todo_digest_run((select now_ts from vr_t) + interval '7 days')::text));
select pg_temp.vr_eq('五 彙整信', '共 2 封', '2', (select count(*)::text from public.mail_outbox where kind = 'todo_digest'));
-- 設成空字串 → 整個不寄
update public.app_settings set value = '' where key = 'todo_digest_recipients';
select pg_temp.vr_eq('五 彙整信', '收件人改成空字串：下一週回 0', '0',
  (select public.todo_digest_run((select now_ts from vr_t) + interval '14 days')::text));
-- 全部補填後沒有未填 → 0
update public.app_settings set value = 'a@example.test' where key = 'todo_digest_recipients';
update public.improvement_tickets set status = 'cancelled', cancelled_by = 'td', cancelled_at = now(), cancel_reason = '假'
 where status = 'open' and employee_id in ('MI-9902', 'MI-9904', 'MI-9905', 'MI-9908');
update public.spot_tickets set status = '作廢', void_reason = '假', voided_by = 'td', voided_at = now()
 where kind = '黃' and status = '有效' and coached_on is null and employee_id in ('MI-9901', 'MI-9902', 'MI-9904', 'MI-9906', 'MI-9907');
select pg_temp.vr_eq('五 彙整信', '假門市的待回填改善單都清掉了', 'true',
  (select ((select count(*) from public.improvement_tickets where status = 'open' and store_code like 'ZZ-T%') = 0)::text));
select pg_temp.vr_eq('五 彙整信', '彙整信函式的權限：網頁角色不能呼叫', 'true',
  (pg_temp.vr_u(('td-cs' || pg_temp.dom()), 'select public.todo_digest_run()::text') like 'ERROR:%')::text);

-- ============================================================
-- 五之二、已上線（不是考核期）但已輔導的人：比照 coached_pending
-- 9909：已上線＋已輔導改善單；9910：已上線＋只有 open（未輔導）；9911：考核期＋已輔導（確認同一人不重複列）
-- ============================================================
insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status) values
  ('MI-9909', '假員9909', 'ZZ-T1', '業務', current_date - 300, '在職', true, '已上線'),
  ('MI-9910', '假員9910', 'ZZ-T1', '業務', current_date - 300, '在職', true, '已上線'),
  ('MI-9911', '假員9911', 'ZZ-T1', '業務', current_date - 40, '在職', true, '考核期');
insert into vr_ids values
  ('tk9', pg_temp.vr_tk('MI-9909', 'ZZ-T1', 'coached')),
  ('tk10', pg_temp.vr_tk('MI-9910', 'ZZ-T1', 'open')),
  ('tk11', pg_temp.vr_tk('MI-9911', 'ZZ-T1', 'coached'));
update public.improvement_tickets
   set coached_on = (now() at time zone 'Asia/Taipei')::date, coach_note = '假輔導',
       coached_by = ('td-sm1' || pg_temp.dom()), coached_at = now()
 where id in (select id from vr_ids where k in ('tk9', 'tk11'));

create temp table vr_b as select pg_temp.vr_ex('td-sm1' || pg_temp.dom())::int as ex;
create or replace function pg_temp.vr_r2(p_email text) returns text language sql as $$
  select pg_temp.vr_u(p_email,
    $q$select coalesce(string_agg(employee_id || ':' || reason, ',' order by employee_id), '(空)')
         from public.todo_unreported_rows() where employee_id in ('MI-9909', 'MI-9910', 'MI-9911')$q$) $$;

select pg_temp.vr_eq('七 已上線已輔導', '已上線＋已輔導（9909）列入；已上線＋只有 open（9910）不列；考核期＋已輔導（9911）只列一次',
  'MI-9909:已輔導未約考,MI-9911:已輔導未約考', pg_temp.vr_r2('td-sm1' || pg_temp.dom()));
select pg_temp.vr_eq('七 已上線已輔導', '9909 的 since_on＝輔導日（台北今天）', to_char((now() at time zone 'Asia/Taipei')::date, 'YYYY-MM-DD'),
  pg_temp.vr_u('td-sm1' || pg_temp.dom(), $q$select to_char(since_on, 'YYYY-MM-DD') from public.todo_unreported_rows() where employee_id = 'MI-9909'$q$));
select pg_temp.vr_eq('七 已上線已輔導', '他店店長看不到 9909', '(空)', pg_temp.vr_r2('td-sm2' || pg_temp.dom()));
select pg_temp.vr_eq('七 已上線已輔導', '客服部看得到 9909', 'MI-9909:已輔導未約考,MI-9911:已輔導未約考', pg_temp.vr_r2('td-cs' || pg_temp.dom()));
select pg_temp.vr_eq('七 已上線已輔導', '與 coached_pending() 一致：9909 也在舊清單內', 'true',
  pg_temp.vr_u('td-sm1' || pg_temp.dom(), $q$select exists (select 1 from public.coached_pending() where employee_id = 'MI-9909')::text$q$));
select pg_temp.vr_eq('七 已上線已輔導', '待考回報紅點＝清單筆數（含已上線已輔導者）', 'true',
  (pg_temp.vr_ex('td-sm1' || pg_temp.dom())::int = (pg_temp.vr_u('td-sm1' || pg_temp.dom(), 'select count(*)::text from public.todo_unreported_rows()'))::int)::text);

-- 送出複檢待考回報 → 9909 消失
select pg_temp.vr_eq('七 已上線已輔導', '店長對 9909 送出「複檢」待考回報成功', 'true',
  pg_temp.vr_u('td-sm1' || pg_temp.dom(),
    format($q$select (public.exam_req_create('複檢', 'MI-9909', array[current_date + 3], null, null, %L::uuid) is not null)::text$q$,
           (select id from vr_ids where k = 'tk9'))));
select pg_temp.vr_eq('七 已上線已輔導', '送出回報後 9909 消失', 'MI-9911:已輔導未約考', pg_temp.vr_r2('td-sm1' || pg_temp.dom()));
select pg_temp.vr_eq('七 已上線已輔導', '紅點少 1', '-1',
  (pg_temp.vr_ex('td-sm1' || pg_temp.dom())::int - (select ex from vr_b) )::text);
select pg_temp.vr_eq('七 已上線已輔導', '回報之後 coached_pending() 也同步不列（語意一致）', 'false',
  pg_temp.vr_u('td-sm1' || pg_temp.dom(), $q$select exists (select 1 from public.coached_pending() where employee_id = 'MI-9909')::text$q$));
-- 已完成的回報也算約過（比照 coached_pending）：把該回報改成已完成仍不列
update public.exam_requests set status = '已完成' where employee_id = 'MI-9909';
select pg_temp.vr_eq('七 已上線已輔導', '回報已完成後 9909 仍不列', 'MI-9911:已輔導未約考', pg_temp.vr_r2('td-sm1' || pg_temp.dom()));
-- 輔導完成後改善單結案就不列
update public.improvement_tickets set status = 'closed', closed_by = 'td', closed_at = now() where id = (select id from vr_ids where k = 'tk11');
select pg_temp.vr_eq('七 已上線已輔導', '考核期的 9911 改善單結案後不再是「已輔導未約考」（回到新人）', 'MI-9911:新人', pg_temp.vr_r2('td-sm1' || pg_temp.dom()));

-- ============================================================
-- 六、權限與簽名
-- ============================================================
select pg_temp.vr_eq('六 權限', 'authenticated 可呼叫四個前端函式', 'true,true,true,true',
  has_function_privilege('authenticated', 'public.improve_badge()', 'execute')::text || ',' ||
  has_function_privilege('authenticated', 'public.spot_badge()', 'execute')::text || ',' ||
  has_function_privilege('authenticated', 'public.todo_unreported_rows()', 'execute')::text || ',' ||
  has_function_privilege('authenticated', 'public.exam_req_badge()', 'execute')::text);
select pg_temp.vr_eq('六 權限', 'anon 全部不能呼叫', 'false,false,false,false,false',
  has_function_privilege('anon', 'public.improve_badge()', 'execute')::text || ',' ||
  has_function_privilege('anon', 'public.spot_badge()', 'execute')::text || ',' ||
  has_function_privilege('anon', 'public.todo_unreported_rows()', 'execute')::text || ',' ||
  has_function_privilege('anon', 'public.exam_req_badge()', 'execute')::text || ',' ||
  has_function_privilege('anon', 'public.todo_digest_run(timestamptz)', 'execute')::text);
select pg_temp.vr_eq('六 權限', 'authenticated 不能呼叫 todo_digest_run', 'false',
  has_function_privilege('authenticated', 'public.todo_digest_run(timestamptz)', 'execute')::text);
select pg_temp.vr_eq('六 簽名', '回傳型別：improve_badge／spot_badge／exam_req_badge 都是 integer', 'integer,integer,integer',
  (select pg_get_function_result('public.improve_badge()'::regprocedure)) || ',' ||
  (select pg_get_function_result('public.spot_badge()'::regprocedure)) || ',' ||
  (select pg_get_function_result('public.exam_req_badge()'::regprocedure)));
select pg_temp.vr_eq('六 簽名', 'todo_unreported_rows 欄位', 'TABLE(employee_id text, employee_label text, store_code text, reason text, since_on date)',
  pg_get_function_result('public.todo_unreported_rows()'::regprocedure));
select pg_temp.vr_eq('六 簽名', '既有 coached_pending_count 沒被動到（仍存在）', 'true',
  (to_regprocedure('public.coached_pending_count()') is not null)::text);
select pg_temp.vr_eq('六 簽名', 'improve_badge 不再算 coached', 'true',
  (select (p.prosrc not like '%coached%')::text from pg_proc p where p.oid = 'public.improve_badge()'::regprocedure));

-- ---------- 輸出結果 ----------
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
  begin execute 'deallocate todo_reminder_vr_out'; exception when others then null; end;
  execute 'prepare todo_reminder_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_ok = v_total then ''
                                   else '；未通過：' || (select string_agg(n::text, '、' order by n) from pg_temp.vr where not pass) end)
          || ', ' || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
end
$$;

rollback;

execute todo_reminder_vr_out;
