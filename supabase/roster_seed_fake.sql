-- ============================================================
-- 業務考核系統：人員名冊「假資料」（僅供測試用）
--
-- ⚠️ 這是測試用假資料：假門市、假暱稱、假員工編號（MI-9001 起）、
--    假信箱（vr-xxx@2motor.tw，符合 accounts 網域檢查）。沒有任何真實人名、信箱或編號。
-- ⚠️ 尚未執行，待老闆同意後才在 Supabase 執行；且須先跑過 roster_schema.sql。
-- 可重複執行（on conflict do nothing）。
-- 到職日用「今天減幾天」產生，所以新人／正式的結果會隨日期變動（邊界案例固定在 -90 與 -91）。
--
-- 資料概況：3 間假門市、15 位假人員（總公司 3、甲店 5、乙店 7，含 1 位 PT 工讀與 1 位離職）、
--           4 個假登入信箱。
-- ============================================================

insert into public.stores (code, name) values
  ('TEST-HQ', '測試總公司'),
  ('TEST-A',  '測試門市甲'),
  ('TEST-B',  '測試門市乙')
on conflict (code) do nothing;

insert into public.employees
  (id, nickname, full_name, store_code, job_title, hire_date, status, include_in_assessment)
values
  -- 測試總公司（3）
  ('MI-9001', '測試小客',   null,       'TEST-HQ', '客服',       (now() at time zone 'Asia/Taipei')::date - 800, '在職', false),
  ('MI-9002', '測試主管A',  '測試甲',   'TEST-HQ', '總公司主管', (now() at time zone 'Asia/Taipei')::date - 900, '在職', false),
  ('MI-9003', '測試主管B',  null,       'TEST-HQ', '總公司主管', (now() at time zone 'Asia/Taipei')::date - 700, '在職', false),
  -- 測試門市甲（5）
  ('MI-9004', '測試店長甲', '測試乙',   'TEST-A',  '店長',       (now() at time zone 'Asia/Taipei')::date - 1500, '在職', false),
  ('MI-9005', '測試業務一', null,       'TEST-A',  '業務',       (now() at time zone 'Asia/Taipei')::date - 30,   '在職', true),   -- 新人
  ('MI-9006', null,         '測試丙',   'TEST-A',  '業務',       (now() at time zone 'Asia/Taipei')::date - 90,   '在職', true),   -- 第 90 天＝新人
  ('MI-9007', '測試收車一', null,       'TEST-A',  '收車業務',   (now() at time zone 'Asia/Taipei')::date - 91,   '在職', true),   -- 第 91 天＝正式
  ('MI-9008', '測試助理甲', null,       'TEST-A',  '助理',       (now() at time zone 'Asia/Taipei')::date - 300,  '在職', false),
  -- 測試門市乙（7）
  ('MI-9009', '測試店長乙', '測試丁',   'TEST-B',  '店長',       (now() at time zone 'Asia/Taipei')::date - 900,  '在職', false),
  ('MI-9010', '測試業務二', null,       'TEST-B',  '業務',       (now() at time zone 'Asia/Taipei')::date - 10,   '在職', true),   -- 新人
  ('MI-9011', '測試業助',   null,       'TEST-B',  '業務/助理',  null,                '在職', true),   -- 未填到職日
  ('MI-9012', null,         '測試戊',   'TEST-B',  '收車業務',   (now() at time zone 'Asia/Taipei')::date - 400,  '在職', true),   -- 正式
  ('MI-9013', '測試業務三', null,       'TEST-B',  '業務',       (now() at time zone 'Asia/Taipei')::date - 200,  '離職', true),   -- 離職
  ('MI-9014', '測試助理乙', null,       'TEST-B',  '助理',       (now() at time zone 'Asia/Taipei')::date - 500,  '在職', false),
  ('PT-9901',  '測試工讀',   null,       'TEST-B',  '工讀',       (now() at time zone 'Asia/Taipei')::date - 20,   '在職', false)   -- PT 開頭
on conflict (id) do nothing;

insert into public.app_users (email, role, store_code, employee_id) values
  ('vr-cs.test1@2motor.tw',  'cs_admin',      null,      'MI-9001'),
  ('vr-hq.test1@2motor.tw',  'hq_viewer',     null,      'MI-9002'),
  ('vr-mgr.a@2motor.tw',     'store_manager', 'TEST-A',  'MI-9004'),
  ('vr-mgr.b@2motor.tw',     'store_manager', 'TEST-B',  'MI-9009')
on conflict (email) do nothing;
