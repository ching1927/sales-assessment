-- ============================================================
-- 業務考核系統：各門市黃單排名 驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 yellow_ranking_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-Y1／ZZ-Y2／ZZ-Y3、假員工 MI-9701～MI-9708、假帳號（vr-xxx@2motor.tw），
--   直接寫入假的抽查與黃單，用 set local role ＋ request.jwt.claims 模擬各角色登入，呼叫 checkup_yellow_ranking，
--   把每項斷言記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果＝「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算成功。
-- 驗證重點：作廢的不算、紅單不算、依開單當時門市（員工之後換店不影響）、日期含頭尾與邊界、
--   人數只算在職＋納入考核＋已上線、總公司排除、店長看得到全部門市但只有四欄彙總、
--   其他角色（沒開通帳號、未登入）被拒、日期範圍不合法被拒。
-- 假門市代碼 ZZ-Y1～ZZ-Y3、假員工編號 MI-9701～MI-9708、假信箱 vr-cs／vr-hq／vr-sm／vr-nobody@2motor.tw 若撞到真實資料，
--   腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regprocedure('public.checkup_yellow_ranking(date, date)') is null then
    raise exception '請先執行 yellow_ranking_schema.sql';
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

-- 一列一列的結果壓成一行文字：'代碼=張數/人數' 以逗號串接（依代碼排序）
create or replace function pg_temp.vr_rank(p_role text, p_email text, p_from date, p_to date)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as(p_role, p_email,
    format($q$select coalesce(string_agg(store_code || '=' || tickets || '/' || headcount, ',' order by store_code), '(空)')
              from public.checkup_yellow_ranking(%L, %L)
              where store_code like 'ZZ-Y%%'$q$, p_from, p_to));
end $$;

-- 一張假黃單（附一筆假抽查）；p_status 為 '作廢' 時補齊作廢欄位；回傳單據 id
create or replace function pg_temp.vr_yellow(p_emp text, p_store text, p_issued date, p_status text default '有效')
returns uuid language plpgsql as $$
declare v_i uuid; v_t uuid;
begin
  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels, total_score, verdict, reason, examiner_email)
  values (p_emp, '假員' || right(p_emp, 4), p_store, p_issued, 'https://example.com/x', '{}'::jsonb, 0, '不適當', '假原因', 'vr-cs@2motor.tw')
  returning id into v_i;
  insert into public.spot_tickets (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on)
  values ('黃', p_emp, '假員' || right(p_emp, 4), p_store, v_i, '假原因', p_issued)
  returning id into v_t;
  if p_status = '作廢' then
    update public.spot_tickets set status = '作廢', void_reason = '假作廢', voided_by = 'vr-cs@2motor.tw', voided_at = now() where id = v_t;
  end if;
  return v_t;
end $$;

-- ---------- 建立假資料 ----------
do $$
declare v_x uuid;
begin
  insert into public.stores (code, name) values ('ZZ-Y1', 'ZZ黃單甲店'), ('ZZ-Y2', 'ZZ黃單乙店'), ('ZZ-Y3', 'ZZ黃單丙店');
  -- ZZ-Y1：4 位「已上線」＋ 1 位離職 ＋ 1 位考核期 ＋ 1 位不納入考核（人數應為 4）；ZZ-Y2：2 位；ZZ-Y3：0 位（只有被換店前的黃單）
  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
  values
    ('MI-9701', '假員9701', 'ZZ-Y1', '業務', current_date - 200, '在職', true),
    ('MI-9702', '假員9702', 'ZZ-Y1', '業務', current_date - 200, '在職', true),
    ('MI-9703', '假員9703', 'ZZ-Y1', '業務', current_date - 200, '在職', true),
    ('MI-9704', '假員9704', 'ZZ-Y1', '業務', current_date - 200, '在職', true),
    ('MI-9705', '假員9705', 'ZZ-Y1', '業務', current_date - 200, '離職', true),
    ('MI-9706', '假員9706', 'ZZ-Y1', '業務', current_date - 20,  '在職', true),
    ('MI-9707', '假員9707', 'ZZ-Y1', '業務', current_date - 200, '在職', false),
    ('MI-9708', '假員9708', 'ZZ-Y2', '業務', current_date - 200, '在職', true),
    ('MI-9709', '假員9709', 'ZZ-Y2', '業務', current_date - 200, '在職', true);
  update public.employees set period_status = '考核期' where id = 'MI-9706';
  update public.employees set period_status = '已上線'
    where id in ('MI-9701','MI-9702','MI-9703','MI-9704','MI-9705','MI-9707','MI-9708','MI-9709');

  insert into public.app_users (email, role, store_code) values
    ('vr-cs@2motor.tw', 'cs_admin', null),
    ('vr-hq@2motor.tw', 'hq_viewer', null),
    ('vr-sm@2motor.tw', 'store_manager', 'ZZ-Y1');

  -- 黃單（日期以 2026 年為例）
  -- ZZ-Y1：Q1 有 3 張有效（3/31 邊界一張）＋1 張作廢；Q2 有 1 張（4/1 邊界）
  v_x := pg_temp.vr_yellow('MI-9701', 'ZZ-Y1', date '2026-01-01');
  v_x := pg_temp.vr_yellow('MI-9702', 'ZZ-Y1', date '2026-02-15');
  v_x := pg_temp.vr_yellow('MI-9702', 'ZZ-Y1', date '2026-03-31');
  v_x := pg_temp.vr_yellow('MI-9703', 'ZZ-Y1', date '2026-02-20', '作廢');
  v_x := pg_temp.vr_yellow('MI-9704', 'ZZ-Y1', date '2026-04-01');
  -- ZZ-Y2：Q1 2 張
  v_x := pg_temp.vr_yellow('MI-9708', 'ZZ-Y2', date '2026-01-10');
  v_x := pg_temp.vr_yellow('MI-9709', 'ZZ-Y2', date '2026-03-05');
  -- 換店：MI-9709 開單後調到 ZZ-Y1；舊單仍歸 ZZ-Y2（單上的門市是開單當時的快照）
  update public.employees set store_code = 'ZZ-Y1' where id = 'MI-9709';
  -- 換店後的新單歸 ZZ-Y1
  v_x := pg_temp.vr_yellow('MI-9709', 'ZZ-Y1', date '2026-05-05');
  -- ZZ-Y3：沒有任何員工，只有 1 張黃單（也要列出）
  v_x := pg_temp.vr_yellow('MI-9701', 'ZZ-Y3', date '2026-06-30');
  -- 一張紅單不得被算進去（直接寫入，來源黃單為隨便一張）
  insert into public.spot_tickets (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on)
  values ('紅', 'MI-9701', '假員9701', 'ZZ-Y2', array[gen_random_uuid()], '假紅單', date '2026-02-01');
exception when others then
  insert into pg_temp.vr (grp, name, expected, actual, pass) values ('建立假資料', '建立假資料意外中斷（可能真實資料撞名）', '無例外', sqlerrm, false);
end
$$;

-- ---------- 驗證 ----------
do $$
declare
  cs text := 'vr-cs@2motor.tw';
begin
  -- 1. 數量：Q1 / Q2 / 全年
  perform pg_temp.vr_eq('數量', 'Q1：甲店3張/5人、乙店2張/1人（MI-9709 已換到甲店，現況人數乙店只剩1人）、丙店無單不列',
    'ZZ-Y1=3/5,ZZ-Y2=2/1', pg_temp.vr_rank('authenticated', cs, date '2026-01-01', date '2026-03-31'));
  perform pg_temp.vr_eq('數量', 'Q2：甲店黃單 2 張（4/1 與 5/5）、丙店 1 張（6/30）、乙店只有人數',
    'ZZ-Y1=2/5,ZZ-Y2=0/1,ZZ-Y3=1/0', pg_temp.vr_rank('authenticated', cs, date '2026-04-01', date '2026-06-30'));
  perform pg_temp.vr_eq('數量', '全年：甲店5張、乙店2張、丙店1張',
    'ZZ-Y1=5/5,ZZ-Y2=2/1,ZZ-Y3=1/0', pg_temp.vr_rank('authenticated', cs, date '2026-01-01', date '2026-12-31'));
  -- 2. 日期邊界
  perform pg_temp.vr_eq('邊界', '3/31 當天算 Q1、4/1 當天算 Q2：只查 3/31 → 甲店 1 張',
    'ZZ-Y1=1/5,ZZ-Y2=0/1', pg_temp.vr_rank('authenticated', cs, date '2026-03-31', date '2026-03-31'));
  perform pg_temp.vr_eq('邊界', '只查 4/1 → 甲店 1 張', 'ZZ-Y1=1/5,ZZ-Y2=0/1', pg_temp.vr_rank('authenticated', cs, date '2026-04-01', date '2026-04-01'));
  perform pg_temp.vr_eq('邊界', '沒有任何黃單的期間：只列有人數的門市（張數 0）',
    'ZZ-Y1=0/5,ZZ-Y2=0/1', pg_temp.vr_rank('authenticated', cs, date '2025-01-01', date '2025-03-31'));
  -- 3. 作廢不算、紅單不算
  perform pg_temp.vr_eq('規則', '作廢的黃單與紅單都不算（Q1 乙店只有 2 張有效黃單）',
    '2', pg_temp.vr_as('authenticated', cs, $q$select tickets::text from public.checkup_yellow_ranking(date '2026-01-01', date '2026-03-31') where store_code = 'ZZ-Y2'$q$));
  -- 4. 人數
  perform pg_temp.vr_eq('人數', '甲店人數：在職＋納入考核＋已上線＝5（MI-9701～9704 加換店來的 MI-9709；離職、考核期、不納入考核都不算）',
    '5', pg_temp.vr_as('authenticated', cs, $q$select headcount::text from public.checkup_yellow_ranking(date '2026-01-01', date '2026-12-31') where store_code = 'ZZ-Y1'$q$));
  -- 5. 依開單當時門市（員工 MI-9709 現在屬甲店，但 3/5 那張單仍歸乙店）
  perform pg_temp.vr_eq('換店', '換店前的舊單仍歸乙店、換店後的新單歸甲店',
    '乙店Q1=2、甲店Q2含5/5那張=2',
    '乙店Q1=' || pg_temp.vr_as('authenticated', cs, $q$select tickets::text from public.checkup_yellow_ranking(date '2026-01-01', date '2026-03-31') where store_code = 'ZZ-Y2'$q$)
    || '、甲店Q2含5/5那張=' || pg_temp.vr_as('authenticated', cs, $q$select tickets::text from public.checkup_yellow_ranking(date '2026-04-01', date '2026-06-30') where store_code = 'ZZ-Y1'$q$));
  -- 6. 總公司排除
  perform pg_temp.vr_eq('規則', '結果裡沒有「總公司」',
    '0', pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_yellow_ranking(date '2026-01-01', date '2026-12-31') where store_code = '總公司'$q$));
  -- 7. 角色：三種角色都看得到全部門市（店長也是）
  perform pg_temp.vr_eq('角色', '總公司主管看到全部門市', 'ZZ-Y1=5/5,ZZ-Y2=2/1,ZZ-Y3=1/0',
    pg_temp.vr_rank('authenticated', 'vr-hq@2motor.tw', date '2026-01-01', date '2026-12-31'));
  perform pg_temp.vr_eq('角色', '店長（甲店）也看到全部門市（含乙店、丙店）', 'ZZ-Y1=5/5,ZZ-Y2=2/1,ZZ-Y3=1/0',
    pg_temp.vr_rank('authenticated', 'vr-sm@2motor.tw', date '2026-01-01', date '2026-12-31'));
  -- 8. 只有四欄彙總（沒有黃單內容、人員）
  perform pg_temp.vr_eq('欄位', '回傳只有四個欄位：store_code、store_name、tickets、headcount',
    'TABLE(store_code text, store_name text, tickets integer, headcount integer)',
    pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw',
      $q$select pg_get_function_result('public.checkup_yellow_ranking(date, date)'::regprocedure)$q$));
  -- 9. 店長不能直接讀別店的黃單（RLS 原樣）：只看得到自己門市的單
  perform pg_temp.vr_eq('RLS', '店長直接讀 spot_tickets 仍只看得到自己門市（乙店、丙店的單讀不到）',
    '0', pg_temp.vr_as('authenticated', 'vr-sm@2motor.tw', $q$select count(*)::text from public.spot_tickets where store_code in ('ZZ-Y2', 'ZZ-Y3')$q$));
  -- 10. 被拒
  perform pg_temp.vr_eq('權限', '有登入但沒開通帳號被拒', 'ERROR: 沒有權限',
    pg_temp.vr_as('authenticated', 'vr-nobody@2motor.tw', $q$select count(*)::text from public.checkup_yellow_ranking(date '2026-01-01', date '2026-12-31')$q$));
  perform pg_temp.vr_eq('權限', '未登入（anon）被拒', 'ERROR: permission denied for function checkup_yellow_ranking',
    pg_temp.vr_as('anon', null, $q$select count(*)::text from public.checkup_yellow_ranking(date '2026-01-01', date '2026-12-31')$q$));
  -- 11. 日期範圍不合法
  perform pg_temp.vr_eq('參數', '起日大於迄日被擋', 'ERROR: 日期範圍不正確',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_yellow_ranking(date '2026-12-31', date '2026-01-01')$q$));
  perform pg_temp.vr_eq('參數', '空日期被擋', 'ERROR: 日期範圍不正確',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_yellow_ranking(null, date '2026-01-01')$q$));
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
  begin execute 'deallocate yellow_ranking_vr_out'; exception when others then null; end;
  execute 'prepare yellow_ranking_vr_out as select * from (values (0, '
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

execute yellow_ranking_vr_out;
