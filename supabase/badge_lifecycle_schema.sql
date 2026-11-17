-- ============================================================
-- 業務考核系統：導覽列紅點「直到這個考生的事情完整結束才消」（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（全部 create or replace）。
--
-- ---------- 老闆要求 ----------
--   「待考回報」與「成績單＆考核後台的改善單」不能再「點進去就消」，要到這個考生的問題或考核完整結束才消。
--   例：新人進來，客服在人員名冊填好資料送出後，該門市店長的待考回報分頁就有紅點，直到這個新人被設為「已上線」才消。
--   結束點：新人＝人員 period_status 變成「已上線」；改善單＝複檢完成（改善單狀態變成 closed）。
--   中途離職（status 不是在職）、改善單被取消的，也不再計入。
--
-- ---------- 改了什麼（簽名與權限都不變，只換函式內容；另新增一支 improve_badge）----------
--   1. exam_req_badge()（導覽「待考回報」分頁的紅點，網頁 js/appbar.js 呼叫）
--        客服部：待處理回報數＋待開通回覆權限數（原本就不靠「已看」，照舊）
--        店長　：自己門市「在職、納入考核、period_status = '考核期'」的人數（新人建檔起算，到已上線才消）
--                原本的「mgr_seen = false 未看過的客服回覆數」拿掉（那就是「點進去就消」的來源）
--        主管　：0；其他身分：丟「沒有權限」（與原本相同）
--   2. improve_badge()（新增；導覽「成績單&考核後台」分頁的紅點，網頁 js/appbar.js 呼叫）
--        客服部：全部門市「待改善（open）＋已輔導（coached）」且人員在職、納入考核的改善單數
--        店長　：同上，但只算自己門市（依改善單開單當時的門市，和後台清單的看得到範圍一致）
--        主管：0；其他身分：丟「沒有權限」
--      改善單變成已結案（closed，複檢完成）或已取消（cancelled）就不再計入。
--
-- ---------- 刻意不動 ----------
--   exam_req_mark_seen、exam_requests.mgr_seen 欄位、coached_pending／coached_pending_count 都不動
--   （mgr_seen 仍用來標記待考回報清單上「新的客服回覆」；只是不再影響導覽紅點）。
--   網頁 js/appbar.js 仍會把 coached_pending_count()（已輔導但尚未送出待考回報的人數）加到店長的待考回報紅點。
--
-- 前提：roster_schema（employees、roster_my_role／roster_my_store）、backoffice_schema（improvement_tickets）、
--       exam_request_schema（exam_requests）、phase1_schema（employees.period_status、reply_activations）已執行。
-- 緊急還原：重跑 phase1_schema.sql 之前版本的 exam_req_badge（見該檔第 13 段）即可；improve_badge 可 drop function。
-- ============================================================
begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.exam_requests') is null
     or to_regclass('public.reply_activations') is null
     or to_regclass('public.improvement_tickets') is null then
    raise exception '請先執行 exam_request_schema.sql、phase1_schema.sql、backoffice_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status') then
    raise exception '請先執行 phase1_schema.sql（缺少 employees.period_status）';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null then
    raise exception '請先執行 roster_schema.sql（缺少必要函式）';
  end if;
end
$$;

-- ---------- 1. exam_req_badge：待考回報分頁紅點 ----------
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
    -- 新人從名冊建檔（考核期）起算，到被設為已上線為止；離職、未納入考核不算
    select count(*)::int into v_n
      from public.employees e
     where e.store_code = public.roster_my_store()
       and e.status = '在職'
       and e.include_in_assessment
       and e.period_status = '考核期';
  elsif v_role = 'hq_viewer' then
    v_n := 0;
  else
    raise exception '沒有權限';
  end if;
  return v_n;
end;
$$;

-- ---------- 2. improve_badge：成績單&考核後台分頁紅點（改善單到複檢完成才消） ----------
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
     where t.status in ('open', 'coached')
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

-- ---------- 3. 權限（exam_req_badge 沿用原設定，這裡重申；improve_badge 比照） ----------
revoke execute on function public.exam_req_badge() from public, anon;
grant  execute on function public.exam_req_badge() to authenticated;
revoke execute on function public.improve_badge()  from public, anon;
grant  execute on function public.improve_badge()  to authenticated;

commit;
