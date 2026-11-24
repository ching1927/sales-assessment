/*
 * 題組「範例圖片」純函式（只給 questions.html／questions-api.js 用，不碰網路與畫面）。
 * 規則對照 supabase/question_images_schema.sql：
 *   路徑 {題組id}/{小寫uuid}.jpg|png|webp，副檔名須與 mime 相符；每題最多 8 張；每張 2MB 內。
 */
(function (root) {
  var MAX_IMAGES = 8;
  var MAX_BYTES = 2 * 1024 * 1024;
  var EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
  var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

  function isOkType(mime) { return Object.prototype.hasOwnProperty.call(EXT, mime); }

  // 產生小寫 uuid（瀏覽器 crypto；測試可傳入 randomBytes 函式）
  function newUuid(c) {
    c = c || (typeof crypto !== 'undefined' ? crypto : null);
    if (c && c.randomUUID) return String(c.randomUUID()).toLowerCase();
    var b = new Uint8Array(16); c.getRandomValues(b);
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    var x = Array.prototype.map.call(b, function (n) { return (n < 16 ? '0' : '') + n.toString(16); }).join('');
    return x.slice(0, 8) + '-' + x.slice(8, 12) + '-' + x.slice(12, 16) + '-' + x.slice(16, 20) + '-' + x.slice(20);
  }

  // {題組id}/{uuid}.{ext}；mime 不合法或 uuid 不是小寫 uuid 回 null
  function buildPath(questionId, uuid, mime) {
    var id = Number(questionId);
    if (!isFinite(id) || id <= 0 || Math.floor(id) !== id) return null;
    uuid = String(uuid || '').toLowerCase();
    if (!UUID_RE.test(uuid) || !isOkType(mime)) return null;
    return id + '/' + uuid + '.' + EXT[mime];
  }

  // 還能再傳幾張
  function slotsLeft(have) { return Math.max(0, MAX_IMAGES - (Number(have) || 0)); }

  // 把第 i 張往前（dir=-1）或往後（dir=1）移一格；回傳新的 id 陣列，移不動回 null
  function moveIds(ids, i, dir) {
    var j = i + dir;
    if (!Array.isArray(ids) || i < 0 || i >= ids.length || j < 0 || j >= ids.length) return null;
    var out = ids.slice(); var t = out[i]; out[i] = out[j]; out[j] = t;
    return out;
  }

  // 資料庫函式或資料表還沒建立（尚未貼 SQL）？
  function isUnavailable(err) {
    if (!err) return false;
    var code = err.code ? String(err.code) : '';
    var msg = err.message ? String(err.message).toLowerCase() : '';
    if (code === 'PGRST202' || code === 'PGRST205' || code === '42P01' || code === '42883') return true;
    return msg.indexOf('could not find the function') >= 0 || msg.indexOf('could not find the table') >= 0 ||
      (msg.indexOf('question_images') >= 0 && msg.indexOf('does not exist') >= 0) ||
      (msg.indexOf('bucket not found') >= 0);
  }

  var api = { MAX_IMAGES: MAX_IMAGES, MAX_BYTES: MAX_BYTES, EXT: EXT, isOkType: isOkType, newUuid: newUuid,
    buildPath: buildPath, slotsLeft: slotsLeft, moveIds: moveIds, isUnavailable: isUnavailable };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.QuestionImagesCore = api;
})(typeof window !== 'undefined' ? window : this);
