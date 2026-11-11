-- ============================================================
-- 業務考核系統：LINE 權限與新類別（技師、公務機）驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 roster_schema.sql、roster_line_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（員工編號 MI-9901～、OF-9901、PT-9951，
--   門市代碼 ZL-A／ZL-B，信箱 vr-line-xxx@2motor.tw，皆明顯是測試用、非任何真人），
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。不會碰任何真實資料。
--   注意：員工編號放寬測試用 OF-9901；若真實資料剛好撞到這些假編號，腳本會在建立假資料時報錯停下。
-- 怎麼看結果：
--   * SQL Editor 只顯示「最後一個」結果，rollback 本身沒有結果，
--     所以腳本在 rollback 之前把結果表存成「預備陳述式 line_vr_out」（連線層級，不受 rollback 影響，
--     裡面只有結果文字），rollback 之後再 execute 它，最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- 涵蓋：員編格式放寬、12 個 LINE 帳號、line_access 權限（客服部／主管／店長／無帳號／未登入）、
--   roster_set_line_access 函式（含失敗不留半套）、外鍵行為、
--   以及「技師、公務機因 include_in_assessment=false 而被各名單排除」（有安裝對應函式才測）。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.employees') is null or to_regclass('public.app_users') is null then
    raise exception '請先執行 roster_schema.sql';
  end if;
  if to_regclass('public.line_access') is null or to_regclass('public.line_accounts') is null then
    raise exception '請先執行 roster_line_schema.sql';
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

create or replace function pg_temp.vr_lk(p_grp text, p_name text, p_expected text, p_actual text, p_pattern text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_rec(p_grp, p_name, p_expected, p_actual, p_actual like p_pattern);
end $$;

-- 以擁有者身分執行單一值查詢，回傳文字
create or replace function pg_temp.vr_q1(p_sql text)
returns text language plpgsql as $$
declare
  v text;
begin
  execute p_sql into v;
  return coalesce(v, '(null)');
end $$;

-- 以指定資料庫角色＋指定 email 執行一段 SQL；p_scalar=true 回傳單一值文字，false 只執行回 'OK'；失敗回 'ERROR: 訊息'
-- p_email 為 null＝沒有登入者
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
    reset role;
    return 'ERROR: ' || sqlerrm;
  end;
end $$;

-- ============================================================
-- 建立假資料（以擁有者身分直接寫入，rollback 後消失）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values
    ('ZL-A', 'ZL測試門市甲'), ('ZL-B', 'ZL測試門市乙');

  -- 甲店：一般業務（納入考核）、技師、公務機（皆不納入考核）、工讀；乙店：業務
  -- 技師與公務機的到職日設成今天（若被當成納入考核，就會出現在「新人」名單，方便抓漏）
  insert into public.employees (id, nickname, full_name, store_code, job_title, hire_date, status, include_in_assessment) values
    ('MI-9901', 'VR業務甲', 'VR測試甲', 'ZL-A', '業務', (now() at time zone 'Asia/Taipei')::date, '在職', true),
    ('MI-9902', 'VR技師甲', null,       'ZL-A', '技師', (now() at time zone 'Asia/Taipei')::date, '在職', false),
    ('OF-9901', '公務機',   null,       'ZL-A', '公務機', (now() at time zone 'Asia/Taipei')::date, '在職', false),
    ('MI-9903', 'VR業務乙', null,       'ZL-B', '業務', (now() at time zone 'Asia/Taipei')::date - 400, '在職', true);

  insert into public.app_users (email, role, store_code, employee_id) values
    ('vr-line-cs@2motor.tw',  'cs_admin',      null,   null),
    ('vr-line-hq@2motor.tw',  'hq_viewer',     null,   null),
    ('vr-line-mga@2motor.tw', 'store_manager', 'ZL-A', null),
    ('vr-line-mgb@2motor.tw', 'store_manager', 'ZL-B', null);

  -- 若已安裝第一期（有 period_status 欄），把三位都設成「考核期」＝最壞情況：
  -- 即使技師、公務機被誤設成考核期，也必須因為不納入考核而被各名單排除
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status') then
    execute $e$update public.employees set period_status = '考核期' where id in ('MI-9901','MI-9902','OF-9901')$e$;
  end if;

  -- 初始 LINE 權限：MI-9901 有 總、中和；MI-9903 有 總、同行
  insert into public.line_access (employee_id, line_code) values
    ('MI-9901', '總'), ('MI-9901', '中和'), ('MI-9903', '總'), ('MI-9903', '同行');
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 A：員工編號格式放寬（OF-xxxx），其餘格式仍擋
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('A','OF-9901 假資料已成功建立（公務機編號被接受）','OF-9901',
    pg_temp.vr_q1($q$select id from public.employees where id = 'OF-9901'$q$));
  perform pg_temp.vr_eq('A','新增 MI-9904 可以','OK',
    pg_temp.vr_as('authenticated', 'vr-line-cs@2motor.tw',
      $q$insert into public.employees (id, nickname, store_code, job_title) values ('MI-9904','VR','ZL-A','業務')$q$, false));
  perform pg_temp.vr_eq('A','新增 PT-9951 可以','OK',
    pg_temp.vr_as('authenticated', 'vr-line-cs@2motor.tw',
      $q$insert into public.employees (id, nickname, store_code, job_title) values ('PT-9951','VR','ZL-A','工讀')$q$, false));
  perform pg_temp.vr_lk('A','編號 XX-1234 被擋（check 約束）','報錯 employees_id_check',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.employees (id, nickname, store_code, job_title) values ('XX-1234','VR','ZL-A','業務')$q$, false),
    'ERROR:%employees_id_check%');
  perform pg_temp.vr_lk('A','編號 OF-12（位數不足）被擋','報錯 employees_id_check',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.employees (id, nickname, store_code, job_title) values ('OF-12','VR','ZL-A','公務機')$q$, false),
    'ERROR:%employees_id_check%');
  perform pg_temp.vr_lk('A','編號 of-9902（小寫）被擋','報錯 employees_id_check',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.employees (id, nickname, store_code, job_title) values ('of-9902','VR','ZL-A','公務機')$q$, false),
    'ERROR:%employees_id_check%');
exception when others then
  perform pg_temp.vr_rec('區段 A','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 B：12 個 LINE 帳號
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('B','line_accounts 共 12 個','12', pg_temp.vr_q1($q$select count(*)::text from public.line_accounts$q$));
  perform pg_temp.vr_eq('B','依排序的名稱','總,同行,中和,新莊,樹林,桃園,新竹,旗艦,南台中,台南,高雄,花蓮',
    pg_temp.vr_q1($q$select string_agg(name, ',' order by sort_order) from public.line_accounts$q$));
  perform pg_temp.vr_eq('B','客服部讀到 12 個','12',
    pg_temp.vr_as('authenticated','vr-line-cs@2motor.tw', $q$select count(*)::text from public.line_accounts$q$, true));
  perform pg_temp.vr_eq('B','主管讀到 12 個','12',
    pg_temp.vr_as('authenticated','vr-line-hq@2motor.tw', $q$select count(*)::text from public.line_accounts$q$, true));
  perform pg_temp.vr_eq('B','店長讀到 12 個','12',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw', $q$select count(*)::text from public.line_accounts$q$, true));
  perform pg_temp.vr_eq('B','沒有帳號者讀到 0 個','0',
    pg_temp.vr_as('authenticated','vr-line-nobody@2motor.tw', $q$select count(*)::text from public.line_accounts$q$, true));
  perform pg_temp.vr_lk('B','未登入 anon 讀取被拒','permission denied',
    pg_temp.vr_as('anon', null, $q$select count(*)::text from public.line_accounts$q$, true), 'ERROR:%permission denied%');
  perform pg_temp.vr_eq('B','客服部可新增第 13 個 LINE（驗證後 rollback）','OK',
    pg_temp.vr_as('authenticated','vr-line-cs@2motor.tw',
      $q$insert into public.line_accounts (code, name, sort_order) values ('ZL測試','ZL測試',99)$q$, false));
  perform pg_temp.vr_lk('B','主管不能新增 LINE 帳號','報錯 row-level security',
    pg_temp.vr_as('authenticated','vr-line-hq@2motor.tw',
      $q$insert into public.line_accounts (code, name, sort_order) values ('ZL測試2','ZL測試2',98)$q$, false),
    'ERROR:%row-level security%');
  perform pg_temp.vr_lk('B','店長不能新增 LINE 帳號','報錯 row-level security',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw',
      $q$insert into public.line_accounts (code, name, sort_order) values ('ZL測試3','ZL測試3',97)$q$, false),
    'ERROR:%row-level security%');
exception when others then
  perform pg_temp.vr_rec('區段 B','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 C：line_access 權限（前提：MI-9901 甲店 2 筆、MI-9903 乙店 2 筆，共 4 筆；先清掉其他真實資料的影響只看假員工）
-- ============================================================
do $$
declare
  v_fake text := $q$ where employee_id in ('MI-9901','MI-9902','MI-9903','MI-9904','OF-9901','PT-9951')$q$;
begin
  perform pg_temp.vr_eq('C','客服部讀到假員工 4 筆','4',
    pg_temp.vr_as('authenticated','vr-line-cs@2motor.tw', 'select count(*)::text from public.line_access' || v_fake, true));
  perform pg_temp.vr_eq('C','主管讀到假員工 4 筆（全部）','4',
    pg_temp.vr_as('authenticated','vr-line-hq@2motor.tw', 'select count(*)::text from public.line_access' || v_fake, true));
  perform pg_temp.vr_eq('C','店長甲只讀到甲店 MI-9901（2 筆）','2/MI-9901',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw',
      'select count(*)::text || ''/'' || min(employee_id) from public.line_access' || v_fake, true));
  perform pg_temp.vr_eq('C','店長甲看不到乙店 MI-9903','0',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw',
      $q$select count(*)::text from public.line_access where employee_id = 'MI-9903'$q$, true));
  perform pg_temp.vr_eq('C','店長乙只讀到乙店 MI-9903（2 筆）','2/MI-9903',
    pg_temp.vr_as('authenticated','vr-line-mgb@2motor.tw',
      'select count(*)::text || ''/'' || min(employee_id) from public.line_access' || v_fake, true));
  perform pg_temp.vr_eq('C','沒有帳號者讀到 0 筆','0',
    pg_temp.vr_as('authenticated','vr-line-nobody@2motor.tw', 'select count(*)::text from public.line_access' || v_fake, true));
  perform pg_temp.vr_lk('C','未登入 anon 讀取被拒','permission denied',
    pg_temp.vr_as('anon', null, 'select count(*)::text from public.line_access', true), 'ERROR:%permission denied%');
  perform pg_temp.vr_eq('C','信箱大小寫不影響（客服部）','4',
    pg_temp.vr_as('authenticated','VR-Line-CS@2motor.tw', 'select count(*)::text from public.line_access' || v_fake, true));

  -- 寫入
  perform pg_temp.vr_eq('C','客服部直接新增一筆 MI-9901／新莊','OK',
    pg_temp.vr_as('authenticated','vr-line-cs@2motor.tw',
      $q$insert into public.line_access (employee_id, line_code) values ('MI-9901','新莊')$q$, false));
  perform pg_temp.vr_eq('C','客服部刪除該筆','1',
    pg_temp.vr_as('authenticated','vr-line-cs@2motor.tw',
      $q$with d as (delete from public.line_access where employee_id='MI-9901' and line_code='新莊' returning 1) select count(*)::text from d$q$, true));
  perform pg_temp.vr_lk('C','主管不能新增','報錯 row-level security',
    pg_temp.vr_as('authenticated','vr-line-hq@2motor.tw',
      $q$insert into public.line_access (employee_id, line_code) values ('MI-9901','樹林')$q$, false),
    'ERROR:%row-level security%');
  perform pg_temp.vr_eq('C','主管不能刪除（0 列）','0',
    pg_temp.vr_as('authenticated','vr-line-hq@2motor.tw',
      $q$with d as (delete from public.line_access where employee_id='MI-9901' returning 1) select count(*)::text from d$q$, true));
  perform pg_temp.vr_lk('C','店長不能新增（連自己門市也不行）','報錯 row-level security',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw',
      $q$insert into public.line_access (employee_id, line_code) values ('MI-9901','樹林')$q$, false),
    'ERROR:%row-level security%');
  perform pg_temp.vr_eq('C','店長不能改（0 列）','0',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw',
      $q$with u as (update public.line_access set line_code='花蓮' where employee_id='MI-9901' and line_code='總' returning 1) select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('C','店長不能刪（0 列）','0',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw',
      $q$with d as (delete from public.line_access where employee_id='MI-9901' returning 1) select count(*)::text from d$q$, true));
  perform pg_temp.vr_eq('C','寫入測試後 MI-9901 仍是 2 筆（總、中和）','2',
    pg_temp.vr_q1($q$select count(*)::text from public.line_access where employee_id = 'MI-9901'$q$));
  perform pg_temp.vr_lk('C','不存在的 LINE 代碼：外鍵擋下','報錯 foreign key',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.line_access (employee_id, line_code) values ('MI-9901','不存在')$q$, false),
    'ERROR:%foreign key%');
  perform pg_temp.vr_lk('C','不存在的人員：外鍵擋下','報錯 foreign key',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.line_access (employee_id, line_code) values ('MI-9999','總')$q$, false),
    'ERROR:%foreign key%');
  perform pg_temp.vr_lk('C','重複的 人員＋LINE：主鍵擋下','報錯 duplicate key',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.line_access (employee_id, line_code) values ('MI-9901','總')$q$, false),
    'ERROR:%duplicate key%');
exception when others then
  perform pg_temp.vr_rec('區段 C','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 D：roster_set_line_access（網頁存檔用）
-- ============================================================
do $$
declare
  cs text := 'vr-line-cs@2motor.tw';
  v_codes text := $q$select coalesce(string_agg(line_code, ',' order by line_code), '(none)') from public.line_access where employee_id = 'MI-9901'$q$;
begin
  perform pg_temp.vr_eq('D','客服部改 MI-9901 為 新莊、樹林','OK',
    pg_temp.vr_as('authenticated', cs, $q$select public.roster_set_line_access('MI-9901', array['新莊','樹林'])$q$, false));
  perform pg_temp.vr_eq('D','改完只剩 新莊、樹林（舊的 總、中和 被換掉）','新莊,樹林', pg_temp.vr_q1(v_codes));
  perform pg_temp.vr_eq('D','重複代碼會去重','OK',
    pg_temp.vr_as('authenticated', cs, $q$select public.roster_set_line_access('MI-9901', array['新莊','新莊','花蓮'])$q$, false));
  perform pg_temp.vr_eq('D','去重後 新莊、花蓮','新莊,花蓮', pg_temp.vr_q1(v_codes));
  perform pg_temp.vr_lk('D','含不存在代碼：整批失敗','報錯 foreign key',
    pg_temp.vr_as('authenticated', cs, $q$select public.roster_set_line_access('MI-9901', array['總','不存在'])$q$, false),
    'ERROR:%foreign key%');
  perform pg_temp.vr_eq('D','失敗後原本的 新莊、花蓮 完整保留（沒有半套）','新莊,花蓮', pg_temp.vr_q1(v_codes));
  perform pg_temp.vr_lk('D','不存在的人員：報錯','找不到這位人員',
    pg_temp.vr_as('authenticated', cs, $q$select public.roster_set_line_access('MI-9999', array['總'])$q$, false),
    'ERROR:%找不到這位人員%');
  perform pg_temp.vr_lk('D','主管呼叫被拒','只有客服部',
    pg_temp.vr_as('authenticated','vr-line-hq@2motor.tw', $q$select public.roster_set_line_access('MI-9901', array['總'])$q$, false),
    'ERROR:%只有客服部%');
  perform pg_temp.vr_lk('D','店長呼叫被拒','只有客服部',
    pg_temp.vr_as('authenticated','vr-line-mga@2motor.tw', $q$select public.roster_set_line_access('MI-9901', array['總'])$q$, false),
    'ERROR:%只有客服部%');
  perform pg_temp.vr_lk('D','沒有帳號者呼叫被拒','只有客服部',
    pg_temp.vr_as('authenticated','vr-line-nobody@2motor.tw', $q$select public.roster_set_line_access('MI-9901', array['總'])$q$, false),
    'ERROR:%只有客服部%');
  perform pg_temp.vr_lk('D','未登入 anon 呼叫被拒','permission denied',
    pg_temp.vr_as('anon', null, $q$select public.roster_set_line_access('MI-9901', array['總'])$q$, false),
    'ERROR:%permission denied%');
  perform pg_temp.vr_eq('D','被拒絕後內容不變','新莊,花蓮', pg_temp.vr_q1(v_codes));
  perform pg_temp.vr_eq('D','客服部傳 12 個全選','OK',
    pg_temp.vr_as('authenticated', cs,
      $q$select public.roster_set_line_access('MI-9901', (select array_agg(code) from public.line_accounts where sort_order <= 12))$q$, false));
  perform pg_temp.vr_eq('D','全選後 12 筆','12',
    pg_temp.vr_q1($q$select count(*)::text from public.line_access where employee_id = 'MI-9901'$q$));
  perform pg_temp.vr_eq('D','傳空陣列＝清空','OK',
    pg_temp.vr_as('authenticated', cs, $q$select public.roster_set_line_access('MI-9901', '{}'::text[])$q$, false));
  perform pg_temp.vr_eq('D','清空後 0 筆','(none)', pg_temp.vr_q1(v_codes));
  perform pg_temp.vr_eq('D','傳 null 也是清空（不報錯）','OK',
    pg_temp.vr_as('authenticated', cs, $q$select public.roster_set_line_access('MI-9901', null)$q$, false));
  perform pg_temp.vr_eq('D','其他人不受影響：MI-9903 仍 2 筆','2',
    pg_temp.vr_q1($q$select count(*)::text from public.line_access where employee_id = 'MI-9903'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 D','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 E：外鍵行為（刪人連帶刪權限；LINE 帳號有人用不能刪；改員編連動）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('E','前提：MI-9903 有 2 筆權限','2',
    pg_temp.vr_q1($q$select count(*)::text from public.line_access where employee_id = 'MI-9903'$q$));
  perform pg_temp.vr_lk('E','「總」LINE 有人在用，不能刪除帳號','報錯 foreign key',
    pg_temp.vr_as('postgres', null, $q$delete from public.line_accounts where code = '總'$q$, false),
    'ERROR:%foreign key%');
  perform pg_temp.vr_eq('E','改員編 MI-9903→MI-9909：權限跟著走','2',
    (select case when pg_temp.vr_q1($q$update public.employees set id = 'MI-9909' where id = 'MI-9903' returning id$q$) = 'MI-9909'
            then pg_temp.vr_q1($q$select count(*)::text from public.line_access where employee_id = 'MI-9909'$q$) else 'update failed' end));
  perform pg_temp.vr_eq('E','刪除該員工：權限連帶刪除（0 筆）','0',
    (select case when pg_temp.vr_q1($q$with d as (delete from public.employees where id = 'MI-9909' returning 1) select count(*)::text from d$q$) = '1'
            then pg_temp.vr_q1($q$select count(*)::text from public.line_access where employee_id = 'MI-9909'$q$) else 'delete failed' end));
exception when others then
  perform pg_temp.vr_rec('區段 E','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 F：技師、公務機（include_in_assessment=false）被各名單排除
--   只測資料庫裡有安裝的函式（沒裝就在結果標「略過」並算通過）。
--   假資料：MI-9901 業務（納入）、MI-9902 技師、OF-9901 公務機，到職日都是今天（新人）。
-- ============================================================
do $$
declare
  cs text := 'vr-line-cs@2motor.tw';
begin
  if to_regprocedure('public.assess_candidates()') is not null then
    perform pg_temp.vr_eq('F','考核名單 assess_candidates：只列業務 MI-9901（含 1，不含技師與公務機）','1/0/0',
      pg_temp.vr_as('authenticated', cs,
        $q$select (select count(*) from public.assess_candidates() where id = 'MI-9901')::text || '/' ||
                  (select count(*) from public.assess_candidates() where id = 'MI-9902')::text || '/' ||
                  (select count(*) from public.assess_candidates() where id = 'OF-9901')::text$q$, true));
  else
    perform pg_temp.vr_rec('F','assess_candidates 略過（尚未安裝 assess_schema.sql）','略過','略過', true);
  end if;

  if to_regprocedure('public.spot_candidates()') is not null then
    perform pg_temp.vr_eq('F','抽查名單 spot_candidates：技師與公務機不在內','0/0',
      pg_temp.vr_as('authenticated', cs,
        $q$select (select count(*) from public.spot_candidates() where id = 'MI-9902')::text || '/' ||
                  (select count(*) from public.spot_candidates() where id = 'OF-9901')::text$q$, true));
  else
    perform pg_temp.vr_rec('F','spot_candidates 略過（尚未安裝 spotcheck_schema.sql）','略過','略過', true);
  end if;

  if to_regprocedure('public.exam_req_candidates(text)') is not null then
    perform pg_temp.vr_eq('F','待考回報候選（新人）exam_req_candidates：業務在、技師與公務機不在','1/0/0',
      pg_temp.vr_as('authenticated', cs,
        $q$select (select count(*) from public.exam_req_candidates('新人') where employee_id = 'MI-9901')::text || '/' ||
                  (select count(*) from public.exam_req_candidates('新人') where employee_id = 'MI-9902')::text || '/' ||
                  (select count(*) from public.exam_req_candidates('新人') where employee_id = 'OF-9901')::text$q$, true));
  else
    perform pg_temp.vr_rec('F','exam_req_candidates 略過（尚未安裝 exam_request_schema.sql）','略過','略過', true);
  end if;

  if to_regprocedure('public.checkup_eligible(text,integer,integer)') is not null then
    perform pg_temp.vr_eq('F','健檢資格 checkup_eligible：技師、公務機皆為 false','false/false',
      pg_temp.vr_as('postgres', null,
        $q$select public.checkup_eligible('MI-9902', 2031, 1)::text || '/' || public.checkup_eligible('OF-9901', 2031, 1)::text$q$, true));
  else
    perform pg_temp.vr_rec('F','checkup_eligible 略過（尚未安裝 checkup_schema.sql）','略過','略過', true);
  end if;
exception when others then
  perform pg_temp.vr_rec('區段 F','意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate line_vr_out';
  exception when others then
    null;
  end;

  execute 'prepare line_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過') || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  begin
    execute 'deallocate line_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare line_vr_out as select '
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
execute line_vr_out;
