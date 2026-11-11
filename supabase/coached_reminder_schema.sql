-- ============================================================
-- 業務考核系統：「已輔導 → 尚未約考」提醒（資料庫部分）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。規格與老闆執行步驟：README_exam_request.md 第六節。
--
-- 做什麼：店長按「已輔導」之後如果一直沒送出待考回報，就算「尚未約考」。本檔提供
--   1. 判斷誰「尚未約考」的資料庫函式（網頁的改善單標籤、待考回報頁黃色提醒條、導覽紅點都問它）
--   2. 預填：依改善單與其來源成績單判斷待考回報要選哪一種「情況」
--   3. 每兩天寄一封提醒信給該門市店長（沿用寄信佇列 mail_outbox、pg_net、Apps Script），
--      由 pg_cron 每天台北 09:00（UTC 01:00）執行 coached_reminder_run()
--
-- 前提（執行順序）：
--   roster → assess → bank → accounts → notes_visible → backoffice → spotcheck → url_patch →
--   weak_suggest → exam_request → phase1 → checkup →（本檔）。缺 improvement_tickets／exam_requests／
--   mail_outbox 等會用中文訊息擋下並整份回復。
--   寄信前提同 exam_request_schema.sql：pg_net 已啟用、mail_relay_url／mail_relay_token 已填；
--   沒有的話提醒信一律記為 skipped（寄信紀錄看得到），不會報錯。
--
-- ⚠️ 執行前請先到 Supabase 備份（Dashboard → Database → Backups），並依 README_exam_request.md 第六節把
--   improvement_tickets 另存一份備份表（本檔會在這張表「新增兩個欄位」，不改、不刪任何既有欄位與資料）。
-- ⚠️ 需先在 Dashboard → Database → Extensions 啟用 pg_cron，才會註冊每天 09:00 的排程。
--   沒啟用也能執行本檔（整份仍成功，只用 notice 提示略過排程註冊）；之後啟用 pg_cron，再把本檔重跑一次即可補上排程。
--
-- 本檔只「新增」東西：
--   欄位（加在 improvement_tickets）：last_reminded_at（最近一次寄提醒的時間）、reminder_count（已寄幾封）
--   對外函式（authenticated 可呼叫）：coached_pending()、coached_pending_count()
--   內部函式（任何網頁角色都不能呼叫）：coached_pending_rows(timestamptz)、coached_reminder_content(...)、
--           coached_reminder_run(timestamptz)（排程與手動測試用）
--   排程：pg_cron 的 coached_reminder_daily（每天 UTC 01:00＝台北 09:00）
--   不修改任何既有函式（含 exam_req_badge、improve_mark_coached、exam_req_create），不動既有資料。
--   mail_outbox 的記錄方式：kind = 'coached_reminder'，request_id 欄位放「改善單編號」（該欄沒有外鍵）。
--
-- 可重複執行：欄位 add column if not exists、函式 create or replace、排程先 unschedule 同名再 schedule。
-- 緊急停止寄提醒信：select cron.unschedule('coached_reminder_daily');
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯整份回復，稍後重跑即可
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.improvement_tickets') is null then
    raise exception '請先執行 backoffice_schema.sql（缺少 improvement_tickets）';
  end if;
  if to_regclass('public.exam_requests') is null
     or to_regclass('public.mail_outbox') is null
     or to_regprocedure('public.exam_req_enqueue(text[], text, text, text, uuid)') is null
     or to_regprocedure('public.exam_req_link()') is null
     or to_regprocedure('public.exam_req_esc(text)') is null
     or to_regprocedure('public.exam_req_label(text, text)') is null then
    raise exception '請先執行 exam_request_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees' and column_name = 'probation_since') then
    raise exception '請先執行 spotcheck_schema.sql（缺少 employees.probation_since）';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null then
    raise exception '請先執行 roster_schema.sql（缺少必要函式）';
  end if;
  if to_regnamespace('cron') is null then
    raise notice '⚠️ 偵測不到 pg_cron：本檔會略過「每天 09:00 排程」的註冊，其餘照常。請到 Dashboard → Database → Extensions 啟用 pg_cron 後，把本檔重跑一次。';
  end if;
end
$$;

-- ---------- 欄位：提醒記錄（加在改善單） ----------
alter table public.improvement_tickets add column if not exists last_reminded_at timestamptz;
alter table public.improvement_tickets add column if not exists reminder_count int not null default 0;

-- ============================================================
-- 內部：尚未約考清單（不看角色，給其他函式用；結尾會把 execute 收回）
--
-- 「尚未約考」＝同時符合：
--   1. 改善單目前是「已輔導」（已結案、已取消、待改善都不算；成績單作廢會自動取消改善單，所以作廢也會停）
--   2. 開單之後，這位人員沒有任何「待處理、已排定、已完成」的待考回報（已取消＝已撤回或已退回，不算有效，仍視為尚未約考）
--      （已完成也算已約考：考核已經考過了，不必再提醒）
--   3. 人員在職且納入考核（否則系統本來就不能替他回報）
-- 預填的「情況」kind：來源成績單判定「需複訓」→ 複檢；判定「不及格」且人員目前在考核期（probation_since 有值）→ 回考核期；
--   其他（例如不及格但不在考核期，系統不允許以回考核期回報；或來源成績單看不到）→ null，由店長自己選。
-- coached_days＝今天（台北日期）減輔導日（coached_at 的台北日期），按「已輔導」當天算 0。
-- p_now 只給排程與驗證腳本模擬不同日期用，預設現在。
-- ============================================================
create or replace function public.coached_pending_rows(p_now timestamptz default now())
returns table(ticket_id uuid, employee_id text, employee_label text, store_code text,
              coached_at timestamptz, coached_days int, kind text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select t.id,
         t.employee_id,
         public.exam_req_label(e.nickname, e.full_name),
         e.store_code,
         t.coached_at,
         ((p_now at time zone 'Asia/Taipei')::date - (t.coached_at at time zone 'Asia/Taipei')::date)::int,
         case when a.verdict = '需複訓' then '複檢'
              when a.verdict = '不及格' and e.probation_since is not null then '回考核期'
              else null end
  from public.improvement_tickets t
  join public.employees e on e.id = t.employee_id
  left join public.assessments a on a.id = t.assessment_id
  where t.status = 'coached'
    and t.coached_at is not null
    and e.status = '在職'
    and e.include_in_assessment
    and not exists (select 1 from public.exam_requests r
                    where r.employee_id = t.employee_id
                      and r.created_at >= t.created_at
                      and r.status in ('待處理', '已排定', '已完成'));
$$;

-- ============================================================
-- 對外：尚未約考清單（客服部、主管看全部；店長只看自己門市；其他身分一律「沒有權限」）
-- 網頁用它畫改善單的黃色標籤、待考回報頁的黃色提醒條，並依 ticket_id 取預填的情況與人員。
-- ============================================================
create or replace function public.coached_pending()
returns table(ticket_id uuid, employee_id text, employee_label text, store_code text,
              coached_at timestamptz, coached_days int, kind text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
begin
  if v_role not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;
  return query
    select p.ticket_id, p.employee_id, p.employee_label, p.store_code, p.coached_at, p.coached_days, p.kind
    from public.coached_pending_rows() p
    where v_role <> 'store_manager' or p.store_code = public.roster_my_store()
    order by p.store_code, p.coached_at, p.ticket_id;
end;
$$;

-- 導覽紅點用：店長＝自己門市尚未約考的人數；客服部、主管、其他身分一律 0（不丟錯，網頁會把它加進 exam_req_badge 的數字）
create or replace function public.coached_pending_count()
returns int
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int := 0;
begin
  if coalesce(public.roster_my_role(), '') = 'store_manager' then
    select count(*)::int into v_n
    from public.coached_pending_rows() p
    where p.store_code = public.roster_my_store();
  end if;
  return v_n;
end;
$$;

-- ============================================================
-- 內部：提醒信內容（主旨與 HTML；文案照老闆確認的樣品畫面 D）
-- 全部使用者文字（門市、人員）都先 HTML escape；不使用「計時」「倒數」「監控」字眼。
-- ============================================================
create or replace function public.coached_reminder_content(
  p_ticket_id uuid, p_label text, p_store_code text, p_days int, p_kind text)
returns table(subject text, body_html text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_store text;
  v_link text;
  v_subject text;
begin
  select coalesce(nullif(btrim(s.name), ''), s.code) into v_store from public.stores s where s.code = p_store_code;
  v_store := coalesce(v_store, p_store_code);
  v_link := public.exam_req_link() || '?from_ticket=' || p_ticket_id::text;
  v_subject := '【提醒】' || p_label || ' 已輔導完成 ' || p_days::text || ' 天，尚未預約考核';
  subject := replace(replace(v_subject, E'\r', ' '), E'\n', ' ');
  body_html :=
    '<div style="font-family:Arial,sans-serif;font-size:15px;color:#222;line-height:1.8">'
    || '<p style="margin:0 0 12px">店長 您好：</p>'
    || '<p style="margin:0 0 12px">' || public.exam_req_esc(v_store) || '的 <b>' || public.exam_req_esc(p_label) || '</b>'
    || case when p_kind is null then '' else '（' || public.exam_req_esc(p_kind) || '）' end
    || ' 已輔導完成 ' || p_days::text || ' 天，尚未預約考核。</p>'
    || '<p style="margin:0 0 12px">請點下方按鈕，選擇希望的考核日期並送出，客服部會接著排定時間。</p>'
    || '<p style="margin:8px 0 16px"><a href="' || public.exam_req_esc(v_link)
    || '" style="display:inline-block;padding:12px 28px;border-radius:10px;background:#0669EB;color:#ffffff;font-weight:700;text-decoration:none;font-size:15px">前往預約考核</a></p>'
    || '<p style="margin:0;color:#888;font-size:12px;border-top:1px solid #eee;padding-top:12px">這是系統自動寄出的提醒。你送出待考回報後，就不會再收到這封信。</p>'
    || '</div>';
  return next;
end;
$$;

-- ============================================================
-- 內部：每日提醒（pg_cron 每天台北 09:00 呼叫；也可在 SQL Editor 手動 select public.coached_reminder_run();）
-- 規則：「尚未約考」且已輔導滿 2 天（coached_days >= 2）者，若還沒寄過、或距上次提醒已滿 2 個台北日、
--   或輔導紀錄在上次提醒之後又被重新填過（coached_at 比 last_reminded_at 新）→ 寄一封給該門市所有店長。
--   準時執行時＝按「已輔導」後第 2、4、6…天各一封；某天漏跑會在下次執行補寄，之後仍每 2 天一封。
-- 同一張單當天不會重複寄（last_reminded_at 記錄）；單張失敗只記一筆 failed 並略過，不影響其他單。
-- 提醒信一律寫進 mail_outbox（kind = 'coached_reminder'，request_id 放改善單編號），客服部在「寄信紀錄」看得到；
--   收件人過濾（只限 app_users 內的 @2motor.tw）由 exam_req_enqueue 負責；沒有店長帳號會記一筆 skipped。
-- 回傳：這次寫進寄信佇列的提醒封數（含因尚未設定寄信而記為 skipped 的；寄出與否看寄信紀錄的狀態）。
-- ============================================================
create or replace function public.coached_reminder_run(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  v_today date := (p_now at time zone 'Asia/Taipei')::date;
  v_to text[];
  v_subject text;
  v_body text;
  v_n int := 0;
begin
  for r in
    select p.ticket_id, p.employee_label, p.store_code, p.coached_days, p.kind
    from public.coached_pending_rows(p_now) p
    join public.improvement_tickets t on t.id = p.ticket_id
    where p.coached_days >= 2
      and (t.last_reminded_at is null
           or t.last_reminded_at < t.coached_at
           or v_today - (t.last_reminded_at at time zone 'Asia/Taipei')::date >= 2)
    order by p.store_code, p.coached_at, p.ticket_id
  loop
    begin
      select coalesce(array_agg(u.email order by u.email), '{}'::text[]) into v_to
      from public.app_users u
      where u.role = 'store_manager' and u.store_code = r.store_code;

      select c.subject, c.body_html into v_subject, v_body
      from public.coached_reminder_content(r.ticket_id, r.employee_label, r.store_code, r.coached_days, r.kind) c;

      perform public.exam_req_enqueue(v_to, v_subject, v_body, 'coached_reminder', r.ticket_id);

      update public.improvement_tickets
         set last_reminded_at = p_now,
             reminder_count = reminder_count + 1
       where id = r.ticket_id;
      v_n := v_n + 1;
    exception when others then
      raise warning '提醒信排入失敗（改善單 %）：%', r.ticket_id, sqlerrm;
      begin
        insert into public.mail_outbox (to_emails, subject, body_html, kind, request_id, status, last_error)
        values ('{}'::text[], '（提醒信產生失敗）', '', 'coached_reminder', r.ticket_id, 'failed', left('排信失敗：' || sqlerrm, 500));
      exception when others then
        null;
      end;
    end;
  end loop;
  return v_n;
end;
$$;

-- ---------- 函式權限：收回 public／anon，只授權 authenticated；內部函式任何網頁角色都不能呼叫 ----------
revoke execute on function public.coached_pending()                                   from public, anon;
revoke execute on function public.coached_pending_count()                             from public, anon;
revoke execute on function public.coached_pending_rows(timestamptz)                   from public, anon, authenticated;
revoke execute on function public.coached_reminder_content(uuid, text, text, int, text) from public, anon, authenticated;
revoke execute on function public.coached_reminder_run(timestamptz)                   from public, anon, authenticated;

grant execute on function public.coached_pending()                                    to authenticated;
grant execute on function public.coached_pending_count()                              to authenticated;

-- ---------- 排程：每天 UTC 01:00（台北 09:00）執行 coached_reminder_run() ----------
-- 沒有 pg_cron 或註冊失敗只提示、不讓整份失敗；先 unschedule 同名再 schedule，可重複執行。
do $$
begin
  if to_regnamespace('cron') is null then
    raise notice '略過排程註冊：沒有 pg_cron。啟用後重跑本檔即可。';
    return;
  end if;
  begin
    begin
      execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'coached_reminder_daily'$q$;
    exception when others then
      null;   -- 原本沒有同名排程就算了
    end;
    execute $q$select cron.schedule('coached_reminder_daily', '0 1 * * *', 'select public.coached_reminder_run()')$q$;
    raise notice '已註冊排程 coached_reminder_daily（每天 UTC 01:00＝台北 09:00）。';
  exception when others then
    raise notice '⚠️ 排程註冊失敗，已略過（其餘部分照常）：%', sqlerrm;
  end;
end
$$;

commit;
