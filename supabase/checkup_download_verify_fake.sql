-- ============================================================
-- 業務考核系統：健檢單下載管制＋下載紀錄 驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 checkup_download_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市 ZZ-D1／ZZ-D2、假員工 MI-9801～MI-9806、假帳號（vd-xxx@2motor.tw），
--   用 set local role ＋ request.jwt.claims 模擬各角色登入，呼叫 checkup_log_download 等函式，
--   把每項斷言記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：最後一個結果＝「序號／測項／預期／實際／通過」表，第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算成功。
-- 驗證重點：店長未開放被拒（季度、年度、Q4 跨年）、開放後可記、他店店長不能記他店、客服部與主管不受日期限制、
--   客服部可讀彙總與明細、店長／主管／未開通／未登入不能讀、資料表網頁角色不能直接讀寫、只增不改（update／delete／truncate 全擋）、
--   季度與年度分開記、參數檢查、下載人顯示名規則、開放日期邊界（含當日、Q4 跨年）。
-- 日期用「今天（台北）的年份」動態算：已開放的情境用 年份-2（最晚隔年 1/10 就開放），未開放的情境用 年份+1。
-- 假門市代碼 ZZ-D1／ZZ-D2、假員工編號 MI-9801～MI-9806、假信箱 vd-*@2motor.tw 若撞到真實資料，
--   腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 「只增不改」三項要用資料庫擁有者（postgres）身分直接動資料表；在 SQL Editor 執行時就是 postgres。
-- ============================================================

begin;
set local lock_timeout = '5s';

do $$
begin
  if to_regprocedure('public.checkup_log_download(text, text, text, int, int, text, text, int)') is null then
    raise exception '請先執行 checkup_download_schema.sql';
  end if;
end
$$;

create temp table vd (
  n int generated always as identity primary key,
  grp text, name text, expected text, actual text, pass boolean
);

create or replace function pg_temp.vd_eq(p_grp text, p_name text, p_expected text, p_actual text)
returns void language plpgsql as $$
begin
  insert into pg_temp.vd (grp, name, expected, actual, pass)
  values (p_grp, p_name, p_expected, coalesce(p_actual, '(null)'), p_expected is not distinct from p_actual);
end $$;

-- 以指定資料庫角色＋email 執行單一值查詢；失敗回 'ERROR: 訊息'；p_email 為 null＝沒有登入者
create or replace function pg_temp.vd_as(p_role text, p_email text, p_sql text)
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

-- 呼叫 checkup_log_download（authenticated 身分）；成功回 'OK'，失敗回 'ERROR: 訊息'
-- p_args 是參數文字，例如 $$'ZZ-D1','單人下載','季度',2024,1,'MI-9802','小王'$$
create or replace function pg_temp.vd_log(p_email text, p_args text)
returns text language plpgsql as $$
declare v text;
begin
  v := pg_temp.vd_as('authenticated', p_email, 'select public.checkup_log_download(' || p_args || ')::text');
  return case when v like 'ERROR:%' then v else 'OK' end;
end $$;

-- 以擁有者身分（不模擬角色）查單一值
create or replace function pg_temp.vd_q(p_sql text)
returns text language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, '(null)');
end $$;

-- 以擁有者身分執行會失敗的語句；回 'ERROR: 訊息' 或 'OK'
create or replace function pg_temp.vd_try(p_sql text)
returns text language plpgsql as $$
begin
  begin
    execute p_sql;
    return 'OK';
  exception when others then
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

-- ---------- 建立假資料 ----------
do $$
begin
  insert into public.stores (code, name) values ('ZZ-D1', 'ZZ下載甲店'), ('ZZ-D2', 'ZZ下載乙店');
  insert into public.employees (id, nickname, full_name, store_code, job_title, hire_date, status, include_in_assessment)
  values
    ('MI-9801', '阿甲', '甲甲甲',  'ZZ-D1', '店長', current_date - 400, '在職', false),
    ('MI-9802', '小王', '王小明',  'ZZ-D1', '業務', current_date - 400, '在職', true),
    ('MI-9803', null,   '王二',    'ZZ-D2', '店長', current_date - 400, '在職', false),
    ('MI-9804', '客服小美', null,  'ZZ-D1', '客服', current_date - 400, '在職', false),
    ('MI-9805', '主管阿強', null,  'ZZ-D1', '主管', current_date - 400, '在職', false),
    ('MI-9806', '小李', '李小華',  'ZZ-D2', '業務', current_date - 400, '在職', true);
  insert into public.app_users (email, role, store_code, employee_id) values
    ('vd-cs@2motor.tw',  'cs_admin',      null,    'MI-9804'),
    ('vd-hq@2motor.tw',  'hq_viewer',     null,    'MI-9805'),
    ('vd-sm1@2motor.tw', 'store_manager', 'ZZ-D1', 'MI-9801'),
    ('vd-sm2@2motor.tw', 'store_manager', 'ZZ-D2', 'MI-9803'),
    ('vd-sm3@2motor.tw', 'store_manager', 'ZZ-D2', null);
exception when others then
  insert into pg_temp.vd (grp, name, expected, actual, pass) values ('建立假資料', '建立假資料意外中斷（可能真實資料撞名）', '無例外', sqlerrm, false);
end
$$;

-- ---------- 驗證 ----------
do $$
declare
  y int := extract(year from (now() at time zone 'Asia/Taipei'))::int;   -- 今天（台北）的年份
  yo int := y - 2;   -- 已開放情境的年份
  yf int := y + 1;   -- 未開放情境的年份
  sm1 text := 'vd-sm1@2motor.tw';
  cs  text := 'vd-cs@2motor.tw';
  hq  text := 'vd-hq@2motor.tw';
begin
  -- 1. 店長未開放被拒（錯誤訊息帶開放日）
  perform pg_temp.vd_eq('未開放', '店長 Q1 未到 4/10（明年 Q1）單人下載被拒', 'ERROR: 這份健檢單 4/10 起開放下載',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','單人下載','季度',%s,1,'MI-9802','小王'$a$, yf)));
  perform pg_temp.vd_eq('未開放', '店長 Q2 未到 7/10 一鍵下載被拒', 'ERROR: 這份健檢單 7/10 起開放下載',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','一鍵下載','季度',%s,2,null,null,3$a$, yf)));
  perform pg_temp.vd_eq('未開放', '店長 Q3 未到 10/10 被拒', 'ERROR: 這份健檢單 10/10 起開放下載',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','一鍵下載','季度',%s,3,null,null,3$a$, yf)));
  perform pg_temp.vd_eq('未開放', '店長 Q4 季度（今年）要等明年 1/10，被拒', 'ERROR: 這份健檢單 1/10 起開放下載',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','單人下載','季度',%s,4,'MI-9802','小王'$a$, y)));
  perform pg_temp.vd_eq('未開放', '店長年度健檢單（今年）要等明年 1/10，被拒', 'ERROR: 這份健檢單 1/10 起開放下載',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','一鍵下載','年度',%s,4,null,null,3$a$, y)));
  perform pg_temp.vd_eq('未開放', '被拒的都沒有留下紀錄', '0',
    pg_temp.vd_q($q$select count(*)::text from public.checkup_download_log where store_code like 'ZZ-D%'$q$));

  -- 2. 店長開放後可記（已開放：yo 年的 Q1～Q4 與年度）
  perform pg_temp.vd_eq('開放後', '店長 Q1 單人下載可記', 'OK',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','單人下載','季度',%s,1,'MI-9802','小王'$a$, yo)));
  perform pg_temp.vd_eq('開放後', '店長 Q4 一鍵下載（季度）可記', 'OK',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','一鍵下載','季度',%s,4,null,null,4$a$, yo)));
  perform pg_temp.vd_eq('開放後', '店長一鍵下載（年度）可記', 'OK',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','一鍵下載','年度',%s,4,null,null,4$a$, yo)));
  perform pg_temp.vd_eq('開放後', '店長單人下載（年度）可記', 'OK',
    pg_temp.vd_log(sm1, format($a$'ZZ-D1','單人下載','年度',%s,4,'MI-9802','小王'$a$, yo)));
  perform pg_temp.vd_eq('欄位', '單人下載：員編、姓名、人數欄位正確',
    'MI-9802|小王|(null)|單人下載|季度|1',
    pg_temp.vd_q(format($q$select employee_id || '|' || employee_name || '|' || coalesce(people_count::text, '(null)') || '|' || method || '|' || kind || '|' || quarter
                           from public.checkup_download_log where store_code = 'ZZ-D1' and method = '單人下載' and kind = '季度' and year = %s$q$, yo)));
  perform pg_temp.vd_eq('欄位', '一鍵下載：人數 4、沒有員編姓名',
    '4|(null)|(null)',
    pg_temp.vd_q(format($q$select people_count || '|' || coalesce(employee_id, '(null)') || '|' || coalesce(employee_name, '(null)')
                           from public.checkup_download_log where store_code = 'ZZ-D1' and method = '一鍵下載' and kind = '季度' and year = %s$q$, yo)));
  perform pg_temp.vd_eq('欄位', '時間是現在、信箱記小寫', 'vd-sm1@2motor.tw|true',
    pg_temp.vd_q($q$select by_email || '|' || (abs(extract(epoch from now() - downloaded_at)) < 60)::text
                      from public.checkup_download_log where store_code = 'ZZ-D1' and method = '單人下載' and kind = '季度' limit 1$q$));

  -- 3. 他店店長不能記他店
  perform pg_temp.vd_eq('門市', '甲店店長記乙店（即使已開放）被拒', 'ERROR: 只能下載自己門市的健檢單',
    pg_temp.vd_log(sm1, format($a$'ZZ-D2','一鍵下載','季度',%s,1,null,null,2$a$, yo)));
  perform pg_temp.vd_eq('門市', '乙店店長記甲店被拒', 'ERROR: 只能下載自己門市的健檢單',
    pg_temp.vd_log('vd-sm2@2motor.tw', format($a$'ZZ-D1','單人下載','季度',%s,1,'MI-9802','小王'$a$, yo)));
  perform pg_temp.vd_eq('門市', '乙店店長記自己店可以', 'OK',
    pg_temp.vd_log('vd-sm2@2motor.tw', format($a$'ZZ-D2','單人下載','季度',%s,1,'MI-9806','小李'$a$, yo)));

  -- 4. 客服部、主管不受日期限制，可記任何門市
  perform pg_temp.vd_eq('客服', '客服部記明年 Q1（店長會被拒的日期）可以', 'OK',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','一鍵下載','季度',%s,1,null,null,5$a$, yf)));
  perform pg_temp.vd_eq('客服', '客服部記今年年度（店長會被拒）可以', 'OK',
    pg_temp.vd_log(cs, format($a$'ZZ-D2','一鍵下載','年度',%s,4,null,null,2$a$, y)));
  perform pg_temp.vd_eq('客服', '客服部單人下載他店人員可以', 'OK',
    pg_temp.vd_log(cs, format($a$'ZZ-D2','單人下載','季度',%s,3,'MI-9806','小李'$a$, y)));
  perform pg_temp.vd_eq('主管', '總公司主管比照客服部不受日期限制', 'OK',
    pg_temp.vd_log(hq, format($a$'ZZ-D1','單人下載','年度',%s,4,'MI-9802','小王'$a$, y)));

  -- 5. 下載人顯示名
  perform pg_temp.vd_eq('顯示名', '店長：門市名-暱稱', 'ZZ下載甲店-阿甲',
    pg_temp.vd_q($q$select by_name from public.checkup_download_log where by_email = 'vd-sm1@2motor.tw' limit 1$q$));
  perform pg_temp.vd_eq('顯示名', '客服部：總公司-名字', '總公司-客服小美',
    pg_temp.vd_q($q$select by_name from public.checkup_download_log where by_email = 'vd-cs@2motor.tw' limit 1$q$));
  perform pg_temp.vd_eq('顯示名', '主管：總公司-名字', '總公司-主管阿強',
    pg_temp.vd_q($q$select by_name from public.checkup_download_log where by_email = 'vd-hq@2motor.tw' limit 1$q$));
  perform pg_temp.vd_eq('顯示名', '沒有暱稱用姓名', 'ZZ下載乙店-王二',
    pg_temp.vd_q($q$select by_name from public.checkup_download_log where by_email = 'vd-sm2@2motor.tw' limit 1$q$));
  perform pg_temp.vd_eq('顯示名', '找不到人員的店長也能記', 'OK',
    pg_temp.vd_log('vd-sm3@2motor.tw', format($a$'ZZ-D2','一鍵下載','季度',%s,2,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('顯示名', '找不到人員用信箱前綴：門市名-vd-sm3', 'ZZ下載乙店-vd-sm3',
    pg_temp.vd_q($q$select by_name from public.checkup_download_log where by_email = 'vd-sm3@2motor.tw' limit 1$q$));
  perform pg_temp.vd_eq('欄位', '單人下載沒帶姓名時用名冊暱稱補', 'OK',
    pg_temp.vd_log(cs, format($a$'ZZ-D2','單人下載','季度',%s,2,'MI-9806',null$a$, yo)));
  perform pg_temp.vd_eq('欄位', '名冊補上的姓名是「小李」', '小李',
    pg_temp.vd_q(format($q$select employee_name from public.checkup_download_log where employee_id = 'MI-9806' and quarter = 2 and year = %s$q$, yo)));

  -- 6. 季度與年度分開記
  perform pg_temp.vd_eq('分開', '甲店 yo 年：季度 Q4 一鍵與年度一鍵各 1 筆、互相獨立', '1|1',
    pg_temp.vd_q(format($q$select (select count(*) from public.checkup_download_log where store_code = 'ZZ-D1' and method = '一鍵下載' and kind = '季度' and year = %s and quarter = 4)::text
                                || '|' || (select count(*) from public.checkup_download_log where store_code = 'ZZ-D1' and method = '一鍵下載' and kind = '年度' and year = %s)::text$q$, yo, yo)));

  -- 7. 讀取：客服部可讀（此時 ZZ-D1：yo Q1 單人、yo Q4 一鍵、yo 年度一鍵、yo 年度單人、明年Q1 一鍵(客服)、今年年度單人(主管)＝6；ZZ-D2：5）
  perform pg_temp.vd_eq('讀取', '客服部彙總（甲店）：總 6／一鍵 3／單人 3', 'ZZ-D1=6/3/3',
    pg_temp.vd_as('authenticated', cs, $q$select store_code || '=' || total || '/' || bulk || '/' || single from public.checkup_download_summary(null) where store_code = 'ZZ-D1'$q$));
  perform pg_temp.vd_eq('讀取', '客服部彙總（乙店）：總 5／一鍵 2／單人 3', 'ZZ-D2=5/2/3',
    pg_temp.vd_as('authenticated', cs, $q$select store_code || '=' || total || '/' || bulk || '/' || single from public.checkup_download_summary(null) where store_code = 'ZZ-D2'$q$));
  perform pg_temp.vd_eq('讀取', '彙總依方式篩選：只看一鍵（甲店 3 次、單人 0）', 'ZZ-D1=3/3/0',
    pg_temp.vd_as('authenticated', cs, $q$select store_code || '=' || total || '/' || bulk || '/' || single from public.checkup_download_summary('一鍵下載') where store_code = 'ZZ-D1'$q$));
  perform pg_temp.vd_eq('讀取', '彙總的最近一次是現在', 'true',
    pg_temp.vd_as('authenticated', cs, $q$select (abs(extract(epoch from now() - last_at)) < 60)::text from public.checkup_download_summary(null) where store_code = 'ZZ-D1'$q$));
  perform pg_temp.vd_eq('讀取', '彙總沒有「總公司」', '0',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_summary(null) where store_code = '總公司'$q$));
  perform pg_temp.vd_eq('讀取', '彙總回傳欄位', 'TABLE(store_code text, store_name text, total integer, bulk integer, single integer, last_at timestamp with time zone)',
    pg_temp.vd_as('authenticated', cs, $q$select pg_get_function_result('public.checkup_download_summary(text)'::regprocedure)$q$));
  perform pg_temp.vd_eq('讀取', '明細：ZZ 門市共 11 筆', '11',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_list(null, null, 500) where store_code like 'ZZ-D%'$q$));
  perform pg_temp.vd_eq('讀取', '明細依門市篩選（乙店 5 筆）', '5',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_list('ZZ-D2', null, 500)$q$));
  perform pg_temp.vd_eq('讀取', '明細依門市＋方式篩選（甲店單人 3 筆）', '3',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_list('ZZ-D1', '單人下載', 500)$q$));
  perform pg_temp.vd_eq('讀取', '明細新到舊排序（id 遞減）', 'true',
    pg_temp.vd_as('authenticated', cs, $q$select coalesce(bool_and(id < prev_id), true)::text
        from (select id, lag(id) over () as prev_id from public.checkup_download_list(null, null, 500) where store_code like 'ZZ-D%') x
        where prev_id is not null$q$));
  perform pg_temp.vd_eq('讀取', '明細筆數上限 p_limit 有效', '2',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_list('ZZ-D1', null, 2)$q$));
  perform pg_temp.vd_eq('讀取', '明細含下載人顯示名與方式、種類', '總公司-客服小美|一鍵下載|季度',
    pg_temp.vd_as('authenticated', cs, $q$select by_name || '|' || method || '|' || kind from public.checkup_download_list('ZZ-D1', '一鍵下載', 500) where by_email = 'vd-cs@2motor.tw'$q$));
  perform pg_temp.vd_eq('讀取', '彙總方式不合法被擋', 'ERROR: 下載方式不正確',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_summary('亂填')$q$));
  perform pg_temp.vd_eq('讀取', '明細方式不合法被擋', 'ERROR: 下載方式不正確',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_list(null, '亂填', 10)$q$));

  -- 8. 讀取：其他角色一律沒有權限
  perform pg_temp.vd_eq('權限', '店長讀彙總被拒', 'ERROR: 沒有權限',
    pg_temp.vd_as('authenticated', sm1, $q$select count(*)::text from public.checkup_download_summary(null)$q$));
  perform pg_temp.vd_eq('權限', '店長讀明細被拒', 'ERROR: 沒有權限',
    pg_temp.vd_as('authenticated', sm1, $q$select count(*)::text from public.checkup_download_list(null, null, 10)$q$));
  perform pg_temp.vd_eq('權限', '總公司主管讀彙總被拒', 'ERROR: 沒有權限',
    pg_temp.vd_as('authenticated', hq, $q$select count(*)::text from public.checkup_download_summary(null)$q$));
  perform pg_temp.vd_eq('權限', '總公司主管讀明細被拒', 'ERROR: 沒有權限',
    pg_temp.vd_as('authenticated', hq, $q$select count(*)::text from public.checkup_download_list(null, null, 10)$q$));
  perform pg_temp.vd_eq('權限', '沒開通帳號讀明細被拒', 'ERROR: 沒有權限',
    pg_temp.vd_as('authenticated', 'vd-nobody@2motor.tw', $q$select count(*)::text from public.checkup_download_list(null, null, 10)$q$));
  perform pg_temp.vd_eq('權限', '沒開通帳號寫入被拒', 'ERROR: 沒有權限',
    pg_temp.vd_log('vd-nobody@2motor.tw', format($a$'ZZ-D1','一鍵下載','季度',%s,1,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('權限', '未登入（anon）讀明細被拒', 'ERROR: permission denied for function checkup_download_list',
    pg_temp.vd_as('anon', null, $q$select count(*)::text from public.checkup_download_list(null, null, 10)$q$));
  perform pg_temp.vd_eq('權限', '未登入（anon）寫入被拒', 'ERROR: permission denied for function checkup_log_download',
    pg_temp.vd_as('anon', null, format($q$select public.checkup_log_download('ZZ-D1','一鍵下載','季度',%s,1,null,null,1)::text$q$, yo)));
  perform pg_temp.vd_eq('權限', '店長直接讀資料表被擋', 'ERROR: permission denied for table checkup_download_log',
    pg_temp.vd_as('authenticated', sm1, $q$select count(*)::text from public.checkup_download_log$q$));
  perform pg_temp.vd_eq('權限', '客服部直接讀資料表也被擋（只能走函式）', 'ERROR: permission denied for table checkup_download_log',
    pg_temp.vd_as('authenticated', cs, $q$select count(*)::text from public.checkup_download_log$q$));
  perform pg_temp.vd_eq('權限', '店長直接 insert 被擋', 'ERROR: permission denied for table checkup_download_log',
    pg_temp.vd_as('authenticated', sm1, $q$insert into public.checkup_download_log (store_code, by_email, by_name, method, kind, year, quarter, people_count) values ('ZZ-D1','x','x','一鍵下載','季度',2020,1,1)$q$));
  perform pg_temp.vd_eq('權限', '客服部直接 update 被擋', 'ERROR: permission denied for table checkup_download_log',
    pg_temp.vd_as('authenticated', cs, $q$update public.checkup_download_log set by_name = 'x'$q$));
  perform pg_temp.vd_eq('權限', '內部函式 is_open 網頁角色不能呼叫', 'ERROR: permission denied for function checkup_download_is_open',
    pg_temp.vd_as('authenticated', sm1, $q$select public.checkup_download_is_open(2020, 1, '季度')::text$q$));

  -- 9. 只增不改（連擁有者直接動也擋）
  perform pg_temp.vd_eq('只增不改', 'update 被擋', 'ERROR: 下載紀錄只增不改',
    pg_temp.vd_try($q$update public.checkup_download_log set by_name = 'x' where store_code like 'ZZ-D%'$q$));
  perform pg_temp.vd_eq('只增不改', 'delete 被擋', 'ERROR: 下載紀錄只增不改',
    pg_temp.vd_try($q$delete from public.checkup_download_log where store_code like 'ZZ-D%'$q$));
  perform pg_temp.vd_eq('只增不改', 'truncate 被擋', 'ERROR: 下載紀錄只增不改',
    pg_temp.vd_try($q$truncate public.checkup_download_log$q$));
  perform pg_temp.vd_eq('只增不改', '被擋之後紀錄筆數不變', '11',
    pg_temp.vd_q($q$select count(*)::text from public.checkup_download_log where store_code like 'ZZ-D%'$q$));

  -- 10. 參數檢查
  perform pg_temp.vd_eq('參數', '年度健檢單季次不是 4 被拒', 'ERROR: 年度健檢單的季次必須是第 4 季',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','一鍵下載','年度',%s,2,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('參數', '方式不合法被拒', 'ERROR: 下載方式不正確',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','亂填','季度',%s,1,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('參數', '種類不合法被拒', 'ERROR: 下載種類不正確',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','一鍵下載','半年',%s,1,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('參數', '季次 5 被拒', 'ERROR: 年度或季次不正確',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','一鍵下載','季度',%s,5,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('參數', '門市不存在被拒', 'ERROR: 門市不存在',
    pg_temp.vd_log(cs, format($a$'ZZ-NONE','一鍵下載','季度',%s,1,null,null,1$a$, yo)));
  perform pg_temp.vd_eq('參數', '單人下載沒帶員編被拒', 'ERROR: 單人下載必須帶人員編號',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','單人下載','季度',%s,1,null,'小王'$a$, yo)));
  perform pg_temp.vd_eq('參數', '一鍵下載沒帶人數被拒', 'ERROR: 一鍵下載必須帶打包人數',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','一鍵下載','季度',%s,1,null,null,null$a$, yo)));
  perform pg_temp.vd_eq('參數', '一鍵下載人數為負被拒', 'ERROR: 一鍵下載必須帶打包人數',
    pg_temp.vd_log(cs, format($a$'ZZ-D1','一鍵下載','季度',%s,1,null,null,-1$a$, yo)));
  perform pg_temp.vd_eq('參數', '年份不合法被拒', 'ERROR: 年度或季次不正確',
    pg_temp.vd_log(cs, $a$'ZZ-D1','一鍵下載','季度',1999,1,null,null,1$a$));
  perform pg_temp.vd_eq('資料表約束', '一鍵下載帶員編（形狀不對）直接寫入被擋', 'ERROR: new row for relation "checkup_download_log" violates check constraint "checkup_download_log_shape"',
    pg_temp.vd_try($q$insert into public.checkup_download_log (store_code, by_email, by_name, method, kind, year, quarter, employee_id, people_count) values ('ZZ-D1','x','x','一鍵下載','季度',2020,1,'MI-9802',1)$q$));
  perform pg_temp.vd_eq('資料表約束', '年度季次不是 4 直接寫入被擋', 'ERROR: new row for relation "checkup_download_log" violates check constraint "checkup_download_log_year_q4"',
    pg_temp.vd_try($q$insert into public.checkup_download_log (store_code, by_email, by_name, method, kind, year, quarter, people_count) values ('ZZ-D1','x','x','一鍵下載','年度',2020,1,1)$q$));

  -- 11. 開放日期邊界（內部函式，傳固定的「今天」；含當日）
  perform pg_temp.vd_eq('邊界', 'Q1 4/9 未開、4/10 開（含當日）', 'false|true',
    pg_temp.vd_q($q$select public.checkup_download_is_open(2026,1,'季度',date '2026-04-09')::text || '|' || public.checkup_download_is_open(2026,1,'季度',date '2026-04-10')::text$q$));
  perform pg_temp.vd_eq('邊界', 'Q2 7/9 未開、7/10 開', 'false|true',
    pg_temp.vd_q($q$select public.checkup_download_is_open(2026,2,'季度',date '2026-07-09')::text || '|' || public.checkup_download_is_open(2026,2,'季度',date '2026-07-10')::text$q$));
  perform pg_temp.vd_eq('邊界', 'Q3 10/9 未開、10/10 開', 'false|true',
    pg_temp.vd_q($q$select public.checkup_download_is_open(2026,3,'季度',date '2026-10-09')::text || '|' || public.checkup_download_is_open(2026,3,'季度',date '2026-10-10')::text$q$));
  perform pg_temp.vd_eq('邊界', 'Q4 季度：當年 12/31 未開（跨年）、隔年 1/9 未開、1/10 開', 'false|false|true',
    pg_temp.vd_q($q$select public.checkup_download_is_open(2026,4,'季度',date '2026-12-31')::text || '|' || public.checkup_download_is_open(2026,4,'季度',date '2027-01-09')::text || '|' || public.checkup_download_is_open(2026,4,'季度',date '2027-01-10')::text$q$));
  perform pg_temp.vd_eq('邊界', '年度：隔年 1/9 未開、1/10 開、不看季次', 'false|true|true',
    pg_temp.vd_q($q$select public.checkup_download_is_open(2026,4,'年度',date '2027-01-09')::text || '|' || public.checkup_download_is_open(2026,4,'年度',date '2027-01-10')::text || '|' || public.checkup_download_is_open(2026,1,'年度',date '2027-01-10')::text$q$));
  perform pg_temp.vd_eq('邊界', '不合法參數一律回未開放', 'false|false|false',
    pg_temp.vd_q($q$select public.checkup_download_is_open(2026,5,'季度',date '2030-01-01')::text || '|' || public.checkup_download_is_open(2026,1,'亂填',date '2030-01-01')::text || '|' || public.checkup_download_is_open(null,1,'季度',date '2030-01-01')::text$q$));
  perform pg_temp.vd_eq('邊界', '開放日期函式：Q1~Q4 與年度', '2026-04-10,2026-07-10,2026-10-10,2027-01-10,2027-01-10',
    pg_temp.vd_q($q$select public.checkup_download_open_date(2026,1,'季度')::text || ',' || public.checkup_download_open_date(2026,2,'季度')::text || ',' || public.checkup_download_open_date(2026,3,'季度')::text || ',' || public.checkup_download_open_date(2026,4,'季度')::text || ',' || public.checkup_download_open_date(2026,2,'年度')::text$q$));
end
$$;

-- ---------- 結果表：先組成「已準備好的查詢」（資料已嵌入），rollback 之後再執行它 ----------
do $$
declare
  v_total int; v_ok int; v_rows text;
begin
  select count(*), count(*) filter (where pass) into v_total, v_ok from pg_temp.vd;
  select string_agg(
           format('(%s, %L, %L, %L, %L)', n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vd;
  begin execute 'deallocate checkup_download_vd_out'; exception when others then null; end;
  execute 'prepare checkup_download_vd_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_ok = v_total then ''
                                   else '；未通過：' || (select string_agg(n::text, '、' order by n) from pg_temp.vd where not pass) end)
          || ', ' || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
end
$$;

-- 備援：rollback 前先顯示一次（若畫面出現兩張一樣的表，看最後一張即可）
select n as "序號", grp || '｜' || name as "測項", expected as "預期", actual as "實際",
       case when pass then '通過' else '失敗' end as "通過"
from pg_temp.vd order by n;

rollback;

execute checkup_download_vd_out;
