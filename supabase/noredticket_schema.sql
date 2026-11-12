-- ============================================================
-- 業務考核系統：停用「紅單」與「回考核期」（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（重跑不報錯、不刪任何資料）。
--
-- ---------- 老闆定案（2026-11）----------
--   抽查制度原本：待加強回覆開黃單 → 當月有效黃單滿 5 張自動開紅單 → 季內有效紅單滿 2 張回考核期（建議移除官方 LINE 權限）。
--   現在整串停掉紅單與回考核期，只保留：黃單（待加強回覆照開，寫原因）、黃單作廢、店長回填輔導、抽查登記、勾面向、截圖。
--   連動停用：考核流程不再有「回考核期」身分與 85 分覆寫；待考回報不再提供「回考核期」情況。
--   「新人考核期」（employees.period_status = '考核期'，新人合格線 70）是另一回事，完全不動。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   … → spotcheck_schema → url_patch → … → phase1_schema → checkup_schema → … → spotdims_schema →
--   【本檔 noredticket_schema.sql】 → noredticket_verify_fake.sql（可選）
--   網頁（spotcheck.html、requests.html 等）要在本檔執行「之後」才上線。
--   ⚠️ 本檔之後不要重跑 spotcheck_schema／url_patch／phase1_schema／checkup_schema／spotdims_schema（會把舊規則蓋回來；
--      phase1_schema 重跑時其前提檢查會直接擋下）。萬一重跑過，再執行一次本檔即可。
--
-- ---------- 備份提醒（執行本檔之前先做；備份表必須啟用 row level security）----------
--   drop table if exists public.bak_noredticket_spot_tickets;
--   create table public.bak_noredticket_spot_tickets as select * from public.spot_tickets;
--   alter table public.bak_noredticket_spot_tickets enable row level security;
--   drop table if exists public.bak_noredticket_spot_probations;
--   create table public.bak_noredticket_spot_probations as select * from public.spot_probations;
--   alter table public.bak_noredticket_spot_probations enable row level security;
--   （備份表不開任何 policy ＝ 網頁角色完全讀不到；確認無誤後可 drop）
--
-- ---------- 本檔做了什麼（全部 create or replace，函式名稱與參數都不變）----------
--   1. spot_register（舊登記）與 spot_register_dims（新登記）：黃單照開；不再自動開紅單、不再建立回考核期、
--      不再設 employees.probation_since。回傳仍有 red_id、probation_id 兩個鍵，固定為 null（舊網頁相容）。
--   2. spot_month_yellow_ids：改成單純的「本日曆月（台北）有效黃單 id」，不再以「最近一張紅單之後」重算。
--      （spot_status 的 yellow_month 跟著變成單純的本月有效黃單數。）
--   3. assess_start：不再因 probation_since 有值就把身分改成「正式」、tenure_source 記「考核期」；
--      身分只看考核期新人（period_status）與到職日（90 天內新人 70 分、之後正式 85 分）。
--   4. assess_submit：拿掉「tenure_source = '考核期' 且總分 >= 85 → 清除 probation_since、spot_probations 改已通過」。
--      其餘（新人通過轉已上線、待開通、健檢只記錄…）逐字不變。
--
-- ---------- 刻意不動（舊資料相容、不 drop）----------
--   資料表 spot_tickets（kind 仍允許 紅）、spot_probations、欄位 employees.probation_since、exam_requests.kind 的「回考核期」、
--   assessments.tenure_source 的「考核期」；函式 spot_status、spot_mark_executed、spot_cancel_probation、spot_quarter_red_ids、
--   spot_candidates、exam_req_candidates、exam_req_create、coached_pending_rows 都不改簽名也不改內容
--   （沒有人在回考核期時，它們的「回考核期」分支不會被走到；exam_req_create 對「回考核期」仍會因為 probation_since 為空而擋下）。
--   既有紅單、回考核期、待考回報、成績單標記若將來有，原樣保留、仍可讀。
--
-- ---------- 安全閘門 ----------
--   若目前有人 probation_since 有值，或有進行中（待執行／已執行）的回考核期紀錄，本檔會直接停下並說明：
--   停用後這些人的考核分數線會改變（從 85 變回依到職日），必須先由老闆決定怎麼處理，不可自動帶過。
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查與安全閘門 ----------
do $$
begin
  if to_regclass('public.spot_tickets') is null
     or to_regclass('public.spot_probations') is null
     or to_regprocedure('public.spot_register(text, date, text, jsonb, text, text)') is null
     or to_regprocedure('public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])') is null
     or to_regprocedure('public.spot_month_yellow_ids(text, date)') is null
     or to_regprocedure('public.assess_start(text, text)') is null
     or to_regprocedure('public.assess_submit(uuid)') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 spotcheck_schema、phase1_schema、checkup_schema、spotdims_schema 等前面的檔案';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'assessments' and column_name = 'kind') then
    raise exception '前提不滿足：請先執行 checkup_schema.sql（assessments.kind）';
  end if;
  if exists (select 1 from public.employees where probation_since is not null) then
    raise exception '停下：目前還有人員在回考核期（employees.probation_since 有值）。停用回考核期後他們的考核分數線會改變，請先請老闆決定處理方式，再執行本檔。';
  end if;
  if exists (select 1 from public.spot_probations where status in ('待執行', '已執行')) then
    raise exception '停下：目前還有進行中的回考核期紀錄（待執行／已執行）。請先請老闆決定處理方式，再執行本檔。';
  end if;
end
$$;

-- ---------- 1. spot_month_yellow_ids：本日曆月的有效黃單（不再以紅單切段） ----------
create or replace function public.spot_month_yellow_ids(p_employee_id text, p_today date)
returns uuid[]
language sql
set search_path = public, pg_temp
as $$
  select coalesce(array_agg(t.id order by t.created_at), '{}'::uuid[])
  from public.spot_tickets t
  where t.employee_id = p_employee_id
    and t.kind = '黃'
    and t.status = '有效'
    and t.issued_on >= date_trunc('month', p_today::timestamp)::date
    and t.issued_on <  (date_trunc('month', p_today::timestamp) + interval '1 month')::date;
$$;

-- ---------- 2. spot_register（舊登記；以 phase1_schema.sql 版為基礎，只拿掉紅單與回考核期） ----------
create or replace function public.spot_register(
  p_employee_id text,
  p_checked_on date,
  p_message text,
  p_levels jsonb,
  p_verdict text,
  p_reason text
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
  v_url text := btrim(coalesce(p_message, ''), E' \t\r\n' || chr(12288));
  v_label text;
  s record;
  v_ins uuid;
  v_y uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  -- 鎖住這個人的名冊列：同一個人的並發登記、作廢、考核通過會在這裡排隊，次數才不會算重或算漏
  select * into v_emp from public.employees where id = p_employee_id for update;
  if not found then
    raise exception '找不到員工：%', p_employee_id;
  end if;

  -- 抽查對象資格
  if v_emp.status <> '在職' then
    raise exception '該員工已離職，不能抽查';
  end if;
  if not v_emp.include_in_assessment then
    raise exception '該員工不在考核名單（需納入考核），不能抽查';
  end if;
  if v_emp.probation_since is not null or v_emp.period_status = '考核期' then   -- 【第一期】period_status 也算考核期
    raise exception '該員工目前在考核期，不能抽查';
  end if;
  if v_emp.hire_date is not null and (v_today - v_emp.hire_date) <= 90 then
    raise exception '該員工是新人（到職日起 90 天內），不能抽查';
  end if;

  if p_checked_on is null then
    raise exception '抽查日期不可空白';
  end if;
  if p_verdict is null or p_verdict not in ('適當', '不適當') then
    raise exception '判定必須是「適當」或「不適當」';
  end if;
  if p_verdict = '不適當' and v_reason is null then
    raise exception '判定不適當時，原因不可空白';
  end if;

  -- 七面向等級驗證＋計分（鍵必須是七面向、值必須是四級或不適用、七個缺一不可、不適用最多 2 個）
  select * into s from public.assess_score_item(p_levels);

  -- 訊息抽檢-LINE聊天室網址（排在其他驗證之後）
  if v_url !~* '^https?://[^[:space:]]+$' or length(v_url) > 500 then
    raise exception '請填寫訊息抽檢的 LINE 聊天室網址（http 或 https 開頭，不可含空白）';
  end if;

  v_label := coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), ''));

  insert into public.spot_inspections
    (employee_id, employee_label, store_code, checked_on, message, levels,
     total_score, dim_points, weakest_dims, verdict, reason, examiner_email)
  values
    (v_emp.id, v_label, v_emp.store_code, p_checked_on, v_url, p_levels,
     s.item_score, s.dim_points, s.weakest_dims, p_verdict, v_reason, v_me)
  returning id into v_ins;

  if p_verdict = '不適當' then
    -- 黃單
    insert into public.spot_tickets
      (kind, employee_id, employee_label, store_code, inspection_id, reason, issued_on)
    values
      ('黃', v_emp.id, v_label, v_emp.store_code, v_ins, v_reason, v_today)
    returning id into v_y;

  end if;

  return jsonb_build_object(
    'inspection_id', v_ins,
    'total_score', s.item_score,
    'weakest_dims', to_jsonb(s.weakest_dims),
    'yellow_id', v_y,
    'red_id', null::uuid,
    'probation_id', null::uuid
  );
end;
$$;

-- ---------- 3. spot_register_dims（新登記；以 spotdims_schema.sql 版為基礎，只拿掉紅單與回考核期） ----------
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

  end if;

  return jsonb_build_object(
    'inspection_id', v_ins,
    'yellow_id', v_y,
    'red_id', null::uuid,
    'probation_id', null::uuid,
    'dims_count', coalesce(cardinality(v_dims), 0),
    'shots_count', coalesce(cardinality(v_paths), 0)
  );
end;
$$;

-- ---------- 4. assess_start（以 checkup_schema.sql 版為基礎，只拿掉 probation_since 分支） ----------
create or replace function public.assess_start(p_employee_id text, p_tenure_override text default null)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_emp public.employees%rowtype;
  v_tenure text;
  v_source text;
  v_id uuid;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception '找不到員工：%', p_employee_id;
  end if;
  if not v_emp.include_in_assessment or v_emp.status <> '在職' then
    raise exception '該員工不在考核名單（需納入考核且在職）';
  end if;

  -- 【回考核期停用】不再因 probation_since 有值就改成「正式／考核期」；身分只看考核期新人（period_status）與到職日
  if v_emp.period_status = '考核期' then
    -- 【第一期新增】考核期新人：一律「新人」（合格線 70），來源維持「自動」；到職日空白也不需要手動指定
    v_tenure := '新人';
    v_source := '自動';
  elsif v_emp.hire_date is not null then
    v_tenure := case
                  when ((now() at time zone 'Asia/Taipei')::date - v_emp.hire_date) <= 90 then '新人'
                  else '正式'
                end;
    v_source := '自動';
  else
    if p_tenure_override is null or p_tenure_override not in ('新人', '正式') then
      raise exception '到職日空白，請手動指定「新人」或「正式」';
    end if;
    v_tenure := p_tenure_override;
    v_source := '手動指定';
  end if;

  -- 直接嘗試新增；同考官同員工已有草稿（含兩個請求同時進來）時，
  -- 唯一部分索引讓 on conflict do nothing 生效，改回傳既有那張，不報唯一鍵錯誤
  insert into public.assessments
    (employee_id, employee_label, store_code, examiner_email, status, tenure, tenure_source, hire_date_snapshot)
  values
    (v_emp.id,
     coalesce(nullif(btrim(v_emp.nickname), ''), nullif(btrim(v_emp.full_name), '')),
     v_emp.store_code, v_me, 'draft', v_tenure, v_source, v_emp.hire_date)
  on conflict (examiner_email, employee_id) where status = 'draft' and kind = 'exam' do nothing
  returning id into v_id;

  if v_id is null then
    select a.id into v_id
    from public.assessments a
    where a.employee_id = v_emp.id and a.examiner_email = v_me and a.status = 'draft' and a.kind = 'exam';
  end if;

  return v_id;
end;
$$;

-- ---------- 5. assess_submit（以 checkup_schema.sql 版為基礎，只拿掉「考核期成績單 >= 85」那一段） ----------
create or replace function public.assess_submit(p_assessment_id uuid)
returns table(total_score numeric, verdict text, pass_line int, weakest_dims text[],
              tenure text, item_count int)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_me text;
  v_a public.assessments%rowtype;
  r record;
  s record;
  v_levels jsonb := '[]'::jsonb;
  v_cnt int := 0;
  v_total numeric;
  v_weak text[];
  v_ver text;
  v_line int;
  v_ps text;
  v_today date := (now() at time zone 'Asia/Taipei')::date;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select * into v_a from public.assessments where id = p_assessment_id for update;
  if not found then
    raise exception '找不到考核';
  end if;
  if v_a.status <> 'draft' then
    raise exception '只有草稿可以送出';
  end if;
  if v_a.examiner_email <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  for r in
    select i.id, i.seq, i.levels, i.is_extra
    from public.assessment_items i
    where i.assessment_id = v_a.id
    order by i.seq
  loop
    begin
      select * into s from public.assess_score_item(r.levels);
    exception when others then
      raise exception '第 % 題組評分不完整或不正確：%', r.seq, sqlerrm;
    end;

    update public.assessment_items
       set item_score = s.item_score,
           dim_points = s.dim_points,
           na_dims = s.na_dims,
           weakest_dims = s.weakest_dims
     where id = r.id;

    -- 【第一期】追加題（is_extra）一樣要評完、一樣寫入自己的分數，但不進總分、判定、最弱面向與題組數
    if not r.is_extra then
      v_cnt := v_cnt + 1;
      v_levels := v_levels || jsonb_build_array(r.levels);
    end if;
  end loop;

  if v_cnt = 0 then
    raise exception '至少要有 1 個題組';
  end if;

  select ss.total_score, ss.weakest_dims into v_total, v_weak
  from public.assess_score_session(v_levels) as ss;

  select vd.verdict, vd.pass_line into v_ver, v_line
  from public.assess_verdict(v_total, v_a.tenure) as vd;

  update public.assessments
     set status = 'submitted',
         total_score = v_total,
         verdict = v_ver,
         pass_line = v_line,
         weakest_dims = v_weak,
         submitted_at = now()
   where id = v_a.id;

  -- 【回考核期停用】原本在這裡的「考核期成績單 >= 85 清除回考核期標記、回考核期紀錄改已通過」已拿掉
  -- 【第一期新增】考核期新人通過：身分是「新人」、總分 >= 70、員工目前是考核期 → 已上線、記通過日、新增待開通
  -- 【健檢】同上：健檢成績單（身分一律正式）不進這一段
  if v_a.kind = 'exam' and v_a.tenure = '新人' and v_total >= 70 then
    select e.period_status into v_ps from public.employees e where e.id = v_a.employee_id for update;
    if v_ps = '考核期' then
      update public.employees
         set period_status = '已上線', passed_on = v_today
       where id = v_a.employee_id;
      insert into public.reply_activations
        (employee_id, employee_label, store_code, assessment_id, passed_on, status)
      values
        (v_a.employee_id, v_a.employee_label, v_a.store_code, v_a.id, v_today, '待開通')
      on conflict (assessment_id) where assessment_id is not null do nothing;
    end if;
  end if;

  total_score := v_total;
  verdict := v_ver;
  pass_line := v_line;
  weakest_dims := v_weak;
  tenure := v_a.tenure;
  item_count := v_cnt;
  return next;
end;
$$;

-- ---------- 6. 權限（沿用原本設定；create or replace 不會改權限，這裡重申一次） ----------
revoke execute on function public.spot_register(text, date, text, jsonb, text, text) from public, anon;
grant  execute on function public.spot_register(text, date, text, jsonb, text, text) to authenticated;
revoke execute on function public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[]) from public, anon;
grant  execute on function public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[]) to authenticated;
revoke execute on function public.assess_start(text, text) from public, anon;
grant  execute on function public.assess_start(text, text) to authenticated;
revoke execute on function public.assess_submit(uuid) from public, anon;
grant  execute on function public.assess_submit(uuid) to authenticated;

commit;

-- ============================================================
-- 驗證查詢（執行完本檔後貼上跑；每一列的「結果」都應該是 通過）
-- ============================================================
select '登記函式不再碰紅單／回考核期' as 項目,
       case when not exists (
         select 1 from pg_proc p
          where p.oid in ('public.spot_register(text, date, text, jsonb, text, text)'::regprocedure,
                          'public.spot_register_dims(uuid, text, date, text, text, text, text[], text, text[])'::regprocedure)
            and (p.prosrc like '%spot_probations%' or p.prosrc like '%''紅''%' or p.prosrc like '%probation_since = v_today%')
       ) then '通過' else '失敗' end as 結果
union all
select 'assess_start 不再看 probation_since 改身分',
       case when exists (select 1 from pg_proc p where p.oid = 'public.assess_start(text, text)'::regprocedure
                         and p.prosrc not like '%v_emp.probation_since%') then '通過' else '失敗' end
union all
select 'assess_submit 不再處理 spot_probations',
       case when exists (select 1 from pg_proc p where p.oid = 'public.assess_submit(uuid)'::regprocedure
                         and p.prosrc not like '%spot_probations%') then '通過' else '失敗' end
union all
select '沒有人在回考核期',
       case when not exists (select 1 from public.employees where probation_since is not null) then '通過' else '失敗' end
union all
select '資料表與欄位都還在（沒有 drop）',
       case when to_regclass('public.spot_probations') is not null
             and exists (select 1 from information_schema.columns where table_schema = 'public'
                          and table_name = 'employees' and column_name = 'probation_since') then '通過' else '失敗' end;
