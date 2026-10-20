-- ============================================================
-- 業務考核系統：帳號管理護欄與操作紀錄 驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 roster_schema.sql、accounts_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後，先「在這個交易內」把 app_users 清空（為了讓客服部人數可控；
--   真實帳號只是在交易內暫時看不到，rollback 後完整復原），再建立假門市／假員工／假帳號，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料與交易內的刪除全部消失）。
-- 假信箱：accounts_schema.sql 規定信箱必須以 @2motor.tw 結尾，用 example.invalid 會被拒，
--   所以假信箱一律用「vr-xxx@2motor.tw」（vr＝verify，明顯是測試用，非任何真人）。
--   全部都在交易內，rollback 後不留任何資料。
-- 假門市代碼 ZZ-A1／ZZ-A2、假員工編號 MI-9801／MI-9802；若真實資料剛好撞到，
--   腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 怎麼看結果：
--   * SQL Editor 只顯示「最後一個」結果，而 rollback 本身沒有結果，
--     所以腳本在 rollback 之前把結果表存成「預備陳述式 accounts_vr_out」
--     （連線層級物件，不受 rollback 影響，裡面只有結果文字，沒有任何資料表內容），
--     rollback 之後再 execute 它，所以最後一個結果就是「序號／測項／預期／實際／通過」表。
--   * rollback 之前還會先 select 一次同樣的表當備援；若畫面出現兩張一樣的表，看最後一張即可。
--   * 第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯停下（rollback 後無影響），不會卡住別人
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.app_users') is null or to_regclass('public.employees') is null then
    raise exception '請先執行 roster_schema.sql';
  end if;
  if to_regclass('public.app_users_audit') is null
     or to_regclass('public.accounts_list') is null then
    raise exception '請先執行 accounts_schema.sql';
  end if;
end
$$;

-- 鎖住 app_users：擋別人寫入、不擋讀取（share row exclusive）。
-- 腳本會在交易內暫時清空 app_users，鎖住可避免別人在這段時間寫入而產生混亂；
-- 整個交易結束（rollback）就自動解鎖。
lock table public.app_users in share row exclusive mode;

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

-- 實際結果要符合 like 樣式（用於比對錯誤訊息）
create or replace function pg_temp.vr_lk(p_grp text, p_name text, p_expected text, p_actual text, p_pattern text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_rec(p_grp, p_name, p_expected, p_actual, p_actual like p_pattern);
end $$;

-- 以目前身分執行單一值查詢，回傳文字（給腳本自己讀資料用，以擁有者身分、不模擬登入）
create or replace function pg_temp.vr_q1(p_sql text)
returns text language plpgsql as $$
declare
  v text;
begin
  execute p_sql into v;
  return coalesce(v, '(null)');
end $$;

-- 以指定資料庫角色（authenticated／anon／postgres）＋指定 email 執行一段 SQL。
-- p_scalar = true：SQL 必須回傳單一值，回傳該值的文字；false：只執行，成功回 'OK'。
-- 失敗回 'ERROR: 訊息'。失敗時子交易自動回復，不會讓整個腳本中斷。
-- p_email 為 null＝沒有登入者（JWT 為空，模擬 SQL Editor）。
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

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);

  -- 交易內暫時清空 app_users（沒有登入者＝護欄不啟動），讓客服部人數完全由假資料決定。
  -- 這個刪除只存在於本交易，rollback 後真實帳號原封不動。
  delete from public.app_users;

  insert into public.stores (code, name) values
    ('ZZ-A1', 'ZZ測試門市甲'), ('ZZ-A2', 'ZZ測試門市乙');

  insert into public.employees (id, nickname, full_name, store_code, job_title, status, include_in_assessment) values
    ('MI-9801', 'VR暱稱甲', 'VR測試甲', 'ZZ-A1', '客服', '在職', false),
    ('MI-9802', 'VR暱稱乙', 'VR測試乙', 'ZZ-A1', '客服', '在職', false);

  insert into public.app_users (email, role, store_code, employee_id) values
    ('vr-admin1@2motor.tw', 'cs_admin',      null,    'MI-9801'),
    ('vr-admin2@2motor.tw', 'cs_admin',      null,    null),
    ('vr-hq@2motor.tw',     'hq_viewer',     null,    null),
    ('vr-mgr@2motor.tw',    'store_manager', 'ZZ-A1', null);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 A：客服部新增、修改、移除一般帳號，操作紀錄正確
-- ============================================================
do $$
declare
  a1 text := 'vr-admin1@2motor.tw';
begin
  perform pg_temp.vr_eq('A','客服部新增一般帳號','OK',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role, store_code) values ('vr-new@2motor.tw', 'store_manager', 'ZZ-A2')$q$, false));
  perform pg_temp.vr_eq('A','客服部修改角色（店長→主管）','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set role = 'hq_viewer', store_code = null
                    where email = 'vr-new@2motor.tw' returning 1) select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('A','客服部移除一般帳號','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with d as (delete from public.app_users where email = 'vr-new@2motor.tw' returning 1)
         select count(*)::text from d$q$, true));

  perform pg_temp.vr_eq('A','操作紀錄：該帳號共 3 筆，順序 insert,update,delete','insert,update,delete',
    pg_temp.vr_q1($q$select string_agg(action, ',' order by id) from public.app_users_audit
                     where email = 'vr-new@2motor.tw'$q$));
  perform pg_temp.vr_eq('A','操作紀錄：操作人信箱為登入者','vr-admin1@2motor.tw',
    pg_temp.vr_q1($q$select string_agg(distinct by_email, ',') from public.app_users_audit
                     where email = 'vr-new@2motor.tw'$q$));
  perform pg_temp.vr_eq('A','操作紀錄 insert：old_row 為空、new_row 角色與門市正確','true/store_manager/ZZ-A2',
    pg_temp.vr_q1($q$select (old_row is null)::text || '/' || (new_row ->> 'role') || '/' || (new_row ->> 'store_code')
                     from public.app_users_audit where email = 'vr-new@2motor.tw' and action = 'insert'$q$));
  perform pg_temp.vr_eq('A','操作紀錄 update：old_row 與 new_row 角色正確','store_manager>hq_viewer',
    pg_temp.vr_q1($q$select (old_row ->> 'role') || '>' || (new_row ->> 'role')
                     from public.app_users_audit where email = 'vr-new@2motor.tw' and action = 'update'$q$));
  perform pg_temp.vr_eq('A','操作紀錄 delete：old_row 有內容、new_row 為空','hq_viewer/true',
    pg_temp.vr_q1($q$select (old_row ->> 'role') || '/' || (new_row is null)::text
                     from public.app_users_audit where email = 'vr-new@2motor.tw' and action = 'delete'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 A','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 B：至少保留一位客服部／不能移除或降級自己
-- 起始：vr-admin1、vr-admin2 兩位客服部
-- ============================================================
do $$
declare
  a1 text := 'vr-admin1@2motor.tw';
  v_cnt text := $q$select count(*)::text from public.app_users where role = 'cs_admin'$q$;
begin
  perform pg_temp.vr_eq('B','前提：客服部有 2 位','2', pg_temp.vr_q1(v_cnt));

  perform pg_temp.vr_eq('B','有第二位客服部時，可移除另一位（不是自己）','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with d as (delete from public.app_users where email = 'vr-admin2@2motor.tw' returning 1)
         select count(*)::text from d$q$, true));
  perform pg_temp.vr_eq('B','移除後客服部剩 1 位','1', pg_temp.vr_q1(v_cnt));

  -- 只剩最後一位：刪除、降級都被擋（訊息為「至少要保留一位客服部」）
  perform pg_temp.vr_lk('B','最後一位客服部被刪除 → 被拒','報錯，訊息含：至少要保留一位客服部',
    pg_temp.vr_as('authenticated', a1,
      $q$delete from public.app_users where email = 'vr-admin1@2motor.tw'$q$, false),
    '%至少要保留一位客服部%');
  perform pg_temp.vr_lk('B','最後一位客服部被降級 → 被拒','報錯，訊息含：至少要保留一位客服部',
    pg_temp.vr_as('authenticated', a1,
      $q$update public.app_users set role = 'hq_viewer' where email = 'vr-admin1@2motor.tw'$q$, false),
    '%至少要保留一位客服部%');
  perform pg_temp.vr_eq('B','被拒後最後一位客服部仍在','1', pg_temp.vr_q1(v_cnt));

  -- 補回第二位（由 admin1 新增）
  perform pg_temp.vr_eq('B','客服部新增第二位客服部','OK',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('vr-admin2@2motor.tw', 'cs_admin')$q$, false));

  -- 有第二位時：自己移除、自己降級仍被擋（訊息為「不能移除或降級自己的客服部身分」）
  perform pg_temp.vr_lk('B','客服部移除自己 → 被拒','報錯，訊息含：不能移除或降級自己的客服部身分',
    pg_temp.vr_as('authenticated', a1,
      $q$delete from public.app_users where email = 'vr-admin1@2motor.tw'$q$, false),
    '%不能移除或降級自己的客服部身分%');
  perform pg_temp.vr_lk('B','客服部把自己降級 → 被拒','報錯，訊息含：不能移除或降級自己的客服部身分',
    pg_temp.vr_as('authenticated', a1,
      $q$update public.app_users set role = 'hq_viewer' where email = 'vr-admin1@2motor.tw'$q$, false),
    '%不能移除或降級自己的客服部身分%');
  perform pg_temp.vr_eq('B','被拒後兩位客服部都還在','2', pg_temp.vr_q1(v_cnt));

  perform pg_temp.vr_lk('B','客服部把自己的信箱改掉（等於移除自己）→ 被拒','報錯，訊息含：不能移除或降級自己的客服部身分',
    pg_temp.vr_as('authenticated', a1,
      $q$update public.app_users set email = 'vr-admin1b@2motor.tw' where email = 'vr-admin1@2motor.tw'$q$, false),
    '%不能移除或降級自己的客服部身分%');
  perform pg_temp.vr_eq('B','自己的信箱被拒後沒有變','1',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users where email = 'vr-admin1@2motor.tw'$q$));
  perform pg_temp.vr_eq('B','客服部改另一位客服部的信箱（不是自己）→ 允許','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set email = 'vr-admin2b@2motor.tw' where email = 'vr-admin2@2motor.tw' returning 1)
         select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('B','把那位的信箱改回來 → 允許','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set email = 'vr-admin2@2motor.tw' where email = 'vr-admin2b@2motor.tw' returning 1)
         select count(*)::text from u$q$, true));

  perform pg_temp.vr_eq('B','改自己的無關欄位（對應員工）→ 允許','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set employee_id = 'MI-9802'
                    where email = 'vr-admin1@2motor.tw' returning 1) select count(*)::text from u$q$, true));

  perform pg_temp.vr_lk('B','一次降級全部客服部（同一語句）→ 被拒','報錯，訊息含：至少要保留一位客服部',
    pg_temp.vr_as('authenticated', a1,
      $q$update public.app_users set role = 'hq_viewer' where role = 'cs_admin'$q$, false),
    '%至少要保留一位客服部%');
  perform pg_temp.vr_eq('B','整批被拒後客服部仍是 2 位','2', pg_temp.vr_q1(v_cnt));

  perform pg_temp.vr_eq('B','降級另一位客服部（不是自己、仍剩 1 位）→ 允許','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set role = 'hq_viewer' where email = 'vr-admin2@2motor.tw' returning 1)
         select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('B','降級後客服部剩 1 位','1', pg_temp.vr_q1(v_cnt));
  perform pg_temp.vr_eq('B','把另一位升回客服部 → 允許（客服部回到 2 位）','2',
    (select case when pg_temp.vr_as('authenticated', a1,
        $q$with u as (update public.app_users set role = 'cs_admin' where email = 'vr-admin2@2motor.tw' returning 1)
           select count(*)::text from u$q$, true) = '1'
      then pg_temp.vr_q1(v_cnt) else '升回失敗' end));
exception when others then
  perform pg_temp.vr_rec('區段 B','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 C：信箱必須是 @2motor.tw
-- ============================================================
do $$
declare
  a1 text := 'vr-admin1@2motor.tw';
begin
  perform pg_temp.vr_lk('C','新增 example.invalid 信箱 → 被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('vr-bad1@example.invalid', 'hq_viewer')$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_lk('C','新增 @2motor.tw.evil.com（網域後面還有字）→ 被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('vr-bad2@2motor.tw.evil.com', 'hq_viewer')$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_lk('C','新增只有網域、沒有帳號名稱（@2motor.tw）→ 被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('@2motor.tw', 'hq_viewer')$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_lk('C','新增含空白的信箱 → 被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('vr bad4@2motor.tw', 'hq_viewer')$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_lk('C','新增含兩個 @ 的信箱 → 被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('vr-bad5@x@2motor.tw', 'hq_viewer')$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_eq('C','無異動的 UPDATE 前：vr-hq 的操作紀錄筆數','1',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users_audit where email = 'vr-hq@2motor.tw'$q$));
  perform pg_temp.vr_eq('C','無異動的 UPDATE（內容完全相同）→ 執行成功','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set role = role where email = 'vr-hq@2motor.tw' returning 1)
         select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('C','無異動的 UPDATE 不寫操作紀錄（筆數仍為 1）','1',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users_audit where email = 'vr-hq@2motor.tw'$q$));
  perform pg_temp.vr_eq('C','新增 vr-xxx@2motor.tw 信箱 → 允許','OK',
    pg_temp.vr_as('authenticated', a1,
      $q$insert into public.app_users (email, role) values ('vr-ren@2motor.tw', 'hq_viewer')$q$, false));
  perform pg_temp.vr_lk('C','修改信箱成不合規（UPDATE email）→ 被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('authenticated', a1,
      $q$update public.app_users set email = 'vr-ren@example.invalid' where email = 'vr-ren@2motor.tw'$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_eq('C','修改信箱成合規的新信箱 → 允許','1',
    pg_temp.vr_as('authenticated', a1,
      $q$with u as (update public.app_users set email = 'vr-ren2@2motor.tw' where email = 'vr-ren@2motor.tw' returning 1)
         select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('C','操作紀錄：改信箱那筆 old_row／new_row 的信箱正確','vr-ren@2motor.tw>vr-ren2@2motor.tw',
    pg_temp.vr_q1($q$select (old_row ->> 'email') || '>' || (new_row ->> 'email')
                     from public.app_users_audit where email = 'vr-ren2@2motor.tw' and action = 'update'$q$));
  perform pg_temp.vr_eq('C','被拒絕的信箱沒有進 app_users','0',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users where email like 'vr-bad%' or email like 'vr-ren@%'$q$));
  perform pg_temp.vr_eq('C','被拒絕的操作不留操作紀錄','0',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users_audit where email like 'vr-bad%'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 C','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 D：各角色對操作紀錄與 app_users 的權限
-- ============================================================
do $$
declare
  r record;
  v_audit_total text;
  s_ins text := $q$insert into public.app_users_audit (by_email, action, email) values ('x', 'insert', 'x')$q$;
  s_upd text := $q$update public.app_users_audit set by_email = 'x'$q$;
  s_del text := $q$delete from public.app_users_audit$q$;
  u_ins text := $q$insert into public.app_users (email, role) values ('vr-x1@2motor.tw', 'hq_viewer')$q$;
  u_upd text := $q$with u as (update public.app_users set employee_id = null returning 1) select count(*)::text from u$q$;
  u_del text := $q$with d as (delete from public.app_users returning 1) select count(*)::text from d$q$;
begin
  v_audit_total := pg_temp.vr_q1($q$select count(*)::text from public.app_users_audit$q$);
  perform pg_temp.vr_rec('D','前提：操作紀錄表內有資料（讓「看不到」有意義）','> 0', v_audit_total, v_audit_total::int > 0);

  -- 客服部：可讀；但連客服部也不能寫操作紀錄
  perform pg_temp.vr_eq('D','客服部：可讀操作紀錄','true',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw',
      $q$select (count(*) > 0)::text from public.app_users_audit$q$, true));
  perform pg_temp.vr_lk('D','客服部：不能 insert 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw', s_ins, false), '%permission denied%');
  perform pg_temp.vr_lk('D','客服部：不能 update 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw', s_upd, false), '%permission denied%');
  perform pg_temp.vr_lk('D','客服部：不能 delete 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw', s_del, false), '%permission denied%');

  -- 店長、主管、有登入但沒有帳號
  for r in
    select * from (values
      ('店長',     'vr-mgr@2motor.tw'),
      ('主管',     'vr-hq@2motor.tw'),
      ('無帳號者', 'vr-ghost@2motor.tw')
    ) as t(label, email)
  loop
    perform pg_temp.vr_eq('D', r.label || '：讀操作紀錄看到 0 筆', '0',
      pg_temp.vr_as('authenticated', r.email, $q$select count(*)::text from public.app_users_audit$q$, true));
    perform pg_temp.vr_lk('D', r.label || '：不能 insert 操作紀錄', '報錯，訊息含：permission denied',
      pg_temp.vr_as('authenticated', r.email, s_ins, false), '%permission denied%');
    perform pg_temp.vr_lk('D', r.label || '：不能 update 操作紀錄', '報錯，訊息含：permission denied',
      pg_temp.vr_as('authenticated', r.email, s_upd, false), '%permission denied%');
    perform pg_temp.vr_lk('D', r.label || '：不能 delete 操作紀錄', '報錯，訊息含：permission denied',
      pg_temp.vr_as('authenticated', r.email, s_del, false), '%permission denied%');
    perform pg_temp.vr_lk('D', r.label || '：不能新增 app_users', '報錯，訊息含：row-level security',
      pg_temp.vr_as('authenticated', r.email, u_ins, false), '%row-level security%');
    perform pg_temp.vr_eq('D', r.label || '：修改 app_users 影響 0 列', '0',
      pg_temp.vr_as('authenticated', r.email, u_upd, true));
    perform pg_temp.vr_eq('D', r.label || '：刪除 app_users 影響 0 列', '0',
      pg_temp.vr_as('authenticated', r.email, u_del, true));
  end loop;

  -- anon（未登入）：全部沒有權限
  perform pg_temp.vr_lk('D','anon：不能讀操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, $q$select count(*)::text from public.app_users_audit$q$, true), '%permission denied%');
  perform pg_temp.vr_lk('D','anon：不能 insert 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, s_ins, false), '%permission denied%');
  perform pg_temp.vr_lk('D','anon：不能 update 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, s_upd, false), '%permission denied%');
  perform pg_temp.vr_lk('D','anon：不能 delete 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, s_del, false), '%permission denied%');
  perform pg_temp.vr_lk('D','anon：不能新增 app_users','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, u_ins, false), '%permission denied%');
  perform pg_temp.vr_lk('D','anon：不能修改 app_users','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, u_upd, true), '%permission denied%');
  perform pg_temp.vr_lk('D','anon：不能刪除 app_users','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, u_del, true), '%permission denied%');

  -- service_role：權限也已收回
  perform pg_temp.vr_lk('D','service_role：不能讀操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('service_role', null, $q$select count(*)::text from public.app_users_audit$q$, true), '%permission denied%');
  perform pg_temp.vr_lk('D','service_role：不能 insert 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('service_role', null, s_ins, false), '%permission denied%');
  perform pg_temp.vr_lk('D','service_role：不能 update 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('service_role', null, s_upd, false), '%permission denied%');
  perform pg_temp.vr_lk('D','service_role：不能 delete 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('service_role', null, s_del, false), '%permission denied%');
  perform pg_temp.vr_lk('D','service_role：不能 truncate 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('service_role', null, $q$truncate public.app_users_audit$q$, false), '%permission denied%');
  perform pg_temp.vr_lk('D','客服部：不能 truncate 操作紀錄','報錯，訊息含：permission denied',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw', $q$truncate public.app_users_audit$q$, false), '%permission denied%');

  -- 第二道鎖：連擁有者（postgres）直接 update／delete／truncate 也被觸發器擋下
  perform pg_temp.vr_lk('D','擁有者（postgres）：update 操作紀錄被觸發器擋下','報錯，訊息含：操作紀錄只增不改',
    pg_temp.vr_as('postgres', null, s_upd, false), '%操作紀錄只增不改%');
  perform pg_temp.vr_lk('D','擁有者（postgres）：delete 操作紀錄被觸發器擋下','報錯，訊息含：操作紀錄只增不改',
    pg_temp.vr_as('postgres', null, s_del, false), '%操作紀錄只增不改%');
  perform pg_temp.vr_lk('D','擁有者（postgres）：truncate 操作紀錄被觸發器擋下','報錯，訊息含：操作紀錄只增不改',
    pg_temp.vr_as('postgres', null, $q$truncate public.app_users_audit$q$, false), '%操作紀錄只增不改%');

  perform pg_temp.vr_eq('D','以上被拒操作都沒有改動操作紀錄表筆數', v_audit_total,
    pg_temp.vr_q1($q$select count(*)::text from public.app_users_audit$q$));
exception when others then
  perform pg_temp.vr_rec('區段 D','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 G：accounts_list 檢視（沿用 RLS）
-- 此時 admin1 的對應員工已改為 MI-9802（見區段 B）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('G','客服部：accounts_list 看到全部假帳號（筆數與 app_users 相同）',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users where email like 'vr-%'$q$),
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw',
      $q$select count(*)::text from public.accounts_list where email like 'vr-%'$q$, true));
  perform pg_temp.vr_eq('G','客服部：accounts_list 帶出員編、暱稱、姓名','MI-9802/VR暱稱乙/VR測試乙',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw',
      $q$select employee_id || '/' || nickname || '/' || full_name from public.accounts_list
         where email = 'vr-admin1@2motor.tw'$q$, true));
  perform pg_temp.vr_eq('G','未對應員工的帳號：暱稱為空（左接）','(null)',
    pg_temp.vr_as('authenticated','vr-admin1@2motor.tw',
      $q$select nickname from public.accounts_list where email = 'vr-hq@2motor.tw'$q$, true));
  perform pg_temp.vr_eq('G','店長：accounts_list 只看到自己 1 列','1',
    pg_temp.vr_as('authenticated','vr-mgr@2motor.tw', $q$select count(*)::text from public.accounts_list$q$, true));
  perform pg_temp.vr_eq('G','主管：accounts_list 只看到自己 1 列','1',
    pg_temp.vr_as('authenticated','vr-hq@2motor.tw', $q$select count(*)::text from public.accounts_list$q$, true));
  perform pg_temp.vr_eq('G','無帳號者：accounts_list 看到 0 列','0',
    pg_temp.vr_as('authenticated','vr-ghost@2motor.tw', $q$select count(*)::text from public.accounts_list$q$, true));
  perform pg_temp.vr_lk('G','anon：不能讀 accounts_list','報錯，訊息含：permission denied',
    pg_temp.vr_as('anon', null, $q$select count(*)::text from public.accounts_list$q$, true), '%permission denied%');
exception when others then
  perform pg_temp.vr_rec('區段 G','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 E：沒有登入者（模擬 SQL Editor／postgres 角色）
-- 護欄 1、2 不啟動；信箱網域檢查與操作紀錄仍生效
-- ============================================================
do $$
declare
  v_cnt text := $q$select count(*)::text from public.app_users where role = 'cs_admin'$q$;
begin
  perform pg_temp.vr_eq('E','前提：沒有登入者時 roster_my_email() 為空','(null)',
    pg_temp.vr_as('postgres', null, $q$select public.roster_my_email()$q$, true));
  perform pg_temp.vr_eq('E','前提：目前客服部有 2 位','2', pg_temp.vr_q1(v_cnt));

  perform pg_temp.vr_eq('E','沒有登入者：可一次刪掉全部客服部（含最後一位，緊急修復用）','2',
    pg_temp.vr_as('postgres', null,
      $q$with d as (delete from public.app_users where role = 'cs_admin' returning 1)
         select count(*)::text from d$q$, true));
  perform pg_temp.vr_eq('E','刪除後客服部為 0 位','0', pg_temp.vr_q1(v_cnt));
  perform pg_temp.vr_eq('E','操作紀錄仍寫入：這兩筆 delete 的 by_email 為 (SQL Editor)','2',
    pg_temp.vr_q1($q$select count(*)::text from public.app_users_audit
                     where email in ('vr-admin1@2motor.tw', 'vr-admin2@2motor.tw')
                       and action = 'delete' and by_email = '(SQL Editor)'$q$));

  perform pg_temp.vr_eq('E','沒有登入者：補回客服部（緊急修復）','OK',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.app_users (email, role) values ('vr-emerg@2motor.tw', 'cs_admin')$q$, false));
  perform pg_temp.vr_eq('E','補回那筆的操作紀錄：by_email 為 (SQL Editor)、action 為 insert','(SQL Editor)/insert',
    pg_temp.vr_q1($q$select by_email || '/' || action from public.app_users_audit
                     where email = 'vr-emerg@2motor.tw'$q$));

  perform pg_temp.vr_eq('E','沒有登入者：可把唯一的客服部降級（護欄不啟動）','1',
    pg_temp.vr_as('postgres', null,
      $q$with u as (update public.app_users set role = 'hq_viewer' where email = 'vr-emerg@2motor.tw' returning 1)
         select count(*)::text from u$q$, true));
  perform pg_temp.vr_eq('E','降級後客服部為 0 位','0', pg_temp.vr_q1(v_cnt));

  perform pg_temp.vr_lk('E','沒有登入者：新增 example.invalid 信箱仍被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.app_users (email, role) values ('vr-bad3@example.invalid', 'hq_viewer')$q$, false),
    '%只收公司信箱（@2motor.tw）%');
  perform pg_temp.vr_lk('E','沒有登入者：修改信箱成不合規仍被拒','報錯，訊息含：只收公司信箱（@2motor.tw）',
    pg_temp.vr_as('postgres', null,
      $q$update public.app_users set email = 'vr-emerg@example.invalid' where email = 'vr-emerg@2motor.tw'$q$, false),
    '%只收公司信箱（@2motor.tw）%');
exception when others then
  perform pg_temp.vr_rec('區段 E','意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 F：既有資料表與函式未被改動
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('F','app_users 欄位不變','email,role,store_code,employee_id',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position)
                     from information_schema.columns
                     where table_schema = 'public' and table_name = 'app_users'$q$));
  perform pg_temp.vr_eq('F','app_users 的 policy 仍是原本 2 條','app_users_cs_write,app_users_select_self',
    pg_temp.vr_q1($q$select string_agg(policyname, ',' order by policyname)
                     from pg_policies where schemaname = 'public' and tablename = 'app_users'$q$));
  perform pg_temp.vr_eq('F','roster_my_email／role／store 三個函式仍在','3',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                     where n.nspname = 'public'
                       and p.proname in ('roster_my_email', 'roster_my_role', 'roster_my_store')$q$));
  perform pg_temp.vr_eq('F','roster_touch_updated_at 與 employees 觸發器仍在','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_trigger t
                     where t.tgrelid = 'public.employees'::regclass and not t.tgisinternal
                       and t.tgname = 'employees_touch_updated_at'$q$));
  perform pg_temp.vr_eq('F','app_users_audit 上有 3 個「只增不改」觸發器','accounts_audit_no_delete_trg,accounts_audit_no_truncate_trg,accounts_audit_no_update_trg',
    pg_temp.vr_q1($q$select string_agg(t.tgname, ',' order by t.tgname) from pg_trigger t
                     where t.tgrelid = 'public.app_users_audit'::regclass and not t.tgisinternal$q$));
  perform pg_temp.vr_eq('F','職稱長度：21 字被拒','報錯含 accounts_employees_job_title_len',
    (select case when m like '%accounts_employees_job_title_len%'
                 then '報錯含 accounts_employees_job_title_len' else m end
     from (select pg_temp.vr_as('postgres', null,
       $q$insert into public.employees (id, nickname, store_code, job_title)
          values ('MI-9803', 'VR暱稱丙', 'ZZ-A1', repeat('職', 21))$q$, false) as m) s));
  perform pg_temp.vr_eq('F','職稱長度：20 字允許','OK',
    pg_temp.vr_as('postgres', null,
      $q$insert into public.employees (id, nickname, store_code, job_title)
         values ('MI-9803', 'VR暱稱丙', 'ZZ-A1', repeat('職', 20))$q$, false));
  perform pg_temp.vr_eq('F','app_users 上只多了本檔 4 個觸發器','accounts_audit_trg,accounts_audit_upd_trg,accounts_email_domain_trg,accounts_guard_trg',
    pg_temp.vr_q1($q$select string_agg(t.tgname, ',' order by t.tgname) from pg_trigger t
                     where t.tgrelid = 'public.app_users'::regclass and not t.tgisinternal$q$));
  perform pg_temp.vr_eq('F','app_users_audit 欄位','id,at,by_email,action,email,old_row,new_row',
    pg_temp.vr_q1($q$select string_agg(column_name, ',' order by ordinal_position)
                     from information_schema.columns
                     where table_schema = 'public' and table_name = 'app_users_audit'$q$));
  perform pg_temp.vr_eq('F','app_users_audit 已啟用 RLS 且只有 1 條 policy（客服部讀）','true/accounts_audit_select_cs',
    pg_temp.vr_q1($q$select c.relrowsecurity::text || '/' || (select string_agg(policyname, ',')
                       from pg_policies where schemaname = 'public' and tablename = 'app_users_audit')
                     from pg_class c where c.oid = 'public.app_users_audit'::regclass$q$));
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
    execute 'deallocate accounts_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare accounts_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過') || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  -- 保險：結果表組不出來也不要讓交易停在中斷狀態，後面的 rollback 一定要能執行；
  -- 改存一則說明訊息（下面備援的 select 仍會顯示結果）
  begin
    execute 'deallocate accounts_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare accounts_vr_out as select '
          || quote_literal('結果表輸出失敗（資料仍會 rollback）：' || sqlerrm) || '::text as "訊息"';
end
$$;

-- 備援：rollback 前先顯示一次（若畫面出現兩張一樣的表，看最後一張即可）
select n as "序號", grp || '｜' || name as "測項", expected as "預期", actual as "實際",
       case when pass then '通過' else '失敗' end as "通過"
from pg_temp.vr
order by n;

rollback;

-- rollback 已執行：上面所有假資料與交易內的刪除都不存在了。最後一個結果就是驗證結果表。
execute accounts_vr_out;
