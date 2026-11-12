-- ============================================================
-- 業務考核系統：抽查登記改版（勾「可改善面向」＋截圖＋說明，不再打七面向分數）（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（重跑不報錯、不改任何既有抽查資料）。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   roster_schema → assess_schema → bank_schema → accounts_schema → notes_visible_schema → backoffice_schema →
--   spotcheck_schema → url_patch → weak_suggest_schema → exam_request_schema → phase1_schema → checkup_schema →
--   （roster_line_schema、coached_reminder_schema、grade3_schema、fullreport_schema 若已上線也都在前面）→
--   【本檔 spotdims_schema.sql】 → spotdims_verify_fake.sql（可選）
--   網頁（spotcheck.html、js/spotcheck-api.js、js/spotdims-core.js）要在本檔執行「之後」才上線
--   （新網頁呼叫本檔的 spot_register_dims；舊網頁呼叫舊 spot_register，本檔不動它，所以先執行本檔不影響舊網頁）。
--
-- ---------- 備份提醒（執行本檔之前先做；備份表必須啟用 row level security）----------
--   drop table if exists public.bak_spotdims_inspections;
--   create table public.bak_spotdims_inspections as select * from public.spot_inspections;
--   alter table public.bak_spotdims_inspections enable row level security;
--   （備份表不開任何 policy ＝ 網頁角色完全讀不到；確認無誤後可 drop）
--
-- ---------- 這次改了什麼（老闆已核可樣品「健檢改版樣品.html」A 分頁）----------
-- 1. 抽查登記保留「判定」與黃單／紅單／回考核期全部既有規則，行為不變。
-- 2. 七面向「打分」拿掉，改成：可改善面向（七面向可複選，0～7 個）＋截圖（可多張）＋說明（選填）。
--    判定為適當的抽查也可以勾面向（不開黃單）。
-- 3. 顯示用字改名（優良回覆／待加強回覆）只在畫面；資料庫存的判定值仍是「適當／不適當」，不改、不遷移。
-- 4. 舊抽查紀錄（含七面向等級、分數）一筆都不改；新登記的不再要求或寫入等級與分數（levels、total_score 存 null）。
--
-- ---------- 已查過：舊的七面向等級與分數沒有被任何邏輯拿來判定 ----------
--   黃單／紅單／回考核期全看 verdict（適當／不適當）與單據張數；spot_status、spot_month_yellow_ids、spot_quarter_red_ids、
--   spot_candidates 都沒有讀 levels／total_score／dim_points／weakest_dims；弱項分析、建議題組、近期考核、健檢都只讀
--   assessment_items，不讀 spot_inspections。所以新登記不寫等級與分數不會改變任何判定或統計。
--
-- ---------- 本檔新增與改動的東西 ----------
--   欄位（spot_inspections，皆新增）：improve_dims text[]（勾的面向，只允許七面向名稱）、
--     improve_note text（一句說明，選填，500 字內）、shot_paths text[]（截圖在 Storage 的路徑，最多 10 張）
--   欄位（spot_inspections，放寬）：levels、total_score 由 not null 改為可空（舊資料不動；新登記存 null）
--   約束：spot_inspections_dims_valid、spot_inspections_dims_count、spot_inspections_note_len、spot_inspections_shots_count
--   函式：spot_register_dims（客服部登記，新）。舊 spot_register(text,date,text,jsonb,text,text) 原封不動、仍可呼叫
--     （為了舊驗證腳本與舊網頁；新網頁不再用它）。
--   Storage：沿用私有 bucket assess-notes（單檔 2MB、只收 jpeg／png／webp，同備註附圖的設定），
--     新增三條 policy 只處理路徑 spot/{抽查id}/{uuid}.jpg|png|webp：
--       讀（assess_spot_shots_select）：客服部、總公司主管全部；店長只讀自己門市的抽查；其他與 anon 無權。
--       傳（assess_spot_shots_insert）：只有客服部，且該抽查 id 還不存在（登記前上傳；登記後不可再塞圖）。
--       刪（assess_spot_shots_delete）：只有客服部，且該抽查 id 不存在（清掉登記失敗留下的孤兒檔）。
--     既有 assess_notes_* 三條 policy 完全不動（它們只處理第一段是考核 id 的路徑，與 spot/ 不重疊）。
--
-- 流程（前端）：產生抽查 id → 縮圖後上傳到 spot/{id}/ → 呼叫 spot_register_dims（帶同一個 id 與路徑）。
--   同一個 id 不能登記兩次（擋重複送出）。函式會確認每個路徑都真的已上傳。
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.spot_inspections') is null
     or to_regclass('public.spot_tickets') is null
     or to_regclass('public.spot_probations') is null
     or to_regprocedure('public.spot_register(text, date, text, jsonb, text, text)') is null
     or to_regprocedure('public.spot_month_yellow_ids(text, date)') is null
     or to_regprocedure('public.spot_quarter_red_ids(text, date)') is null
     or to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_dim_order()') is null
     or to_regprocedure('public.assess_safe_uuid(text)') is null
     or to_regprocedure('public.roster_my_email()') is null
     or to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null
     or to_regclass('storage.objects') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 assess_schema、spotcheck_schema、url_patch、phase1_schema 等前面的檔案';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status') then
    raise exception '前提不滿足：請先執行 phase1_schema.sql（employees.period_status）';
  end if;
end
$$;

-- ---------- 1. 欄位與約束 ----------
-- 舊資料不動：levels、total_score 只是放寬為可空（舊列仍有值）；新增的三欄舊列用預設值（空陣列／null）。
alter table public.spot_inspections alter column levels drop not null;
alter table public.spot_inspections alter column total_score drop not null;

alter table public.spot_inspections
  add column if not exists improve_dims text[] not null default '{}'::text[];
alter table public.spot_inspections
  add column if not exists improve_note text;
alter table public.spot_inspections
  add column if not exists shot_paths text[] not null default '{}'::text[];

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.spot_inspections'::regclass
                  and conname = 'spot_inspections_dims_valid') then
    alter table public.spot_inspections
      add constraint spot_inspections_dims_valid
      check (improve_dims <@ array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識','語氣與禮貌','文字品質']::text[]);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.spot_inspections'::regclass
                  and conname = 'spot_inspections_dims_count') then
    alter table public.spot_inspections
      add constraint spot_inspections_dims_count
      check (coalesce(cardinality(improve_dims), 0) <= 7);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.spot_inspections'::regclass
                  and conname = 'spot_inspections_note_len') then
    alter table public.spot_inspections
      add constraint spot_inspections_note_len
      check (improve_note is null or (length(improve_note) <= 500 and nullif(btrim(improve_note), '') is not null));
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.spot_inspections'::regclass
                  and conname = 'spot_inspections_shots_count') then
    alter table public.spot_inspections
      add constraint spot_inspections_shots_count
      check (coalesce(cardinality(shot_paths), 0) <= 10);
  end if;
end
$$;

-- ---------- 2. spot_register_dims：登記一次抽查（客服部） ----------
-- 規則與 phase1_schema.sql 版 spot_register 逐項相同（資格、日期、判定、不適當必填原因、網址、
-- 黃單→紅單→回考核期、同交易、鎖員工列），只把「七面向等級＋分數」換成「勾選面向＋截圖＋說明」。
-- 參數：
--   p_inspection_id：前端先產生的抽查 id（截圖路徑以它為資料夾）；不傳也可以（沒有截圖時）。已存在就擋（防重複送出）。
--   p_dims：勾的面向（0～7 個，不可重複、只能是七面向名稱）；null 視為沒勾。
--   p_note：一句說明（選填；去頭尾空白後空白視為沒填；最長 500 字）。
--   p_shot_paths：截圖路徑（spot/{p_inspection_id}/{uuid}.jpg|png|webp；最多 10 張；每張必須已上傳）。
-- 驗證順序：身分 → 員工與資格 → 日期 → 判定 → 不適當原因 → 面向 → 說明 → 截圖 → 網址（最後）。
-- 回傳 {inspection_id, yellow_id, red_id, probation_id, dims_count, shots_count}（沒有就是 null）。
create or replace function public.spot_register_dims(
  p_inspection_id uuid,
  p_employee_id text,
  p_checked_on date,
  p_message text,
  p_verdict text,
  p_reason text,
  p_dims text[],
  p_note text,
  p_shot_paths text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_emp public.employees%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, ''), E' \t\r\n' || chr(12288)), '');
  v_note text := nullif(btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288)), '');
  v_url text := btrim(coalesce(p_message, ''), E' \t\r\n' || chr(12288));
  v_dims text[] := coalesce(p_dims, '{}'::text[]);
  v_paths text[] := coalesce(p_shot_paths, '{}'::text[]);
  v_id uuid := coalesce(p_inspection_id, gen_random_uuid());
  v_label text;
  v_d text;
  v_p text;
  v_ins uuid;
  v_y uuid;
  v_r uuid;
  v_pr uuid;
  v_ys uuid[];
  v_rs uuid[];
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 鎖住這個人的名冊列：同一個人的並發登記、作廢、考核通過會在這裡排隊，次數才不會算重或算漏
  select * into v_emp from public.employees where id = p_employee_id for update;
  if not found then
    raise exception '找不到員工：%', p_employee_id;
  end if;

  -- 抽查對象資格（與 spot_register 相同）
  if v_emp.status <> '在職' then
    raise exception '該員工已離職，不能抽查';
  end if;
  if not v_emp.include_in_assessment then
    raise exception '該員工不在考核名單（需納入考核），不能抽查';
  end if;
  if v_emp.probation_since is not null or v_emp.period_status = '考核期' then
    raise exception '該員工目前在考核期，不能抽查';
  end if;
  if v_emp.hire_date is not null and (v_today - v_emp.hire_date) <= 90 then
    raise exception '該員工是新人（到職日起 90 天內），不能抽查';
  end if;

  if p_checked_on is null then
    raise exception '抽查日期不可空白';
  end if;
  if p_verdict is null or p_verdict not in ('適當', '不適當') then
    raise exception '判定必須是「優良回覆」或「待加強回覆」';
  end if;
  if p_verdict = '不適當' and v_reason is null then
    raise exception '判定待加強回覆時，原因不可空白';
  end if;

  -- 可改善面向：只能是七面向名稱、不可重複、0～7 個
  foreach v_d in array v_dims loop
    if v_d is null or not (v_d = any (public.assess_dim_order())) then
      raise exception '可改善面向「%」不是七面向之一', coalesce(v_d, '(空)');
    end if;
  end loop;
  if coalesce(cardinality(v_dims), 0) <> (select count(distinct x) from unnest(v_dims) as x) then
    raise exception '可改善面向不可重複勾選';
  end if;

  -- 說明
  if v_note is not null and length(v_note) > 500 then
    raise exception '說明最多 500 字';
  end if;

  -- 截圖：路徑格式、資料夾必須是這次抽查 id、不可重複、最多 10 張、檔案必須已上傳
  if coalesce(cardinality(v_paths), 0) > 10 then
    raise exception '截圖最多 10 張';
  end if;
  if coalesce(cardinality(v_paths), 0) > 0 and p_inspection_id is null then
    raise exception '有截圖時必須帶抽查編號';
  end if;
  foreach v_p in array v_paths loop
    if v_p is null or v_p !~ ('^spot/' || v_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$') then
      raise exception '截圖路徑不正確';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'assess-notes' and o.name = v_p) then
      raise exception '有截圖還沒上傳成功，請重新選取截圖後再送出';
    end if;
  end loop;
  if coalesce(cardinality(v_paths), 0) <> (select count(distinct x) from unnest(v_paths) as x) then
    raise exception '截圖不可重複';
  end if;

  -- 訊息抽檢-LINE聊天室網址（排在其他驗證之後，與 spot_register 相同）
  if v_url !~* '^https?://[^[:space:]]+$' or length(v_url) > 500 then
    raise exception '請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）';
  end if;

  -- 擋重複送出：同一個抽查 id 只能登記一次
  if exists (select 1 from public.spot_inspections where id = v_id) then
    raise exception '這次抽查已經登記過了，請重新整理頁面確認，不要重複送出';
  end if;

  v_label := coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), ''));

  insert into public.spot_inspections
    (id, employee_id, employee_label, store_code, checked_on, message, levels,
     total_score, dim_points, weakest_dims, verdict, reason, examiner_email,
     improve_dims, improve_note, shot_paths)
  values
    (v_id, v_emp.id, v_label, v_emp.store_code, p_checked_on, v_url, null,
     null, null, null, p_verdict, v_reason, v_me,
     v_dims, v_note, v_paths)
  returning id into v_ins;

  if p_verdict = '不適當' then
    -- 黃單
    insert into public.spot_tickets
      (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on)
    values
      ('黃', v_emp.id, v_label, v_emp.store_code, v_ins, v_reason, v_today)
    returning id into v_y;

    -- 紅單：本日曆月、最近一張有效紅單之後的有效黃單滿 5 張
    v_ys := public.spot_month_yellow_ids(v_emp.id, v_today);
    if coalesce(array_length(v_ys, 1), 0) >= 5 then
      insert into public.spot_tickets
        (kind, employee_id, employee_label, store_code, source_ticket_ids, reason, issued_on)
      values
        ('紅', v_emp.id, v_label, v_emp.store_code, v_ys,
         format('同一日曆月內累積 %s 張有效黃單，系統自動開立改善紅單', array_length(v_ys, 1)),
         v_today)
      returning id into v_r;

      -- 回考核期：本日曆季、最近一筆回考核期紀錄（任何狀態）之後的有效紅單滿 2 張
      v_rs := public.spot_quarter_red_ids(v_emp.id, v_today);
      if coalesce(array_length(v_rs, 1), 0) >= 2 then
        insert into public.spot_probations
          (employee_id, employee_label, store_code, red_ticket_ids, triggered_on, status)
        values
          (v_emp.id, v_label, v_emp.store_code, v_rs, v_today, '待執行')
        returning id into v_pr;

        -- period_status 同步設為考核期（與 phase1_schema.sql 版 spot_register 相同）
        update public.employees set probation_since = v_today, period_status = '考核期' where id = v_emp.id;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'inspection_id', v_ins,
    'yellow_id', v_y,
    'red_id', v_r,
    'probation_id', v_pr,
    'dims_count', coalesce(cardinality(v_dims), 0),
    'shots_count', coalesce(cardinality(v_paths), 0)
  );
end;
$$;

revoke execute on function public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[]) from public, anon;
grant  execute on function public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[]) to authenticated;

-- ---------- 3. Storage：截圖放在 assess-notes 的 spot/ 路徑 ----------
-- 路徑慣例：spot/{抽查id}/{uuid}.jpg|png|webp（第一段是固定字 spot，與備註附圖的 {考核id}/… 不重疊）。
-- 讀：客服部、總公司主管全部；店長只讀「路徑第二段對應的抽查」在其權限內的物件（由 spot_inspections 的 RLS 決定，
--     即自己門市）；第二段不是合法 uuid 視為無權限。bucket 維持私有（前端用簽名網址顯示）。
drop policy if exists assess_spot_shots_select on storage.objects;
create policy assess_spot_shots_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'assess-notes'
    and storage.objects.name like 'spot/%'
    and exists (
      select 1 from public.spot_inspections s
      where s.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 2))
    )
  );

-- 傳：只有客服部；路徑格式必須正確；該抽查 id 還不存在（登記前上傳）
drop policy if exists assess_spot_shots_insert on storage.objects;
create policy assess_spot_shots_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'assess-notes'
    and public.roster_my_role() = 'cs_admin'
    and storage.objects.name ~ '^spot/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
    and not exists (
      select 1 from public.spot_inspections s
      where s.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 2))
    )
  );

-- 刪：只有客服部；只能刪「還沒有對應抽查」的孤兒檔（登記失敗或取消後清理）；已登記抽查的截圖不可刪
drop policy if exists assess_spot_shots_delete on storage.objects;
create policy assess_spot_shots_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'assess-notes'
    and public.roster_my_role() = 'cs_admin'
    and storage.objects.name ~ '^spot/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
    and not exists (
      select 1 from public.spot_inspections s
      where s.id = public.assess_safe_uuid(split_part(storage.objects.name, '/', 2))
    )
  );

-- 讓 Supabase API 立刻認得新函式與新欄位
notify pgrst, 'reload schema';

commit;
