-- ============================================================
-- exam_notice_patch.sql：排定信改版（可單獨貼進 Supabase SQL Editor 執行，可重複執行）
--   1) exam_req_mail_content：排定信（scheduled）改寫成「請店長轉傳給考生」；
--      情況為「新人」時附「考前通知」（固定文字）；複檢等其他情況不附。
--   2) exam_req_notify：排定信的收件人＝回報人＋該門市（store_code）的店長，轉小寫去重；
--      new（寄客服部）、returned（寄回報人）不變。收件人合格與否仍由 exam_req_enqueue 過濾。
-- 只含這兩個函式的 create or replace，不動資料表、不動其他函式、不含任何信箱。
-- 前提：exam_request_schema.sql 已執行過（函式簽名不變，權限 revoke 不會被覆蓋）。
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
    v_intro := '客服部已排定考核時間，請店長轉傳給考生。';
    v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">排定時間</td><td style="padding:4px 0">'
              || public.exam_req_esc(to_char(r.scheduled_at at time zone 'Asia/Taipei', 'YYYY-MM-DD HH24:MI')) || '</td></tr>';
    v_text := r.reply_note;
    if nullif(btrim(coalesce(v_text, '')), '') is not null then
      v_rows := v_rows || '<tr><td style="padding:4px 12px 4px 0;color:#666">備註</td><td style="padding:4px 0">'
                || public.exam_req_esc(left(v_text, 80) || case when char_length(v_text) > 80 then '…' else '' end)
                || '</td></tr>';
    end if;
    v_extra := '<p style="margin:12px 0"><b>考核在線上進行，請同仁準時上線。</b></p>';
    -- 新人才附「考前通知」（全部是固定文字，不放任何使用者輸入）
    if r.kind = '新人' then
      v_extra := v_extra
        || '<p style="margin:16px 0 4px"><b>考前通知（請店長轉傳給考生）</b></p>'
        || '<p style="margin:4px 0"><b>【新人考核通知】</b></p>'
        || '<p style="margin:4px 0">請準時上線，用手機的 LINE 官方帳號參加（時間見上方「排定時間」）。</p>'
        || '<p style="margin:4px 0">請準備：1. 手機（電量充足、網路穩定）　2. 登入 LINE 官方帳號聊天室　3. 找一個安靜、不會被打斷的地方。</p>'
        || '<p style="margin:4px 0">不需要事先複習。考官會用私人 LINE 扮演客人傳訊息給你，你用官方 LINE 像平常回客人一樣回覆，可以查公司資料。共 6 個題組，由兩位考官輪流出題，考官 1 先考完再換考官 2。</p>'
        || '<p style="margin:4px 0">考完不用交東西，成績由客服部通知。</p>';
    end if;

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
    elsif p_type = 'scheduled' then
      -- 排定信：回報人＋該門市店長（轉傳給考生）；轉小寫去重，合格與否交給 exam_req_enqueue 過濾
      select coalesce(array_agg(x.mail order by x.mail), '{}'::text[]) into v_to
      from (select distinct lower(btrim(t.mail)) as mail
            from (select r.requested_by as mail
                  union all
                  select u.email from public.app_users u
                   where u.role = 'store_manager' and u.store_code = r.store_code) t
            where t.mail is not null) x;
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

-- 檢查：兩個函式都在 → 回傳 2 列
select p.proname as 函式, 'ok' as 狀態
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('exam_req_mail_content', 'exam_req_notify')
order by p.proname;
