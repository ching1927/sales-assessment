-- ============================================================
-- 業務考核系統：網址欄位修補（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 前提：spotcheck_schema.sql 與 notes_visible_schema.sql 已執行（本檔可直接在「已執行舊版」的資料庫上跑）。
-- 全新安裝：spotcheck_schema.sql 內的 spot_register 已是新版，但 assessment_items.note_url 與
-- 四參數的 assess_save_item 只在本檔，所以全新安裝後仍要再跑一次本檔。
--
-- ---------- 兩項變更（老闆決定）----------
-- 1. spot_register：p_message 參數與 spot_inspections.message 欄位名稱不變，內容改為
--    「訊息抽檢-LINE聊天室網址」，必填。去頭尾空白（含全形空白、換行）後必須符合
--    ^https?://[^[:space:]]+$（不分大小寫）且長度 <= 500，存去空白後的值。
--    這項驗證排在其他所有驗證之後（找不到員工、資格、日期、判定、原因、七面向等級的錯誤優先）。
--    與目前 spotcheck_schema.sql 的 spot_register 只差這一項（本檔內容與它逐字相同）。
-- 2. assessment_items 新增 note_url（備註網址，非必填）＋check（null 或 長度 <= 500 且符合同一個格式）；
--    assess_save_item 新增第 4 個參數 p_note_url text default null。
--    assess_save_item 以「最後生效的版本」為基礎：notes_visible_schema.sql（備註寫入 assessment_items.note）
--    晚於 assess_schema.sql，所以以 notes_visible_schema.sql 的版本為準，其餘行為逐行保留
--    （簽名前三個參數、回傳 void、security definer、固定 search_path、客服部檢查、題組歸屬／草稿／本人檢查、
--      check_levels 驗證、備註處理 nullif(btrim(p_note), '') 都完全相同）。
--    新增行為：p_note_url 去頭尾空白後，空字串或全空白視為 null；格式錯誤丟
--    「備註網址格式不正確（需 http 或 https 開頭，不可含空白，最長 500 字）」；排在所有既有檢查之後。
--    每次呼叫「整份取代」該題組的評分、備註與備註網址（與備註一樣：沒傳＝清除）。
--    ⚠️ 舊的三參數呼叫（例如尚未更新的前端）仍可運作，但每次存檔會把 note_url 清成 null；
--       前端存檔時必須一併傳 p_note_url。
--    為避免函式重載產生歧義，先 drop 舊的三參數版本，再建立新版，並重做 revoke／grant。
--    可見性：note_url 在 assessment_items 上，沿用既有 RLS（客服部全看；主管看已送出；店長看自己門市已送出；
--    草稿與作廢只有客服部），不需改 RLS。已送出／作廢後 assess_save_item 一律被拒，note_url 同樣不可改。
--
-- 怎麼執行（之後老闆同意才做）：
--   1. Supabase SQL Editor → New query → 貼上整份 → Run。
--   2. 再跑 url_patch_verify_fake.sql，再跑 spotcheck_verify_fake.sql（全程 rollback，不留資料）。
--
-- 單一交易：begin; … commit;，任何一步報錯整份回復。可重複執行：add column if not exists、
-- 約束先 drop 再建、函式 create or replace／drop if exists 後重建。既有資料不受影響（新欄位預設 null）。
--
-- ⚠️ 影響到的既有驗證腳本：notes_visible_verify_fake.sql 內以三參數簽名
--    'public.assess_save_item(uuid, jsonb, text)'::regprocedure 查函式的兩項（區段 4），本檔執行後會失敗
--    （簽名已變成四參數），那兩項需另行更新；其餘三參數「呼叫」寫法照舊可用。
-- ============================================================

begin;

set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessment_items') is null
     or to_regclass('public.spot_inspections') is null then
    raise exception '請先執行 assess_schema.sql 與 spotcheck_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'assessment_items' and column_name = 'note') then
    raise exception '請先執行 notes_visible_schema.sql（assessment_items 沒有 note 欄位）';
  end if;
  if to_regprocedure('public.spot_register(text, date, text, jsonb, text, text)') is null
     or to_regprocedure('public.assess_assert_cs()') is null
     or to_regprocedure('public.assess_check_levels(jsonb, boolean)') is null then
    raise exception '缺少必要函式，請先執行 assess_schema.sql 與 spotcheck_schema.sql';
  end if;
end
$$;

-- ---------- 1. assessment_items.note_url ----------
alter table public.assessment_items add column if not exists note_url text;

alter table public.assessment_items drop constraint if exists assessment_items_note_url_check;
alter table public.assessment_items
  add constraint assessment_items_note_url_check
  check (note_url is null
         or (length(note_url) <= 500 and note_url ~* '^https?://[^[:space:]]+$'));

comment on column public.assessment_items.note_url is
  '考核備註網址（非必填，http 或 https 開頭、不含空白、最長 500 字）。可見範圍與備註文字相同。';

-- ---------- 2. spot_register：p_message 改為必填的 LINE 聊天室網址（與 spotcheck_schema.sql 相同） ----------
-- 登記一次抽查（客服部）。
-- 驗證人員資格、七面向等級（缺一不可、不適用最多 2 個）、不適當必填原因；寫入抽查；
-- p_message ＝「訊息抽檢-LINE聊天室網址」：去頭尾空白後必填、符合 ^https?://[^[:space:]]+$（不分大小寫）、長度 <= 500，
-- 存去空白後的值；這項驗證排在其他所有驗證之後（其他錯誤優先）。
-- 不適當就開黃單，並在「同一個交易內」套用紅單與回考核期的規則：
--   * 本日曆月、最近一張有效紅單之後的有效黃單 >= 5 → 自動開一張紅單，黃單從 0 重算
--   * 本日曆季、最近一筆回考核期紀錄之後的有效紅單 >= 2 → 自動開一筆回考核期（待執行），employees.probation_since 設為今天
-- 回傳 {inspection_id, total_score, weakest_dims, yellow_id, red_id, probation_id}（沒有就是 null）。
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
  v_r uuid;
  v_p uuid;
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

  -- 抽查對象資格
  if v_emp.status <> '在職' then
    raise exception '該員工已離職，不能抽查';
  end if;
  if not v_emp.include_in_assessment then
    raise exception '該員工不在考核名單（需納入考核），不能抽查';
  end if;
  if v_emp.probation_since is not null then
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
        returning id into v_p;

        update public.employees set probation_since = v_today where id = v_emp.id;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'inspection_id', v_ins,
    'total_score', s.item_score,
    'weakest_dims', to_jsonb(s.weakest_dims),
    'yellow_id', v_y,
    'red_id', v_r,
    'probation_id', v_p
  );
end;
$$;

-- ---------- 3. assess_save_item：新增第 4 個參數 p_note_url ----------
-- 先 drop 舊的三參數版本，避免出現「三參數」與「四參數（第 4 個有預設值）」兩個函式造成呼叫歧義。
drop function if exists public.assess_save_item(uuid, jsonb, text);

create or replace function public.assess_save_item(p_item_id uuid, p_levels jsonb, p_note text, p_note_url text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_me text;
  v_status text;
  v_owner text;
  v_url text := nullif(btrim(coalesce(p_note_url, ''), E' \t\r\n' || chr(12288)), '');
begin
  perform public.assess_assert_cs();
  v_me := public.roster_my_email();

  select a.status, a.examiner_email into v_status, v_owner
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

  perform public.assess_check_levels(p_levels, false);

  -- 【新增】備註網址（非必填；空白視為 null）；排在所有既有檢查之後
  if v_url is not null and (v_url !~* '^https?://[^[:space:]]+$' or length(v_url) > 500) then
    raise exception '備註網址格式不正確（需 http 或 https 開頭，不可含空白，最長 500 字）';
  end if;

  update public.assessment_items
     set levels = p_levels,
         note = nullif(btrim(p_note), ''),
         note_url = v_url
   where id = p_item_id;
end;
$$;

-- ---------- 函式權限（重做） ----------
revoke execute on function public.spot_register(text, date, text, jsonb, text, text) from public, anon;
grant  execute on function public.spot_register(text, date, text, jsonb, text, text) to authenticated;
revoke execute on function public.assess_save_item(uuid, jsonb, text, text) from public, anon;
grant  execute on function public.assess_save_item(uuid, jsonb, text, text) to authenticated;

commit;
