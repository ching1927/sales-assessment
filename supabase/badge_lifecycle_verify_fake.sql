-- ============================================================
-- 業務考核系統：導覽紅點「到事情完整結束才消」驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 badge_lifecycle_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-B1／ZZ-B2、假人員 MI-9801～MI-9810、假帳號（bl-xxx@2motor.tw），
--   用 set local role ＋ request.jwt.claims 模擬各角色登入，呼叫 exam_req_badge（待考回報分頁）與
--   improve_badge（成績單&考核後台分頁），並走真實的 exam_req_create／exam_req_mark_seen／exam_req_schedule／
--   exam_req_return／improve_mark_coached／improve_close／improve_cancel；每項斷言記在暫存表，最後 rollback。
-- 怎麼看結果：最後一個結果＝「序號／群組／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；
--   「通過」欄全是「通過」才算成功。
-- 驗證重點：
--   新人在名冊建檔（考核期）後店長就有紅點；店長點進去（mark_seen）、送出待考回報、客服排定、回報被退回，紅點都不消；
--   設為已上線才消；他店店長看不到；離職／未納入考核不計；
--   改善單（待改善→已輔導→送複檢回報）紅點都在，客服部結案（複檢完成）才消；取消、人員離職也不計；
--   客服部的待處理紅點仍照舊；主管為 0；沒開通帳號被拒；匿名被拒；函式權限正確。
-- 假門市 ZZ-B1／ZZ-B2、假員工 MI-9801～MI-9810、假信箱 bl-*@2motor.tw 若撞到真實資料，腳本會在建立時報錯並停下
--   （rollback 後不影響任何資料）。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regprocedure('public.improve_badge()') is null then
    raise exception '請先執行 badge_lifecycle_schema.sql';
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
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

-- 兩個紅點的快捷：回傳數字文字或 'ERROR: …'
create or replace function pg_temp.vr_ex(p_email text) returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_email, 'select public.exam_req_badge()::text') $$;
create or replace function pg_temp.vr_im(p_email text) returns text language sql as $$
  select pg_temp.vr_as('authenticated', p_email, 'select public.improve_badge()::text') $$;

-- 一張改善單（含來源成績單），擁有者身分；回傳改善單 id
create or replace function pg_temp.vr_tk(p_emp text, p_store text, p_status text)
returns uuid language plpgsql as $$
declare v_a uuid; v_t uuid;
begin
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
     total_score, verdict, pass_line, submitted_at)
  values (p_emp, '假員' || right(p_emp, 4), p_store, 'bl-cs@2motor.tw', 'submitted', '正式', '自動', 50, '不及格', 70, now())
  returning id into v_a;
  insert into public.improvement_tickets (assessment_id, employee_id, store_code, status, due_date, coached_on, coach_note)
  values (v_a, p_emp, p_store, p_status, current_date + 14,
          case when p_status = 'coached' then current_date else null end,
          case when p_status = 'coached' then '假輔導' else null end)
  returning id into v_t;
  return v_t;
end $$;

-- ---------- 建立假資料（先建帳號與門市，才能量「客服部基準數」）----------
do $$
begin
  insert into public.stores (code, name) values ('ZZ-B1', 'ZZ紅點甲店'), ('ZZ-B2', 'ZZ紅點乙店');
  insert into public.app_users (email, role, store_code) values
    ('bl-cs@2motor.tw', 'cs_admin', null),
    ('bl-hq@2motor.tw', 'hq_viewer', null),
    ('bl-sm1@2motor.tw', 'store_manager', 'ZZ-B1'),
    ('bl-sm2@2motor.tw', 'store_manager', 'ZZ-B2');
end $$;

-- 客服部基準數（資料庫裡若已有真實資料，之後只看「增減量」）
create temp table vr_base as
  select pg_temp.vr_ex('bl-cs@2motor.tw')::int as ex, pg_temp.vr_im('bl-cs@2motor.tw')::int as im;

-- ============================================================
-- 一、新人：建檔 → 店長紅點 → 點進去、送出回報、排定、退回都不消 → 已上線才消
-- ============================================================
select pg_temp.vr_eq('一 新人', '建檔前：甲店店長 0', '0', pg_temp.vr_ex('bl-sm1@2motor.tw'));

-- 客服在名冊建檔：考核期新人（到職 5 天內）
insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status)
values ('MI-9801', '假新人9801', 'ZZ-B1', '業務', current_date - 5, '在職', true, '考核期');

select pg_temp.vr_eq('一 新人', '建檔後：甲店店長 1', '1', pg_temp.vr_ex('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('一 新人', '他店（乙店）店長看不到：0', '0', pg_temp.vr_ex('bl-sm2@2motor.tw'));
select pg_temp.vr_eq('一 新人', '客服部不因新人建檔增加（只算待處理回報／待開通）', '0',
  (pg_temp.vr_ex('bl-cs@2motor.tw')::int - (select ex from vr_base))::text);
select pg_temp.vr_eq('一 新人', '主管 0', '0', pg_temp.vr_ex('bl-hq@2motor.tw'));

-- 店長點進待考回報頁（頁面會呼叫 exam_req_mark_seen）：紅點不消
select pg_temp.vr_eq('一 新人', '店長呼叫 mark_seen 成功', '',
  pg_temp.vr_as('authenticated', 'bl-sm1@2motor.tw', 'select public.exam_req_mark_seen()::text'));
select pg_temp.vr_eq('一 新人', '點進去（mark_seen）後紅點仍是 1', '1', pg_temp.vr_ex('bl-sm1@2motor.tw'));

-- 店長送出待考回報：紅點仍在；客服部多一個待處理
select pg_temp.vr_eq('一 新人', '店長送出「新人」待考回報成功', 'true',
  pg_temp.vr_as('authenticated', 'bl-sm1@2motor.tw',
    $q$select (public.exam_req_create('新人', 'MI-9801', array[current_date + 3], true, null, null) is not null)::text$q$));
select pg_temp.vr_eq('一 新人', '送出回報後店長紅點變 0（已回報不再待填）', '0', pg_temp.vr_ex('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('一 新人', '客服部待處理 +1（照舊）', '1',
  (pg_temp.vr_ex('bl-cs@2motor.tw')::int - (select ex from vr_base))::text);

-- 客服排定：客服部待處理 -1；店長紅點仍在（人還沒上線）；店長看過回覆也不消
select pg_temp.vr_eq('一 新人', '客服排定成功', '',
  pg_temp.vr_as('authenticated', 'bl-cs@2motor.tw',
    format($q$select public.exam_req_schedule(%L::uuid, now() + interval '2 days', '假備註')::text$q$,
           (select id from public.exam_requests where employee_id = 'MI-9801' and status = '待處理'))));
select pg_temp.vr_eq('一 新人', '排定後客服部待處理回到基準', '0',
  (pg_temp.vr_ex('bl-cs@2motor.tw')::int - (select ex from vr_base))::text);
select pg_temp.vr_eq('一 新人', '排定後店長紅點仍是 0（已排定，沒有待填）', '0', pg_temp.vr_ex('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('一 新人', '排定後店長點進去（mark_seen）仍是 0', '0',
  (select case when pg_temp.vr_as('authenticated', 'bl-sm1@2motor.tw', 'select public.exam_req_mark_seen()::text') = ''
               then pg_temp.vr_ex('bl-sm1@2motor.tw') else 'mark_seen 失敗' end));

-- 客服退回這筆回報（已取消）：人還在考核期，店長紅點仍在
select pg_temp.vr_eq('一 新人', '客服退回回報成功', '',
  pg_temp.vr_as('authenticated', 'bl-cs@2motor.tw',
    format($q$select public.exam_req_return(%L::uuid, '假退回')::text$q$,
           (select id from public.exam_requests where employee_id = 'MI-9801' and status = '已排定'))));
select pg_temp.vr_eq('一 新人', '回報被退回後店長紅點仍是 1（人還沒上線）', '1', pg_temp.vr_ex('bl-sm1@2motor.tw'));

-- 其他不計入的人：離職考核期、未納入考核的考核期、已上線、他店考核期
insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status)
values ('MI-9802', '假離職9802', 'ZZ-B1', '業務', current_date - 5, '離職', true, '考核期'),
       ('MI-9803', '假不考核9803', 'ZZ-B1', '業務', current_date - 5, '在職', false, '考核期'),
       ('MI-9804', '假已上線9804', 'ZZ-B1', '業務', current_date - 200, '在職', true, '已上線'),
       ('MI-9805', '假乙店新人9805', 'ZZ-B2', '業務', current_date - 5, '在職', true, '考核期');
select pg_temp.vr_eq('一 新人', '離職／未納入考核／已上線都不計：甲店仍是 1', '1', pg_temp.vr_ex('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('一 新人', '乙店新人只算乙店：乙店 1', '1', pg_temp.vr_ex('bl-sm2@2motor.tw'));

-- 設為已上線：紅點消失（乙店不受影響）
update public.employees set period_status = '已上線', passed_on = current_date where id = 'MI-9801';
select pg_temp.vr_eq('一 新人', '設為已上線後甲店店長 0', '0', pg_temp.vr_ex('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('一 新人', '甲店已上線不影響乙店：乙店仍 1', '1', pg_temp.vr_ex('bl-sm2@2motor.tw'));

-- 中途離職：不再計入
insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status)
values ('MI-9806', '假中途離職9806', 'ZZ-B1', '業務', current_date - 3, '在職', true, '考核期');
select pg_temp.vr_eq('一 新人', '另一位新人建檔：甲店 1', '1', pg_temp.vr_ex('bl-sm1@2motor.tw'));
update public.employees set status = '離職' where id = 'MI-9806';
select pg_temp.vr_eq('一 新人', '中途離職後甲店 0', '0', pg_temp.vr_ex('bl-sm1@2motor.tw'));

-- ============================================================
-- 二、改善單：待改善 → 已輔導 → 送複檢回報 → 結案（複檢完成）才消
-- ============================================================
insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, period_status)
values ('MI-9807', '假改善9807', 'ZZ-B1', '業務', current_date - 200, '在職', true, '已上線'),
       ('MI-9808', '假改善9808', 'ZZ-B1', '業務', current_date - 200, '在職', true, '已上線'),
       ('MI-9809', '假改善9809', 'ZZ-B1', '業務', current_date - 200, '在職', true, '已上線'),
       ('MI-9810', '假改善9810', 'ZZ-B2', '業務', current_date - 200, '在職', true, '已上線');

create temp table vr_tk (k text primary key, id uuid);
insert into vr_tk values ('A', pg_temp.vr_tk('MI-9807', 'ZZ-B1', 'open'));

select pg_temp.vr_eq('二 改善單', '開單（待改善）：甲店店長 1', '1', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '他店（乙店）店長看不到：0', '0', pg_temp.vr_im('bl-sm2@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '客服部 +1', '1', (pg_temp.vr_im('bl-cs@2motor.tw')::int - (select im from vr_base))::text);
select pg_temp.vr_eq('二 改善單', '主管 0', '0', pg_temp.vr_im('bl-hq@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '改善單紅點不影響待考回報分頁的店長數字', '0', pg_temp.vr_ex('bl-sm1@2motor.tw'));

select pg_temp.vr_eq('二 改善單', '店長標記已輔導成功', '',
  pg_temp.vr_as('authenticated', 'bl-sm1@2motor.tw',
    format($q$select public.improve_mark_coached(%L::uuid, current_date, '假輔導紀錄')::text$q$, (select id from vr_tk where k = 'A'))));
select pg_temp.vr_eq('二 改善單', '已輔導後甲店店長改善單紅點變 0（只算未回填的 open）', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '已輔導後客服部相對基準 +0（只算 open）', '0', (pg_temp.vr_im('bl-cs@2motor.tw')::int - (select im from vr_base))::text);

select pg_temp.vr_eq('二 改善單', '店長送出「複檢」待考回報成功', 'true',
  pg_temp.vr_as('authenticated', 'bl-sm1@2motor.tw',
    format($q$select (public.exam_req_create('複檢', 'MI-9807', array[current_date + 2], null, null, %L::uuid) is not null)::text$q$,
           (select id from vr_tk where k = 'A'))));
select pg_temp.vr_eq('二 改善單', '送出複檢回報後甲店店長改善單紅點仍是 0', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '店長點進去（mark_seen）後改善單紅點仍是 0', '0',
  (select case when pg_temp.vr_as('authenticated', 'bl-sm1@2motor.tw', 'select public.exam_req_mark_seen()::text') = ''
               then pg_temp.vr_im('bl-sm1@2motor.tw') else 'mark_seen 失敗' end));

-- 複檢完成：造一張開單之後送出、判定及格的複檢成績單，客服部結案
insert into public.assessments
  (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source,
   total_score, verdict, pass_line, submitted_at)
values ('MI-9807', '假員9807', 'ZZ-B1', 'bl-cs@2motor.tw', 'submitted', '正式', '自動', 90, '及格', 85,
        clock_timestamp() + interval '1 minute');
select pg_temp.vr_eq('二 改善單', '複檢成績單送出後、結案前紅點仍是 0（已輔導不算）', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '客服部結案（複檢完成）成功', '',
  pg_temp.vr_as('authenticated', 'bl-cs@2motor.tw',
    format($q$select public.improve_close(%L::uuid, %L::uuid, '假結案')::text$q$,
           (select id from vr_tk where k = 'A'),
           (select id from public.assessments where employee_id = 'MI-9807' and verdict = '及格'))));
select pg_temp.vr_eq('二 改善單', '結案後甲店店長 0', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '結案後客服部回到基準', '0', (pg_temp.vr_im('bl-cs@2motor.tw')::int - (select im from vr_base))::text);

-- 取消的改善單不計
insert into vr_tk values ('B', pg_temp.vr_tk('MI-9808', 'ZZ-B1', 'coached'));
select pg_temp.vr_eq('二 改善單', '新開一張已輔導改善單：甲店 0（已輔導不算）', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '客服部取消改善單成功', '',
  pg_temp.vr_as('authenticated', 'bl-cs@2motor.tw',
    format($q$select public.improve_cancel(%L::uuid, '假取消')::text$q$, (select id from vr_tk where k = 'B'))));
select pg_temp.vr_eq('二 改善單', '取消後甲店 0', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));

-- 人員中途離職不計
insert into vr_tk values ('C', pg_temp.vr_tk('MI-9809', 'ZZ-B1', 'coached'));
select pg_temp.vr_eq('二 改善單', '再開一張（已輔導）：甲店 0', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
update public.employees set status = '離職' where id = 'MI-9809';
select pg_temp.vr_eq('二 改善單', '人員離職後甲店 0', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '人員離職後客服部回到基準', '0', (pg_temp.vr_im('bl-cs@2motor.tw')::int - (select im from vr_base))::text);

-- 乙店改善單：甲店看不到、乙店與客服部看得到
insert into vr_tk values ('D', pg_temp.vr_tk('MI-9810', 'ZZ-B2', 'open'));
select pg_temp.vr_eq('二 改善單', '乙店改善單：甲店店長仍 0', '0', pg_temp.vr_im('bl-sm1@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '乙店改善單：乙店店長 1', '1', pg_temp.vr_im('bl-sm2@2motor.tw'));
select pg_temp.vr_eq('二 改善單', '乙店改善單：客服部 +1', '1', (pg_temp.vr_im('bl-cs@2motor.tw')::int - (select im from vr_base))::text);

-- ============================================================
-- 三、權限與身分
-- ============================================================
select pg_temp.vr_eq('三 權限', '沒開通帳號呼叫 exam_req_badge 被拒', 'ERROR: 沒有權限', pg_temp.vr_ex('bl-nobody@2motor.tw'));
select pg_temp.vr_eq('三 權限', '沒開通帳號呼叫 improve_badge 被拒', 'ERROR: 沒有權限', pg_temp.vr_im('bl-nobody@2motor.tw'));
select pg_temp.vr_eq('三 權限', '匿名（anon）不能呼叫 exam_req_badge', 'true',
  (pg_temp.vr_as('anon', null, 'select public.exam_req_badge()::text') like 'ERROR:%')::text);
select pg_temp.vr_eq('三 權限', '匿名（anon）不能呼叫 improve_badge', 'true',
  (pg_temp.vr_as('anon', null, 'select public.improve_badge()::text') like 'ERROR:%')::text);
select pg_temp.vr_eq('三 權限', 'authenticated 可執行兩個函式', 'true,true',
  has_function_privilege('authenticated', 'public.exam_req_badge()', 'execute')::text || ',' ||
  has_function_privilege('authenticated', 'public.improve_badge()', 'execute')::text);
select pg_temp.vr_eq('三 權限', 'anon 不可執行兩個函式', 'false,false',
  has_function_privilege('anon', 'public.exam_req_badge()', 'execute')::text || ',' ||
  has_function_privilege('anon', 'public.improve_badge()', 'execute')::text);
select pg_temp.vr_eq('三 權限', '函式簽名不變：兩個都無參數、回傳 integer', 'integer,integer',
  (select pg_get_function_result('public.exam_req_badge()'::regprocedure)) || ',' ||
  (select pg_get_function_result('public.improve_badge()'::regprocedure)));
select pg_temp.vr_eq('三 權限', 'exam_req_badge 不再用 mgr_seen（不靠「已看」）', 'true',
  (select (p.prosrc not like '%mgr_seen%')::text from pg_proc p where p.oid = 'public.exam_req_badge()'::regprocedure));

-- ---------- 輸出結果 ----------
-- rollback 會讓暫存表消失，所以先把結果做成「預備查詢」（prepare 不受 rollback 影響），rollback 之後再 execute 出來
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
  begin execute 'deallocate badge_lifecycle_vr_out'; exception when others then null; end;
  execute 'prepare badge_lifecycle_vr_out as select * from (values (0, '
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

execute badge_lifecycle_vr_out;
