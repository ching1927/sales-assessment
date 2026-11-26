-- ============================================================
-- 業務考核系統：各門市黃單排名（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（create or replace，不動任何資料、不建任何資料表）。
--
-- ---------- 老闆定案（2026-11）----------
--   每一季與全年，各門市被開的黃單數量排名。算法：
--   1. 黃單＝spot_tickets 中 kind = '黃' 且 status = '有效'（被作廢的不算）。
--   2. 期間以開單日 issued_on 落在 [p_from, p_to]（含頭尾）為準。
--   3. 依「開單當時的門市」歸屬：spot_tickets.store_code 是開單當下的門市快照，人員之後換店，歷史排名不會變。
--   4. 人數＝該門市「目前」在職、納入考核、已上線的人數（employees 現況，不是歷史人數）。
--   5. 排除總公司；列出所有門市（2026-11-26 老闆改：原本只回「人數 > 0 或 黃單 > 0」，中和因沒有已上線人員而不見，改為全列，沒資料的門市 0 張／0 人）。
--   6. 客服部、總公司主管、店長都看得到「全部門市」的彙總（店長也看全部，這是老闆定案）；
--      但只回 { 門市代碼、門市名稱、黃單張數、人數 } 四欄，不含任何黃單內容、原因、人員姓名或編號、抽查網址與截圖。
--      其他角色與沒登入的人一律「沒有權限」。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   … → roster_schema → spotcheck_schema → phase1_schema（employees.period_status）→ checkup_schema → …
--   【本檔 yellow_ranking_schema.sql】 → yellow_ranking_verify_fake.sql（可選）
--   網頁（checkup.html 的「黃單排名」分頁）要在本檔執行「之後」才上線；沒執行前頁面會顯示「排名功能尚未啟用」的提示。
--
-- ---------- 本檔做了什麼 ----------
--   新增 1 個對外函式 checkup_yellow_ranking(p_from date, p_to date)（security definer、stable）。
--   不改任何既有函式與資料表；checkup_quarters_list 等「門市季次」函式與資料原樣保留（網頁只是不再顯示季次表）。
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.spot_tickets') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.employees') is null
     or to_regprocedure('public.roster_my_role()') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 roster_schema、spotcheck_schema、phase1_schema 等前面的檔案';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status') then
    raise exception '前提不滿足：請先執行 phase1_schema.sql（employees.period_status）';
  end if;
end
$$;

-- ---------- 1. checkup_yellow_ranking：各門市黃單張數＋人數（只回彙總） ----------
create or replace function public.checkup_yellow_ranking(p_from date, p_to date)
returns table(store_code text, store_name text, tickets int, headcount int)
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
  if p_from is null or p_to is null or p_from > p_to then
    raise exception '日期範圍不正確';
  end if;

  return query
    with t as (
      select k.store_code, count(*)::int as n
      from public.spot_tickets k
      where k.kind = '黃'
        and k.status = '有效'
        and k.issued_on >= p_from
        and k.issued_on <= p_to
      group by k.store_code
    ), h as (
      select e.store_code, count(*)::int as n
      from public.employees e
      where e.status = '在職'
        and e.include_in_assessment
        and e.period_status = '已上線'
      group by e.store_code
    )
    select s.code, s.name, coalesce(t.n, 0), coalesce(h.n, 0)
    from public.stores s
    left join t on t.store_code = s.code
    left join h on h.store_code = s.code
    where s.code <> '總公司'
    order by s.code;
end;
$$;

-- ---------- 2. 函式權限：收回 public／anon，只授權 authenticated（角色檢查在函式內部） ----------
revoke execute on function public.checkup_yellow_ranking(date, date) from public, anon, authenticated;
grant  execute on function public.checkup_yellow_ranking(date, date) to authenticated;

commit;
