-- ============================================================
-- 停用舊考題抽選器（舊抽選器與舊管理頁共用密碼的入口）— 可還原
--
-- ⚠️ 尚未執行，待老闆確認新題庫管理頁好用之後才執行
--
-- 做什麼：對 8 個舊函式收回 anon（未登入的網頁端）的 execute，
--   讓舊抽選器與舊管理頁完全無法運作（共用密碼這個繞過「只有客服部」規則的入口就此關閉）。
-- 不做什麼：不刪除任何函式、不動 app_secret（密碼雜湊）、不動題庫資料（questions、drawn、category_last）。
--   _pw_ok、_assert_pw 兩個內部函式本來就沒開放給 anon，不需處理。
--
-- ---------- 實證：新系統沒有任何地方呼叫舊的密碼函式 ----------
-- 以下是「讀檔」得到的結果（本檔作者不能執行 SQL）：
--   * assess_schema.sql 的所有 assess_* 函式（assess_categories、assess_candidates、assess_start、
--     assess_draw、assess_save_item、assess_submit、assess_void、assess_abandon、assess_add_image、
--     assess_remove_image 與計算小工具）本身都不呼叫 _pw_ok、_assert_pw、list_categories、
--     draw_questions、admin_*；它們的身分檢查一律走 assess_assert_cs()（看 JWT 信箱與 app_users），
--     只直接讀寫 questions、drawn、category_last 三張表。
--   * 新的 bank_* 函式同樣只走 bank_assert_cs()，不呼叫任何舊函式。
--   * 整個「業務考核系統」資料夾搜尋舊函式名稱，只出現在：roster_schema.sql、assess_schema.sql、
--     backoffice_schema.sql 的「說明註解」（列出既有名稱以避免衝突），以及 assess_verify_fake.sql 的驗證
--     （它檢查舊函式「還在」，以及「draw_questions 仍開放 anon」——停用後這一列會變「失敗」，見下方提醒）。
--     前端頁面與 js 沒有任何一處呼叫舊函式。
--   * 下面第一段 do 區塊會在資料庫實際掃一遍：若有任何舊 10 個函式以外的 public 函式、policy、檢視
--     引用了舊函式名稱，就丟錯停下、什麼都不會改（請回報，不要自行處理）。
--     防護範圍：只掃 public schema 的函式內容、public 與 storage 的 policy、public 的檢視；
--     未掃觸發器、欄位預設值與其他 schema。以現況（已讀檔實證沒有引用）足夠；
--     日後若新增相關物件，須重新檢查。
--
-- ---------- 重要提醒 ----------
--   * 執行後，assess_verify_fake.sql 裡「draw_questions 仍開放 anon 執行」那一列會顯示「失敗」，
--     這是預期的（它是停用前的驗證）；其他列不受影響。
--   * 上半段（收回）可直接整份執行。
--   * 下半段（還原）整段包在 /* ... */ 註解裡，平常不會執行：只有要恢復舊抽選器時，
--     才把那段單獨複製出來執行（或拿掉 /* 和 */ 後只選取該段執行）。
--   * 驗證腳本 bank_verify_fake.sql 內有這兩段的相同語句（在交易內執行後 rollback）；
--     兩邊若要修改必須同步。
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
-- 可重複執行：revoke 重跑不會報錯。
-- ============================================================

-- ---------- 防護：先確認新系統沒有引用舊函式，且 8 個舊函式都在 ----------
do $$
declare
  v_pat text := '(_pw_ok|_assert_pw|list_categories|draw_questions|admin_(login|list_questions|save_question|delete_question|rename_category|reset))';
  v_names text;
  v_n int;
begin
  -- 1. 舊 10 個函式以外的 public 函式，內容不得引用舊函式
  select count(*), string_agg(p.proname, '、' order by p.proname)
    into v_n, v_names
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prokind = 'f'
    and p.proname not in ('_pw_ok', '_assert_pw', 'list_categories', 'draw_questions', 'admin_login',
                          'admin_list_questions', 'admin_save_question', 'admin_delete_question',
                          'admin_rename_category', 'admin_reset')
    and p.prosrc ~* v_pat;
  if v_n > 0 then
    raise exception '停下：以下函式的內容引用了舊的密碼函式：%。請回報，不要自行處理', v_names;
  end if;

  -- 2. policy（含 storage）與 public 檢視不得引用舊函式
  select count(*) into v_n
  from pg_policies
  where schemaname in ('public', 'storage')
    and (coalesce(qual, '') ~* v_pat or coalesce(with_check, '') ~* v_pat);
  if v_n > 0 then
    raise exception '停下：有 % 條 policy 引用了舊的密碼函式。請回報，不要自行處理', v_n;
  end if;

  select count(*) into v_n
  from pg_views
  where schemaname = 'public' and definition ~* v_pat;
  if v_n > 0 then
    raise exception '停下：有 % 個檢視引用了舊的密碼函式。請回報，不要自行處理', v_n;
  end if;

  -- 3. 8 個舊函式都要存在（缺的話代表資料庫狀態和預期不同，先停下）
  select count(*) into v_n
  from unnest(array[
    'public.list_categories(text)',
    'public.draw_questions(text, text[])',
    'public.admin_login(text)',
    'public.admin_list_questions(text)',
    'public.admin_save_question(text, bigint, text, text, text, jsonb)',
    'public.admin_delete_question(text, bigint)',
    'public.admin_rename_category(text, text, text)',
    'public.admin_reset(text, text)'
  ]) as s
  where to_regprocedure(s) is not null;
  if v_n <> 8 then
    raise exception '停下：舊函式只找到 % 個（應為 8 個）。請回報，不要自行處理', v_n;
  end if;
end
$$;

-- ============================================================
-- 上半段：停用舊抽選器（收回 anon 的 execute）
-- ============================================================
revoke execute on function public.list_categories(text)                                          from anon;
revoke execute on function public.draw_questions(text, text[])                                   from anon;
revoke execute on function public.admin_login(text)                                              from anon;
revoke execute on function public.admin_list_questions(text)                                     from anon;
revoke execute on function public.admin_save_question(text, bigint, text, text, text, jsonb)     from anon;
revoke execute on function public.admin_delete_question(text, bigint)                            from anon;
revoke execute on function public.admin_rename_category(text, text, text)                        from anon;
revoke execute on function public.admin_reset(text, text)                                        from anon;

-- ============================================================
-- 下半段：還原（恢復舊抽選器）
-- ⚠️ 只有要恢復舊抽選器時才執行！平常整段是註解，不會被執行。
-- 把 /* 和 */ 之間的 8 行單獨複製出來執行即可（與舊 schema.sql 最後一段授權相同）。
-- ============================================================
/*
grant execute on function public.list_categories(text)                                          to anon;
grant execute on function public.draw_questions(text, text[])                                   to anon;
grant execute on function public.admin_login(text)                                              to anon;
grant execute on function public.admin_list_questions(text)                                     to anon;
grant execute on function public.admin_save_question(text, bigint, text, text, text, jsonb)     to anon;
grant execute on function public.admin_delete_question(text, bigint)                            to anon;
grant execute on function public.admin_rename_category(text, text, text)                        to anon;
grant execute on function public.admin_reset(text, text)                                        to anon;
*/
