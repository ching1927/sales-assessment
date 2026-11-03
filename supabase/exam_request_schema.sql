-- ============================================================
-- 業務考核系統：待考回報（含寄信佇列）資料庫結構（Supabase / Postgres）
--
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行。
-- 規格：README_exam_request.md（唯一規格；對不上就停下來回報，不要自己改約定）。
--
-- 前提：roster_schema.sql、assess_schema.sql、spotcheck_schema.sql（employees.probation_since）、
--       backoffice_schema.sql（improvement_tickets）已在同一個專案執行過。
-- 寄信前提：Dashboard → Database → Extensions 啟用 pg_net（本檔不 create extension；
--       沒啟用也能執行，只是寄信一律記為 skipped，執行時會用 notice 提示）。
--
-- 本檔只「新增」東西；不修改、不刪除任何既有資料表、函式、policy、欄位、既有觸發器，
-- 也不改 assess_submit 任何一行。唯一碰到既有資料表的地方：在 assessments 上「掛上一個新觸發器」。
--
-- ---------- 名稱衝突自查：無衝突 ----------
-- 專案內原本沒有任何 exam_req_、exam_requests、mail_outbox、app_settings 開頭的名稱
-- （supabase\ 全部 .sql／.md、js\ 皆查過；js\requests-core.js 只是網頁端的純函式）。
-- 本檔新增的名稱：
--   資料表：exam_requests、mail_outbox、app_settings
--   索引：exam_requests_status_idx、exam_requests_store_idx、exam_requests_employee_idx、
--         exam_requests_open_emp_kind_uq（唯一部分索引）、exam_requests_open_ticket_uq（唯一部分索引）、
--         mail_outbox_status_idx、mail_outbox_request_idx
--   觸發器：exam_requests_touch_trg、mail_outbox_touch_trg、mail_outbox_dispatch_trg（掛在 mail_outbox）、
--           exam_req_auto_complete_trg（掛在 assessments，新增）
--   對外函式（authenticated 可呼叫）：exam_req_candidates、exam_req_create、exam_req_withdraw、
--           exam_req_schedule、exam_req_return、exam_req_mark_seen、exam_req_badge、mail_outbox_sync
--   內部函式（任何網頁角色都不能直接呼叫）：exam_req_status_open、exam_req_label、exam_req_esc、
--           exam_req_setting、exam_req_link、exam_req_net_ready、exam_req_net_post、exam_req_net_result、
--           exam_req_mail_content、exam_req_enqueue、exam_req_notify、
--           mail_outbox_dispatch（觸發器函式）、exam_req_auto_complete（觸發器函式）
--   RLS policy：exam_requests_select、mail_outbox_select（app_settings 刻意沒有任何 policy）
--
-- 怎麼執行（之後老闆同意才做）：
--   Supabase 專案 → SQL Editor → New query → 貼上整份 → Run。
--   執行完再跑 exam_request_verify_fake.sql 驗證（全程 rollback，不留資料）。
--   之後到 SQL Editor 填 mail_relay_url 與 mail_relay_token（見 README_exam_request.md 第五節）。
--
-- 可重複執行：資料表／索引 if not exists、函式 create or replace、policy 與 trigger 先 drop 再建、
-- app_settings 預設值 on conflict do nothing；重跑不會報錯，也不會刪掉或改掉既有回報、寄信紀錄與設定。
--
-- 安全設計：三張表都開 RLS，直接寫入權限（insert／update／delete／truncate）一律不給，
--   只能透過下面的函式與觸發器寫入；app_settings 連 select 都不給（只有 security definer 函式讀）。
--
-- 為什麼 pg_net 相關動作包成 exam_req_net_ready／exam_req_net_post／exam_req_net_result 三個內部函式：
--   觸發器與 mail_outbox_sync 都只透過它們碰 net.http_post 與 net._http_response，行為與直接呼叫相同；
--   好處是驗證腳本能在交易內暫時換成假的實作（rollback 後消失），不必真的對外寄信也能測全部分支。
--
-- 緊急停用（不影響成績單送出與作廢）：
--   自動完成：drop trigger if exists exam_req_auto_complete_trg on public.assessments;
--   寄信：    drop trigger if exists mail_outbox_dispatch_trg on public.mail_outbox;
--             （停用後新信會留在 queued 狀態，不會對外寄出）
-- ============================================================

begin;

-- 安全：等鎖最多 5 秒，拿不到就報錯整份回復，稍後重跑即可
set local lock_timeout = '5s';

-- ---------- 前置檢查 ----------
do $$
begin
  if to_regclass('public.assessments') is null
     or to_regclass('public.employees') is null
     or to_regclass('public.stores') is null
     or to_regclass('public.app_users') is null
     or to_regclass('public.employees_with_tenure') is null then
    raise exception '請先執行 roster_schema.sql 與 assess_schema.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'employees' and column_name = 'probation_since') then
    raise exception '請先執行 spotcheck_schema.sql（缺少 employees.probation_since）';
  end if;
  if to_regclass('public.improvement_tickets') is null then
    raise exception '請先執行 backoffice_schema.sql（缺少 improvement_tickets）';
  end if;
  if to_regprocedure('public.roster_my_role()') is null
     or to_regprocedure('public.roster_my_store()') is null
     or to_regprocedure('public.roster_my_email()') is null
     or to_regprocedure('public.roster_touch_updated_at()') is null then
    raise exception '請先執行 roster_schema.sql（缺少必要函式）';
  end if;

  -- pg_net 提示（不是錯誤）：沒有的話整份仍會執行成功，只是信件會記為 skipped
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'net' and p.proname = 'http_post') then
    raise notice '⚠️ 偵測不到 pg_net（net.http_post）：寄信會一律記為 skipped。請到 Dashboard → Database → Extensions 啟用 pg_net 後即可寄信，不必重跑本檔。';
  else
    raise notice 'pg_net 已啟用。記得在 SQL Editor 填 mail_relay_url 與 mail_relay_token（見 README_exam_request.md 第五節），否則信件仍記為 skipped。';
  end if;
end
$$;

-- ---------- 資料表：待考回報 ----------
create table if not exists public.exam_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('新人', '回考核期', '複檢')),
  employee_id text not null
    references public.employees(id) on update cascade on delete cascade,
  employee_label text not null,                       -- 回報當下的暱稱或姓名（顯示用快照）
  store_code text not null,                           -- 回報當下人員所屬門市的快照
  requested_by text not null
    check (requested_by = lower(btrim(requested_by)) and length(requested_by) > 0),
  requested_role text not null check (requested_role in ('店長', '客服部')),
  desired_dates date[] not null
    check (array_ndims(desired_dates) = 1 and cardinality(desired_dates) between 1 and 3),
  video_done boolean,                                 -- 新人才有（必須 true）；其他情況 null
  note text check (note is null or char_length(note) <= 500),
  improvement_ticket_id uuid
    references public.improvement_tickets(id) on delete set null,   -- 複檢才有
  status text not null default '待處理'
    check (status in ('待處理', '已排定', '已完成', '已取消')),
  scheduled_at timestamptz,
  reply_note text,
  handled_by text,
  cancel_by text check (cancel_by in ('店長', '客服部')),
  cancel_reason text,
  assessment_id uuid
    references public.assessments(id) on delete set null,
  mgr_seen boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- 新人必須看完影片（true）；另兩種情況存 null
  constraint exam_requests_video_by_kind
    check ((kind = '新人' and video_done is true) or (kind <> '新人' and video_done is null)),
  -- 只有複檢會帶改善單（改善單日後若被刪除，欄位會被資料庫設為 null，所以複檢允許 null）
  constraint exam_requests_ticket_by_kind
    check (kind = '複檢' or improvement_ticket_id is null)
);

create index if not exists exam_requests_status_idx   on public.exam_requests(status);
create index if not exists exam_requests_store_idx    on public.exam_requests(store_code, status);
create index if not exists exam_requests_employee_idx on public.exam_requests(employee_id);

-- 防重複（資料庫最後一道防線）：未結案（待處理、已排定）時，
--   新人／回考核期：同一人同一種情況只能有一筆；
--   複檢：以改善單為單位，同一張改善單只能有一筆（同一人有兩張已輔導改善單時可各報一筆）。
create unique index if not exists exam_requests_open_emp_kind_uq
  on public.exam_requests(employee_id, kind)
  where status in ('待處理', '已排定') and kind <> '複檢';
create unique index if not exists exam_requests_open_ticket_uq
  on public.exam_requests(improvement_ticket_id)
  where status in ('待處理', '已排定') and kind = '複檢' and improvement_ticket_id is not null;

-- ---------- 資料表：寄信佇列 ----------
create table if not exists public.mail_outbox (
  id uuid primary key default gen_random_uuid(),
  to_emails text[] not null,
  subject text not null,
  body_html text not null,
  kind text,                                          -- new／scheduled／returned（信件種類）
  request_id uuid,                                    -- 對應的回報（不設外鍵：回報被刪也要留寄信紀錄）
  status text not null default 'queued'
    check (status in ('queued', 'sent', 'failed', 'skipped')),
  net_request_id bigint,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists mail_outbox_status_idx  on public.mail_outbox(status);
create index if not exists mail_outbox_request_idx on public.mail_outbox(request_id);

-- ---------- 資料表：系統設定（只有 security definer 函式讀得到） ----------
create table if not exists public.app_settings (
  key text primary key check (length(btrim(key)) > 0),
  value text
);

-- 預設值：只預填 site_url；mail_relay_url 與 mail_relay_token 刻意不預填，由老闆之後自己填
insert into public.app_settings (key, value)
values ('site_url', 'https://ching1927.github.io/sales-assessment/')
on conflict (key) do nothing;

-- 更新時間自動更新（沿用名冊的函式）
drop trigger if exists exam_requests_touch_trg on public.exam_requests;
create trigger exam_requests_touch_trg
  before update on public.exam_requests
  for each row execute function public.roster_touch_updated_at();

drop trigger if exists mail_outbox_touch_trg on public.mail_outbox;
create trigger mail_outbox_touch_trg
  before update on public.mail_outbox
  for each row execute function public.roster_touch_updated_at();

-- ---------- 權限與 RLS ----------
alter table public.exam_requests enable row level security;
alter table public.mail_outbox   enable row level security;
alter table public.app_settings  enable row level security;

-- 先全收回；exam_requests、mail_outbox 只給 authenticated「讀」（實際能看什麼由 RLS 決定）；
-- app_settings 完全不給（也不建任何 policy）
revoke all on table public.exam_requests from public, anon, authenticated;
revoke all on table public.mail_outbox   from public, anon, authenticated;
revoke all on table public.app_settings  from public, anon, authenticated;
grant select on public.exam_requests to authenticated;
grant select on public.mail_outbox   to authenticated;

-- exam_requests：客服部、總公司主管全看；店長只看自己門市
drop policy if exists exam_requests_select on public.exam_requests;
create policy exam_requests_select on public.exam_requests
  for select to authenticated
  using (
    public.roster_my_role() in ('cs_admin', 'hq_viewer')
    or (public.roster_my_role() = 'store_manager' and store_code = public.roster_my_store())
  );

-- mail_outbox：只有客服部
drop policy if exists mail_outbox_select on public.mail_outbox;
create policy mail_outbox_select on public.mail_outbox
  for select to authenticated
  using (public.roster_my_role() = 'cs_admin');

-- ============================================================
-- 內部小工具（只給其他函式用；結尾會把 execute 全部收回）
-- ============================================================

-- 「未結案」的狀態清單（待處理、已排定）
create or replace function public.exam_req_status_open()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array['待處理', '已排定']::text[];
$$;

-- 人員顯示名稱：暱稱優先，否則姓名（與 assess_start 的 employee_label 同一寫法）
create or replace function public.exam_req_label(p_nickname text, p_full_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(p_nickname), ''), nullif(btrim(p_full_name), ''));
$$;

-- HTML escape（& < > " '），null 當空字串
create or replace function public.exam_req_esc(p_text text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select replace(replace(replace(replace(replace(
           coalesce(p_text, ''),
           '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

-- 讀系統設定（去頭尾空白，空字串視為沒設定）
create or replace function public.exam_req_setting(p_key text)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select nullif(btrim(s.value), '') from public.app_settings s where s.key = p_key;
$$;

-- 信件裡的登入連結：site_url（補上結尾斜線）+ requests.html
create or replace function public.exam_req_link()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
           when public.exam_req_setting('site_url') is null then 'requests.html'
           when public.exam_req_setting('site_url') like '%/' then public.exam_req_setting('site_url') || 'requests.html'
           else public.exam_req_setting('site_url') || '/requests.html'
         end;
$$;

-- pg_net 有沒有裝（net.http_post 存在才算）
create or replace function public.exam_req_net_ready()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'net' and p.proname = 'http_post');
$$;

-- 呼叫 net.http_post（pg_net 在交易提交後才真正送出請求）；回傳 pg_net 的請求編號
create or replace function public.exam_req_net_post(p_url text, p_body jsonb, p_headers jsonb, p_timeout_ms int)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := $4)'
    into v_id
    using p_url, p_body, p_headers, p_timeout_ms;
  return v_id;
end;
$$;

-- 讀 pg_net 的回應（沒有 net._http_response 表就回 0 列）
create or replace function public.exam_req_net_result(p_request_id bigint)
returns table(status_code int, timed_out boolean, error_msg text, content text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if to_regclass('net._http_response') is null then
    return;
  end if;
  return query execute
    'select r.status_code::int, r.timed_out, r.error_msg::text, r.content::text
       from net._http_response r where r.id = $1'
    using p_request_id;
end;
$$;

-- ============================================================
-- 信件內容產生（subject 與 HTML body）
-- 全部使用者文字（門市名稱、人員、備註、原因、連結）都先 HTML escape；備註只取前 80 字。
-- p_type：new（新回報，寄客服部）／scheduled（排定，寄回報人）／returned（退回，寄回報人）
-- ============================================================
create or replace function public.exam_req_mail_content(p_type text, p_id uuid)
returns table(subject text, body_html text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  r public.exam_requests%rowtype;
  v_store text;
  v_dates text;
  v_intro text;
  v_extra text := '';
  v_rows text := '';
  v_text text;
  v_subject text;
begin
  select * into r from public.exam_requests where id = p_id;
  if not found then
    raise exception '找不到回報';
  end if;
  select coalesce(nullif(btrim(s.name), ''), s.code) into v_store from public.stores s where s.code = r.store_code;
  v_store := coalesce(v_store, r.store_code);

  select string_agg(to_char(d, 'YYYY-MM-DD'), '、' order by ord)
    into v_dates from unnest(r.desired_dates) with ordinality as t(d, ord);

  -- 共同欄位
  v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">門市</td><td style="padding:4px 0">'
            || public.exam_req_esc(v_store) || '</td></tr>';
  v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">人員</td><td style="padding:4px 0">'
            || public.exam_req_esc(r.employee_label) || '</td></tr>';
  v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">情況</td><td style="padding:4px 0">'
            || public.exam_req_esc(r.kind) || '</td></tr>';

  if p_type = 'new' then
    v_subject := '【待考回報】' || v_store || ' ' || r.employee_label || '（' || r.kind || '）';
    v_intro := '有一筆新的待考回報，請到系統處理。';
    v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">希望考核日期</td><td style="padding:4px 0">'
              || public.exam_req_esc(v_dates) || '</td></tr>';
    if r.kind = '新人' then
      v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">影片</td><td style="padding:4px 0">'
                || '已看完線上回覆實戰全攻略影片</td></tr>';
    end if;
    v_text := r.note;
    if nullif(btrim(coalesce(v_text, '')), '') is not null then
      v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">備註</td><td style="padding:4px 0">'
                || public.exam_req_esc(left(v_text, 80) || case when char_length(v_text) > 80 then '…' else '' end)
                || '</td></tr>';
    end if;

  elsif p_type = 'scheduled' then
    v_subject := '【考核已排定】' || v_store || ' ' || r.employee_label || '（' || r.kind || '）';
    v_intro := '客服部已排定考核時間。';
    v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">排定時間</td><td style="padding:4px 0">'
              || public.exam_req_esc(to_char(r.scheduled_at at time zone 'Asia/Taipei', 'YYYY-MM-DD HH24:MI')) || '</td></tr>';
    v_text := r.reply_note;
    if nullif(btrim(coalesce(v_text, '')), '') is not null then
      v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">備註</td><td style="padding:4px 0">'
                || public.exam_req_esc(left(v_text, 80) || case when char_length(v_text) > 80 then '…' else '' end)
                || '</td></tr>';
    end if;
    v_extra := '<p style="margin:12px 0"><b>考核在線上進行，請同仁準時上線。</b></p>';

  elsif p_type = 'returned' then
    v_subject := '【待考回報已退回】' || v_store || ' ' || r.employee_label || '（' || r.kind || '）';
    v_intro := '客服部已退回這筆待考回報。';
    v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">希望考核日期</td><td style="padding:4px 0">'
              || public.exam_req_esc(v_dates) || '</td></tr>';
    v_text := r.cancel_reason;
    v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">退回原因</td><td style="padding:4px 0">'
              || public.exam_req_esc(left(coalesce(v_text, ''), 80) || case when char_length(coalesce(v_text, '')) > 80 then '…' else '' end)
              || '</td></tr>';

  else
    raise exception '不認識的信件種類';
  end if;

  subject := replace(replace(v_subject, E'\r', ' '), E'\n', ' ');
  body_html :=
    '<div style="font-family:Arial,sans-serif;font-size:15px;color:#222;line-height:1.6">'
    || '<p style="margin:0 0 12px">' || public.exam_req_esc(v_intro) || '</p>'
    || '<table style="border-collapse:collapse">' || v_rows || '</table>'
    || v_extra
    || '<p style="margin:16px 0"><a href="' || public.exam_req_esc(public.exam_req_link()) || '">登入系統查看</a></p>'
    || '<p style="margin:0;color:#888;font-size:12px">這是系統自動寄出的通知信，請勿直接回覆。</p>'
    || '</div>';
  return next;
end;
$$;

-- 排一封信進寄信佇列。
-- 收件人過濾：轉小寫去空白、必須是 @2motor.tw、而且必須是 app_users 內的帳號、去重；
-- 過濾後沒有任何收件人 → 仍寫一筆 skipped 紀錄（留下原因），不寄。
create or replace function public.exam_req_enqueue(p_to text[], p_subject text, p_body text, p_kind text, p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_to text[];
  v_id uuid;
begin
  select coalesce(array_agg(x.email order by x.email), '{}'::text[])
    into v_to
  from (select distinct lower(btrim(t.e)) as email
        from unnest(coalesce(p_to, '{}'::text[])) as t(e)) x
  where x.email ~ '^[a-z0-9._%+-]+@2motor\.tw$'
    and exists (select 1 from public.app_users u where u.email = x.email);

  if cardinality(v_to) = 0 then
    insert into public.mail_outbox (to_emails, subject, body_html, kind, request_id, status, last_error)
    values ('{}'::text[], p_subject, p_body, p_kind, p_request_id, 'skipped', '沒有可寄送的收件人（需為 app_users 內的 @2motor.tw 信箱）')
    returning id into v_id;
  else
    insert into public.mail_outbox (to_emails, subject, body_html, kind, request_id)
    values (v_to, p_subject, p_body, p_kind, p_request_id)
    returning id into v_id;     -- AFTER INSERT 觸發器 mail_outbox_dispatch_trg 接手寄出
  end if;
  return v_id;
end;
$$;

-- 通知：任何錯誤都吞掉（寄信相關的問題絕不讓回報本身失敗），並盡力留一筆 failed 紀錄
create or replace function public.exam_req_notify(p_type text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r public.exam_requests%rowtype;
  v_to text[];
  v_subject text;
  v_body text;
begin
  begin
    select * into r from public.exam_requests where id = p_id;
    if not found then
      raise exception '找不到回報';
    end if;
    if p_type = 'new' then
      select coalesce(array_agg(u.email order by u.email), '{}'::text[]) into v_to
      from public.app_users u where u.role = 'cs_admin';
    else
      v_to := array[r.requested_by];
    end if;
    select c.subject, c.body_html into v_subject, v_body from public.exam_req_mail_content(p_type, p_id) c;
    perform public.exam_req_enqueue(v_to, v_subject, v_body, p_type, p_id);
  exception when others then
    begin
      insert into public.mail_outbox (to_emails, subject, body_html, kind, request_id, status, last_error)
      values ('{}'::text[], '（信件產生失敗）', '', p_type, p_id, 'failed', left('排信失敗：' || sqlerrm, 500));
    exception when others then
      null;
    end;
  end;
end;
$$;

-- ============================================================
-- 寄信觸發器：mail_outbox 新增一列（狀態 queued）後，呼叫 pg_net 送到公司 Google Apps Script。
--   pg_net 沒裝、或 mail_relay_url／mail_relay_token 沒填 → 狀態改 skipped；
--   呼叫成功 → 記 net_request_id（狀態維持 queued，之後由 mail_outbox_sync 依回應改 sent／failed）；
--   任何錯誤 → 狀態 failed、錯誤寫進 last_error；一律吞掉，絕不讓主交易失敗。
--   JSON：{ "token": …, "to": [信箱…], "subject": …, "html": … }
-- ============================================================
create or replace function public.mail_outbox_dispatch()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_url text;
  v_token text;
  v_req bigint;
begin
  if new.status <> 'queued' then
    return null;
  end if;
  begin
    v_url := public.exam_req_setting('mail_relay_url');
    v_token := public.exam_req_setting('mail_relay_token');

    if not public.exam_req_net_ready() then
      update public.mail_outbox set status = 'skipped', last_error = '尚未啟用 pg_net' where id = new.id;
    elsif v_url is null or v_token is null then
      update public.mail_outbox set status = 'skipped', last_error = '尚未設定 mail_relay_url 或 mail_relay_token' where id = new.id;
    else
      v_req := public.exam_req_net_post(
        v_url,
        jsonb_build_object('token', v_token, 'to', to_jsonb(new.to_emails),
                           'subject', new.subject, 'html', new.body_html),
        jsonb_build_object('Content-Type', 'application/json'),
        10000);
      update public.mail_outbox set net_request_id = v_req where id = new.id;
    end if;
  exception when others then
    begin
      update public.mail_outbox set status = 'failed', last_error = left(sqlerrm, 500) where id = new.id;
    exception when others then
      null;
    end;
  end;
  return null;
end;
$$;

drop trigger if exists mail_outbox_dispatch_trg on public.mail_outbox;
create trigger mail_outbox_dispatch_trg
  after insert on public.mail_outbox
  for each row execute function public.mail_outbox_dispatch();

-- ============================================================
-- 觸發器：成績單送出（status 轉為 submitted）→ 該員工未結案回報自動完成
-- 不改 assess_submit；草稿不觸發；之後作廢成績單不倒回。mgr_seen 設 false 讓店長看到。
-- 例外一律吞掉並發出警告（絕不能讓 assess_submit 失敗）；萬一漏標，由客服部手動處理（退回或撤回該回報）。
-- 緊急時用檔頭的 drop trigger 停用。
-- ============================================================
create or replace function public.exam_req_auto_complete()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' then
    begin
      update public.exam_requests
         set status = '已完成',
             assessment_id = new.id,
             mgr_seen = false
       where employee_id = new.employee_id
         and status in ('待處理', '已排定');
    exception when others then
      raise warning '待處理回報自動完成失敗：%', sqlerrm;
    end;
  end if;
  return null;
end;
$$;

drop trigger if exists exam_req_auto_complete_trg on public.assessments;
create trigger exam_req_auto_complete_trg
  after update of status on public.assessments
  for each row
  when (old.status is distinct from 'submitted' and new.status = 'submitted')
  execute function public.exam_req_auto_complete();

-- ============================================================
-- 對外函式
-- ============================================================

-- 可回報的人（客服部、店長；店長只列自己門市；已有未結案回報者不列）
--   新人：在職、納入考核、tenure_group = '新人'、probation_since is null
--   回考核期：在職、納入考核、probation_since is not null
--   複檢：每張「已輔導」且尚無未結案複檢回報的改善單一列（帶 ticket_id、輔導備註）
create or replace function public.exam_req_candidates(p_kind text)
returns table(employee_id text, label text, store_code text, ticket_id uuid, ticket_note text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
#variable_conflict use_column
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_store text;
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_kind is null or p_kind not in ('新人', '回考核期', '複檢') then
    raise exception '情況必須是「新人」「回考核期」或「複檢」';
  end if;
  if v_role = 'store_manager' then
    v_store := public.roster_my_store();
  end if;

  if p_kind in ('新人', '回考核期') then
    return query
      select e.id,
             public.exam_req_label(e.nickname, e.full_name),
             e.store_code,
             null::uuid,
             null::text
      from public.employees_with_tenure e
      where e.status = '在職'
        and e.include_in_assessment
        and (v_store is null or e.store_code = v_store)
        and ((p_kind = '新人' and e.probation_since is null and e.tenure_group = '新人')
             or (p_kind = '回考核期' and e.probation_since is not null))
        and not exists (select 1 from public.exam_requests r
                        where r.employee_id = e.id and r.kind = p_kind
                          and r.status = any(public.exam_req_status_open()))
      order by e.store_code, e.id;
  else
    return query
      select e.id,
             public.exam_req_label(e.nickname, e.full_name),
             e.store_code,
             t.id,
             t.coach_note
      from public.improvement_tickets t
      join public.employees e on e.id = t.employee_id
      where t.status = 'coached'
        and e.status = '在職'
        and e.include_in_assessment
        and (v_store is null or e.store_code = v_store)
        and not exists (select 1 from public.exam_requests r
                        where r.improvement_ticket_id = t.id and r.kind = '複檢'
                          and r.status = any(public.exam_req_status_open()))
        -- 已完成的複檢（連到的成績單目前仍是已送出）不再列；成績單被作廢者可重報
        and not exists (select 1 from public.exam_requests r
                        join public.assessments a on a.id = r.assessment_id
                        where r.improvement_ticket_id = t.id and r.kind = '複檢'
                          and r.status = '已完成' and a.status = 'submitted')
      order by e.store_code, e.id, t.created_at;
  end if;
end;
$$;

-- 新增回報（客服部、店長〔限自己門市〕）。回傳新回報 id。
create or replace function public.exam_req_create(
  p_kind text,
  p_employee_id text,
  p_dates date[],
  p_video boolean,
  p_note text,
  p_ticket_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  v_today date := (now() at time zone 'Asia/Taipei')::date;
  v_emp public.employees%rowtype;
  v_tenure text;
  v_tk public.improvement_tickets%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288)), '');
  v_id uuid;
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;
  if p_kind is null or p_kind not in ('新人', '回考核期', '複檢') then
    raise exception '情況必須是「新人」「回考核期」或「複檢」';
  end if;

  -- 每日頻率限制：同一個回報人當天（台北日期）已建立 20 筆（含已取消）就拒絕
  if (select count(*) from public.exam_requests r
      where r.requested_by = public.roster_my_email()
        and (r.created_at at time zone 'Asia/Taipei')::date = v_today) >= 20 then
    raise exception '今天回報次數已達上限（20 筆），請明天再試或聯絡客服部';
  end if;

  -- 鎖住人員那一列：同一個人的並發回報在這裡排隊
  select * into v_emp from public.employees where id = p_employee_id for update;
  -- 店長：找不到或別間門市一律回同一句，不讓店長藉編號探知別間門市的人
  if not found
     or (v_role = 'store_manager' and v_emp.store_code is distinct from public.roster_my_store()) then
    raise exception '找不到這位人員或沒有權限';
  end if;

  -- 資格（三種情況都要求在職且納入考核）
  if v_emp.status <> '在職' then
    raise exception '這位人員已離職，不能回報';
  end if;
  if not v_emp.include_in_assessment then
    raise exception '這位人員未納入考核，不能回報';
  end if;
  if p_kind in ('新人', '回考核期') then
    if p_kind = '新人' then
      if v_emp.probation_since is not null then
        raise exception '這位人員目前在考核期，只能以「回考核期」回報';
      end if;
      select w.tenure_group into v_tenure from public.employees_with_tenure w where w.id = v_emp.id;
      if v_tenure is distinct from '新人' then
        raise exception '這位人員不是新人（到職 90 天內才算新人），不能以「新人」回報';
      end if;
    else
      if v_emp.probation_since is null then
        raise exception '這位人員目前不在考核期，不能以「回考核期」回報';
      end if;
    end if;
  else
    if p_ticket_id is null then
      raise exception '複檢必須指定改善單';
    end if;
    select * into v_tk from public.improvement_tickets where id = p_ticket_id for update;
    if not found or v_tk.employee_id <> v_emp.id then
      raise exception '找不到這位人員的這張改善單';
    end if;
    if v_tk.status <> 'coached' then
      raise exception '這張改善單還不能回報複檢（必須是已輔導的改善單）';
    end if;
    if exists (select 1 from public.exam_requests r
               join public.assessments a on a.id = r.assessment_id
               where r.improvement_ticket_id = v_tk.id and r.kind = '複檢'
                 and r.status = '已完成' and a.status = 'submitted') then
      raise exception '這張改善單的複檢已經完成，不能再回報';
    end if;
  end if;

  -- 日期：1～3 個、不可有空值、不可重複、不可早於今天（台北時間；今天可）
  if p_dates is null or coalesce(cardinality(p_dates), 0) not between 1 and 3 then
    raise exception '希望考核日期請填 1 到 3 個';
  end if;
  if exists (select 1 from unnest(p_dates) as t(d) where t.d is null) then
    raise exception '希望考核日期不可空白';
  end if;
  if (select count(distinct t.d) from unnest(p_dates) as t(d)) <> cardinality(p_dates) then
    raise exception '希望考核日期不可重複';
  end if;
  if exists (select 1 from unnest(p_dates) as t(d) where t.d < v_today) then
    raise exception '希望考核日期不可早於今天';
  end if;

  -- 影片：新人必須勾選；其他情況不適用（一律存 null）
  if p_kind = '新人' and p_video is not true then
    raise exception '新人必須勾選「已看完線上回覆實戰全攻略影片」';
  end if;

  -- 備註
  if v_note is not null and char_length(v_note) > 500 then
    raise exception '備註最多 500 字';
  end if;

  -- 防重複
  if p_kind = '複檢' then
    if exists (select 1 from public.exam_requests r
               where r.improvement_ticket_id = v_tk.id and r.kind = '複檢'
                 and r.status = any(public.exam_req_status_open())) then
      raise exception '這張改善單已有複檢回報在處理中';
    end if;
  else
    if exists (select 1 from public.exam_requests r
               where r.employee_id = v_emp.id and r.kind = p_kind
                 and r.status = any(public.exam_req_status_open())) then
      raise exception '這位人員已有一筆「%」回報在處理中', p_kind;
    end if;
  end if;

  begin
    insert into public.exam_requests
      (kind, employee_id, employee_label, store_code, requested_by, requested_role,
       desired_dates, video_done, note, improvement_ticket_id)
    values
      (p_kind, v_emp.id, public.exam_req_label(v_emp.nickname, v_emp.full_name), v_emp.store_code,
       public.roster_my_email(),
       case when v_role = 'cs_admin' then '客服部' else '店長' end,
       p_dates,
       case when p_kind = '新人' then true else null end,
       v_note,
       case when p_kind = '複檢' then v_tk.id else null end)
    returning id into v_id;
  exception when unique_violation then
    raise exception '這位人員（或這張改善單）已有同一種情況的回報在處理中';
  end;

  perform public.exam_req_notify('new', v_id);
  return v_id;
end;
$$;

-- 撤回（店長：自己門市、待處理；客服部：待處理或已排定）
create or replace function public.exam_req_withdraw(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(public.roster_my_role(), '');
  r public.exam_requests%rowtype;
begin
  if v_role not in ('cs_admin', 'store_manager') then
    raise exception '沒有權限';
  end if;

  select * into r from public.exam_requests where id = p_id for update;
  if v_role = 'store_manager'
     and (not found or r.store_code is distinct from public.roster_my_store()) then
    raise exception '找不到這筆回報或沒有權限';
  end if;
  if not found then
    raise exception '找不到回報';
  end if;

  if v_role = 'store_manager' and r.status <> '待處理' then
    raise exception '只有「待處理」的回報可以撤回（目前：%）', r.status;
  end if;
  if v_role = 'cs_admin' and r.status not in ('待處理', '已排定') then
    raise exception '只有「待處理」或「已排定」的回報可以撤回（目前：%）', r.status;
  end if;

  if v_role = 'cs_admin' and r.requested_by is distinct from public.roster_my_email() then
    -- 客服部撤回別人的回報：原因寫「客服部撤回」，並讓店長看到
    update public.exam_requests
       set status = '已取消',
           cancel_by = '客服部',
           cancel_reason = '客服部撤回',
           mgr_seen = false
     where id = p_id;
  else
    update public.exam_requests
       set status = '已取消',
           cancel_by = case when v_role = 'cs_admin' then '客服部' else '店長' end,
           cancel_reason = '回報人撤回'
     where id = p_id;
  end if;
end;
$$;

-- 排定（客服部）：待處理或已排定 → 已排定（可重新排定）
create or replace function public.exam_req_schedule(p_id uuid, p_at timestamptz, p_note text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r public.exam_requests%rowtype;
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;

  select * into r from public.exam_requests where id = p_id for update;
  if not found then
    raise exception '找不到回報';
  end if;
  if r.status not in ('待處理', '已排定') then
    raise exception '只有「待處理」或「已排定」的回報可以排定（目前：%）', r.status;
  end if;
  if p_at is null then
    raise exception '請填寫考核日期時間';
  end if;
  if p_at < now() - interval '1 hour' then
    raise exception '考核時間不可早於現在往前 1 小時';
  end if;

  update public.exam_requests
     set status = '已排定',
         scheduled_at = p_at,
         reply_note = nullif(btrim(coalesce(p_note, ''), E' \t\r\n' || chr(12288)), ''),
         handled_by = public.roster_my_email(),
         mgr_seen = false
   where id = p_id;

  perform public.exam_req_notify('scheduled', p_id);
end;
$$;

-- 退回（客服部）：待處理或已排定 → 已取消，原因必填
create or replace function public.exam_req_return(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r public.exam_requests%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''), E' \t\r\n' || chr(12288));
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;

  select * into r from public.exam_requests where id = p_id for update;
  if not found then
    raise exception '找不到回報';
  end if;
  if r.status not in ('待處理', '已排定') then
    raise exception '只有「待處理」或「已排定」的回報可以退回（目前：%）', r.status;
  end if;
  if v_reason = '' then
    raise exception '退回原因不可空白';
  end if;

  update public.exam_requests
     set status = '已取消',
         cancel_by = '客服部',
         cancel_reason = v_reason,
         handled_by = public.roster_my_email(),
         mgr_seen = false
   where id = p_id;

  perform public.exam_req_notify('returned', p_id);
end;
$$;

-- 店長標記已看：自己門市所有 mgr_seen = false 的回報設為已看
create or replace function public.exam_req_mark_seen()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(public.roster_my_role(), '') <> 'store_manager' then
    raise exception '沒有權限';
  end if;
  update public.exam_requests
     set mgr_seen = true
   where store_code = public.roster_my_store()
     and mgr_seen = false;
end;
$$;

-- 紅點數字：客服部＝待處理數；店長＝自己門市未看過的回覆數；主管＝0
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
    select count(*)::int into v_n from public.exam_requests where status = '待處理';
  elsif v_role = 'store_manager' then
    select count(*)::int into v_n from public.exam_requests
     where store_code = public.roster_my_store() and mgr_seen = false;
  elsif v_role = 'hq_viewer' then
    v_n := 0;
  else
    raise exception '沒有權限';
  end if;
  return v_n;
end;
$$;

-- 依 pg_net 的回應更新寄信佇列（客服部）。回傳這次更新的筆數。
--   逾時（timed_out）或有錯誤訊息（error_msg）→ failed，原因寫進 last_error
--   status_code 200～399 → sent（意思是「寄信腳本已收到請求」；Google Apps Script 常回 302 轉址，所以 3xx 也算）
--   status_code 400 以上（或 200 以下）→ failed，last_error 記 HTTP 狀態碼與回應前 200 字
--   還沒有回應的列維持 queued；沒有 pg_net 時什麼都不做
create or replace function public.mail_outbox_sync()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row record;
  v_res record;
  v_n int := 0;
begin
  if coalesce(public.roster_my_role(), '') <> 'cs_admin' then
    raise exception '沒有權限';
  end if;
  if not public.exam_req_net_ready() then
    return 0;
  end if;

  for v_row in
    select m.id, m.net_request_id
    from public.mail_outbox m
    where m.status = 'queued' and m.net_request_id is not null
    order by m.created_at
  loop
    select * into v_res from public.exam_req_net_result(v_row.net_request_id);
    if not found then
      continue;     -- 還沒有回應（或回應已被 pg_net 清掉）
    end if;

    if coalesce(v_res.timed_out, false) then
      update public.mail_outbox
         set status = 'failed', last_error = left('逾時' || coalesce('：' || nullif(btrim(v_res.error_msg), ''), ''), 500)
       where id = v_row.id;
      v_n := v_n + 1;
    elsif nullif(btrim(coalesce(v_res.error_msg, '')), '') is not null then
      update public.mail_outbox
         set status = 'failed', last_error = left(v_res.error_msg, 500)
       where id = v_row.id;
      v_n := v_n + 1;
    elsif v_res.status_code between 200 and 399
          and coalesce(v_res.content, '') ~* '"ok"[[:space:]]*:[[:space:]]*false' then
      -- 腳本有回應但明說 ok:false（例如密碼不正確）
      update public.mail_outbox
         set status = 'failed', last_error = left(btrim(v_res.content), 200)
       where id = v_row.id;
      v_n := v_n + 1;
    elsif v_res.status_code between 200 and 399 then
      update public.mail_outbox
         set status = 'sent', last_error = null
       where id = v_row.id;
      v_n := v_n + 1;
    elsif v_res.status_code is not null then
      update public.mail_outbox
         set status = 'failed',
             last_error = left('HTTP ' || v_res.status_code::text
                               || coalesce('：' || nullif(left(btrim(coalesce(v_res.content, '')), 200), ''), ''), 500)
       where id = v_row.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

-- ---------- 函式權限：收回 public／anon，只授權 authenticated ----------
-- 對外函式的角色檢查在函式內部（非授權角色一律丟「沒有權限」）。
revoke execute on function public.exam_req_candidates(text)                                   from public, anon;
revoke execute on function public.exam_req_create(text, text, date[], boolean, text, uuid)    from public, anon;
revoke execute on function public.exam_req_withdraw(uuid)                                     from public, anon;
revoke execute on function public.exam_req_schedule(uuid, timestamptz, text)                  from public, anon;
revoke execute on function public.exam_req_return(uuid, text)                                 from public, anon;
revoke execute on function public.exam_req_mark_seen()                                        from public, anon;
revoke execute on function public.exam_req_badge()                                            from public, anon;
revoke execute on function public.mail_outbox_sync()                                          from public, anon;
-- 內部小工具與觸發器函式：任何網頁角色都不能直接呼叫（函式之間以擁有者身分呼叫）
revoke execute on function public.exam_req_status_open()                                      from public, anon, authenticated;
revoke execute on function public.exam_req_label(text, text)                                  from public, anon, authenticated;
revoke execute on function public.exam_req_esc(text)                                          from public, anon, authenticated;
revoke execute on function public.exam_req_setting(text)                                      from public, anon, authenticated;
revoke execute on function public.exam_req_link()                                             from public, anon, authenticated;
revoke execute on function public.exam_req_net_ready()                                        from public, anon, authenticated;
revoke execute on function public.exam_req_net_post(text, jsonb, jsonb, int)                  from public, anon, authenticated;
revoke execute on function public.exam_req_net_result(bigint)                                 from public, anon, authenticated;
revoke execute on function public.exam_req_mail_content(text, uuid)                           from public, anon, authenticated;
revoke execute on function public.exam_req_enqueue(text[], text, text, text, uuid)            from public, anon, authenticated;
revoke execute on function public.exam_req_notify(text, uuid)                                 from public, anon, authenticated;
revoke execute on function public.mail_outbox_dispatch()                                      from public, anon, authenticated;
revoke execute on function public.exam_req_auto_complete()                                    from public, anon, authenticated;

grant execute on function public.exam_req_candidates(text)                                    to authenticated;
grant execute on function public.exam_req_create(text, text, date[], boolean, text, uuid)     to authenticated;
grant execute on function public.exam_req_withdraw(uuid)                                      to authenticated;
grant execute on function public.exam_req_schedule(uuid, timestamptz, text)                   to authenticated;
grant execute on function public.exam_req_return(uuid, text)                                  to authenticated;
grant execute on function public.exam_req_mark_seen()                                         to authenticated;
grant execute on function public.exam_req_badge()                                             to authenticated;
grant execute on function public.mail_outbox_sync()                                           to authenticated;

commit;
