-- ============================================================
-- 業務考核系統：題組「範例圖片」（估價範例等，只有客服部看得到）資料庫（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
--
-- 套用順序（獨立檔）：
--   前提：roster_schema.sql、assess_schema.sql、bank_schema.sql 都已執行過。
--   本檔可在 dual_examiner_schema.sql「之前」貼（兩檔互不相依；上線順序＝先貼本檔，再貼雙考官那份）。
--
-- 本檔只「新增」東西，不修改任何既有資料表、函式、policy、觸發器：
--   * 私有 Storage bucket：question-samples（不公開、單檔 2MB、只收 jpeg／png／webp）
--   * 資料表：question_images(id, question_id, storage_path, mime, size_bytes, sort_order, created_at)
--   * 函式：bank_add_question_image、bank_remove_question_image、bank_reorder_question_images
--   * storage.objects policy：question_samples_select／question_samples_insert／question_samples_delete
--     （名稱不用 assess_notes_ 開頭，不會被既有 assess_notes_* 條數檢查算進去；沒有 update policy：
--      檔案不可覆蓋，要換圖請刪掉再傳新的）
--   * 不改 bank_list_questions 的回傳型別。
--
-- 路徑慣例：{question_id}/{uuid}.jpg|png|webp
--
-- 安全設計：
--   * 圖片只有客服部（roster_my_role() = 'cs_admin'）看得到、改得動：
--     資料表只開客服部 select；沒有任何直接寫入權限（只能透過函式寫）；
--     storage 的 select／insert／delete 也全限客服部。總公司主管、店長、未開通帳號、anon 一律被擋。
--   * 三個函式全 security definer、固定 search_path，先 bank_assert_cs（非客服部丟「沒有權限」）。
--   * 寫入類函式取與題庫其他寫入同一把 advisory lock（pg_advisory_xact_lock(hashtext('exam_draw_questions'))），
--     抽題與管理操作不會同時發生。
--   * 每題最多 8 張、每張 2MB 內；路徑必須是「該題 id／」開頭、副檔名合法且與 mime 相符。
--   * 題組被刪除時，圖片資料列由 cascade 一併刪除（Storage 裡的檔案不會自動刪，
--     前端刪題前可先逐張呼叫 bank_remove_question_image 取得 path 再刪檔）。
--
-- 怎麼執行（老闆同意才做）：Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
-- 可重複執行：全部是 if not exists／create or replace／drop policy if exists 再建，重跑不報錯、不動既有資料。
-- ============================================================

begin;

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.questions') is null
     or to_regclass('public.app_users') is null
     or to_regclass('storage.objects') is null
     or to_regclass('storage.buckets') is null then
    raise exception '請先執行考題抽選器的 schema.sql、roster_schema.sql（並確認 Supabase Storage 已啟用）';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.bank_assert_cs()') is null then
    raise exception '請先執行 roster_schema.sql 與 bank_schema.sql';
  end if;
end
$$;

-- ---------- 私有 bucket ----------
-- 不公開、單檔 2MB、只收 jpeg／png／webp（重跑會更新成這組設定）
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('question-samples', 'question-samples', false, 2097152,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

-- ---------- 資料表 ----------
create table if not exists public.question_images (
  id uuid primary key default gen_random_uuid(),
  question_id bigint not null references public.questions(id) on delete cascade,
  storage_path text not null unique,
  mime text not null check (mime in ('image/jpeg', 'image/png', 'image/webp')),
  size_bytes int not null check (size_bytes > 0 and size_bytes <= 2097152),
  sort_order int not null,
  created_at timestamptz not null default now()
);

create index if not exists question_images_question_idx
  on public.question_images(question_id, sort_order);

-- ---------- 權限與 RLS ----------
alter table public.question_images enable row level security;

-- 先全收回；只給 authenticated「讀」（再由 policy 限客服部），沒有任何人有直接寫入權限
revoke all on table public.question_images from public, anon, authenticated;
grant select on public.question_images to authenticated;

drop policy if exists question_images_select on public.question_images;
create policy question_images_select on public.question_images
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- ---------- Storage policy（bucket question-samples） ----------
-- 讀／傳／刪：只有客服部。傳的路徑必須是 {題組id}/{uuid}.jpg|png|webp。
-- （題組是否存在、張數上限由 bank_add_question_image 把關；沒有 update policy）
drop policy if exists question_samples_select on storage.objects;
create policy question_samples_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'question-samples'
    and public.roster_my_role() = 'cs_admin'
  );

drop policy if exists question_samples_insert on storage.objects;
create policy question_samples_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'question-samples'
    and public.roster_my_role() = 'cs_admin'
    and storage.objects.name ~ '^[0-9]{1,18}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
  );

drop policy if exists question_samples_delete on storage.objects;
create policy question_samples_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'question-samples'
    and public.roster_my_role() = 'cs_admin'
  );

-- ---------- 新增圖片資料列 ----------
-- 檔案本身由前端先傳到 Storage 的 question-samples，再呼叫本函式登記。
-- 回傳新圖片 id；sort_order 接在該題最後面。
create or replace function public.bank_add_question_image(
  p_question_id bigint, p_path text, p_mime text, p_size bigint)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ext text;
  v_n int;
  v_next int;
  v_id uuid;
begin
  perform public.bank_assert_cs();

  if p_question_id is null then raise exception '缺少題組'; end if;
  if p_mime is null or p_mime not in ('image/jpeg', 'image/png', 'image/webp') then
    raise exception '圖片格式只收 jpg、png、webp';
  end if;
  if p_size is null or p_size <= 0 or p_size > 2097152 then
    raise exception '圖片大小必須在 2MB 以內';
  end if;

  -- 路徑必須是「{題組id}/{uuid}.副檔名」，題組 id 對得上，副檔名合法且與 mime 相符
  if p_path is null
     or p_path !~ ('^' || p_question_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$') then
    raise exception '圖片路徑不正確';
  end if;
  v_ext := substring(p_path from '\.([a-z]+)$');
  if (v_ext = 'jpg'  and p_mime <> 'image/jpeg')
     or (v_ext = 'png'  and p_mime <> 'image/png')
     or (v_ext = 'webp' and p_mime <> 'image/webp') then
    raise exception '圖片副檔名與格式不符';
  end if;

  -- 與題庫其他寫入共用同一把鎖
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  perform 1 from public.questions q where q.id = p_question_id for share;
  if not found then
    raise exception '找不到題目：%', p_question_id;
  end if;

  if exists (select 1 from public.question_images g where g.storage_path = p_path) then
    raise exception '這張圖片已經登記過';
  end if;

  select count(*), coalesce(max(g.sort_order), 0) into v_n, v_next
  from public.question_images g where g.question_id = p_question_id;
  if v_n >= 8 then
    raise exception '每個題組最多 8 張範例圖片';
  end if;

  insert into public.question_images (question_id, storage_path, mime, size_bytes, sort_order)
  values (p_question_id, p_path, p_mime, p_size::int, v_next + 1)
  returning id into v_id;

  return v_id;
end;
$$;

-- ---------- 移除圖片資料列 ----------
-- 回傳 storage_path，讓前端去 Storage 刪檔（資料庫端不直接 delete storage.objects）。
create or replace function public.bank_remove_question_image(p_image_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_path text;
begin
  perform public.bank_assert_cs();
  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  delete from public.question_images g
   where g.id = p_image_id
  returning g.storage_path into v_path;
  if not found then
    raise exception '找不到這張圖片';
  end if;

  return v_path;
end;
$$;

-- ---------- 調整圖片順序 ----------
-- p_image_ids 必須「恰好」是該題全部圖片（不多、不少、不重複），依陣列順序重排成 1..N。
create or replace function public.bank_reorder_question_images(
  p_question_id bigint, p_image_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_have int;
  v_given int;
  v_distinct int;
  v_match int;
begin
  perform public.bank_assert_cs();

  if p_question_id is null then raise exception '缺少題組'; end if;
  if p_image_ids is null then raise exception '圖片順序不正確'; end if;

  perform pg_advisory_xact_lock(hashtext('exam_draw_questions'));

  perform 1 from public.questions q where q.id = p_question_id for share;
  if not found then
    raise exception '找不到題目：%', p_question_id;
  end if;

  v_given := coalesce(cardinality(p_image_ids), 0);
  select count(distinct x) into v_distinct from unnest(p_image_ids) x;
  select count(*) into v_have from public.question_images g where g.question_id = p_question_id;
  select count(*) into v_match from public.question_images g
   where g.question_id = p_question_id and g.id = any (p_image_ids);

  if v_given <> v_distinct or v_given <> v_have or v_match <> v_have then
    raise exception '圖片順序不正確：必須恰好包含該題組的全部圖片，且不可重複';
  end if;

  update public.question_images g
     set sort_order = o.n
    from unnest(p_image_ids) with ordinality as o(id, n)
   where g.id = o.id and g.question_id = p_question_id;
end;
$$;

-- ---------- 權限：收回 public／anon，只授權 authenticated（客服部與否由函式內部檢查） ----------
revoke execute on function public.bank_add_question_image(bigint, text, text, bigint)   from public, anon, authenticated;
revoke execute on function public.bank_remove_question_image(uuid)                       from public, anon, authenticated;
revoke execute on function public.bank_reorder_question_images(bigint, uuid[])           from public, anon, authenticated;

grant execute on function public.bank_add_question_image(bigint, text, text, bigint)    to authenticated;
grant execute on function public.bank_remove_question_image(uuid)                        to authenticated;
grant execute on function public.bank_reorder_question_images(bigint, uuid[])            to authenticated;

commit;
