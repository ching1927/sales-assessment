-- ============================================================
-- 業務考核系統：「該填未填」紅點提醒＋客服部每週彙整信（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。規格與上線步驟：README_todo_reminder.md。
--
-- ---------- 做什麼 ----------
--   店長端：「該填未填」都要有紅點；客服部：每週一早上收到一封「各門市未填清單與天數」彙整信。
--
-- ---------- 改寫的既有函式（簽名與權限不變，只換內容；原始定義請先用「待填提醒_上線前備份.sql」存起來）----------
--   1. improve_badge()   成績單&考核後台分頁紅點
--        原本：改善單 open＋coached 都算 → 現在：只算 open（店長還沒回填輔導紀錄的張數）。
--        cs_admin 全部；store_manager 只算自己門市；hq_viewer 0；其他「沒有權限」。
--        其餘過濾（人員在職、納入考核、依改善單開單當時的門市）沿用原本。
--   2. exam_req_badge()  待考回報分頁紅點
--        cs_admin 分支與原本逐字相同；store_manager 改成「todo_unreported_rows() 的筆數」
--        （含「已輔導未約考」，所以前端之後可以拿掉額外加 coached_pending_count() 的那次呼叫）；
--        hq_viewer 0；其他「沒有權限」。
--
-- ---------- 新增 ----------
--   spot_badge()            → int    異常回覆單（黃單：spot_tickets.kind='黃'）「有效且 coached_on 為空」的張數
--   todo_unreported_rows()  → table  店長「該回報待考但還沒回報」的人（見下方定義）
--   todo_digest_run()       → int    每週彙整信（內部函式，網頁角色不能呼叫；排程與手動測試用）
--   排程 todo_digest_weekly：每週一 UTC 01:00＝台北 09:00（pg_cron；沒啟用只提示、不讓整份失敗）
--
-- ---------- 刻意不動 ----------
--   coached_pending()／coached_pending_count()／coached_reminder_run() 與每兩天一封的提醒信，一律不動
--   （coached_reminder_content 的信件文字不含「改善單」，所以不需要改文字）。
--
-- ---------- todo_unreported_rows 的定義 ----------
--   人員一律要在職、納入考核，一人最多一列，並符合下列 A 或 B：
--   A. period_status = '考核期'：沒有待處理／已排定的待考回報，且沒有 status = 'open' 的改善單（還沒輔導的，先去輔導）。
--   B. 已上線（period_status 不是考核期）：有 status = 'coached' 的改善單，且比照 coached_pending_rows：
--      該單有輔導時間（coached_at），開單後沒有任何待處理／已排定／已完成的待考回報。
--   reason：有（符合條件的）coached 改善單 → '已輔導未約考'，否則 '新人'（B 一定是已輔導未約考）。
--   since_on：已輔導未約考＝最早那張 coached 改善單的輔導日（coached_at 的台北日期，沒有才用 coached_on）；
--             新人＝coalesce(probation_since, hire_date, 名冊建檔日 created_at 的台北日期)
--             （回考核期的人用進考核期那天；一般新人用到職日；到職日沒填就用建檔日）。
--
-- ---------- 彙整信規則 ----------
--   收件人：app_settings 的 key = 'todo_digest_recipients'（逗號分隔信箱）。沒設或空字串＝整個不寄、回 0。
--   內容：各門市「待回填輔導紀錄（status='open' 的改善單）」與「未輔導的異常回覆單」筆數、該門市最久天數、
--         超過 7 天未填的人員名單。天數＝今天（台北）減開單日（改善單 created_at、異常回覆單 issued_on）。
--   同一個台北週只寄一次（再跑回 0）。收件人只做信箱格式檢查，不要求是 app_users（和 exam_req_enqueue 不同，
--   因為這是老闆自己在 app_settings 設定的名單）。信件寫進 mail_outbox（kind = 'todo_digest'），由既有寄信觸發器送出。
--
-- 前提（執行順序）：… → backoffice → spotcheck → exam_request → phase1 → coached_reminder → badge_lifecycle →（本檔）。
--   缺什麼會用中文訊息擋下並整份回復。
-- 可重複執行：函式全部 create or replace；排程先 unschedule 同名再 schedule。
-- 緊急停止彙整信：select cron.unschedule('todo_digest_weekly');
-- 緊急還原紅點：用備份表 bak_todo_funcs 裡的 def 重新執行（見 README_todo_reminder.md）。
-- ============================================================
begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.improvement_tickets') is null then
    raise exception '請先執行 backoffice_schema.sql（缺少 improvement_tickets）';
  end if;
  if to_regclass('public.spot_tickets') is null then
    raise exception '請先執行 spotcheck_schema.sql（缺少 spot_tickets）';
  end if;
  if to_regclass('public.exam_requests') is null
     or to_regclass('public.mail_outbox') is null
     or to_regclass('public.app_settings') is null
     or to_regprocedure('public.exam_req_label(text, text)') is null
     or to_regprocedure('public.exam_req_esc(text)') is null
     or to_regprocedure('public.exam_req_setting(text)') is null
     or to_regprocedure('public.exam_req_badge()') is null then
    raise exception '請先執行 exam_request_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status') then
    raise exception '請先執行 phase1_schema.sql（缺少 employees.period_status）';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees' and column_name = 'probation_since') then
    raise exception '請先執行 spotcheck_schema.sql（缺少 employees.probation_since）';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'spot_tickets' and column_name = 'coached_on') then
    raise exception '請先執行 spotcheck_schema.sql（spot_tickets 缺少 coached_on）';
  end if;
  if to_regprocedure('public.coached_reminder_run(timestamptz)') is null then
    raise exception '請先執行 coached_reminder_schema.sql';
  end if;
  if to_regprocedure('public.improve_badge()') is null then
    raise exception '請先執行 badge_lifecycle_schema.sql（缺少 improve_badge）';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null then
    raise exception '請先執行 roster_schema.sql（缺少必要函式）';
  end if;
  if to_regnamespace('cron') is null then
    raise notice '⚠️ 偵測不到 pg_cron：本檔會略過「每週一 09:00 排程」的註冊，其餘照常。請啟用 pg_cron 後把本檔重跑一次。';
  end if;
end
$$;

-- ---------- 1. improve_badge：只算「店長還沒回填輔導」的改善單（open） ----------
create or replace function public.improve_badge()
returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_n int;
begin
  if v_role in ('cs_admin', 'store_manager') then
    select count(*)::int into v_n
      from public.improvement_tickets t
      join public.employees e on e.id = t.employee_id
     where t.status = 'open'
       and e.status = '在職'
       and e.include_in_assessment
       and (v_role = 'cs_admin' or t.store_code = public.roster_my_store());
  elsif v_role = 'hq_viewer' then
    v_n := 0;
  else
    raise exception '沒有權限';
  end if;
  return v_n;
end;
$$;

-- ---------- 2. spot_badge：異常回覆單（黃單）有效且還沒回填輔導 ----------
create or replace function public.spot_badge()
returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_n int;
begin
  if v_role in ('cs_admin', 'store_manager') then
    select count(*)::int into v_n
      from public.spot_tickets t
      join public.employees e on e.id = t.employee_id
     where t.kind = '黃'
       and t.status = '有效'
       and t.coached_on is null
       and e.status = '在職'
       and e.include_in_assessment
       and (v_role = 'cs_admin' or t.store_code = public.roster_my_store());
  elsif v_role = 'hq_viewer' then
    v_n := 0;
  else
    raise exception '沒有權限';
  end if;
  return v_n;
end;
$$;

-- ---------- 3. todo_unreported_rows：店長該回報待考但還沒回報的人 ----------
create or replace function public.todo_unreported_rows()
returns table(employee_id text, employee_label text, store_code text, reason text, since_on date)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
begin
  if v_role not in ('cs_admin', 'store_manager', 'hq_viewer') then
    raise exception '沒有權限';
  end if;
  if v_role = 'hq_viewer' then
    return;
  end if;
  return query
    select e.id,
           public.exam_req_label(e.nickname, e.full_name),
           e.store_code,
           case when c.n > 0 then '已輔導未約考' else '新人' end,
           coalesce(c.d, e.probation_since, e.hire_date, (e.created_at at time zone 'Asia/Taipei')::date)
      from public.employees e
      left join lateral (
             select count(*) as n,
                    min(coalesce((t.coached_at at time zone 'Asia/Taipei')::date, t.coached_on)) as d
               from public.improvement_tickets t
              where t.employee_id = e.id and t.status = 'coached'
                and (e.period_status = '考核期'
                     -- 已上線者比照 coached_pending_rows：有輔導時間，且開單後沒有有效回報（待處理、已排定、已完成）
                     or (t.coached_at is not null
                         and not exists (select 1 from public.exam_requests r
                                          where r.employee_id = t.employee_id
                                            and r.created_at >= t.created_at
                                            and r.status in ('待處理', '已排定', '已完成'))))) c on true
     where e.status = '在職'
       and e.include_in_assessment
       and (
             -- A. 考核期：沒有待處理／已排定的回報，且沒有還沒輔導的（open）改善單
             (e.period_status = '考核期'
              and not exists (select 1 from public.exam_requests r
                               where r.employee_id = e.id and r.status in ('待處理', '已排定'))
              and not exists (select 1 from public.improvement_tickets t2
                               where t2.employee_id = e.id and t2.status = 'open'))
             -- B. 已上線（不是考核期）：有符合 coached_pending 條件的「已輔導」改善單
             or (e.period_status <> '考核期' and c.n > 0)
           )
       and (v_role = 'cs_admin' or e.store_code = public.roster_my_store())
     order by e.store_code, 5, e.id;
end;
$$;

-- ---------- 4. exam_req_badge：cs_admin 分支與原本逐字相同；店長改算 todo_unreported_rows ----------
create or replace function public.exam_req_badge()
returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_n int;
begin
  if v_role = 'cs_admin' then
    select ((select count(*) from public.exam_requests where status = '待處理')
            + (select count(*) from public.reply_activations where status = '待開通'))::int
      into v_n;
  elsif v_role = 'store_manager' then
    select count(*)::int into v_n from public.todo_unreported_rows();
  elsif v_role = 'hq_viewer' then
    v_n := 0;
  else
    raise exception '沒有權限';
  end if;
  return v_n;
end;
$$;

-- ---------- 5. 每週彙整信給客服部（內部函式） ----------
-- p_now 只給排程與驗證腳本模擬不同日期用，預設現在（todo_digest_run() 不帶參數即可呼叫）。
create or replace function public.todo_digest_run(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_today date := (p_now at time zone 'Asia/Taipei')::date;
  v_week timestamp := date_trunc('week', p_now at time zone 'Asia/Taipei');
  v_raw text := public.exam_req_setting('todo_digest_recipients');
  v_to text[];
  r record;
  v_rows text := '';
  v_total int := 0;
  v_over text;
  v_link text := public.exam_req_setting('site_url');
  v_body text;
  v_subject text;
begin
  if v_raw is null then
    return 0;
  end if;

  -- 收件人：逗號（半形、全形）、分號分隔；只留格式正確的信箱，小寫去重
  select coalesce(array_agg(x.email order by x.email), '{}'::text[]) into v_to
    from (select distinct lower(btrim(t.e)) as email
            from unnest(regexp_split_to_array(v_raw, '[,，;；]')) as t(e)) x
   where x.email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$';
  if cardinality(v_to) = 0 then
    return 0;
  end if;

  -- 同一個台北週不重複寄
  if exists (select 1 from public.mail_outbox m
              where m.kind = 'todo_digest'
                and date_trunc('week', m.created_at at time zone 'Asia/Taipei') = v_week) then
    return 0;
  end if;

  create temp table if not exists pg_temp.todo_digest_items (
    store_code text, src text, label text, days int) on commit drop;
  truncate pg_temp.todo_digest_items;

  insert into pg_temp.todo_digest_items (store_code, src, label, days)
  select t.store_code, 'improve', public.exam_req_label(e.nickname, e.full_name),
         v_today - (t.created_at at time zone 'Asia/Taipei')::date
    from public.improvement_tickets t
    join public.employees e on e.id = t.employee_id
   where t.status = 'open' and e.status = '在職' and e.include_in_assessment;
  insert into pg_temp.todo_digest_items (store_code, src, label, days)
  select t.store_code, 'spot', t.employee_label, v_today - t.issued_on
    from public.spot_tickets t
    join public.employees e on e.id = t.employee_id
   where t.kind = '黃' and t.status = '有效' and t.coached_on is null
     and e.status = '在職' and e.include_in_assessment;

  for r in
    select i.store_code,
           coalesce(nullif(btrim(s.name), ''), i.store_code) as store_name,
           count(*) filter (where i.src = 'improve') as n_improve,
           count(*) filter (where i.src = 'spot') as n_spot,
           max(i.days) as max_days
      from pg_temp.todo_digest_items i
      left join public.stores s on s.code = i.store_code
     group by i.store_code, s.name
     order by i.store_code
  loop
    select string_agg(public.exam_req_esc(x.label) || '（' || x.d::text || ' 天）', '、' order by x.d desc, x.label)
      into v_over
      from (select i.label, max(i.days) as d
              from pg_temp.todo_digest_items i
             where i.store_code = r.store_code
             group by i.label
            having max(i.days) > 7) x;
    v_total := v_total + r.n_improve + r.n_spot;
    v_rows := v_rows
      || '<tr>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eee">' || public.exam_req_esc(r.store_name) || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center">' || r.n_improve::text || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center">' || r.n_spot::text || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:center">' || r.max_days::text || ' 天</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eee">' || coalesce(v_over, '無') || '</td>'
      || '</tr>';
  end loop;

  if v_total = 0 then
    return 0;
  end if;

  v_subject := '【每週彙整】各門市尚未回填的輔導紀錄（共 ' || v_total::text || ' 筆）';
  v_body :=
    '<div style="font-family:Arial,sans-serif;font-size:15px;color:#222;line-height:1.8">'
    || '<p style="margin:0 0 12px">客服部 您好：</p>'
    || '<p style="margin:0 0 12px">以下是截至 ' || to_char(v_today, 'YYYY-MM-DD') || ' 各門市還沒回填的項目，共 ' || v_total::text || ' 筆。</p>'
    || '<table style="border-collapse:collapse;font-size:14px;width:100%">'
    || '<tr style="background:#f4f6fa">'
    || '<th style="padding:8px 10px;text-align:left">門市</th>'
    || '<th style="padding:8px 10px">待回填輔導紀錄</th>'
    || '<th style="padding:8px 10px">未輔導的異常回覆單</th>'
    || '<th style="padding:8px 10px">最久天數</th>'
    || '<th style="padding:8px 10px;text-align:left">超過 7 天未填</th>'
    || '</tr>'
    || v_rows
    || '</table>'
    || case when v_link is null then '' else
         '<p style="margin:16px 0 0"><a href="' || public.exam_req_esc(v_link) || '">前往系統查看</a></p>' end
    || '<p style="margin:12px 0 0;color:#888;font-size:12px;border-top:1px solid #eee;padding-top:12px">這是系統每週一自動寄出的彙整信。</p>'
    || '</div>';

  insert into public.mail_outbox (to_emails, subject, body_html, kind, created_at)
  values (v_to, v_subject, v_body, 'todo_digest', p_now);
  return 1;
end;
$$;

-- ---------- 函式權限 ----------
revoke execute on function public.improve_badge()            from public, anon;
revoke execute on function public.exam_req_badge()           from public, anon;
revoke execute on function public.spot_badge()               from public, anon;
revoke execute on function public.todo_unreported_rows()     from public, anon;
revoke execute on function public.todo_digest_run(timestamptz) from public, anon, authenticated;

grant execute on function public.improve_badge()             to authenticated;
grant execute on function public.exam_req_badge()            to authenticated;
grant execute on function public.spot_badge()                to authenticated;
grant execute on function public.todo_unreported_rows()      to authenticated;

-- ---------- 排程：每週一 UTC 01:00（台北 09:00）執行 todo_digest_run() ----------
do $$
begin
  if to_regnamespace('cron') is null then
    raise notice '略過排程註冊：沒有 pg_cron。啟用後重跑本檔即可。';
    return;
  end if;
  begin
    begin
      execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'todo_digest_weekly'$q$;
    exception when others then
      null;   -- 原本沒有同名排程就算了
    end;
    execute $q$select cron.schedule('todo_digest_weekly', '0 1 * * 1', 'select public.todo_digest_run()')$q$;
    raise notice '已註冊排程 todo_digest_weekly（每週一 UTC 01:00＝台北 09:00）。';
  exception when others then
    raise notice '⚠️ 排程註冊失敗，已略過（其餘部分照常）：%', sqlerrm;
  end;
end
$$;

commit;
