/*
 * 雙考官輪流考核的純函式（不連資料庫、不碰畫面）。規則見 supabase/dual_examiner_schema.sql 與設計文件。
 * 瀏覽器：window.AssessDualCore；Node：module.exports。
 *
 * 資料形狀：
 *   examiners = { my_slot, slots: [{ slot, name, scope, submittedAt, lastSavedAt }] }（AssessApi.loadExaminers 的結果；不含信箱）
 *   前端題組 item = { id, cat, code, name, levels, note, noteUrl, dimNotes, imgs, slot }，slot 是負責考官（1 或 2）
 */
(function (root) {
  var DIM_COUNT = 7;
  var CAT_ORDER = ['基礎', '進階', '綜合'];

  function isNotEnabled(err) {
    var code = err && err.code ? String(err.code) : '';
    var msg = err && err.message ? String(err.message) : '';
    return code === 'PGRST202' || code === '42883' || /Could not find the function|does not exist/i.test(msg);
  }

  function hm(iso) {
    if (!iso) return '';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    return d.toLocaleString('sv-SE', { timeZone: 'Asia/Taipei' }).slice(11, 16);
  }
  function md(iso) {
    var d = new Date(iso);
    return d.toLocaleString('sv-SE', { timeZone: 'Asia/Taipei' }).slice(5, 10);
  }
  // 相對時間：1 分鐘內「剛剛」、1 小時內「N 分鐘前」、同一天「HH:MM」、更早「MM-DD HH:MM」
  function relTime(iso, nowMs) {
    if (!iso) return '';
    var t = new Date(iso).getTime();
    if (isNaN(t)) return '';
    var now = nowMs == null ? Date.now() : nowMs;
    var diff = Math.max(0, now - t);
    if (diff < 60000) return '剛剛';
    if (diff < 3600000) return Math.floor(diff / 60000) + ' 分鐘前';
    if (md(new Date(now).toISOString()) === md(iso)) return hm(iso);
    return md(iso) + ' ' + hm(iso);
  }

  // 七面向都有選才算評完
  function levelsDone(levels) {
    return !!levels && Object.keys(levels).filter(function (k) { return !!levels[k]; }).length >= DIM_COUNT;
  }

  function slotItems(items, slot) {
    return (items || []).filter(function (i) { return i.slot === slot; });
  }
  function progress(items, slot) {
    var list = slotItems(items, slot);
    return { done: list.filter(function (i) { return levelsDone(i.levels); }).length, total: list.length };
  }
  function totalProgress(items) {
    var list = items || [];
    return { done: list.filter(function (i) { return levelsDone(i.levels); }).length, total: list.length };
  }

  // 該考官負責的範圍文字：基礎 3、進階 2＋綜合 1
  function scopeDesc(items, slot) {
    var list = slotItems(items, slot), cnt = {};
    list.forEach(function (i) { cnt[i.cat] = (cnt[i.cat] || 0) + 1; });
    var cats = CAT_ORDER.filter(function (c) { return cnt[c]; });
    Object.keys(cnt).forEach(function (c) { if (cats.indexOf(c) < 0) cats.push(c); });
    return cats.map(function (c) { return c + ' ' + cnt[c]; }).join('＋');
  }

  // 題組標籤：基礎 1、基礎 2、進階 1……（同分類內依出現順序編號）
  function groupLabel(items, item) {
    var n = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].cat === item.cat) n++;
      if (items[i] === item || items[i].id === item.id) return item.cat + ' ' + n;
    }
    return item.cat;
  }

  // assess_examiners 資料列（不含信箱）整理成 dual 狀態
  function makeDual(ex) {
    var slots = ((ex && ex.slots) || []).map(function (s) {
      return { slot: Number(s.slot), name: s.name || '', scope: s.scope || '', submittedAt: s.submittedAt || null, lastSavedAt: s.lastSavedAt || null };
    });
    var my = Number(ex && ex.my_slot);
    if (my !== 1 && my !== 2) return null;
    var other = 3 - my;
    function by(n) { return slots.filter(function (s) { return s.slot === n; })[0] || null; }
    var me = by(my), ot = by(other);
    if (!me || !ot) return null;
    return {
      mySlot: my, otherSlot: other, slots: slots,
      myName: me.name, otherName: ot.name,
      myScope: me.scope, otherScope: ot.scope,
      mySubmittedAt: me.submittedAt, otherSubmittedAt: ot.submittedAt,
      mySubmitted: !!me.submittedAt, otherSubmitted: !!ot.submittedAt,
      otherSavedAt: ot.lastSavedAt, mySavedAt: me.lastSavedAt
    };
  }
  function nameOfSlot(dual, slot) {
    var s = (dual && dual.slots || []).filter(function (x) { return x.slot === slot; })[0];
    return s ? s.name : '';
  }
  // 「考官2 PENNY」
  function slotTitle(dual, slot) { return '考官' + slot + ' ' + nameOfSlot(dual, slot); }

  // 自己的題組能不能改：是自己負責的、且自己還沒交卷
  function editable(dual, item) {
    if (!dual) return true;
    return item.slot === dual.mySlot && !dual.mySubmitted;
  }

  // 自己的題組是否都評完了（交卷條件）；missing 是還沒評完的題組標籤
  function canSubmit(items, mySlot) {
    var mine = slotItems(items, mySlot);
    var missing = mine.filter(function (i) { return !levelsDone(i.levels); }).map(function (i) { return groupLabel(items, i); });
    return { ok: mine.length > 0 && missing.length === 0, missing: missing, total: mine.length };
  }

  // 輪詢更新：只換對方題組的內容（等級、備註、網址、面向備註、圖片），自己的題組一律原封不動（不覆蓋未存的改動）
  function mergeOther(current, fresh, mySlot) {
    var by = {};
    (fresh || []).forEach(function (f) { by[f.id] = f; });
    return (current || []).map(function (c) {
      if (c.slot === mySlot) return c;
      var f = by[c.id];
      if (!f) return c;
      var o = {};
      Object.keys(c).forEach(function (k) { o[k] = c[k]; });
      o.levels = f.levels; o.note = f.note; o.noteUrl = f.noteUrl; o.dimNotes = f.dimNotes; o.imgs = f.imgs;
      o.hadDimNotes = f.hadDimNotes;
      return o;
    });
  }
  // 對方資料的指紋：輪詢後判斷有沒有變動，沒變就不重畫
  function otherSignature(items, dual) {
    var rows = slotItems(items, dual.otherSlot).map(function (i) {
      return [i.id, i.levels, i.note, i.noteUrl, i.dimNotes, (i.imgs || []).map(function (m) { return m.id; })];
    });
    return JSON.stringify([rows, dual.otherSubmittedAt, dual.otherSavedAt, dual.mySubmittedAt]);
  }

  // 另一位考官也在這張考核上，最後更新：考官1 UNA 剛剛
  function coEditText(dual, nowMs) {
    var t = dual.otherSavedAt ? relTime(dual.otherSavedAt, nowMs) : '尚未有更新';
    return '另一位考官也在這張考核上，最後更新：考官' + dual.otherSlot + ' ' + dual.otherName + ' ' + t;
  }
  function savedText(iso) { return iso ? '已自動暫存 ' + hm(iso) : ''; }

  // 草稿清單（assess_my_drafts 的一列）→ 顯示用
  function draftInfo(row) {
    var mp = row.my_progress || {}, op = row.other_progress || {};
    return {
      id: row.assessment_id,
      label: '考官' + row.my_slot + '・' + (row.my_scope || ''),
      openedByMe: !!row.opened_by_me,
      otherName: row.other_name || '',
      myProg: Number(mp.done || 0) + ' / ' + Number(mp.total || 0),
      otherProg: Number(op.done || 0) + ' / ' + Number(op.total || 0),
      mySubmitted: !!row.my_submitted_at,
      otherSubmitted: !!row.other_submitted
    };
  }

  // assess_start_dual 的回傳整理：{ aid, existing, mySlot }
  function parseStart(r) {
    var d = Array.isArray(r) ? r[0] : r;
    if (!d || !d.assessment_id) return null;
    return { aid: d.assessment_id, existing: !!d.existing, mySlot: d.my_slot == null ? null : Number(d.my_slot) };
  }
  // assess_submit_part 的回傳：{ done, waiting_for_slot }
  function parseSubmit(r) {
    var d = Array.isArray(r) ? r[0] : r;
    d = d || {};
    return { done: !!d.done, waitingForSlot: d.waiting_for_slot == null ? null : Number(d.waiting_for_slot) };
  }

  // 送出頁（仿樣品第 4 頁）：雙方進度、能不能送出、提示文字、等待對方文字、能不能撤回
  function submitView(items, dual) {
    var mine = canSubmit(items, dual.mySlot);
    function side(slot, submitted) {
      var list = slotItems(items, slot);
      var missing = list.filter(function (i) { return !levelsDone(i.levels); }).map(function (i) { return groupLabel(items, i); });
      return { slot: slot, total: list.length, done: list.length - missing.length, missing: missing, scope: scopeDesc(items, slot), submitted: !!submitted };
    }
    var me = side(dual.mySlot, dual.mySubmitted), ot = side(dual.otherSlot, dual.otherSubmitted);
    var hint;
    if (dual.mySubmitted) hint = '';
    else if (!me.total) hint = '沒有你負責的題組，無法送出。';
    else if (me.missing.length) hint = '還差 ' + me.missing.length + ' 題未完成';
    else hint = '你負責的題組都評完了，可以送出。';
    var waiting = '';
    if (dual.mySubmitted) waiting = dual.otherSubmitted ? '兩位考官都已送出，系統正在合併成績單。' : '已送出，等待考官' + dual.otherSlot + ' ' + dual.otherName;
    return { mine: me, other: ot, canSubmit: !dual.mySubmitted && mine.ok, canUnsubmit: !!dual.mySubmitted, hint: hint, waiting: waiting };
  }

  // 放棄被資料庫拒絕（已有考官送出）：要先撤回送出
  function needUnsubmit(msg) { return /請先撤回送出/.test(String(msg || '')); }
  function abandonGuide(msg, mySubmitted) {
    var base = String(msg || '').replace(/[。\s]+$/, '');
    return base + '。' + (mySubmitted
      ? '你已送出自己的題組，請先到「送出我的題組」頁按「撤回送出」，再放棄。'
      : '請先請已送出的考官到這張考核的「送出我的題組」頁按「撤回送出」（如果是你自己送出的，請先進入這張考核撤回），再放棄。');
  }
  // 撤回被資料庫拒絕：整張已完成
  function alreadyDone(msg) { return /已經完成|已完成|已作廢/.test(String(msg || '')); }

  // 範例圖片分組：secrets = [{ item_id, question_id }]，images = [{ id, question_id, storage_path, mime, size_bytes, sort_order }]
  // 回傳 { [item_id]: [{ id, path, mime, size }] }（依 sort_order；題組沒有圖就是空陣列）
  function groupSamples(secrets, images) {
    var byQ = {};
    (images || []).slice().sort(function (a, b) {
      var d = (Number(a.sort_order) || 0) - (Number(b.sort_order) || 0);
      return d || (String(a.id) < String(b.id) ? -1 : String(a.id) > String(b.id) ? 1 : 0);
    }).forEach(function (g) {
      var k = String(g.question_id);
      (byQ[k] = byQ[k] || []).push({ id: g.id, path: g.storage_path, mime: g.mime, size: Number(g.size_bytes) || 0 });
    });
    var out = {};
    (secrets || []).forEach(function (s) { out[s.item_id] = (byQ[String(s.question_id)] || []).slice(); });
    return out;
  }

  var api = {
    submitView: submitView, needUnsubmit: needUnsubmit, abandonGuide: abandonGuide, alreadyDone: alreadyDone, groupSamples: groupSamples,
    isNotEnabled: isNotEnabled, hm: hm, relTime: relTime, levelsDone: levelsDone,
    slotItems: slotItems, progress: progress, totalProgress: totalProgress, scopeDesc: scopeDesc, groupLabel: groupLabel,
    makeDual: makeDual, nameOfSlot: nameOfSlot, slotTitle: slotTitle, editable: editable, canSubmit: canSubmit,
    mergeOther: mergeOther, otherSignature: otherSignature, coEditText: coEditText, savedText: savedText,
    draftInfo: draftInfo, parseStart: parseStart, parseSubmit: parseSubmit
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.AssessDualCore = api;
})(typeof window !== 'undefined' ? window : this);
