-- ============================================================
-- 業務考核系統：各門市面向分析 驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 spotdims_schema.sql 與 store_dim_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-D1～ZZ-D4、假員工 MI-9801～MI-9804、假帳號（vd-xxx@2motor.tw），
--   直接寫入假的抽查登記，用 set local role ＋ request.jwt.claims 模擬各角色登入，呼叫 checkup_store_dims，
--   把每項斷言記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果＝「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算成功。
-- 假門市代碼 ZZ-D1～ZZ-D4、假員工編號 MI-9801～MI-9804、假信箱 vd-cs／vd-hq／vd-sm／vd-nobody@2motor.tw 若撞到真實資料，
--   腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regprocedure('public.checkup_store_dims(date, date)') is null then
    raise exception '請先執行 store_dim_schema.sql';
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

-- 結果壓成一行文字：'代碼=筆數[7個次數以-相連]' 以分號串接（依代碼排序，只看假門市）
create or replace function pg_temp.vr_dims(p_role text, p_email text, p_from date, p_to date)
returns text language plpgsql as $$
begin
  return pg_temp.vr_as(p_role, p_email,
    format($q$select coalesce(string_agg(store_code || '=' || weak_records || '[' || array_to_string(dim_counts, '-') || ']', ';' order by store_code), '(空)')
              from public.checkup_store_dims(%L, %L)
              where store_code like 'ZZ-D%%'$q$, p_from, p_to));
end $$;

-- 一筆假抽查登記
create or replace function pg_temp.vr_insp(p_emp text, p_store text, p_on date, p_verdict text, p_dims text[])
returns void language plpgsql as $$
begin
  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels, total_score, verdict, reason, examiner_email, improve_dims)
  values (p_emp, '假員' || right(p_emp, 4), p_store, p_on, 'https://example.com/x', null, null, p_verdict,
          case when p_verdict = '不適當' then '假原因' else null end, 'vd-cs@2motor.tw', p_dims);
end $$;

-- ---------- 建立假資料 ----------
do $$
begin
  insert into public.stores (code, name) values
    ('ZZ-D1', 'ZZ面向甲店'), ('ZZ-D2', 'ZZ面向乙店'), ('ZZ-D3', 'ZZ面向丙店（無紀錄）'), ('ZZ-D4', 'ZZ面向丁店（無人只有紀錄）');
  insert into public.employees (id, nickname, store_code, job_title, hire_date, status, include_in_assessment)
  values
    ('MI-9801', '假員9801', 'ZZ-D1', '業務', current_date - 200, '在職', true),
    ('MI-9802', '假員9802', 'ZZ-D1', '業務', current_date - 200, '在職', true),
    ('MI-9803', '假員9803', 'ZZ-D2', '業務', current_date - 200, '在職', true),
    ('MI-9804', '假員9804', 'ZZ-D3', '業務', current_date - 200, '在職', true);
  update public.employees set period_status = '已上線' where id in ('MI-9801','MI-9802','MI-9803','MI-9804');

  insert into public.app_users (email, role, store_code) values
    ('vd-cs@2motor.tw', 'cs_admin', null),
    ('vd-hq@2motor.tw', 'hq_viewer', null),
    ('vd-sm@2motor.tw', 'store_manager', 'ZZ-D1');

  -- 甲店
  perform pg_temp.vr_insp('MI-9801', 'ZZ-D1', date '2026-01-01', '不適當', array['資訊正確性','問題掌握']);
  perform pg_temp.vr_insp('MI-9802', 'ZZ-D1', date '2026-03-31', '不適當', array['問題掌握','文字品質']);
  perform pg_temp.vr_insp('MI-9801', 'ZZ-D1', date '2026-02-01', '適當',   array['資訊正確性']);          -- 優良回覆勾面向：不算
  perform pg_temp.vr_insp('MI-9802', 'ZZ-D1', date '2026-02-02', '不適當', '{}'::text[]);                 -- 沒勾面向：不算
  perform pg_temp.vr_insp('MI-9801', 'ZZ-D1', date '2026-04-01', '不適當', array['語氣與禮貌']);
  -- 乙店：七個面向全勾
  perform pg_temp.vr_insp('MI-9803', 'ZZ-D2', date '2026-01-10', '不適當',
    array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識','語氣與禮貌','文字品質']);
  -- 丁店：沒有任何員工，只有 1 筆紀錄（也要列出）
  perform pg_temp.vr_insp('MI-9803', 'ZZ-D4', date '2026-06-30', '不適當', array['風險意識']);
exception when others then
  insert into pg_temp.vr (grp, name, expected, actual, pass) values ('建立假資料', '建立假資料意外中斷（可能真實資料撞名）', '無例外', sqlerrm, false);
end
$$;

-- ---------- 驗證 ----------
do $$
declare
  cs text := 'vd-cs@2motor.tw';
  q1 text := 'ZZ-D1=2[1-0-2-0-0-0-1];ZZ-D2=1[1-1-1-1-1-1-1];ZZ-D3=0[0-0-0-0-0-0-0]';
  yr text := 'ZZ-D1=3[1-0-2-0-0-1-1];ZZ-D2=1[1-1-1-1-1-1-1];ZZ-D3=0[0-0-0-0-0-0-0];ZZ-D4=1[0-0-0-0-1-0-0]';
begin
  -- 1. 三種角色皆可呼叫（結果相同＝店長也看全部門市）
  perform pg_temp.vr_eq('角色', '客服部可呼叫', yr, pg_temp.vr_dims('authenticated', cs, date '2026-01-01', date '2026-12-31'));
  perform pg_temp.vr_eq('角色', '總公司主管可呼叫', yr, pg_temp.vr_dims('authenticated', 'vd-hq@2motor.tw', date '2026-01-01', date '2026-12-31'));
  perform pg_temp.vr_eq('角色', '店長（甲店）也看到全部門市', yr, pg_temp.vr_dims('authenticated', 'vd-sm@2motor.tw', date '2026-01-01', date '2026-12-31'));
  -- 2. 非授權角色被擋
  perform pg_temp.vr_eq('權限', '有登入但沒開通帳號被拒', 'ERROR: 沒有權限',
    pg_temp.vr_as('authenticated', 'vd-nobody@2motor.tw', $q$select count(*)::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31')$q$));
  perform pg_temp.vr_eq('權限', '未登入（anon）被拒', 'ERROR: permission denied for function checkup_store_dims',
    pg_temp.vr_as('anon', null, $q$select count(*)::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31')$q$));
  -- 3. 只算待加強回覆、且至少勾 1 面向
  perform pg_temp.vr_eq('規則', 'Q1 甲店只有 2 筆（優良回覆勾面向、沒勾面向的待加強回覆都不算）', q1,
    pg_temp.vr_dims('authenticated', cs, date '2026-01-01', date '2026-03-31'));
  perform pg_temp.vr_eq('規則', '只查 2/1～2/2（只有優良回覆與沒勾面向）→ 甲店 0 筆全 0',
    'ZZ-D1=0[0-0-0-0-0-0-0];ZZ-D2=0[0-0-0-0-0-0-0];ZZ-D3=0[0-0-0-0-0-0-0]',
    pg_temp.vr_dims('authenticated', cs, date '2026-02-01', date '2026-02-02'));
  -- 4. 日期邊界含頭尾
  perform pg_temp.vr_eq('邊界', '只查 3/31 當天（含）→ 甲店 1 筆',
    'ZZ-D1=1[0-0-1-0-0-0-1];ZZ-D2=0[0-0-0-0-0-0-0];ZZ-D3=0[0-0-0-0-0-0-0]',
    pg_temp.vr_dims('authenticated', cs, date '2026-03-31', date '2026-03-31'));
  perform pg_temp.vr_eq('邊界', '只查 1/1 當天（含）→ 甲店 1 筆',
    'ZZ-D1=1[1-0-1-0-0-0-0];ZZ-D2=0[0-0-0-0-0-0-0];ZZ-D3=0[0-0-0-0-0-0-0]',
    pg_temp.vr_dims('authenticated', cs, date '2026-01-01', date '2026-01-01'));
  perform pg_temp.vr_eq('邊界', '只查 4/1 當天（含）→ 甲店 1 筆（語氣與禮貌）',
    'ZZ-D1=1[0-0-0-0-0-1-0];ZZ-D2=0[0-0-0-0-0-0-0];ZZ-D3=0[0-0-0-0-0-0-0]',
    pg_temp.vr_dims('authenticated', cs, date '2026-04-01', date '2026-04-01'));
  -- 5. 沒紀錄門市：有人的門市 0 筆、dim_counts 長度 7；沒人也沒紀錄的不列
  perform pg_temp.vr_eq('門市', '丙店（有人、無紀錄）出現且 weak_records=0',
    '0', pg_temp.vr_as('authenticated', cs, $q$select weak_records::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code = 'ZZ-D3'$q$));
  perform pg_temp.vr_eq('門市', '丙店 dim_counts 長度為 7',
    '7', pg_temp.vr_as('authenticated', cs, $q$select cardinality(dim_counts)::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code = 'ZZ-D3'$q$));
  perform pg_temp.vr_eq('門市', '所有門市的 dim_counts 長度都是 7（不符合者數量）',
    '0', pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where cardinality(dim_counts) <> 7$q$));
  perform pg_temp.vr_eq('門市', '丁店（無人、無紀錄的期間）不列出；Q1 只列甲乙丙', q1,
    pg_temp.vr_dims('authenticated', cs, date '2026-01-01', date '2026-03-31'));
  perform pg_temp.vr_eq('門市', '結果裡沒有「總公司」',
    '0', pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code = '總公司'$q$));
  -- 6. 跨門市彙總與順序
  perform pg_temp.vr_eq('彙總', '全年跨門市 weak_records 合計＝5（甲3＋乙1＋丁1）',
    '5', pg_temp.vr_as('authenticated', cs, $q$select sum(weak_records)::text from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code like 'ZZ-D%'$q$));
  perform pg_temp.vr_eq('彙總', '全年跨門市七面向被勾總次數＝2,1,3,1,2,2,2（甲 1,0,2,0,0,1,1＋乙全 1＋丁風險意識）',
    '2,1,3,1,2,2,2'::text,
    pg_temp.vr_as('authenticated', cs, $q$select string_agg(s::text, ',' order by i)
      from (select i, sum(dim_counts[i]) as s from public.checkup_store_dims(date '2026-01-01', date '2026-12-31'),
            generate_series(1, 7) as i where store_code like 'ZZ-D%' group by i) z$q$));
  perform pg_temp.vr_eq('順序', '乙店七面向各勾 1 次，丁店只勾第 5 個（風險意識）→ 順序為 資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識、語氣與禮貌、文字品質',
    '[1-1-1-1-1-1-1]|[0-0-0-0-1-0-0]|[1-0-2-0-0-1-1]',
    pg_temp.vr_as('authenticated', cs, $q$select
      (select '[' || array_to_string(dim_counts, '-') || ']' from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code = 'ZZ-D2') || '|' ||
      (select '[' || array_to_string(dim_counts, '-') || ']' from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code = 'ZZ-D4') || '|' ||
      (select '[' || array_to_string(dim_counts, '-') || ']' from public.checkup_store_dims(date '2026-01-01', date '2026-12-31') where store_code = 'ZZ-D1')$q$));
  -- 7. 欄位：不含姓名、內容
  perform pg_temp.vr_eq('欄位', '回傳只有四個欄位：store_code、store_name、weak_records、dim_counts',
    'TABLE(store_code text, store_name text, weak_records integer, dim_counts integer[])',
    pg_temp.vr_as('authenticated', 'vd-sm@2motor.tw',
      $q$select pg_get_function_result('public.checkup_store_dims(date, date)'::regprocedure)$q$));
  -- 8. 參數
  perform pg_temp.vr_eq('參數', '起日大於迄日被擋', 'ERROR: 日期範圍不正確',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_store_dims(date '2026-12-31', date '2026-01-01')$q$));
  perform pg_temp.vr_eq('參數', '空日期被擋', 'ERROR: 日期範圍不正確',
    pg_temp.vr_as('authenticated', cs, $q$select count(*)::text from public.checkup_store_dims(null, date '2026-01-01')$q$));
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
  begin execute 'deallocate store_dim_vr_out'; exception when others then null; end;
  execute 'prepare store_dim_vr_out as select * from (values (0, '
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

execute store_dim_vr_out;
