-- ============================================================
-- 業務考核系統：題庫管理（客服部用 Google 登入管理題庫）資料庫函式（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 用途：取代舊管理頁（共用密碼）。新增五個「以客服部身分檢查」的函式，
--   行為與舊抽選器 schema.sql 的 admin_* 函式一致（驗證規則、洗牌、改名／合併都照舊）。
-- 前提：roster_schema.sql、assess_schema.sql、考題抽選器的 schema.sql 都已在同一個專案執行過。
-- 本檔只「新增」東西：不新增資料表、不修改也不刪除既有任何資料表、函式、policy、觸發器。
--
-- ---------- 名稱衝突自查結果：無衝突 ----------
-- 既有名稱（本檔不會碰）：
--   考題抽選器：questions、drawn、category_last、app_secret、_pw_ok、_assert_pw、
--               list_categories、draw_questions、admin_login、admin_list_questions、
--               admin_save_question、admin_delete_question、admin_rename_category、admin_reset
--   人員名冊／評分：roster_*、assess_*、assessment*（含 assess_categories）
-- 本檔新增的名稱（全部以 bank_ 開頭，與上面皆不重複）：
--   函式：bank_assert_cs、bank_list_questions、bank_save_question、
--         bank_delete_question、bank_rename_category、bank_reset
--
-- 分類剩餘題數沿用已上線的 assess_categories()，本檔不重複實作。
--
-- 安全設計：
--   * 全部 security definer、固定 search_path；不是客服部（含未登入、沒帳號、總公司主管、店長）
--     一律 raise exception '沒有權限'。
--   * 收回 public／anon 的 execute，只授權 authenticated。
--   * 不開放網頁直接讀寫 questions、drawn、category_last（這三張表維持原樣：開 RLS、無 policy、
--     無任何直接權限）。題庫內容（含考點）只有客服部可經由這些函式讀到。
--   * 會寫入的四個函式（儲存、刪除、改名、洗牌）與舊 draw_questions、assess_draw 使用同一把 advisory lock
--     （pg_advisory_xact_lock(hashtext('exam_draw_questions'))），抽題與管理操作不會同時發生；
--     列表是純讀取，不取鎖（與舊 admin_list_questions 一致）。
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   執行完再跑 bank_verify_fake.sql 驗證（全程 rollback，不留資料）。
--
-- 可重複執行：函式 create or replace，重跑不會報錯，也不會動到題庫資料。
-- ============================================================

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.questions') is null
     or to_regclass('public.drawn') is null
     or to_regclass('public.category_last') is null
     or to_regclass('public.app_users') is null then
    raise exception '請先執行考題抽選器的 schema.sql 與 roster_schema.sql';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.assess_categories()') is null then
    raise exception '請先執行 roster_schema.sql 與 assess_schema.sql';
  end if;
end
$$;

-- ---------- 身分檢查（內部用，不開放給前端直接呼叫） ----------
-- 不是客服部（含未登入、沒帳號、總公司主管、店長）一律丟「沒有權限」。
create or replace function public.bank_assert_cs()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;
end;
$$;

-- ---------- 列出題庫 ----------
-- 回傳全部題組（含考點），drawn＝本輪是否已抽。
-- 排序：分類依「第一次出現」（該分類最小 id）、同分類內依 id（同舊 admin_list_questions）。
create or replace function public.bank_list_questions()
returns table(id bigint, category text, code text, title text, steps jsonb, drawn boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
begin
  perform public.bank_assert_cs();
  return query
    select q.id, q.category, q.code, q.title, q.steps,
           exists (select 1 from public.drawn d where d.question_id = q.id)
    from public.questions q
    order by min(q.id) over (partition by q.category), q.id;
end;
$$;

-- ---------- 新增／編輯題組 ----------
-- p_id 為 null＝新增，回傳新題組 id；否則編輯該題，回傳 p_id。
-- 驗證規則與舊 admin_save_question 完全一致（去空白、名稱 ≤100 字、代號 ≤10 字、
-- 步驟 1～30 個、每步 action 為非空文字、point 為文字或缺漏、action／point 各 ≤500 字；
-- 只保留 action、point 兩個鍵）。
-- 編輯時若改變分類，把這題從已抽記錄移除（同舊函式，避免記錄錯亂）。
create or replace function public.bank_save_question(
  p_id bigint, p_category text, p_code text, p_title text, p_steps jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cat text := btrim(coalesce(p_category, ''));
  v_code text := nullif(btrim(coalesce(p_code, '')), '');
  v_title text := btrim(coalesce(p_title, ''));
  v_steps jsonb;
  v_n int;
  v_bad int;
  v_old text;
  v_id bigint;
begin
  perform public.bank_assert_cs();

  if v_cat = '' then raise exception '分類不可空白'; end if;
  if v_title = '' then raise exception '題組名稱不可空白'; end if;
  if length(v_title) > 100 then raise exception '題組名稱太長（最多 100 字）'; end if;
  if v_code is not null and length(v_code) > 10 then raise exception '代號太長（最多 10 字）'; end if;

  if p_steps is null or jsonb_typeof(p_steps) <> 'array' then
    raise exception '步驟格式不正確，必須是清單';
  end if;
  v_n := jsonb_array_length(p_steps);
  if v_n < 1 then raise exception '至少要有 1 個步驟'; end if;
  if v_n > 30 then raise exception '步驟太多（最多 30 個）'; end if;

  -- 每個步驟必須是物件，action 為非空字串，point 為字串或缺漏
  select count(*) into v_bad
  from jsonb_array_elements(p_steps) e
  where jsonb_typeof(e) <> 'object'
     or jsonb_typeof(e -> 'action') is distinct from 'string'
     or btrim(e ->> 'action') = ''
     or (e ? 'point' and jsonb_typeof(e -> 'point') not in ('string', 'null'));
  if v_bad > 0 then
    raise exception '每個步驟都要有「考官操作」文字，考點必須是文字';
  end if;

  select count(*) into v_bad
  from jsonb_array_elements(p_steps) e
  where length(btrim(e ->> 'action')) > 500
     or length(btrim(coalesce(e ->> 'point', ''))) > 500;
  if v_bad > 0 then
    raise exception '步驟文字太長（考官操作、考點各最多 500 字）';
  end if;

  -- 只保留 action、point 兩個鍵並 trim，依原順序
  select jsonb_agg(jsonb_build_object(
           'action', btrim(e.v ->> 'action'),
           'point', btrim(coalesce(e.v ->> 'point', ''))) order by e.n)
    into v_steps
  from jsonb_array_elements(p_steps) with ordinality as e(v, n);

  -- 與抽題共用同一把鎖：抽題與管理操作不會同時發生
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  if p_id is null then
    insert into public.questions (category, code, title, steps)
    values (v_cat, v_code, v_title, v_steps)
    returning id into v_id;
    return v_id;
  end if;

  select q.category into v_old from public.questions q where q.id = p_id for update;
  if not found then
    raise exception '找不到題目：%', p_id;
  end if;

  update public.questions
     set category = v_cat, code = v_code, title = v_title, steps = v_steps
   where id = p_id;

  -- 換分類時，把這題從已抽記錄移除，避免記錄錯亂
  if v_old is distinct from v_cat then
    delete from public.drawn where question_id = p_id;
  end if;

  return p_id;
end;
$$;

-- ---------- 刪除題組 ----------
-- 同舊函式：找不到該題不報錯；已抽記錄由 cascade 一併清除。
create or replace function public.bank_delete_question(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.bank_assert_cs();
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));
  delete from public.questions where id = p_id; -- drawn 由 cascade 一併清除
end;
$$;

-- ---------- 分類改名（新名稱已存在＝合併） ----------
-- 回傳受影響題數；舊分類找不到題就回傳 0（同舊函式）。
-- 舊分類的「最近一題」記錄刪掉；新舊名稱相同則不動。
create or replace function public.bank_rename_category(p_old text, p_new text)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_new text := btrim(coalesce(p_new, ''));
  v_count integer;
begin
  perform public.bank_assert_cs();

  if v_new = '' then raise exception '新分類名稱不可空白'; end if;

  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  update public.questions set category = v_new where category = p_old;
  get diagnostics v_count = row_count;

  -- 舊分類的「最近一題」記錄刪掉即可
  if p_old is distinct from v_new then
    delete from public.category_last where category = p_old;
  end if;

  return v_count;
end;
$$;

-- ---------- 洗牌（重置本輪已抽記錄） ----------
-- p_category 為 null＝全部分類（清空 drawn 與 category_last）；
-- 否則只清該分類的 drawn 與該分類的 category_last（同舊 admin_reset）。
create or replace function public.bank_reset(p_category text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.bank_assert_cs();
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  if p_category is null then
    delete from public.drawn where true;
    delete from public.category_last where true;
  else
    delete from public.drawn
    where question_id in (select q.id from public.questions q where q.category = p_category);
    delete from public.category_last where category = p_category;
  end if;
end;
$$;

-- ---------- 函式權限：收回 public／anon，只授權 authenticated ----------
-- 客服部與否由函式內部檢查（bank_assert_cs）。

revoke execute on function public.bank_list_questions()                                    from public, anon, authenticated;
revoke execute on function public.bank_save_question(bigint, text, text, text, jsonb)      from public, anon, authenticated;
revoke execute on function public.bank_delete_question(bigint)                             from public, anon, authenticated;
revoke execute on function public.bank_rename_category(text, text)                         from public, anon, authenticated;
revoke execute on function public.bank_reset(text)                                         from public, anon, authenticated;
-- 內部身分檢查：連 authenticated 都不開放直接呼叫（函式之間以擁有者身分呼叫）
revoke execute on function public.bank_assert_cs()                                         from public, anon, authenticated;

grant execute on function public.bank_list_questions()                                     to authenticated;
grant execute on function public.bank_save_question(bigint, text, text, text, jsonb)       to authenticated;
grant execute on function public.bank_delete_question(bigint)                              to authenticated;
grant execute on function public.bank_rename_category(text, text)                          to authenticated;
grant execute on function public.bank_reset(text)                                          to authenticated;
