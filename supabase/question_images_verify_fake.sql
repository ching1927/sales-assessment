-- ============================================================
-- 業務考核系統：題組「範例圖片」驗證腳本（只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行（且必須先執行過 question_images_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假帳號（vr-xxx@2motor.tw）／假題組，
--   跑完所有驗證，把結果記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：同 bank_verify_fake.sql——rollback 前先 select 一次備援，rollback 後 execute 預備陳述式
--   qimg_vr_out，所以最後一個結果就是「序號／測項／預期／實際／通過」表；第一列「總結」顯示 N/M 項通過。
-- 假門市代碼 ZZ-Q1、假信箱 vr-cs／vr-hq／vr-sm／vr-nobody@2motor.tw、假分類 ZZ圖片；
--   若真實資料撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 注意：Storage 只驗 policy 內容與「各角色 select／insert／update 的結果」；
--   delete policy 不實際刪檔（Supabase 的 storage.protect_delete 會擋直接 delete storage.objects），
--   只驗 policy 內容，實際刪檔請用 Storage API／儀表板手動驗證。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.question_images') is null
     or to_regprocedure('public.bank_add_question_image(bigint, text, text, bigint)') is null
     or to_regprocedure('public.bank_remove_question_image(uuid)') is null
     or to_regprocedure('public.bank_reorder_question_images(bigint, uuid[])') is null then
    raise exception '請先執行 question_images_schema.sql';
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

-- 以指定資料庫角色＋指定 email 執行一段 SQL（p_scalar＝true 回傳單一值文字，否則成功回 'OK'；失敗回 'ERROR: 訊息'）
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

create or replace function pg_temp.vr_deny(p_grp text, p_name text, p_role text, p_email text, p_sql text, p_pattern text)
returns void language plpgsql as $$
declare
  v_r text := pg_temp.vr_as(p_role, p_email, p_sql, false);
begin
  perform pg_temp.vr_rec(p_grp, p_name, '報錯，訊息含：' || trim(both '%' from p_pattern), v_r,
                         v_r like 'ERROR: ' || p_pattern);
end $$;

-- 客服部身分的捷徑
create or replace function pg_temp.vr_cs(p_sql text, p_scalar boolean default true)
returns text language sql as $$
  select pg_temp.vr_as('authenticated', 'vr-cs@2motor.tw', p_sql, p_scalar);
$$;

create or replace function pg_temp.vr_csdeny(p_grp text, p_name text, p_sql text, p_pattern text)
returns void language sql as $$
  select pg_temp.vr_deny(p_grp, p_name, 'authenticated', 'vr-cs@2motor.tw', p_sql, p_pattern);
$$;

-- 以擁有者身分造一題假題組，回傳 id
create or replace function pg_temp.vr_mkq(p_code text)
returns bigint language plpgsql as $$
declare
  v_id bigint;
begin
  insert into public.questions (category, code, title, steps)
  values ('ZZ圖片', p_code, '假題組' || p_code, '[{"action":"動作","point":"考點"}]'::jsonb)
  returning id into v_id;
  return v_id;
end $$;

-- 產生合法路徑 {題組id}/{uuid}.副檔名
create or replace function pg_temp.vr_path(p_q bigint, p_ext text default 'jpg')
returns text language sql as $$
  select p_q::text || '/' || gen_random_uuid()::text || '.' || p_ext;
$$;

-- 以客服部身分新增一張圖，回傳新圖片 id（失敗回 'ERROR: …'）
create or replace function pg_temp.vr_add(p_q bigint, p_path text, p_mime text default 'image/jpeg', p_size bigint default 1000)
returns text language sql as $$
  select pg_temp.vr_cs(format('select public.bank_add_question_image(%L, %L, %L, %L)::text', p_q, p_path, p_mime, p_size));
$$;

-- 該題目前的圖片順序（以 id 前 8 碼代表），給重排前後比對
create or replace function pg_temp.vr_order(p_q bigint)
returns text language sql as $$
  select coalesce(string_agg(left(id::text, 8) || ':' || sort_order::text, ',' order by sort_order, id), '')
    from public.question_images where question_id = p_q;
$$;

-- ============================================================
-- 建立假資料
-- ============================================================
do $$
begin
  perform set_config('request.jwt.claims', '', true);
  insert into public.stores (code, name) values ('ZZ-Q1', 'ZZ測試門市Q');
  insert into public.app_users (email, role, store_code) values
    ('vr-cs@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw', 'hq_viewer',     null),
    ('vr-sm@2motor.tw', 'store_manager', 'ZZ-Q1');
  perform pg_temp.vr_set('q1', pg_temp.vr_mkq('Q1')::text);
  perform pg_temp.vr_set('q2', pg_temp.vr_mkq('Q2')::text);
  perform pg_temp.vr_set('q3', pg_temp.vr_mkq('Q3')::text);
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：結構（bucket、資料表、函式屬性、權限）
-- ============================================================
do $$
declare
  r record;
begin
  perform pg_temp.vr_eq('1 結構','bucket question-samples：不公開／2MB／三種 mime','false/2097152/image/jpeg,image/png,image/webp',
    (select b.public::text || '/' || b.file_size_limit::text || '/' || array_to_string(b.allowed_mime_types, ',')
       from storage.buckets b where b.id = 'question-samples'));
  perform pg_temp.vr_eq('1 結構','question_images 開了 RLS','true',
    (select relrowsecurity::text from pg_class where oid = 'public.question_images'::regclass));
  perform pg_temp.vr_eq('1 結構','question_images 只有 1 條 policy（select）','1/SELECT',
    (select count(*)::text || '/' || string_agg(cmd, ',') from pg_policies
      where schemaname = 'public' and tablename = 'question_images'));
  perform pg_temp.vr_eq('1 結構','question_images select policy 判斷 cs_admin','true',
    (select (qual like '%cs_admin%')::text from pg_policies
      where schemaname = 'public' and tablename = 'question_images' and policyname = 'question_images_select'));
  perform pg_temp.vr_eq('1 結構','authenticated 對 question_images 只有 select 權限','true/false/false/false',
    (select has_table_privilege('authenticated', 'public.question_images', 'select')::text || '/'
         || has_table_privilege('authenticated', 'public.question_images', 'insert')::text || '/'
         || has_table_privilege('authenticated', 'public.question_images', 'update')::text || '/'
         || has_table_privilege('authenticated', 'public.question_images', 'delete')::text));
  perform pg_temp.vr_eq('1 結構','anon 對 question_images 完全沒權限','false/false/false/false',
    (select has_table_privilege('anon', 'public.question_images', 'select')::text || '/'
         || has_table_privilege('anon', 'public.question_images', 'insert')::text || '/'
         || has_table_privilege('anon', 'public.question_images', 'update')::text || '/'
         || has_table_privilege('anon', 'public.question_images', 'delete')::text));
  perform pg_temp.vr_eq('1 結構','question_id 外鍵 on delete cascade','c',
    (select confdeltype::text from pg_constraint
      where conrelid = 'public.question_images'::regclass and contype = 'f'));
  perform pg_temp.vr_eq('1 結構','storage_path 有唯一約束','true',
    (select exists (select 1 from pg_constraint c
                     where c.conrelid = 'public.question_images'::regclass and c.contype = 'u')::text));

  for r in
    select * from (values
      ('bank_add_question_image',      'public.bank_add_question_image(bigint, text, text, bigint)'),
      ('bank_remove_question_image',   'public.bank_remove_question_image(uuid)'),
      ('bank_reorder_question_images', 'public.bank_reorder_question_images(bigint, uuid[])')
    ) as t(nm, sig)
  loop
    perform pg_temp.vr_eq('1 結構', r.nm || '：security definer＋固定 search_path', 'true/true',
      (select p.prosecdef::text || '/' || (coalesce(p.proconfig::text, '') like '%search_path%')::text
         from pg_proc p where p.oid = r.sig::regprocedure));
    perform pg_temp.vr_eq('1 結構', r.nm || '：先 bank_assert_cs', 'true',
      (select (p.prosrc like '%perform public.bank_assert_cs();%')::text from pg_proc p where p.oid = r.sig::regprocedure));
    perform pg_temp.vr_eq('1 結構', r.nm || '：取同一把 advisory lock', 'true',
      (select (p.prosrc like '%pg_advisory_xact_lock(hashtext(''exam_draw_questions''))%')::text
         from pg_proc p where p.oid = r.sig::regprocedure));
    perform pg_temp.vr_eq('1 結構', r.nm || '：authenticated 可執行、anon 不可', 'true/false',
      has_function_privilege('authenticated', r.sig, 'execute')::text || '/' ||
      has_function_privilege('anon', r.sig, 'execute')::text);
  end loop;

  perform pg_temp.vr_eq('1 結構','bank_list_questions 回傳欄位沒被改動','id:bigint,category:text,code:text,title:text,steps:jsonb,drawn:boolean',
    (select string_agg(a.n || ':' || format_type(a.t, null), ',' order by a.ord)
       from pg_proc p,
            unnest(p.proargnames, p.proallargtypes, p.proargmodes) with ordinality as a(n, t, m, ord)
      where p.oid = 'public.bank_list_questions()'::regprocedure and a.m = 't'));
exception when others then
  perform pg_temp.vr_rec('區段 1','結構檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：身分——只有客服部能呼叫（RPC）；直接讀寫資料表被擋
-- ============================================================
do $$
declare
  v_q1 bigint := pg_temp.vr_get('q1')::bigint;
  v_id text;
  r record;
  v_sql_add text;
  v_sql_rm text;
  v_sql_re text;
  v_sql_ins text;
begin
  -- 客服部先放一張，給其他角色嘗試移除／重排
  v_id := pg_temp.vr_add(v_q1, pg_temp.vr_path(v_q1));
  perform pg_temp.vr_eq('2 身分','客服部新增成功（回傳 uuid）','true', (v_id ~ '^[0-9a-f-]{36}$')::text);

  v_sql_add := format('select public.bank_add_question_image(%L, %L, %L, %L)', v_q1, pg_temp.vr_path(v_q1), 'image/jpeg', 1000);
  v_sql_rm  := format('select public.bank_remove_question_image(%L)', v_id);
  v_sql_re  := format('select public.bank_reorder_question_images(%L, array[%L]::uuid[])', v_q1, v_id);
  v_sql_ins := format('insert into public.question_images (question_id, storage_path, mime, size_bytes, sort_order) values (%L, %L, %L, 1, 9)',
                      v_q1, pg_temp.vr_path(v_q1), 'image/jpeg');

  for r in
    select * from (values
      ('總公司主管', 'authenticated', 'vr-hq@2motor.tw'),
      ('店長',       'authenticated', 'vr-sm@2motor.tw'),
      ('未開通帳號', 'authenticated', 'vr-nobody@2motor.tw'),
      ('沒有 JWT 的 authenticated', 'authenticated', null)
    ) as t(label, rl, email)
  loop
    perform pg_temp.vr_deny('2 身分', r.label || '：新增被擋', r.rl, r.email, v_sql_add, '%沒有權限%');
    perform pg_temp.vr_deny('2 身分', r.label || '：移除被擋', r.rl, r.email, v_sql_rm,  '%沒有權限%');
    perform pg_temp.vr_deny('2 身分', r.label || '：重排被擋', r.rl, r.email, v_sql_re,  '%沒有權限%');
    perform pg_temp.vr_deny('2 身分', r.label || '：直接 insert 被拒', r.rl, r.email, v_sql_ins, '%permission denied%');
    perform pg_temp.vr_deny('2 身分', r.label || '：直接 update 被拒', r.rl, r.email,
      'update public.question_images set sort_order = 99', '%permission denied%');
    perform pg_temp.vr_deny('2 身分', r.label || '：直接 delete 被拒', r.rl, r.email,
      'delete from public.question_images', '%permission denied%');
    perform pg_temp.vr_eq('2 身分', r.label || '：select 看不到任何一張', '0',
      pg_temp.vr_as(r.rl, r.email, 'select count(*)::text from public.question_images', true));
  end loop;

  -- anon：函式 execute 被收回；資料表權限被收回
  perform pg_temp.vr_deny('2 身分','anon：新增被拒','anon',null, v_sql_add, '%permission denied%');
  perform pg_temp.vr_deny('2 身分','anon：移除被拒','anon',null, v_sql_rm,  '%permission denied%');
  perform pg_temp.vr_deny('2 身分','anon：重排被拒','anon',null, v_sql_re,  '%permission denied%');
  perform pg_temp.vr_deny('2 身分','anon：select 被拒','anon',null, 'select count(*) from public.question_images', '%permission denied%');
  perform pg_temp.vr_deny('2 身分','anon：直接 insert 被拒','anon',null, v_sql_ins, '%permission denied%');
  perform pg_temp.vr_deny('2 身分','anon：直接 update 被拒','anon',null, 'update public.question_images set sort_order = 99', '%permission denied%');
  perform pg_temp.vr_deny('2 身分','anon：直接 delete 被拒','anon',null, 'delete from public.question_images', '%permission denied%');

  -- 客服部：select 看得到；直接寫入一樣被拒（只能走函式）
  perform pg_temp.vr_eq('2 身分','客服部：select 看得到 1 張','1',
    pg_temp.vr_cs('select count(*)::text from public.question_images'));
  perform pg_temp.vr_csdeny('2 身分','客服部：直接 insert 被拒', v_sql_ins, '%permission denied%');
  perform pg_temp.vr_csdeny('2 身分','客服部：直接 update 被拒', 'update public.question_images set sort_order = 99', '%permission denied%');
  perform pg_temp.vr_csdeny('2 身分','客服部：直接 delete 被拒', 'delete from public.question_images', '%permission denied%');

  -- 以上被擋的操作都沒有改到資料
  perform pg_temp.vr_eq('2 身分','被擋之後資料不變（仍 1 張、sort_order=1）','1/1',
    (select count(*)::text || '/' || min(sort_order)::text from public.question_images));
exception when others then
  perform pg_temp.vr_rec('區段 2','身分檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：新增的驗證（mime、大小、路徑、重複、題組不存在）與排序
-- ============================================================
do $$
declare
  v_q2 bigint := pg_temp.vr_get('q2')::bigint;
  v_q1 bigint := pg_temp.vr_get('q1')::bigint;
  v_path text;
  v_u text := gen_random_uuid()::text;
begin
  -- 3-1 排序：接在最後
  perform pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'jpg'), 'image/jpeg', 1000);
  perform pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'png'), 'image/png', 2000);
  perform pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'webp'), 'image/webp', 3000);
  perform pg_temp.vr_eq('3 新增','三張依序 sort_order = 1,2,3，mime 與大小照存','1,2,3/image/jpeg,image/png,image/webp/1000,2000,3000',
    (select string_agg(sort_order::text, ',' order by sort_order) || '/' || string_agg(mime, ',' order by sort_order)
            || '/' || string_agg(size_bytes::text, ',' order by sort_order)
       from public.question_images where question_id = v_q2));
  perform pg_temp.vr_eq('3 新增','每題各自排序（q1 的第一張 sort_order 是 1）','1',
    (select min(sort_order)::text from public.question_images where question_id = v_q1));

  -- 3-2 大小
  v_path := pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2), 'image/jpeg', 2097152);
  perform pg_temp.vr_eq('3 新增','大小剛好 2097152 可以（第 4 張，sort_order = 4）','true/4',
    (v_path ~ '^[0-9a-f-]{36}$')::text || '/' ||
    (select max(sort_order)::text from public.question_images where question_id = v_q2));
  perform pg_temp.vr_eq('3 新增','大小 2097153 被拒','ERROR: 圖片大小必須在 2MB 以內',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2), 'image/jpeg', 2097153));
  perform pg_temp.vr_eq('3 新增','大小 0 被拒','ERROR: 圖片大小必須在 2MB 以內',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2), 'image/jpeg', 0));
  perform pg_temp.vr_eq('3 新增','大小負數被拒','ERROR: 圖片大小必須在 2MB 以內',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2), 'image/jpeg', -5));
  perform pg_temp.vr_eq('3 新增','大小 null 被拒','ERROR: 圖片大小必須在 2MB 以內',
    pg_temp.vr_cs(format('select public.bank_add_question_image(%L, %L, %L, null)::text', v_q2, pg_temp.vr_path(v_q2), 'image/jpeg')));

  -- 3-3 mime
  perform pg_temp.vr_eq('3 新增','mime = image/gif 被拒','ERROR: 圖片格式只收 jpg、png、webp',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'jpg'), 'image/gif', 1000));
  perform pg_temp.vr_eq('3 新增','mime = application/pdf 被拒','ERROR: 圖片格式只收 jpg、png、webp',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'jpg'), 'application/pdf', 1000));
  perform pg_temp.vr_eq('3 新增','mime = null 被拒','ERROR: 圖片格式只收 jpg、png、webp',
    pg_temp.vr_cs(format('select public.bank_add_question_image(%L, %L, null, 1000)::text', v_q2, pg_temp.vr_path(v_q2))));
  perform pg_temp.vr_eq('3 新增','副檔名 jpg 但 mime = png 被拒','ERROR: 圖片副檔名與格式不符',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'jpg'), 'image/png', 1000));
  perform pg_temp.vr_eq('3 新增','副檔名 webp 但 mime = jpeg 被拒','ERROR: 圖片副檔名與格式不符',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2, 'webp'), 'image/jpeg', 1000));

  -- 3-4 路徑
  perform pg_temp.vr_eq('3 新增','路徑前綴是別題的 id 被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q1)));
  perform pg_temp.vr_eq('3 新增','路徑沒有題組前綴被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_u || '.jpg'));
  perform pg_temp.vr_eq('3 新增','題組 id 後面多數字（前綴不是完整一段）被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '0/' || v_u || '.jpg'));
  perform pg_temp.vr_eq('3 新增','路徑多一層資料夾被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '/x/' || v_u || '.jpg'));
  perform pg_temp.vr_eq('3 新增','路徑含 ../ 被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '/../' || v_q1::text || '/' || v_u || '.jpg'));
  perform pg_temp.vr_eq('3 新增','副檔名 gif 被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '/' || v_u || '.gif'));
  perform pg_temp.vr_eq('3 新增','副檔名大寫 JPG 被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '/' || v_u || '.JPG'));
  perform pg_temp.vr_eq('3 新增','沒有副檔名被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '/' || v_u));
  perform pg_temp.vr_eq('3 新增','檔名不是 uuid 被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_add(v_q2, v_q2::text || '/photo.jpg'));
  perform pg_temp.vr_eq('3 新增','路徑為空字串被拒','ERROR: 圖片路徑不正確', pg_temp.vr_add(v_q2, ''));
  perform pg_temp.vr_eq('3 新增','路徑為 null 被拒','ERROR: 圖片路徑不正確',
    pg_temp.vr_cs(format('select public.bank_add_question_image(%L, null, %L, 1000)::text', v_q2, 'image/jpeg')));
  perform pg_temp.vr_eq('3 新增','題組 id 為 null 被拒','ERROR: 缺少題組',
    pg_temp.vr_cs(format('select public.bank_add_question_image(null, %L, %L, 1000)::text', pg_temp.vr_path(v_q2), 'image/jpeg')));

  -- 3-5 重複路徑、題組不存在
  select storage_path into v_path from public.question_images where question_id = v_q2 order by sort_order limit 1;
  perform pg_temp.vr_eq('3 新增','同一路徑重複登記被拒','ERROR: 這張圖片已經登記過', pg_temp.vr_add(v_q2, v_path));
  perform pg_temp.vr_eq('3 新增','題組不存在被拒（路徑前綴對得上但題組不存在）','ERROR: 找不到題目：999999999',
    pg_temp.vr_add(999999999, pg_temp.vr_path(999999999)));

  perform pg_temp.vr_eq('3 新增','被拒的新增都沒有寫入（q2 仍 4 張）','4',
    (select count(*)::text from public.question_images where question_id = v_q2));
exception when others then
  perform pg_temp.vr_rec('區段 3','新增驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：張數上限（每題 8 張）
-- ============================================================
do $$
declare
  v_q3 bigint := pg_temp.vr_get('q3')::bigint;
  v_q1 bigint := pg_temp.vr_get('q1')::bigint;
  v_i int;
begin
  for v_i in 1..8 loop
    perform pg_temp.vr_add(v_q3, pg_temp.vr_path(v_q3, (array['jpg','png','webp'])[1 + v_i % 3]),
                           (array['image/jpeg','image/png','image/webp'])[1 + v_i % 3], 100 * v_i);
  end loop;
  perform pg_temp.vr_eq('4 上限','前 8 張都成功','8/1,2,3,4,5,6,7,8',
    (select count(*)::text || '/' || string_agg(sort_order::text, ',' order by sort_order)
       from public.question_images where question_id = v_q3));
  perform pg_temp.vr_eq('4 上限','第 9 張被拒','ERROR: 每個題組最多 8 張範例圖片',
    pg_temp.vr_add(v_q3, pg_temp.vr_path(v_q3)));
  perform pg_temp.vr_eq('4 上限','第 9 張被拒後仍 8 張','8',
    (select count(*)::text from public.question_images where question_id = v_q3));
  perform pg_temp.vr_eq('4 上限','別的題組不受 q3 滿額影響（q1 還能加）','true',
    (pg_temp.vr_add(v_q1, pg_temp.vr_path(v_q1)) ~ '^[0-9a-f-]{36}$')::text);
exception when others then
  perform pg_temp.vr_rec('區段 4','張數上限意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：移除（回傳 path）
-- ============================================================
do $$
declare
  v_q3 bigint := pg_temp.vr_get('q3')::bigint;
  v_id uuid;
  v_path text;
  v_new text;
begin
  select id, storage_path into v_id, v_path from public.question_images where question_id = v_q3 and sort_order = 3;
  perform pg_temp.vr_eq('5 移除','移除回傳該圖的 storage_path','true',
    (pg_temp.vr_cs(format('select public.bank_remove_question_image(%L)', v_id)) = v_path)::text);
  perform pg_temp.vr_eq('5 移除','資料列已刪（q3 剩 7 張，該 id 0 筆）','7/0',
    (select count(*)::text from public.question_images where question_id = v_q3) || '/' ||
    (select count(*)::text from public.question_images where id = v_id));
  perform pg_temp.vr_eq('5 移除','再移除同一張被拒','ERROR: 找不到這張圖片',
    pg_temp.vr_cs(format('select public.bank_remove_question_image(%L)', v_id)));
  perform pg_temp.vr_eq('5 移除','移除不存在的 id 被拒','ERROR: 找不到這張圖片',
    pg_temp.vr_cs(format('select public.bank_remove_question_image(%L)', gen_random_uuid())));
  perform pg_temp.vr_eq('5 移除','移除 null 被拒','ERROR: 找不到這張圖片',
    pg_temp.vr_cs('select public.bank_remove_question_image(null)'));
  -- 滿額後刪一張又能再加；sort_order 接在目前最大值後面（8 之後 = 9），不撞號
  v_new := pg_temp.vr_add(v_q3, pg_temp.vr_path(v_q3));
  perform pg_temp.vr_eq('5 移除','刪一張後可再加，sort_order = 最大值 + 1（9），共 8 張','8/9',
    (select count(*)::text || '/' || max(sort_order)::text from public.question_images where question_id = v_q3));
  perform pg_temp.vr_eq('5 移除','刪除後 sort_order 有缺號但不重複','true',
    (select (count(*) = count(distinct sort_order))::text from public.question_images where question_id = v_q3));
exception when others then
  perform pg_temp.vr_rec('區段 5','移除驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：重排
-- ============================================================
do $$
declare
  v_q1 bigint := pg_temp.vr_get('q1')::bigint;
  v_q2 bigint := pg_temp.vr_get('q2')::bigint;
  v_q3 bigint := pg_temp.vr_get('q3')::bigint;
  v_ids uuid[];
  v_other uuid;
  v_before text;
  v_before_q1 text;
  v_rev uuid[];
  v_q4 bigint;
  v_bad constant text := 'ERROR: 圖片順序不正確：必須恰好包含該題組的全部圖片，且不可重複';
begin
  select array_agg(id order by sort_order) into v_ids from public.question_images where question_id = v_q2;
  select id into v_other from public.question_images where question_id = v_q1 order by sort_order limit 1;
  perform pg_temp.vr_eq('6 重排','q2 目前 4 張','4', cardinality(v_ids)::text);

  -- 合法：反轉
  select array_agg(x order by o desc) into v_rev from unnest(v_ids) with ordinality as t(x, o);
  perform pg_temp.vr_eq('6 重排','合法重排（反轉）成功','OK',
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, v_rev::text), false));
  perform pg_temp.vr_eq('6 重排','重排後順序與傳入一致','true',
    (select (array_agg(id order by sort_order) = v_rev)::text from public.question_images where question_id = v_q2));
  perform pg_temp.vr_eq('6 重排','重排後 sort_order = 1..4','1,2,3,4',
    (select string_agg(sort_order::text, ',' order by sort_order) from public.question_images where question_id = v_q2));
  v_before := pg_temp.vr_order(v_q2);
  v_before_q1 := pg_temp.vr_order(v_q1);

  -- 不合法：每種都應被拒，且順序完全不變
  perform pg_temp.vr_eq('6 重排','少一張被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, (v_ids[1:3])::text)));
  perform pg_temp.vr_eq('6 重排','多一張（別題的圖）被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, (v_ids || v_other)::text)));
  perform pg_temp.vr_eq('6 重排','數量相同但混入別題的圖被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, (v_ids[1:3] || v_other)::text)));
  perform pg_temp.vr_eq('6 重排','重複 id（數量夠但有重複）被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, (v_ids[1:3] || v_ids[1])::text)));
  perform pg_temp.vr_eq('6 重排','不存在的 id 被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, (v_ids[1:3] || gen_random_uuid())::text)));
  perform pg_temp.vr_eq('6 重排','空陣列（該題有圖）被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, '{}')));
  perform pg_temp.vr_eq('6 重排','只傳別題的一張圖被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q2, array[v_other]::text)));
  perform pg_temp.vr_eq('6 重排','null 陣列被拒','ERROR: 圖片順序不正確',
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, null)', v_q2)));
  perform pg_temp.vr_eq('6 重排','題組 id 為 null 被拒','ERROR: 缺少題組',
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(null, %L::uuid[])', v_ids::text)));
  perform pg_temp.vr_eq('6 重排','題組不存在被拒','ERROR: 找不到題目：999999999',
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(999999999, %L::uuid[])', v_ids::text)));
  perform pg_temp.vr_eq('6 重排','被拒的重排都沒有改到順序（q2）','true', (pg_temp.vr_order(v_q2) = v_before)::text);
  perform pg_temp.vr_eq('6 重排','別題的 sort_order 沒被動到（q1）','true', (pg_temp.vr_order(v_q1) = v_before_q1)::text);

  -- 沒有圖的題組：空陣列合法；塞別題的圖被拒
  v_q4 := pg_temp.vr_mkq('Q4');
  perform pg_temp.vr_eq('6 重排','沒有圖的題組：空陣列重排成功','OK',
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q4, '{}'), false));
  perform pg_temp.vr_eq('6 重排','沒有圖的題組：傳入別題的圖被拒', v_bad,
    pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, %L::uuid[])', v_q4, array[v_other]::text)));

  -- 區段 5 讓 q3 有缺號（3 被刪、第 8 張是 9）；重排後壓成連續 1..8
  v_before := pg_temp.vr_cs(format('select public.bank_reorder_question_images(%L, (select array_agg(id order by sort_order desc) from public.question_images where question_id = %L))',
                                   v_q3, v_q3), false);
  perform pg_temp.vr_eq('6 重排','q3 有缺號時重排成功並壓成 1..8','OK/1,2,3,4,5,6,7,8',
    v_before || '/' || (select string_agg(sort_order::text, ',' order by sort_order) from public.question_images where question_id = v_q3));
exception when others then
  perform pg_temp.vr_rec('區段 6','重排驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 7：刪題 cascade
-- ============================================================
do $$
declare
  v_q2 bigint := pg_temp.vr_get('q2')::bigint;
  v_q3 bigint := pg_temp.vr_get('q3')::bigint;
begin
  perform pg_temp.vr_eq('7 cascade','刪題前 q2 有 4 張、q3 有 8 張','4/8',
    (select count(*)::text from public.question_images where question_id = v_q2) || '/' ||
    (select count(*)::text from public.question_images where question_id = v_q3));
  perform pg_temp.vr_eq('7 cascade','客服部 bank_delete_question 刪 q2 成功','OK',
    pg_temp.vr_cs(format('select public.bank_delete_question(%L)', v_q2), false));
  perform pg_temp.vr_eq('7 cascade','q2 的圖片列連帶消失','0',
    (select count(*)::text from public.question_images where question_id = v_q2));
  perform pg_temp.vr_eq('7 cascade','其他題組的圖片不受影響（q3 仍 8 張）','8',
    (select count(*)::text from public.question_images where question_id = v_q3));
  -- 擁有者直接刪題也 cascade
  delete from public.questions where id = v_q3;
  perform pg_temp.vr_eq('7 cascade','直接 delete questions 也 cascade（q3）','0',
    (select count(*)::text from public.question_images where question_id = v_q3));
  perform pg_temp.vr_eq('7 cascade','對已刪除的題組新增被拒','ERROR: 找不到題目：' || v_q2,
    pg_temp.vr_add(v_q2, pg_temp.vr_path(v_q2)));
exception when others then
  perform pg_temp.vr_rec('區段 7','cascade 驗證意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 8：Storage policy（bucket question-samples）
-- ============================================================
do $$
declare
  v_q1 bigint := pg_temp.vr_get('q1')::bigint;
  v_n_ok text := pg_temp.vr_path(pg_temp.vr_get('q1')::bigint, 'jpg');
  v_n_png text := pg_temp.vr_path(pg_temp.vr_get('q1')::bigint, 'png');
  v_n_webp text := pg_temp.vr_path(pg_temp.vr_get('q1')::bigint, 'webp');
  v_q text;
  v_res text;
  r record;
begin
  perform pg_temp.vr_eq('8 Storage','storage.objects 有 3 條 question_samples_* policy（DELETE,INSERT,SELECT）','3/DELETE,INSERT,SELECT',
    (select count(*)::text || '/' || string_agg(cmd, ',' order by cmd)
       from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'question\_samples\_%'));
  perform pg_temp.vr_eq('8 Storage','沒有 UPDATE（或 ALL）policy（檔案不可覆蓋）','0',
    (select count(*)::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects'
        and policyname like 'question\_samples\_%' and cmd in ('UPDATE', 'ALL')));
  perform pg_temp.vr_eq('8 Storage','三條 policy 都限 authenticated、bucket question-samples、且判斷 cs_admin','3',
    (select count(*)::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects' and policyname like 'question\_samples\_%'
        and roles = '{authenticated}'
        and coalesce(qual, '') || coalesce(with_check, '') like '%question-samples%'
        and coalesce(qual, '') || coalesce(with_check, '') like '%cs_admin%'));
  perform pg_temp.vr_eq('8 Storage','insert policy 限制路徑格式（含 jpg|png|webp）','true',
    (select (with_check like '%jpg|png|webp%')::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects' and policyname = 'question_samples_insert'));
  perform pg_temp.vr_eq('8 Storage','assess_notes_* policy 仍恰好 3 條（不被本檔增減）','3',
    (select count(*)::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects' and policyname like 'assess\_notes\_%'));
  perform pg_temp.vr_eq('8 Storage','question_samples_* policy 不含 assess-notes 字樣','0',
    (select count(*)::text from pg_policies
      where schemaname = 'storage' and tablename = 'objects' and policyname like 'question\_samples\_%'
        and coalesce(qual, '') || coalesce(with_check, '') like '%assess-notes%'));

  -- 以擁有者放 3 筆物件（question-samples 2 筆、別的 bucket 1 筆），看各角色看不看得到
  insert into storage.buckets (id, name, public) values ('zz-other', 'zz-other', false) on conflict (id) do nothing;
  insert into storage.objects (bucket_id, name) values
    ('question-samples', v_n_ok), ('question-samples', v_n_png), ('zz-other', v_n_webp);
  v_q := format($q$select count(*)::text from storage.objects where name in (%L,%L,%L)$q$, v_n_ok, v_n_png, v_n_webp);
  for r in
    select * from (values
      ('客服部（只看 question-samples 的 2 筆，看不到別的 bucket）', 'vr-cs@2motor.tw',     '2'),
      ('總公司主管',                                                  'vr-hq@2motor.tw',     '0'),
      ('店長',                                                        'vr-sm@2motor.tw',     '0'),
      ('有登入但沒帳號',                                              'vr-nobody@2motor.tw', '0')
    ) as t(label, email, expected)
  loop
    perform pg_temp.vr_eq('8 Storage', r.label || '：storage.objects 可見筆數', r.expected,
      pg_temp.vr_as('authenticated', r.email, v_q, true));
  end loop;
  perform pg_temp.vr_eq('8 Storage','anon 看不到物件（0 筆或被拒）','true',
    (select (a = '0' or a like 'ERROR:%')::text from (select pg_temp.vr_as('anon', null, v_q, true) as a) s));

  -- insert：只有客服部＋合法路徑＋正確 bucket
  for r in
    select * from (values
      ('客服部＋合法 jpg 路徑',               'authenticated', 'vr-cs@2motor.tw',     'question-samples', pg_temp.vr_path(v_q1, 'jpg'),  'OK'),
      ('客服部＋合法 png 路徑',               'authenticated', 'vr-cs@2motor.tw',     'question-samples', pg_temp.vr_path(v_q1, 'png'),  'OK'),
      ('客服部＋合法 webp 路徑',              'authenticated', 'vr-cs@2motor.tw',     'question-samples', pg_temp.vr_path(v_q1, 'webp'), 'OK'),
      ('客服部＋副檔名 gif 被拒',             'authenticated', 'vr-cs@2motor.tw',     'question-samples', v_q1::text || '/' || gen_random_uuid()::text || '.gif', 'ERROR'),
      ('客服部＋檔名不是 uuid 被拒',          'authenticated', 'vr-cs@2motor.tw',     'question-samples', v_q1::text || '/photo.jpg', 'ERROR'),
      ('客服部＋少一層（沒有題組資料夾）被拒', 'authenticated', 'vr-cs@2motor.tw',     'question-samples', gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('客服部＋多一層路徑被拒',              'authenticated', 'vr-cs@2motor.tw',     'question-samples', v_q1::text || '/x/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('客服部＋題組資料夾不是數字被拒',      'authenticated', 'vr-cs@2motor.tw',     'question-samples', 'abc/' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('客服部＋路徑含 ../ 被拒',             'authenticated', 'vr-cs@2motor.tw',     'question-samples', v_q1::text || '/../' || gen_random_uuid()::text || '.jpg', 'ERROR'),
      ('客服部＋寫進別的 bucket 被拒（沒有對應 policy）', 'authenticated', 'vr-cs@2motor.tw', 'zz-other', pg_temp.vr_path(v_q1, 'jpg'), 'ERROR'),
      ('總公司主管＋合法路徑也被拒',          'authenticated', 'vr-hq@2motor.tw',     'question-samples', pg_temp.vr_path(v_q1, 'jpg'),  'ERROR'),
      ('店長＋合法路徑也被拒',                'authenticated', 'vr-sm@2motor.tw',     'question-samples', pg_temp.vr_path(v_q1, 'jpg'),  'ERROR'),
      ('有登入但沒帳號＋合法路徑被拒',        'authenticated', 'vr-nobody@2motor.tw', 'question-samples', pg_temp.vr_path(v_q1, 'jpg'),  'ERROR'),
      ('未登入 anon＋合法路徑被拒',           'anon',          null,                  'question-samples', pg_temp.vr_path(v_q1, 'jpg'),  'ERROR')
    ) as t(label, rl, email, bucket, path, expected)
  loop
    v_res := pg_temp.vr_as(r.rl, r.email,
      format($q$insert into storage.objects (bucket_id, name) values (%L, %L)$q$, r.bucket, r.path), false);
    perform pg_temp.vr_eq('8 Storage', 'insert policy：' || r.label, r.expected,
      case when v_res like 'ERROR:%' then 'ERROR' else v_res end);
  end loop;

  -- update：沒有 update policy，客服部也改不到任何一列（RLS 讓 update 影響 0 列）
  perform pg_temp.vr_eq('8 Storage','客服部 update storage.objects（question-samples）影響 0 列','0',
    pg_temp.vr_cs($q$with u as (update storage.objects set name = name || 'x' where bucket_id = 'question-samples' returning 1) select count(*)::text from u$q$));
  perform pg_temp.vr_eq('8 Storage','update 之後物件名稱原樣','2',
    (select count(*)::text from storage.objects where bucket_id = 'question-samples' and name in (v_n_ok, v_n_png)));
exception when others then
  perform pg_temp.vr_rec('區段 8','Storage 檢查意外中斷（請改照手動檢查）','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 結果：預備陳述式 qimg_vr_out（rollback 不會讓它消失），再 rollback，最後 execute
-- ============================================================
do $$
declare
  v_total int;
  v_ok int;
  v_rows text;
  v_fail text;
begin
  select count(*), count(*) filter (where pass) into v_total, v_ok from pg_temp.vr;
  select string_agg('#' || f.n, '、' order by f.n) into v_fail
  from (select n from pg_temp.vr where not pass order by n limit 20) f;
  select string_agg(
           format('(%s, %L, %L, %L, %L)',
                  n, grp || '｜' || name, coalesce(expected, ''), coalesce(actual, '(null)'),
                  case when pass then '通過' else '失敗' end),
           ', ' order by n)
    into v_rows from pg_temp.vr;

  begin
    execute 'deallocate qimg_vr_out';
  exception when others then
    null;
  end;

  execute 'prepare qimg_vr_out as select * from (values (0, '
          || quote_literal('總結') || ', ' || quote_literal('全部通過') || ', '
          || quote_literal(v_ok::text || '/' || v_total::text || ' 項通過'
                           || case when v_fail is not null then '；未通過：' || v_fail else '' end) || ', '
          || quote_literal(case when v_ok = v_total then '通過' else '失敗' end)
          || '), ' || v_rows
          || ') as t("序號", "測項", "預期", "實際", "通過") order by 1';
exception when others then
  begin
    execute 'deallocate qimg_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare qimg_vr_out as select '
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
execute qimg_vr_out;
