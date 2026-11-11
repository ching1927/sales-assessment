/*
 * 三級制評分的純函式（不連資料庫、不碰畫面）。
 * 瀏覽器：window.Grade3Core；Node：module.exports。
 *
 * 規則（老闆已批准）：
 *   新單等級：優良、尚可、待加強（另有「不適用」）；舊單保留原字串：優、良、待加強、不及格，不換算。
 *   顏色：優良／優＝綠、尚可／良＝橘、待加強／不及格＝紅、不適用＝灰（舊字串的文字維持舊名稱，只借用對應顏色）。
 *   新人考核：面向選「尚可」或「待加強」時，面向備註必填（去掉空白後不是空的，無字數下限）；
 *   其他考核（正式、回考核期、健檢）：同一個備註欄只是選填。
 *
 * 用法：
 *   Grade3Core.levelKind('尚可')                    // 'top' | 'mid' | 'low' | 'na'；不認得回 ''
 *   Grade3Core.levelColor('良')                      // '#F59E0B'（舊字串也有顏色）
 *   Grade3Core.isLegacyLevel('優')                   // true（優、良、不及格）
 *   Grade3Core.hasLegacy({資訊正確性:'良'})            // true
 *   Grade3Core.noteApplies('尚可')                   // true：這個等級要顯示面向備註欄（尚可、待加強）
 *   Grade3Core.noteRequired('新人', '尚可')           // true：只有新人考核的尚可／待加強必填
 *   Grade3Core.missingNotes('新人', levels, notes)   // ['預設訊息運用', ...]：必填但還沒寫的面向（照七面向順序）
 *   Grade3Core.notesPayload(levels, notes)           // 要送資料庫的面向備註：只留尚可／待加強、去空白後非空
 *   Grade3Core.reportNotes(levels, notes)            // 成績單用：[{dim, level, note}]，只含有備註的非優良面向
 *   Grade3Core.missingText(missing)                  // 擋送出時的白話訊息
 */
(function (root) {
  var DIMS = ['資訊正確性', '預設訊息運用', '問題掌握', '主動引導', '風險意識', '語氣與禮貌', '文字品質'];
  var NA = '不適用';
  var KIND = { '優良': 'top', '優': 'top', '尚可': 'mid', '良': 'mid', '待加強': 'low', '不及格': 'low' };
  KIND[NA] = 'na';
  var COLOR = { top: '#10B981', mid: '#F59E0B', low: '#EF4444', na: '#9CA3AF' };
  var LEGACY = ['優', '良', '不及格'];

  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  // 去掉半形與全形空白
  function trim(s) { return String(s == null ? '' : s).replace(/^[\s　]+|[\s　]+$/g, ''); }

  function levelKind(lv) { return typeof lv === 'string' && has(KIND, lv) ? KIND[lv] : ''; }
  function levelColor(lv) { var k = levelKind(lv); return k ? COLOR[k] : ''; }
  function isLegacyLevel(lv) { return LEGACY.indexOf(lv) >= 0; }
  function hasLegacy(levels) {
    if (!levels || typeof levels !== 'object') return false;
    return Object.keys(levels).some(function (k) { return isLegacyLevel(levels[k]); });
  }
  function noteApplies(lv) { return lv === '尚可' || lv === '待加強'; }
  function noteRequired(tenure, lv) { return tenure === '新人' && noteApplies(lv); }

  function missingNotes(tenure, levels, notes) {
    var out = [];
    if (tenure !== '新人' || !levels) return out;
    DIMS.forEach(function (d) {
      if (noteRequired(tenure, levels[d]) && !trim(notes && notes[d])) out.push(d);
    });
    return out;
  }

  function notesPayload(levels, notes) {
    var out = {};
    if (!levels || !notes) return out;
    DIMS.forEach(function (d) {
      var t = trim(notes[d]);
      if (noteApplies(levels[d]) && t) out[d] = t;
    });
    return out;
  }

  function reportNotes(levels, notes) {
    var out = [];
    if (!levels || !notes || typeof notes !== 'object') return out;
    DIMS.forEach(function (d) {
      var t = trim(notes[d]), lv = levels[d];
      if (t && lv && lv !== '優良' && lv !== '優' && lv !== NA) out.push({ dim: d, level: lv, note: t });
    });
    return out;
  }

  function missingText(missing) {
    if (!missing || !missing.length) return '';
    return '不能送出：以下面向選了尚可或待加強，還沒寫備註：' + missing.map(function (m) { return '「' + m + '」'; }).join('、') + '。';
  }

  var api = {
    DIMS: DIMS,
    NOT_APPLICABLE: NA,
    levelKind: levelKind,
    levelColor: levelColor,
    isLegacyLevel: isLegacyLevel,
    hasLegacy: hasLegacy,
    noteApplies: noteApplies,
    noteRequired: noteRequired,
    missingNotes: missingNotes,
    notesPayload: notesPayload,
    reportNotes: reportNotes,
    missingText: missingText
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.Grade3Core = api;
})(typeof window !== 'undefined' ? window : null);
