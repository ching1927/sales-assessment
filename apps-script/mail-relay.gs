/**
 * 貳輪嶼業務考核系統：寄信小幫手（Google Apps Script）
 *
 * 作用：Supabase 資料庫有「待考回報」等事件時，會把信件內容送到這支腳本，由它用公司 Google 帳號寄出。
 * 安全做法：
 *   1. 必須帶正確的密碼（RELAY_TOKEN，存在「指令碼屬性」，不寫在程式裡，也不會進公開倉庫）才會寄。
 *   2. 收件人只接受 @2motor.tw 的信箱，且一次最多 30 位。
 *   3. 主旨會去掉換行並限制長度；內容長度也有上限。
 * 設定步驟請看專案裡的「設定步驟E_寄信.md」。
 */

var ALLOWED_DOMAIN = '@2motor.tw';
var MAX_RECIPIENTS = 30;
var MAX_SUBJECT = 200;
var MAX_HTML = 20000;
var SENDER_NAME = '貳輪嶼業務考核系統';

function doPost(e) {
  try {
    var expected = PropertiesService.getScriptProperties().getProperty('RELAY_TOKEN');
    if (!expected || expected.length < 20) return out_({ ok: false, error: 'RELAY_TOKEN 尚未設定或太短（至少 20 字）' });

    var data = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (!safeEqual_(String(data.token || ''), expected)) return out_({ ok: false, error: '密碼不正確' });

    var to = (data.to || []).map(function (x) { return String(x || '').trim().toLowerCase(); })
      .filter(function (x, i, a) { return x && a.indexOf(x) === i; });
    if (!to.length) return out_({ ok: false, error: '沒有收件人' });
    if (to.length > MAX_RECIPIENTS) return out_({ ok: false, error: '收件人太多' });
    var bad = to.filter(function (x) {
      return !/^[a-z0-9._%+\-]+@[a-z0-9.\-]+$/.test(x) || x.slice(-ALLOWED_DOMAIN.length) !== ALLOWED_DOMAIN;
    });
    if (bad.length) return out_({ ok: false, error: '只接受 ' + ALLOWED_DOMAIN + ' 的信箱' });

    var subject = String(data.subject || '').replace(/[\r\n]+/g, ' ').trim().slice(0, MAX_SUBJECT);
    var html = String(data.html || '');
    if (!subject || !html) return out_({ ok: false, error: '主旨或內容是空的' });
    if (html.length > MAX_HTML) return out_({ ok: false, error: '內容太長' });

    MailApp.sendEmail({
      to: to.join(','),
      subject: subject,
      htmlBody: html,
      body: html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim(),
      name: SENDER_NAME
    });
    return out_({ ok: true, sent: to.length });
  } catch (err) {
    return out_({ ok: false, error: String(err && err.message ? err.message : err) });
  }
}

// 用瀏覽器直接開網址只會看到「ok」，不會洩漏任何設定
function doGet() {
  return ContentService.createTextOutput('ok');
}

function out_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// 比對密碼（長度相同才逐字比，避免提早結束）
function safeEqual_(a, b) {
  if (a.length !== b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * 測試用：在編輯器選這個函式按「執行」，會寄一封測試信給「目前登入的你自己」。
 * 第一次執行 Google 會要求授權寄信權限，請用公司帳號同意。
 */
function testSend() {
  var me = Session.getEffectiveUser().getEmail();
  if (!me) throw new Error('取不到目前使用者信箱');
  MailApp.sendEmail({
    to: me,
    subject: '【測試】貳輪嶼業務考核系統寄信小幫手',
    htmlBody: '<p>如果你收到這封信，代表寄信小幫手可以正常寄信。</p>',
    name: SENDER_NAME
  });
  Logger.log('已寄出測試信給 ' + me);
}
