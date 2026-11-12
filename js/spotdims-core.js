/*
 * 抽查登記改版的純函式（不連資料庫、不碰畫面）。
 * 瀏覽器：window.SpotDims；Node：module.exports。
 *
 * 規則（老闆已核可）：
 *   * 資料庫存的判定值仍是「適當／不適當」，不改、不遷移；畫面一律顯示「優良回覆／待加強回覆」。
 *     所有顯示判定的地方都走 verdictLabel（共用對照函式），不要在別處自己寫對照。
 *   * 七面向不再打分，改成「可改善面向」複選（0～7 個）＋截圖（最多 10 張）＋說明（選填，500 字內）。
 *   * 舊抽查紀錄（有七面向等級與分數）一筆不改；legacyScore 讓畫面可以標示「舊制分數」。
 *
 * 用法：
 *   SpotDims.verdictLabel('適當')            // '優良回覆'；'不適當' → '待加強回覆'；不認得的原樣回傳；null 回 ''
 *   SpotDims.VERDICTS                        // [{value:'適當', label:'優良回覆'}, {value:'不適當', label:'待加強回覆'}]
 *   SpotDims.DIMS                            // 七面向名稱（固定順序）
 *   SpotDims.normalizeDims(['問題掌握','亂寫','問題掌握'])  // ['問題掌握']：去不認得、去重、依七面向順序
 *   SpotDims.shotPath(regId, fileId, 'image/jpeg')           // 'spot/{regId}/{fileId}.jpg'（Storage 路徑）
 *   SpotDims.legacyScore(row)                // 舊制分數（數字）；新制紀錄回 null
 *   SpotDims.validateReg(form)               // 登記前的檢查，回傳白話錯誤訊息；沒問題回 ''
 *   SpotDims.resultLines(label, day, verdict, res) // 登記成功後顯示的幾行文字
 */
(function (root) {
  var DIMS = ['資訊正確性', '預設訊息運用', '問題掌握', '主動引導', '風險意識', '語氣與禮貌', '文字品質'];
  var VERDICTS = [{ value: '適當', label: '優良回覆' }, { value: '不適當', label: '待加強回覆' }];
  var MAX_SHOTS = 10;
  var MAX_NOTE = 500;
  var EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

  function verdictLabel(v) {
    if (v == null) return '';
    for (var i = 0; i < VERDICTS.length; i++) if (VERDICTS[i].value === v) return VERDICTS[i].label;
    return String(v);
  }

  function normalizeDims(arr) {
    var seen = {};
    (Array.isArray(arr) ? arr : []).forEach(function (d) { if (DIMS.indexOf(d) >= 0) seen[d] = true; });
    return DIMS.filter(function (d) { return seen[d]; });
  }

  function shotPath(regId, fileId, mime) {
    if (!has(EXT, mime)) return '';
    return 'spot/' + regId + '/' + fileId + '.' + EXT[mime];
  }

  function legacyScore(row) {
    if (!row || row.total_score == null || row.total_score === '') return null;
    var n = Number(row.total_score);
    return isFinite(n) ? n : null;
  }

  // form: { emp, day, url, verdict, reason, dims, note, shotCount }
  function validateReg(f) {
    f = f || {};
    var url = String(f.url == null ? '' : f.url).replace(/^[\s　]+|[\s　]+$/g, '');
    var reason = String(f.reason == null ? '' : f.reason).replace(/^[\s　]+|[\s　]+$/g, '');
    var note = String(f.note == null ? '' : f.note).replace(/^[\s　]+|[\s　]+$/g, '');
    if (!f.emp) return '請選擇被抽查人員。';
    if (!f.day) return '請選擇抽查日期。';
    if (!url) return '請填寫訊息抽檢的 LINE 聊天室網址。';
    if (!/^https?:\/\/\S/i.test(url)) return '網址必須以 http:// 或 https:// 開頭，後面要接完整網址。';
    if (/\s/.test(url)) return '網址不可含空白。';
    if (url.length > 500) return '網址不可超過 500 字。';
    if (f.verdict !== '適當' && f.verdict !== '不適當') return '請選擇判定。';
    if (f.verdict === '不適當' && !reason) return '判定待加強回覆時，原因必填。';
    if (Array.isArray(f.dims) && normalizeDims(f.dims).length !== f.dims.length) return '可改善面向有不認得或重複的項目，請重新勾選。';
    if (note.length > MAX_NOTE) return '說明最多 ' + MAX_NOTE + ' 字。';
    if ((f.shotCount || 0) > MAX_SHOTS) return '截圖最多 ' + MAX_SHOTS + ' 張。';
    return '';
  }

  function resultLines(label, day, verdict, res) {
    var d = res && Array.isArray(res) ? res[0] : res;
    d = d || {};
    var lines = ['已登記：' + label + '，' + day + '，判定「' + verdictLabel(verdict) + '」；可改善面向 ' +
      (d.dims_count != null ? d.dims_count : 0) + ' 項、截圖 ' + (d.shots_count != null ? d.shots_count : 0) + ' 張。'];
    if (d.yellow_id) lines.push('已開立一張黃單。');
    if (d.red_id) lines.push('本月累積滿 5 張黃單，已自動開立一張改善紅單，黃單重新從 0 算。');
    if (d.probation_id) lines.push('本季累積 2 張紅單：建議移除官方 LINE 回覆權限，並已回到考核期。');
    return lines;
  }

  var api = {
    DIMS: DIMS, VERDICTS: VERDICTS, MAX_SHOTS: MAX_SHOTS, MAX_NOTE: MAX_NOTE,
    verdictLabel: verdictLabel, normalizeDims: normalizeDims, shotPath: shotPath,
    legacyScore: legacyScore, validateReg: validateReg, resultLines: resultLines
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.SpotDims = api;
})(typeof window !== 'undefined' ? window : this);
