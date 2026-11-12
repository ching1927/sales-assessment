-- ============================================================
-- 業務考核系統：抽查登記改版（勾可改善面向＋截圖＋說明）驗證腳本
-- （只用假資料，全程 rollback，不留任何資料）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行（且必須先執行過 spotdims_schema.sql，以及 grade3_schema.sql）。
--
-- 怎麼跑：Supabase SQL Editor → New query → 貼上整份 → Run。
-- 做了什麼：begin 之後建立假門市／假員工／假帳號（vr-xxx@2motor.tw），用 set_config('request.jwt.claims', …) ＋
--   set local role 模擬各角色登入，真的呼叫 spot_register_dims（新）與舊 spot_register，
--   並以各角色讀寫 storage.objects（假檔案列，不是真檔案），把每一項斷言的結果記在暫存表，最後 rollback（假資料全部消失）。
-- 怎麼看結果：與 spotcheck_verify_fake.sql 相同——最後一個結果就是「序號／測項／預期／實際／通過」表，
--   第一列「總結」顯示 N/M 項通過；「通過」欄全是「通過」才算驗證成功。若畫面出現兩張一樣的表，看最後一張即可。
-- 假門市代碼 ZZ-D1／ZZ-D2、假員工編號 MI-9701～MI-9710、假信箱 vr-cs1／vr-hq／vr-sm1／vr-sm2／vr-nobody@2motor.tw，
--   若真實資料剛好撞到，腳本會在建立假資料時報錯並停下（rollback 後不影響任何資料）。
-- 刪除（delete）storage.objects 的 policy 只做內容檢查，不實際刪：Supabase 的 storage.protect_delete 會擋直接 delete。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regprocedure('public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])') is null then
    raise exception '請先執行 spotdims_schema.sql';
  end if;
  if to_regprocedure('public.spot_register(text, date, text, jsonb, text, text)') is null then
    raise exception '請先執行 spotcheck_schema.sql';
  end if;
  if public.assess_level_pct('優良') is null then
    raise exception '請先執行 grade3_schema.sql（本腳本的舊紀錄假資料用三級制等級）';
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

-- ============================================================
-- 建立假資料（以資料庫擁有者身分、沒有登入者的狀態直接寫入，rollback 後消失）
-- D1＝ZZ-D1（店長 vr-sm1）、D2＝ZZ-D2（店長 vr-sm2）
-- 9701 主情境  9702 紅單與回考核期  9703 D2 正式  9704 新人  9705 不納入考核  9706 離職  9707 考核期
-- 9708 舊紀錄  9709 輸入驗證  9710 D2 另一位
-- ============================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  perform set_config('request.jwt.claims', '', true);

  insert into public.stores (code, name) values
    ('ZZ-D1', 'ZZ測試門市甲'), ('ZZ-D2', 'ZZ測試門市乙');

  insert into public.employees
    (id, nickname, store_code, job_title, hire_date, status, include_in_assessment, probation_since)
  values
    ('MI-9701', '假員9701', 'ZZ-D1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9702', '假員9702', 'ZZ-D1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9703', '假員9703', 'ZZ-D2', '業務', v_today - 200, '在職', true,  null),
    ('MI-9704', '假員9704', 'ZZ-D1', '業務', v_today - 30,  '在職', true,  null),
    ('MI-9705', '假員9705', 'ZZ-D1', '業務', v_today - 200, '在職', false, null),
    ('MI-9706', '假員9706', 'ZZ-D1', '業務', v_today - 200, '離職', true,  null),
    ('MI-9707', '假員9707', 'ZZ-D1', '業務', v_today - 200, '在職', true,  v_today),
    ('MI-9708', '假員9708', 'ZZ-D1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9709', '假員9709', 'ZZ-D1', '業務', v_today - 200, '在職', true,  null),
    ('MI-9710', '假員9710', 'ZZ-D2', '業務', v_today - 200, '在職', true,  null);

  insert into public.app_users (email, role, store_code) values
    ('vr-cs1@2motor.tw', 'cs_admin',      null),
    ('vr-hq@2motor.tw',  'hq_viewer',     null),
    ('vr-sm1@2motor.tw', 'store_manager', 'ZZ-D1'),
    ('vr-sm2@2motor.tw', 'store_manager', 'ZZ-D2');
  -- vr-nobody@2motor.tw 刻意不建立帳號（模擬有登入但未開通）
exception when others then
  perform pg_temp.vr_rec('建立假資料','建立假資料意外中斷（可能真實資料撞名）','無例外', sqlerrm, false);
end
$$;

-- 實際值符合 like 樣式才通過
create or replace function pg_temp.vr_like(p_grp text, p_name text, p_pattern text, p_actual text)
returns void language plpgsql as $$
begin
  perform pg_temp.vr_rec(p_grp, p_name, '符合：' || trim(both '%' from p_pattern), p_actual, p_actual like p_pattern);
end $$;

-- 讀 storage.objects 的可見筆數（指定角色與信箱）；anon 若連讀取權限都沒有，也算「看不到」（回 0）
create or replace function pg_temp.vr_objcount(p_role text, p_email text, p_path text)
returns text language plpgsql as $$
declare
  v text := pg_temp.vr_as(p_role, p_email,
    format($q$select count(*)::text from storage.objects where bucket_id = 'assess-notes' and name = %L$q$, p_path), true);
begin
  if p_role = 'anon' and v like 'ERROR: %permission denied%' then return '0'; end if;
  return v;
end $$;

-- ============================================================
-- 區段 0：結構（欄位、約束、函式、權限、policy）
-- ============================================================
do $$
begin
  perform pg_temp.vr_eq('0 結構','新增三個欄位都存在（improve_dims／shot_paths 是陣列、improve_note 是文字）','ARRAY/text/ARRAY',
    pg_temp.vr_q1($q$select (select data_type from information_schema.columns where table_schema='public' and table_name='spot_inspections' and column_name='improve_dims')
                         || '/' || (select data_type from information_schema.columns where table_schema='public' and table_name='spot_inspections' and column_name='improve_note')
                         || '/' || (select data_type from information_schema.columns where table_schema='public' and table_name='spot_inspections' and column_name='shot_paths')$q$));

  perform pg_temp.vr_eq('0 結構','levels、total_score 已放寬為可空（新登記不再寫入）','YES/YES',
    pg_temp.vr_q1($q$select (select is_nullable from information_schema.columns where table_schema='public' and table_name='spot_inspections' and column_name='levels')
                         || '/' || (select is_nullable from information_schema.columns where table_schema='public' and table_name='spot_inspections' and column_name='total_score')$q$));

  perform pg_temp.vr_eq('0 結構','四條新約束都存在','4',
    pg_temp.vr_q1($q$select count(*)::text from pg_constraint
                     where conrelid = 'public.spot_inspections'::regclass
                       and conname in ('spot_inspections_dims_valid','spot_inspections_dims_count','spot_inspections_note_len','spot_inspections_shots_count')$q$));

  perform pg_temp.vr_eq('0 結構','新函式與舊 spot_register 都在（舊的不動，舊網頁與舊驗證腳本照常）','2',
    pg_temp.vr_q1($q$select count(to_regprocedure(s))::text from unnest(array[
        'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])',
        'public.spot_register(text, date, text, jsonb, text, text)']) as s$q$));

  perform pg_temp.vr_eq('0 結構','spot_register_dims 是 security definer 且固定 search_path','1',
    pg_temp.vr_q1($q$select count(*)::text from pg_proc p
                     where p.oid = 'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])'::regprocedure
                       and p.prosecdef
                       and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')$q$));

  perform pg_temp.vr_eq('0 結構','spot_register_dims：authenticated 有 execute、anon 沒有','true/false',
    pg_temp.vr_q1($q$select has_function_privilege('authenticated', 'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])', 'execute')::text
                         || '/' || has_function_privilege('anon', 'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])', 'execute')::text$q$));

  perform pg_temp.vr_eq('0 結構','spot_register_dims 內容含 for update（同一個人並發登記會排隊，靜態確認）','true',
    pg_temp.vr_q1($q$select (position('for update' in lower(pg_get_functiondef('public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])'::regprocedure))) > 0)::text$q$));

  perform pg_temp.vr_eq('0 結構','storage.objects 新增 3 條 assess_spot_shots_* policy（DELETE,INSERT,SELECT）','3/DELETE,INSERT,SELECT',
    pg_temp.vr_q1($q$select count(*)::text || '/' || string_agg(cmd, ',' order by cmd) from pg_policies
                     where schemaname = 'storage' and tablename = 'objects' and policyname like 'assess_spot_shots_%'$q$));

  perform pg_temp.vr_eq('0 結構','既有 assess_notes_* 三條 policy 仍在（備註附圖不受影響）','3/DELETE,INSERT,SELECT',
    pg_temp.vr_q1($q$select count(*)::text || '/' || string_agg(cmd, ',' order by cmd) from pg_policies
                     where schemaname = 'storage' and tablename = 'objects' and policyname like 'assess_notes_%'$q$));

  perform pg_temp.vr_eq('0 結構','刪除 policy 只放行「沒有對應抽查」的孤兒檔（內容含 not exists）且限客服部','true/true',
    pg_temp.vr_q1($q$select (qual like '%not (exists%' or qual like '%NOT (EXISTS%')::text || '/' || (qual like '%cs_admin%')::text
                     from pg_policies where schemaname='storage' and tablename='objects' and policyname='assess_spot_shots_delete'$q$));

  perform pg_temp.vr_eq('0 結構','bucket assess-notes 仍是私有、單檔 2MB、只收 jpeg／png／webp（截圖沿用同一組設定）','false/2097152/image/jpeg,image/png,image/webp',
    pg_temp.vr_q1($q$select public::text || '/' || file_size_limit::text || '/' || array_to_string(allowed_mime_types, ',')
                     from storage.buckets where id = 'assess-notes'$q$));
exception when others then
  perform pg_temp.vr_rec('區段 0','結構檢查意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 1：角色權限（只有客服部能登記）
-- ============================================================
do $$
declare
  v_sql text := $q$select public.spot_register_dims(null::uuid, 'MI-9701', current_date, 'https://line.me/R/ti/p/test-1', '適當', null, null::text[], null, null::text[])$q$;
begin
  perform pg_temp.vr_denyset('1 角色權限', 'spot_register_dims', v_sql, 'hsna');
  perform pg_temp.vr_eq('1 角色權限','被拒的呼叫都沒有留下任何抽查（9701 還是 0 筆）','0', pg_temp.vr_ic('MI-9701'));
exception when others then
  perform pg_temp.vr_rec('區段 1','角色權限意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 2：登記（判定、面向、說明、截圖、驗證順序、重複送出）
-- ============================================================
do $$
declare
  v_id1 uuid := gen_random_uuid();
  v_id2 uuid := gen_random_uuid();
  v_id3 uuid := gen_random_uuid();
  v_idx uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_p1 text; v_p2 text; v_p3 text;
  j jsonb;
  v_n text;
  v_paths text[] := '{}';
  i int;
begin
  -- 2-1 優良回覆（資料庫值「適當」）＋勾 2 個面向＋2 張截圖＋說明
  v_p1 := pg_temp.vr_obj(v_id1); v_p2 := pg_temp.vr_obj(v_id1);
  j := pg_temp.vr_regd('MI-9701', '適當', null, array['問題掌握','風險意識'], '客人問保固，回覆沒有附上條款', array[v_p1, v_p2], v_id1);
  perform pg_temp.vr_eq('2 登記','優良回覆＋勾面向＋截圖：成功，回傳面向 2、截圖 2、沒有黃單','2/2/無/無/無',
    coalesce(j ->> 'dims_count', j::text) || '/' || coalesce(j ->> 'shots_count', '?') || '/' || pg_temp.vr_has(j, 'yellow_id')
    || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_set('id1', v_id1::text); perform pg_temp.vr_set('p1', v_p1);
  perform pg_temp.vr_eq('2 登記','存入的抽查：抽查 id＝前端給的、判定仍存「適當」、面向、說明、2 張截圖、登記人','true/適當/問題掌握,風險意識/客人問保固，回覆沒有附上條款/2/vr-cs1@2motor.tw',
    pg_temp.vr_q1(format($q$select (id = %L::uuid)::text || '/' || verdict || '/' || array_to_string(improve_dims, ',') || '/' || improve_note
                                   || '/' || cardinality(shot_paths)::text || '/' || examiner_email
                            from public.spot_inspections where id = %L::uuid$q$, v_id1, v_id1)));
  perform pg_temp.vr_eq('2 登記','新登記不寫七面向等級與分數（levels、total_score、dim_points、weakest_dims 都是 null）','true',
    pg_temp.vr_q1(format($q$select (levels is null and total_score is null and dim_points is null and weakest_dims is null)::text
                            from public.spot_inspections where id = %L::uuid$q$, v_id1)));
  perform pg_temp.vr_eq('2 登記','判定「適當」不開黃單','0', pg_temp.vr_tc('MI-9701', '黃'));

  -- 2-2 優良回覆：什麼都不勾、沒截圖、沒說明、不帶抽查 id（資料庫自己產生）
  j := pg_temp.vr_regd('MI-9701', '適當');
  perform pg_temp.vr_eq('2 登記','最簡登記（沒勾面向、沒截圖、沒說明、不帶 id）可以','有/0/0',
    case when j ? 'error' then j::text else pg_temp.vr_has(j, 'inspection_id') || '/' || (j ->> 'dims_count') || '/' || (j ->> 'shots_count') end);
  perform pg_temp.vr_eq('2 登記','最簡登記存成：面向空陣列、截圖空陣列、說明 null','0/0/true',
    pg_temp.vr_q1(format($q$select cardinality(improve_dims)::text || '/' || cardinality(shot_paths)::text || '/' || (improve_note is null)::text
                            from public.spot_inspections where id = %L::uuid$q$, j ->> 'inspection_id')));

  -- 2-3 待加強回覆（資料庫值「不適當」）：開黃單，原因寫進黃單；也可勾面向與截圖
  v_p3 := pg_temp.vr_obj(v_id2);
  j := pg_temp.vr_regd('MI-9701', '不適當', '沒確認需求就報價', array['資訊正確性','問題掌握','文字品質'], '報價前沒問車款', array[v_p3], v_id2);
  perform pg_temp.vr_set('id2', v_id2::text);
  perform pg_temp.vr_eq('2 登記','待加強回覆：開 1 張黃單，沒有紅單與回考核期','有/無/無',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('2 登記','黃單內容：連到這次抽查、原因同抽查、有效、開單日今天','黃/true/沒確認需求就報價/有效/' || pg_temp.vr_today()::text,
    pg_temp.vr_q1(format($q$select kind || '/' || (inspection_id = %L::uuid)::text || '/' || reason || '/' || status || '/' || issued_on::text
                            from public.spot_tickets where employee_id = 'MI-9701' and kind = '黃'$q$, v_id2)));
  perform pg_temp.vr_eq('2 登記','待加強回覆的抽查：判定存「不適當」、勾了 3 個面向、1 張截圖','不適當/資訊正確性,問題掌握,文字品質/1',
    pg_temp.vr_q1(format($q$select verdict || '/' || array_to_string(improve_dims, ',') || '/' || cardinality(shot_paths)::text
                            from public.spot_inspections where id = %L::uuid$q$, v_id2)));

  -- 2-4 判定與原因的既有規則照舊
  v_n := pg_temp.vr_ic('MI-9701');
  perform pg_temp.vr_eq('2 驗證','待加強回覆沒寫原因被擋','ERROR: 判定待加強回覆時，原因不可空白', pg_temp.vr_regd_t('MI-9701', '不適當'));
  perform pg_temp.vr_eq('2 驗證','待加強回覆原因只有空白（含全形空白）被擋','ERROR: 判定待加強回覆時，原因不可空白', pg_temp.vr_regd_t('MI-9701', '不適當', E' \t' || chr(12288)));
  perform pg_temp.vr_eq('2 驗證','判定不是「適當／不適當」被擋（訊息用新名稱）','ERROR: 判定必須是「優良回覆」或「待加強回覆」', pg_temp.vr_regd_t('MI-9701', '優良回覆'));
  perform pg_temp.vr_eq('2 驗證','判定空白被擋','ERROR: 判定必須是「優良回覆」或「待加強回覆」', pg_temp.vr_regd_t('MI-9701', null));
  perform pg_temp.vr_eq('2 驗證','抽查日期空白被擋','ERROR: 抽查日期不可空白',
    pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      $q$select public.spot_register_dims(null::uuid, 'MI-9701', null::date, 'https://line.me/R/ti/p/test-1', '適當', null, null::text[], null, null::text[])$q$, false)
      || '');
  perform pg_temp.vr_eq('2 驗證','被擋的登記都沒有留下抽查或黃單（筆數不變）', v_n || '/1', pg_temp.vr_ic('MI-9701') || '/' || pg_temp.vr_tc('MI-9701', '黃'));

  -- 2-5 可改善面向
  perform pg_temp.vr_eq('2 面向','七個面向全勾可以（回傳面向 7）','7', coalesce(pg_temp.vr_regd('MI-9701', '適當', null, array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識','語氣與禮貌','文字品質']) ->> 'dims_count', 'ERR'));
  perform pg_temp.vr_like('2 面向','面向名稱不在七面向內被擋','ERROR: 可改善面向「亂寫」不是七面向之一%', pg_temp.vr_regd_t('MI-9701', '適當', null, array['亂寫']));
  perform pg_temp.vr_like('2 面向','面向含空值被擋','ERROR: 可改善面向「(空)」不是七面向之一%', pg_temp.vr_regd_t('MI-9701', '適當', null, array['問題掌握', null]));
  perform pg_temp.vr_eq('2 面向','面向重複勾被擋','ERROR: 可改善面向不可重複勾選', pg_temp.vr_regd_t('MI-9701', '適當', null, array['問題掌握','問題掌握']));
  perform pg_temp.vr_eq('2 面向','面向傳空陣列可以（等於沒勾）','OK', pg_temp.vr_regd_t('MI-9701', '適當', null, '{}'::text[]));

  -- 2-6 說明
  j := pg_temp.vr_regd('MI-9701', '適當', null, null, E'  有空白的說明　 ');
  perform pg_temp.vr_eq('2 說明','說明去頭尾空白（含全形）後存入','有空白的說明',
    pg_temp.vr_q1(format($q$select improve_note from public.spot_inspections where id = %L::uuid$q$, j ->> 'inspection_id')));
  j := pg_temp.vr_regd('MI-9701', '適當', null, null, E'   　 ');
  perform pg_temp.vr_eq('2 說明','說明只有空白視為沒填（存 null）','true',
    pg_temp.vr_q1(format($q$select (improve_note is null)::text from public.spot_inspections where id = %L::uuid$q$, j ->> 'inspection_id')));
  perform pg_temp.vr_eq('2 說明','說明剛好 500 字可以','OK', pg_temp.vr_regd_t('MI-9701', '適當', null, null, repeat('字', 500)));
  perform pg_temp.vr_eq('2 說明','說明 501 字被擋','ERROR: 說明最多 500 字', pg_temp.vr_regd_t('MI-9701', '適當', null, null, repeat('字', 501)));

  -- 2-7 截圖
  perform pg_temp.vr_eq('2 截圖','截圖資料夾不是這次的抽查 id 被擋','ERROR: 截圖路徑不正確',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, array[pg_temp.vr_obj(v_other)], v_idx));
  perform pg_temp.vr_eq('2 截圖','截圖副檔名不是 jpg／png／webp 被擋','ERROR: 截圖路徑不正確',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, array['spot/' || v_idx::text || '/' || gen_random_uuid()::text || '.gif'], v_idx));
  perform pg_temp.vr_eq('2 截圖','截圖路徑不是 spot/ 開頭（想塞別人的備註附圖）被擋','ERROR: 截圖路徑不正確',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, array[v_idx::text || '/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg'], v_idx));
  perform pg_temp.vr_eq('2 截圖','截圖路徑格式對但檔案沒上傳被擋','ERROR: 有截圖還沒上傳成功，請重新選取截圖後再送出',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, array['spot/' || v_idx::text || '/' || gen_random_uuid()::text || '.jpg'], v_idx));
  perform pg_temp.vr_eq('2 截圖','有截圖卻沒帶抽查 id 被擋','ERROR: 有截圖時必須帶抽查編號',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, array['spot/' || v_idx::text || '/' || gen_random_uuid()::text || '.jpg'], null));
  v_p1 := pg_temp.vr_obj(v_idx);
  perform pg_temp.vr_eq('2 截圖','同一張截圖列兩次被擋','ERROR: 截圖不可重複',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, array[v_p1, v_p1], v_idx));
  for i in 1 .. 11 loop v_paths := v_paths || pg_temp.vr_obj(v_idx); end loop;
  perform pg_temp.vr_eq('2 截圖','11 張截圖被擋','ERROR: 截圖最多 10 張', pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, v_paths, v_idx));
  perform pg_temp.vr_eq('2 截圖','剛好 10 張截圖可以','10', coalesce(pg_temp.vr_regd('MI-9701', '適當', null, null, null, v_paths[1:10], v_idx) ->> 'shots_count', 'ERR'));

  -- 2-8 擋重複送出：同一個抽查 id 只能登記一次
  perform pg_temp.vr_eq('2 重複送出','同一個抽查 id 再登記一次被擋','ERROR: 這次抽查已經登記過了，請重新整理頁面確認，不要重複送出',
    pg_temp.vr_regd_t('MI-9701', '不適當', '重複送出', null, null, null, v_id1));
  perform pg_temp.vr_eq('2 重複送出','重複送出沒有多開黃單（9701 仍是 1 張）、同一個 id 只有 1 筆抽查','1/1',
    pg_temp.vr_tc('MI-9701', '黃') || '/' || pg_temp.vr_q1(format($q$select count(*)::text from public.spot_inspections where id = %L::uuid$q$, v_id1)));

  -- 2-9 網址驗證排在最後；失敗的登記不留任何資料
  v_n := pg_temp.vr_ic('MI-9701');
  perform pg_temp.vr_eq('2 網址','網址不合格被擋（沿用既有訊息）','ERROR: 請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, null, null, 'line.me/abc'));
  perform pg_temp.vr_eq('2 網址','網址空白被擋','ERROR: 請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）',
    pg_temp.vr_regd_t('MI-9701', '適當', null, null, null, null, null, '   '));
  perform pg_temp.vr_eq('2 網址','面向與網址同時有錯：先報面向（網址排在其他驗證之後）','ERROR: 可改善面向不可重複勾選',
    pg_temp.vr_regd_t('MI-9701', '適當', null, array['問題掌握','問題掌握'], null, null, null, 'x'));
  perform pg_temp.vr_eq('2 網址','網址頭尾空白會去掉後存入','https://line.me/R/ti/p/test-1',
    pg_temp.vr_q1(format($q$select message from public.spot_inspections where id = %L::uuid$q$,
      (pg_temp.vr_regd('MI-9701', '適當', null, null, null, null, null, E'  https://line.me/R/ti/p/test-1 　') ->> 'inspection_id'))));
  perform pg_temp.vr_eq('2 網址','網址被擋的登記沒有留下抽查（筆數只因上一項成功的那筆 +1）', (v_n::int + 1)::text, pg_temp.vr_ic('MI-9701'));

  -- 2-10 抽查對象資格（與舊 spot_register 相同的訊息）
  perform pg_temp.vr_eq('2 資格','新人不能抽查','ERROR: 該員工是新人（到職日起 90 天內），不能抽查', pg_temp.vr_regd_t('MI-9704', '適當'));
  perform pg_temp.vr_eq('2 資格','不納入考核不能抽查','ERROR: 該員工不在考核名單（需納入考核），不能抽查', pg_temp.vr_regd_t('MI-9705', '適當'));
  perform pg_temp.vr_eq('2 資格','離職不能抽查','ERROR: 該員工已離職，不能抽查', pg_temp.vr_regd_t('MI-9706', '適當'));
  perform pg_temp.vr_eq('2 資格','考核期不能抽查','ERROR: 該員工目前在考核期，不能抽查', pg_temp.vr_regd_t('MI-9707', '適當'));
  perform pg_temp.vr_eq('2 資格','找不到員工','ERROR: 找不到員工：MI-0000', pg_temp.vr_regd_t('MI-0000', '適當'));
  perform pg_temp.vr_eq('2 資格','以上資格不符的登記都沒有留下資料','0/0/0/0',
    pg_temp.vr_ic('MI-9704') || '/' || pg_temp.vr_ic('MI-9705') || '/' || pg_temp.vr_ic('MI-9706') || '/' || pg_temp.vr_ic('MI-9707'));

  -- 2-11 D2 門市的人也登記一筆（含截圖），供後面的權限測試用
  v_other := gen_random_uuid();
  j := pg_temp.vr_regd('MI-9703', '適當', null, array['語氣與禮貌'], '語氣可再親切', array[pg_temp.vr_obj(v_other)], v_other);
  perform pg_temp.vr_set('id_d2', v_other::text);
  perform pg_temp.vr_eq('2 登記','D2 門市的抽查登記成功','1/1', coalesce(j ->> 'dims_count', j::text) || '/' || coalesce(j ->> 'shots_count', '?'));
exception when others then
  perform pg_temp.vr_rec('區段 2','登記意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 3：黃單 → 紅單 → 回考核期（規則與舊 spot_register 完全相同）
--   9702 走新函式、9709 走舊函式，各登記 4＋1＋5 次待加強回覆，結果指紋逐項相同
-- ============================================================
do $$
declare
  j jsonb;
  i int;
  v_new text; v_old text;
  v_lv jsonb := pg_temp.vr_mk('待加強','尚可','優良','優良','尚可','優良','優良');
begin
  -- 新函式：先 1 次優良回覆（勾了面向）不算黃單
  j := pg_temp.vr_regd('MI-9702', '適當', null, array['問題掌握']);
  perform pg_temp.vr_eq('3 規則','先登記 1 次優良回覆（有勾面向）不算黃單','0', pg_temp.vr_tc('MI-9702', '黃'));

  for i in 1 .. 4 loop j := pg_temp.vr_regd('MI-9702', '不適當', '假原因' || i, array['問題掌握']); end loop;
  perform pg_temp.vr_eq('3 規則','累積 4 張有效黃單，不開紅單','4/0/無', pg_temp.vr_tc('MI-9702', '黃') || '/' || pg_temp.vr_tc('MI-9702', '紅') || '/' || pg_temp.vr_has(j, 'red_id'));

  j := pg_temp.vr_regd('MI-9702', '不適當', '第五張', array['風險意識']);
  perform pg_temp.vr_eq('3 規則','第 5 張有效黃單：同一次呼叫自動開紅單；還不到回考核期','有/有/無',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('3 規則','紅單：種類／狀態／開單日／湊成它的黃單 5 張／沒有抽查連結','紅/有效/' || pg_temp.vr_today()::text || '/5/無',
    pg_temp.vr_q1(format($q$select kind || '/' || status || '/' || issued_on::text || '/' || array_length(source_ticket_ids, 1)::text || '/'
                                   || case when inspection_id is null then '無' else '有' end
                            from public.spot_tickets where id = %L::uuid$q$, j ->> 'red_id')));

  for i in 1 .. 4 loop j := pg_temp.vr_regd('MI-9702', '不適當', '二輪' || i); end loop;
  j := pg_temp.vr_regd('MI-9702', '不適當', '二輪第五張');
  perform pg_temp.vr_eq('3 規則','第二張紅單：同次呼叫開回考核期（待執行）','有/有/有',
    pg_temp.vr_has(j, 'yellow_id') || '/' || pg_temp.vr_has(j, 'red_id') || '/' || pg_temp.vr_has(j, 'probation_id'));
  perform pg_temp.vr_eq('3 規則','員工被拉回考核期：probation_since＝今天、period_status＝考核期','true/考核期',
    pg_temp.vr_q1($q$select (probation_since = (now() at time zone 'Asia/Taipei')::date)::text || '/' || period_status from public.employees where id = 'MI-9702'$q$));
  perform pg_temp.vr_eq('3 規則','回考核期後不能再抽查','ERROR: 該員工目前在考核期，不能抽查', pg_temp.vr_regd_t('MI-9702', '適當'));

  -- 舊函式：同一組情境（新等級字串），指紋要與新函式相同
  for i in 1 .. 4 loop
    perform pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select public.spot_register('MI-9709', current_date, 'https://line.me/R/ti/p/test-1', %L::jsonb, '不適當', %L)$q$, v_lv::text, '舊' || i), true);
  end loop;
  perform pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select public.spot_register('MI-9709', current_date, 'https://line.me/R/ti/p/test-1', %L::jsonb, '適當', null)$q$, v_lv::text), true);
  for i in 1 .. 6 loop
    perform pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
      format($q$select public.spot_register('MI-9709', current_date, 'https://line.me/R/ti/p/test-1', %L::jsonb, '不適當', %L)$q$, v_lv::text, '舊二' || i), true);
  end loop;
  -- 指紋：黃單數／紅單數／回考核期狀態／period_status／probation_since 是否有值
  v_new := pg_temp.vr_q1($q$select (select count(*) from public.spot_tickets where employee_id='MI-9702' and kind='黃')::text || '/'
        || (select count(*) from public.spot_tickets where employee_id='MI-9702' and kind='紅')::text || '/'
        || coalesce((select status from public.spot_probations where employee_id='MI-9702'), '無') || '/'
        || (select period_status from public.employees where id='MI-9702') || '/'
        || (select (probation_since is not null)::text from public.employees where id='MI-9702')$q$);
  v_old := pg_temp.vr_q1($q$select (select count(*) from public.spot_tickets where employee_id='MI-9709' and kind='黃')::text || '/'
        || (select count(*) from public.spot_tickets where employee_id='MI-9709' and kind='紅')::text || '/'
        || coalesce((select status from public.spot_probations where employee_id='MI-9709'), '無') || '/'
        || (select period_status from public.employees where id='MI-9709') || '/'
        || (select (probation_since is not null)::text from public.employees where id='MI-9709')$q$);
  perform pg_temp.vr_eq('3 規則','新函式（9702）的黃單／紅單／回考核期結果指紋', '10/2/待執行/考核期/true', v_new);
  perform pg_temp.vr_eq('3 規則','新函式與舊函式（9709）走同一組情境，結果指紋相同', v_old, v_new);
exception when others then
  perform pg_temp.vr_rec('區段 3','紅單與回考核期意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 4：舊抽查紀錄不動、新舊並存仍可正常讀
-- ============================================================
do $$
declare
  v_lv jsonb := pg_temp.vr_mk('待加強','尚可','優良','優良','尚可','優良','優良');
  v_before text;
  v_old_id text;
  j jsonb;
begin
  -- 9708 先用舊函式登記一筆舊制紀錄（有七面向等級與分數）
  v_old_id := pg_temp.vr_as('authenticated', 'vr-cs1@2motor.tw',
    format($q$select (public.spot_register('MI-9708', current_date, 'https://line.me/R/ti/p/test-1', %L::jsonb, '不適當', '舊制原因') ->> 'inspection_id')$q$, v_lv::text), true);
  perform pg_temp.vr_set('old_id', v_old_id);
  perform pg_temp.vr_eq('4 舊紀錄','舊紀錄有七面向等級與分數（舊函式仍可用）、面向／截圖欄位是預設空值','true/true/0/0',
    pg_temp.vr_q1(format($q$select (levels is not null)::text || '/' || (total_score is not null)::text || '/' || cardinality(improve_dims)::text || '/' || cardinality(shot_paths)::text
                            from public.spot_inspections where id = %L::uuid$q$, v_old_id)));
  v_before := pg_temp.vr_q1(format($q$select md5(row_to_json(s)::text) from public.spot_inspections s where id = %L::uuid$q$, v_old_id));
  perform pg_temp.vr_set('old_md5', v_before);

  -- 同一個人再用新函式登記幾筆
  j := pg_temp.vr_regd('MI-9708', '不適當', '新制原因', array['問題掌握'], '新制說明');
  j := pg_temp.vr_regd('MI-9708', '適當', null, array['風險意識']);
  perform pg_temp.vr_eq('4 舊紀錄','新登記後，舊紀錄整列內容完全沒變（md5 相同）', v_before,
    pg_temp.vr_q1(format($q$select md5(row_to_json(s)::text) from public.spot_inspections s where id = %L::uuid$q$, v_old_id)));
  perform pg_temp.vr_eq('4 舊紀錄','舊紀錄的判定仍是資料庫值「不適當」（沒有遷移成新名稱）','不適當',
    pg_temp.vr_q1(format($q$select verdict from public.spot_inspections where id = %L::uuid$q$, v_old_id)));
  perform pg_temp.vr_eq('4 新紀錄','所有用新函式登記的抽查，都沒有等級與分數（9701、9702、9703、9708 的新紀錄）','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_inspections
                     where employee_id in ('MI-9701','MI-9702','MI-9703') and (levels is not null or total_score is not null or dim_points is not null or weakest_dims is not null)$q$));
  perform pg_temp.vr_eq('4 新紀錄','資料庫存的判定值只有「適當」「不適當」兩種（沒有出現新名稱）','0',
    pg_temp.vr_q1($q$select count(*)::text from public.spot_inspections where store_code like 'ZZ-D%' and verdict not in ('適當', '不適當')$q$));

  -- 新舊並存：店長、主管、客服部都讀得到（含新欄位）；舊紀錄的 total_score 有值、新紀錄為 null
  perform pg_temp.vr_eq('4 並存','店長 D1 以新欄位清單讀抽查（含舊紀錄）成功，舊紀錄 total_score 有值、新紀錄為 null','true',
    pg_temp.vr_as('authenticated', 'vr-sm1@2motor.tw',
      format($q$select ((select count(*) from public.spot_inspections where id = %L::uuid and total_score is not null) = 1
                       and (select count(*) from public.spot_inspections where employee_id = 'MI-9708' and total_score is null) = 2)::text$q$, v_old_id), true));
  perform pg_temp.vr_eq('4 並存','總公司主管讀得到舊紀錄與新欄位','1',
    pg_temp.vr_as('authenticated', 'vr-hq@2motor.tw',
      format($q$select count(*)::text from public.spot_inspections where id = %L::uuid and improve_dims is not null and shot_paths is not null$q$, v_old_id), true));
exception when others then
  perform pg_temp.vr_rec('區段 4','舊紀錄意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 5：可見範圍（RLS）與 Storage 截圖權限
-- ============================================================
do $$
declare
  cs text := 'vr-cs1@2motor.tw';
  hq text := 'vr-hq@2motor.tw';
  sm1 text := 'vr-sm1@2motor.tw';
  sm2 text := 'vr-sm2@2motor.tw';
  nb text := 'vr-nobody@2motor.tw';
  v_d1 text := pg_temp.vr_get('p1');                                   -- D1 門市那筆抽查的截圖
  v_d2 text;
  v_orphan text := 'spot/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg';
  v_new uuid := gen_random_uuid();
  v_newp text;
begin
  select o.name into v_d2 from storage.objects o where o.name like 'spot/' || pg_temp.vr_get('id_d2') || '/%' limit 1;
  insert into storage.objects (bucket_id, name) values ('assess-notes', v_orphan);

  -- 抽查表可見範圍（新欄位）
  perform pg_temp.vr_cmp('5 可見範圍','spot_inspections：客服部看到全部（假資料）','authenticated', cs,
    $q$select count(*)::text from public.spot_inspections where store_code like 'ZZ-D%'$q$, $q$select count(*)::text from public.spot_inspections where store_code like 'ZZ-D%'$q$);
  perform pg_temp.vr_cmp('5 可見範圍','spot_inspections：總公司主管看到全部（假資料）','authenticated', hq,
    $q$select count(*)::text from public.spot_inspections where store_code like 'ZZ-D%'$q$, $q$select count(*)::text from public.spot_inspections where store_code like 'ZZ-D%'$q$);
  perform pg_temp.vr_cmp('5 可見範圍','spot_inspections：店長 D1 只看到自己門市','authenticated', sm1,
    'select count(*)::text from public.spot_inspections', $q$select count(*)::text from public.spot_inspections where store_code = 'ZZ-D1'$q$);
  perform pg_temp.vr_cmp('5 可見範圍','spot_inspections：店長 D2 只看到自己門市','authenticated', sm2,
    'select count(*)::text from public.spot_inspections', $q$select count(*)::text from public.spot_inspections where store_code = 'ZZ-D2'$q$);
  perform pg_temp.vr_eq('5 可見範圍','D1 與 D2 都有抽查（上面比對不是空轉）','true',
    pg_temp.vr_q1($q$select ((select count(*) from public.spot_inspections where store_code='ZZ-D1') > 0 and (select count(*) from public.spot_inspections where store_code='ZZ-D2') > 0)::text$q$));
  perform pg_temp.vr_eq('5 可見範圍','有登入但未開通帳號看不到任何抽查','0', pg_temp.vr_as('authenticated', nb, 'select count(*)::text from public.spot_inspections', true));
  perform pg_temp.vr_deny('5 可見範圍','未登入（anon）讀抽查被拒','anon', null, 'select count(*) from public.spot_inspections', '%permission denied%');
  perform pg_temp.vr_eq('5 可見範圍','店長 D2 以抽查 id 直接查 D1 的抽查（含面向與截圖路徑）是 0 筆','0',
    pg_temp.vr_as('authenticated', sm2, format($q$select count(*)::text from public.spot_inspections where id = %L::uuid$q$, pg_temp.vr_get('id1')), true));
  perform pg_temp.vr_eq('5 可見範圍','店長 D1 讀得到自己門市抽查的面向與截圖路徑','問題掌握,風險意識/2',
    pg_temp.vr_as('authenticated', sm1, format($q$select array_to_string(improve_dims, ',') || '/' || cardinality(shot_paths)::text from public.spot_inspections where id = %L::uuid$q$, pg_temp.vr_get('id1')), true));

  perform pg_temp.vr_deny('5 直接寫入','客服部直接 insert 抽查（含新欄位）被拒','authenticated', cs,
    $q$insert into public.spot_inspections (employee_id, employee_label, store_code, checked_on, verdict, examiner_email, improve_dims)
       values ('MI-9701', 'x', 'ZZ-D1', current_date, '適當', 'vr-cs1@2motor.tw', array['問題掌握'])$q$, '%permission denied%');
  perform pg_temp.vr_deny('5 直接寫入','客服部直接 update 面向欄位被拒','authenticated', cs,
    $q$update public.spot_inspections set improve_dims = '{}'$q$, '%permission denied%');

  -- Storage 讀：截圖
  perform pg_temp.vr_eq('5 Storage 讀','D1 的截圖：客服部讀得到','1', pg_temp.vr_objcount('authenticated', cs, v_d1));
  perform pg_temp.vr_eq('5 Storage 讀','D1 的截圖：總公司主管讀得到','1', pg_temp.vr_objcount('authenticated', hq, v_d1));
  perform pg_temp.vr_eq('5 Storage 讀','D1 的截圖：D1 店長讀得到','1', pg_temp.vr_objcount('authenticated', sm1, v_d1));
  perform pg_temp.vr_eq('5 Storage 讀','D1 的截圖：D2 店長讀不到','0', pg_temp.vr_objcount('authenticated', sm2, v_d1));
  perform pg_temp.vr_eq('5 Storage 讀','D1 的截圖：未開通帳號讀不到','0', pg_temp.vr_objcount('authenticated', nb, v_d1));
  perform pg_temp.vr_eq('5 Storage 讀','D1 的截圖：未登入（anon）讀不到','0', pg_temp.vr_objcount('anon', null, v_d1));
  perform pg_temp.vr_eq('5 Storage 讀','D2 的截圖：D2 店長讀得到、D1 店長讀不到','1/0',
    pg_temp.vr_objcount('authenticated', sm2, v_d2) || '/' || pg_temp.vr_objcount('authenticated', sm1, v_d2));
  perform pg_temp.vr_eq('5 Storage 讀','沒有對應抽查的孤兒檔：客服部看得到、主管與店長看不到','1/0/0',
    pg_temp.vr_objcount('authenticated', cs, v_orphan) || '/' || pg_temp.vr_objcount('authenticated', hq, v_orphan) || '/' || pg_temp.vr_objcount('authenticated', sm1, v_orphan));

  -- Storage 傳：只有客服部、路徑格式要對、抽查 id 還不存在
  v_newp := 'spot/' || v_new::text || '/' || gen_random_uuid()::text || '.png';
  perform pg_temp.vr_ok('5 Storage 傳','客服部上傳路徑正確、抽查尚未登記的截圖可以', cs,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, v_newp));
  perform pg_temp.vr_deny('5 Storage 傳','總公司主管上傳被拒','authenticated', hq,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spot/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg'), '%row-level security%');
  perform pg_temp.vr_deny('5 Storage 傳','店長上傳被拒','authenticated', sm1,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spot/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg'), '%row-level security%');
  perform pg_temp.vr_deny('5 Storage 傳','未開通帳號上傳被拒','authenticated', nb,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spot/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg'), '%row-level security%');
  perform pg_temp.vr_eq('5 Storage 傳','未登入（anon）上傳被拒（無權限或被安全規則擋下）','true',
    (pg_temp.vr_as('anon', null,
      format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spot/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg'), false)
     like 'ERROR: %')::text);
  perform pg_temp.vr_deny('5 Storage 傳','客服部上傳路徑格式不對（資料夾不是 uuid）被拒','authenticated', cs,
    $q$insert into storage.objects (bucket_id, name) values ('assess-notes', 'spot/abc/def.jpg')$q$, '%row-level security%');
  perform pg_temp.vr_deny('5 Storage 傳','客服部上傳 gif 被拒','authenticated', cs,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spot/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.gif'), '%row-level security%');
  perform pg_temp.vr_deny('5 Storage 傳','客服部不能把圖塞進「已登記」抽查的資料夾','authenticated', cs,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spot/' || pg_temp.vr_get('id1') || '/' || gen_random_uuid()::text || '.jpg'), '%row-level security%');
  perform pg_temp.vr_deny('5 Storage 傳','客服部不能用 spot/ 路徑冒充備註附圖路徑（第一段要是 spot）','authenticated', cs,
    format($q$insert into storage.objects (bucket_id, name) values ('assess-notes', %L)$q$, 'spotx/' || gen_random_uuid()::text || '/' || gen_random_uuid()::text || '.jpg'), '%row-level security%');
exception when others then
  perform pg_temp.vr_rec('區段 5','可見範圍意外中斷','無例外', sqlerrm, false);
end
$$;

-- ============================================================
-- 區段 6：資料完整性（約束：直接以擁有者身分寫入也擋得住）
-- ============================================================
do $$
declare
  v_base text := $q$insert into public.spot_inspections (employee_id, employee_label, store_code, checked_on, verdict, examiner_email, %s) values ('MI-9710', 'x', 'ZZ-D2', current_date, '適當', 'vr-cs1@2motor.tw', %s)$q$;
begin
  perform pg_temp.vr_ownerr('6 完整性','面向名稱不在七面向內，資料庫直接擋', format(v_base, 'improve_dims', $v$array['亂寫']$v$), '%spot_inspections_dims_valid%');
  perform pg_temp.vr_ownerr('6 完整性','面向超過 7 個（重複勾），資料庫直接擋', format(v_base, 'improve_dims', $v$array['問題掌握','問題掌握','問題掌握','問題掌握','問題掌握','問題掌握','問題掌握','問題掌握']$v$), '%spot_inspections_dims_count%');
  perform pg_temp.vr_ownerr('6 完整性','說明超過 500 字，資料庫直接擋', format(v_base, 'improve_note', quote_literal(repeat('字', 501))), '%spot_inspections_note_len%');
  perform pg_temp.vr_ownerr('6 完整性','說明只有空白，資料庫直接擋（要存 null）', format(v_base, 'improve_note', quote_literal('   ')), '%spot_inspections_note_len%');
  perform pg_temp.vr_ownerr('6 完整性','截圖超過 10 張，資料庫直接擋', format(v_base, 'shot_paths', 'array_fill(''x''::text, array[11])'), '%spot_inspections_shots_count%');
  perform pg_temp.vr_eq('6 完整性','新欄位合法值可以直接寫入（確認上面的失敗不是欄位寫法錯）','OK',
    pg_temp.vr_own(format(v_base, 'improve_dims', $v$array['問題掌握','風險意識']$v$)));
  perform pg_temp.vr_own($q$delete from public.spot_inspections where employee_id = 'MI-9710'$q$);
exception when others then
  perform pg_temp.vr_rec('區段 6','完整性意外中斷','無例外', sqlerrm, false);
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
    execute 'deallocate spotdims_vr_out';
  exception when others then
    null;   -- 之前沒有就算了
  end;

  execute 'prepare spotdims_vr_out as select * from (values (0, '
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
    execute 'deallocate spotdims_vr_out';
  exception when others then
    null;
  end;
  execute 'prepare spotdims_vr_out as select '
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
execute spotdims_vr_out;
