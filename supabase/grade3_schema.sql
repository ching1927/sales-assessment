-- ============================================================
-- 業務考核系統：三級制評分（優良／尚可／待加強）＋新人考核面向備註必填（Supabase / Postgres）
--
-- ⚠️ 尚未在真實 Supabase 執行，待老闆同意後才執行。可重複執行（重跑不報錯、不改任何成績單資料）。
--
-- ---------- 執行順序（前提：下列都已執行過）----------
--   roster_schema → assess_schema → bank_schema → accounts_schema → notes_visible_schema → backoffice_schema →
--   spotcheck_schema → url_patch → weak_suggest_schema → exam_request_schema → phase1_schema → checkup_schema →
--   （roster_line_schema、coached_reminder_schema 若已上線也都在前面）→ 【本檔 grade3_schema.sql】 → grade3_verify_fake.sql（可選）
--   網頁（js/、assess.html 等）要在本檔執行「之後」才上線（舊網頁還會送舊等級，本檔執行後會被擋）。
--
-- ---------- 備份提醒（執行本檔之前先做；備份表必須啟用 row level security）----------
--   drop table if exists public.bak_grade3_items;
--   drop table if exists public.bak_grade3_secrets;
--   drop table if exists public.bak_grade3_spot;
--   create table public.bak_grade3_items   as select * from public.assessment_items;
--   create table public.bak_grade3_secrets as select * from public.assessment_item_secrets;
--   create table public.bak_grade3_spot    as select * from public.spot_inspections;
--   alter table public.bak_grade3_items   enable row level security;
--   alter table public.bak_grade3_secrets enable row level security;
--   alter table public.bak_grade3_spot    enable row level security;
--   （備份表不開任何 policy ＝ 網頁角色完全讀不到；確認無誤後可 drop）
--
-- ---------- 這次改了什麼（老闆已批准）----------
-- 等級改三級：優良 100、尚可 70、待加強 40，另保留「不適用」（每題組最多 2 個，不變）。
-- 舊成績單（等級字串為 優／良／待加強／不及格）一律不換算、不修改：
--   * 讀取與計分函式「同時認得新舊字串」：優、優良→100；良、尚可→70；待加強→40；不及格→0
--   * 新送出的資料「只准新字串」：舊字串「優」「良」「不及格」會被擋下（見下方三個觸發器）
--   * 七面向配分、合格線（新人 70、其餘 85）、判定門檻都沒有動
-- 新人考核（assessments.tenure = '新人'）送出時，面向評為尚可或待加強者，面向備註不得為空（去掉空白後）。
--
-- ---------- 資料庫實際硬寫等級名稱的地方（已逐一查過）----------
--   等級在資料庫是「存字串」（assessment_items.levels／spot_inspections.levels 的 jsonb，值是等級名稱），不是存分數。
--   整個資料庫只有一個函式把等級名稱換成百分比：assess_level_pct。其他全都透過它：
--   assess_check_levels（暫存與送出的格式檢查）、assess_score_item、assess_score_session（題組分數、總分、最弱面向）、
--   assess_submit（含健檢，checkup_schema 版）、assess_weak_profile／assess_draft_weak／assess_suggest_pool
--   （弱項分析、建議題組）、analytics_dim_rates／assessment 面向檢視（近期考核、雷達圖資料）。
--   所以只需讓 assess_level_pct 認得新字串，上面全部自動同時支援新舊單；assess_verdict（判定）只看總分，不看等級名稱。
--
-- ---------- 本檔動到的既有函式（create or replace，僅此一個）----------
--   1. public.assess_level_pct(text)：新增 優良→100、尚可→70；原本 優→100、良→70、待加強→40、不及格→0 全部保留。
--      還原方式（若要退回）：用 assess_schema.sql 內同名函式的原定義覆蓋即可。
--   不改 assess_submit、assess_save_item、spot_register、assess_check_levels（避免整份複製長函式造成回歸風險）。
--
-- ---------- 本檔新增的東西 ----------
--   * 欄位 assessment_item_secrets.dim_notes（jsonb，預設空物件）：面向備註 { 面向名: 文字 }。
--     放在機密表＝只有客服部讀得到；店長與主管現在看不到（是否開放屬另一項任務）。舊單沒有這欄資料＝空物件，不會出錯。
--   * 函式 assess_save_dim_notes(題組id, 面向備註)：客服部、本人草稿才能寫；只留「該面向目前是尚可／待加強」的備註。
--   * 函式 grade3_levels_guard()＋觸發器：assessment_items、spot_inspections 的 levels 一旦被新增或改動，
--     只准新等級（拒絕 優／良／不及格）；沒改 levels 的更新（例如送出時寫分數）不受影響，既有資料完全不動。
--   * 函式 grade3_submit_guard()＋觸發器：成績單由草稿變已送出時，(1) 每個題組不得含舊等級（舊草稿保險）；
--     (2) 新人考核：尚可／待加強的面向備註不得為空。錯誤訊息一律中文。
--
-- 單一交易：中途任何一步報錯整份自動回復。
-- ============================================================
begin;
set local lock_timeout = '10s';

-- ---------- 0. 前提檢查 ----------
do $$
begin
  if to_regprocedure('public.assess_level_pct(text)') is null
     or to_regprocedure('public.assess_dim_order()') is null
     or to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.roster_my_email()') is null
     or to_regprocedure('public.assess_submit(uuid)') is null
     or to_regprocedure('public.assess_save_item(uuid, jsonb, text, text)') is null
     or to_regclass('public.assessment_item_secrets') is null
     or to_regclass('public.spot_inspections') is null then
    raise exception '前提不滿足：請先依檔頭順序執行 assess_schema、url_patch、spotcheck_schema 等前面的檔案';
  end if;
end
$$;

-- ---------- 1. 等級 → 百分比：新舊字串都認得 ----------
create or replace function public.assess_level_pct(p_level text)
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select (case p_level
            -- 新（三級制）
            when '優良' then 100
            when '尚可' then 70
            -- 舊（四級制，只用來讀舊單；新資料由觸發器擋下舊字串）
            when '優' then 100
            when '良' then 70
            when '不及格' then 0
            -- 兩制共用
            when '待加強' then 40
          end)::numeric;
$$;

-- ---------- 2. 面向備註欄位（機密表，只有客服部讀得到）----------
alter table public.assessment_item_secrets
  add column if not exists dim_notes jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.assessment_item_secrets'::regclass
                    and conname = 'assessment_item_secrets_dim_notes_object') then
    alter table public.assessment_item_secrets
      add constraint assessment_item_secrets_dim_notes_object
      check (jsonb_typeof(dim_notes) = 'object');
  end if;
end
$$;

-- ---------- 3. assess_save_dim_notes：暫存面向備註 ----------
-- 與 assess_save_item 同樣的權限：只有客服部、只有建立者本人、只有草稿。
-- 備註只保留「該面向目前等級是尚可或待加強」的（所以要先 assess_save_item 存等級、再呼叫本函式）；
-- 去頭尾空白（含全形空白），空字串不存；單則最多 2000 字。
create or replace function public.assess_save_dim_notes(p_item_id uuid, p_dim_notes jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
  v_levels jsonb;
  v_dims text[] := public.assess_dim_order();
  v_out jsonb := '{}'::jsonb;
  k text;
  v jsonb;
  v_txt text;
  v_n int;
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select a.status, a.examiner_email, i.levels into v_status, v_owner, v_levels
  from public.assessment_items i
  join public.assessments a on a.id = i.assessment_id
  where i.id = p_item_id
  for update of a;
  if not found then
    raise exception '找不到題組';
  end if;
  if v_status <> 'draft' then
    raise exception '只有草稿可以暫存評分';
  end if;
  if v_owner <> v_me then
    raise exception '只有建立者本人可以操作這張考核';
  end if;

  if p_dim_notes is null or jsonb_typeof(p_dim_notes) <> 'object' then
    raise exception '面向備註格式不正確，必須是物件';
  end if;

  for k, v in select key, value from jsonb_each(p_dim_notes) loop
    if not (k = any(v_dims)) then
      raise exception '未知的面向：%', k;
    end if;
    if jsonb_typeof(v) <> 'string' then
      raise exception '面向「%」的備註必須是文字', k;
    end if;
    v_txt := btrim(v #>> '{}', E' \t\r\n' || chr(12288));
    if length(v_txt) > 2000 then
      raise exception '面向「%」的備註太長（最多 2000 字）', k;
    end if;
    if v_txt <> '' and (v_levels ->> k) in ('尚可', '待加強') then
      v_out := v_out || jsonb_build_object(k, v_txt);
    end if;
  end loop;

  update public.assessment_item_secrets set dim_notes = v_out where item_id = p_item_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception '找不到題組資料';
  end if;
end;
$$;

-- ---------- 4. 新資料只准新等級（觸發器）----------
-- 套在 assessment_items 與 spot_inspections：新增，或 levels 欄位被改成不同的值時檢查。
-- 沒動到 levels 的更新（例如送出時寫分數、作廢）完全不檢查，所以舊資料不受影響。
create or replace function public.grade3_levels_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  k text;
  v text;
begin
  if tg_op = 'UPDATE' and new.levels is not distinct from old.levels then
    return new;
  end if;
  for k, v in select key, value from jsonb_each_text(new.levels) loop
    if v in ('優', '良', '不及格') then
      raise exception '面向「%」的等級「%」是舊制等級；現在只能選優良、尚可、待加強或不適用', k, v;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists grade3_items_levels_trg on public.assessment_items;
create trigger grade3_items_levels_trg
  before insert or update of levels on public.assessment_items
  for each row execute function public.grade3_levels_guard();

drop trigger if exists grade3_spot_levels_trg on public.spot_inspections;
create trigger grade3_spot_levels_trg
  before insert or update of levels on public.spot_inspections
  for each row execute function public.grade3_levels_guard();

-- ---------- 5. 送出時的把關（觸發器）：舊等級保險＋新人面向備註必填 ----------
-- 成績單 status 由 draft 變 submitted 的瞬間檢查（assess_submit 先算完各題組分數才會走到這裡，
-- 所以「評分不完整」的錯誤仍然優先）。追加題（is_extra）也一樣要寫。
-- security definer：要讀機密表的備註；不開放前端直接呼叫（見權限段）。
create or replace function public.grade3_submit_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  d text;
  v_lv text;
  v_dims text[] := public.assess_dim_order();
begin
  for r in
    select i.seq, i.is_extra, i.levels, coalesce(s.dim_notes, '{}'::jsonb) as notes
    from public.assessment_items i
    left join public.assessment_item_secrets s on s.item_id = i.id
    where i.assessment_id = new.id
    order by i.seq
  loop
    foreach d in array v_dims loop
      v_lv := r.levels ->> d;
      if v_lv in ('優', '良', '不及格') then
        raise exception '第 % 個題組的「%」還是舊制等級「%」；新的成績單只能選優良、尚可、待加強或不適用，請重新評分', r.seq, d, v_lv;
      end if;
      if new.tenure = '新人'
         and v_lv in ('尚可', '待加強')
         and nullif(btrim(r.notes ->> d, E' \t\r\n' || chr(12288) || chr(160) || chr(8203) || chr(65279)), '') is null then
        raise exception '新人考核：第 % 個題組的「%」評為「%」，必須寫下備註才能送出', r.seq, d, v_lv;
      end if;
    end loop;
  end loop;
  return new;
end;
$$;

drop trigger if exists grade3_submit_guard_trg on public.assessments;
create trigger grade3_submit_guard_trg
  before update of status on public.assessments
  for each row
  when (old.status = 'draft' and new.status = 'submitted')
  execute function public.grade3_submit_guard();

-- ---------- 6. 函式權限 ----------
revoke execute on function public.assess_save_dim_notes(uuid, jsonb)   from public, anon;
grant  execute on function public.assess_save_dim_notes(uuid, jsonb)   to authenticated;
revoke execute on function public.grade3_levels_guard()         from public, anon, authenticated;
revoke execute on function public.grade3_submit_guard()         from public, anon, authenticated;
-- assess_level_pct 的授權沿用 assess_schema.sql 的設定（create or replace 不會改動既有授權）

commit;
