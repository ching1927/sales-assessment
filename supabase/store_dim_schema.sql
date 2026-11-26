-- ============================================================
-- 業務考核系統：各門市面向分析（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（create or replace，不動任何資料、不建任何資料表）。
--
-- ---------- 規則 ----------
--   依門市彙整「待加強回覆」登記時勾選的「可改善面向」被勾次數。
--   1. 資料來源 spot_inspections；只計 verdict = '不適當'（畫面叫待加強回覆）且 improve_dims 至少勾 1 個面向的登記。
--      優良回覆、舊制紀錄、沒勾面向的待加強回覆，分子分母都不算。
--   2. 期間以登記日 checked_on 落在 [p_from, p_to]（含頭尾）為準。
--   3. 依「登記當時的門市」歸屬（spot_inspections.store_code 是登記當下的快照）。
--   4. 回傳 { 門市代碼、門市名稱、weak_records（符合條件的筆數）、dim_counts（7 個元素的次數陣列）}。
--      dim_counts 順序固定：資訊正確性、預設訊息運用、問題掌握、主動引導、風險意識、語氣與禮貌、文字品質。
--   5. 門市清單與 checkup_yellow_ranking 同一套：排除總公司；只回「在職＋納入考核＋已上線人數 > 0 或 weak_records > 0」的門市；
--      沒有符合紀錄的門市也列出（weak_records = 0、dim_counts 全 0）。
--   6. 客服部、總公司主管、店長都看得到全部門市的彙總；其他角色與沒登入的人一律「沒有權限」。
--   7. 不回傳任何登記內容、原因、人員姓名或編號、網址與截圖。
--   （spot_inspections 沒有作廢欄位，登記不會被作廢，所以沒有「作廢不算」的條件。）
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   … → spotcheck_schema → phase1_schema → spotdims_schema（improve_dims）→ …
--   【本檔 store_dim_schema.sql】 → store_dim_verify_fake.sql（可選）
--
-- 新增 1 個函式 checkup_store_dims(p_from date, p_to date)（security definer、stable）；不改任何既有函式與資料表。
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regclass('public.spot_inspections') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.employees') is null
     or to_regprocedure('public.roster_my_role()') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 roster_schema、spotcheck_schema、phase1_schema 等前面的檔案';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'employees' and column_name = 'period_status') then
    raise exception '前提不滿足：請先執行 phase1_schema.sql（employees.period_status）';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'spot_inspections' and column_name = 'improve_dims') then
    raise exception '前提不滿足：請先執行 spotdims_schema.sql（spot_inspections.improve_dims）';
  end if;
end
$$;

-- ---------- 1. checkup_store_dims：各門市面向被勾次數（只回彙總） ----------
create or replace function public.checkup_store_dims(p_from date, p_to date)
returns table(store_code text, store_name text, weak_records int, dim_counts int[])
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_dims text[] := array['資訊正確性','預設訊息運用','問題掌握','主動引導','風險意識','語氣與禮貌','文字品質']::text[];
begin
  if v_role not in ('cs_admin', 'hq_viewer', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception '日期範圍不正確';
  end if;

  return query
    with w as (
      select i.store_code, i.improve_dims
      from public.spot_inspections i
      where i.verdict = '不適當'
        and coalesce(cardinality(i.improve_dims), 0) >= 1
        and i.checked_on >= p_from
        and i.checked_on <= p_to
    ), t as (
      select w.store_code,
             count(*)::int as n,
             array[
               (count(*) filter (where v_dims[1] = any (w.improve_dims)))::int,
               (count(*) filter (where v_dims[2] = any (w.improve_dims)))::int,
               (count(*) filter (where v_dims[3] = any (w.improve_dims)))::int,
               (count(*) filter (where v_dims[4] = any (w.improve_dims)))::int,
               (count(*) filter (where v_dims[5] = any (w.improve_dims)))::int,
               (count(*) filter (where v_dims[6] = any (w.improve_dims)))::int,
               (count(*) filter (where v_dims[7] = any (w.improve_dims)))::int
             ] as dc
      from w
      group by w.store_code
    ), h as (
      select e.store_code, count(*)::int as n
      from public.employees e
      where e.status = '在職'
        and e.include_in_assessment
        and e.period_status = '已上線'
      group by e.store_code
    )
    select s.code, s.name, coalesce(t.n, 0),
           coalesce(t.dc, array[0,0,0,0,0,0,0]::int[])
    from public.stores s
    left join t on t.store_code = s.code
    left join h on h.store_code = s.code
    where s.code <> '總公司'
      and (coalesce(t.n, 0) > 0 or coalesce(h.n, 0) > 0)
    order by s.code;
end;
$$;

-- ---------- 2. 函式權限：收回 public／anon，只授權 authenticated（角色檢查在函式內部） ----------
revoke execute on function public.checkup_store_dims(date, date) from public, anon, authenticated;
grant  execute on function public.checkup_store_dims(date, date) to authenticated;

notify pgrst, 'reload schema';

commit;
