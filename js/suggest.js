/*
 * 弱項建議題組選題（純函式，不連資料庫、不碰畫面）。規則見 supabase/README_weak_suggest.md 第一節。
 * 瀏覽器：window.Suggest；Node：module.exports。
 *
 * 用法：
 *   Suggest.TAG_DIMS     // 可勾選、可拿來挑題的 5 個面向
 *   Suggest.ALWAYS_DIMS  // 每題都評、不勾選也不挑題的 2 個面向（語氣與禮貌、文字品質）
 *   Suggest.WEAK_BELOW   // 85：弱項必須得分率低於這個值（剛好 85 不算）
 *   Suggest.weakOf(profile) // 保留下來的弱項 [{dim, pct}]（5 個面向、pct < 85、由低到高、至多 2 個）；畫面顯示弱項標籤只用它
 *   Suggest.pick(profile, pool, n[, rng])
 *     profile：assess_weak_profile 回傳的 jsonb（{ n, rates, weak:[{dim,pct}], always_low }）
 *     pool：assess_suggest_pool 的列（{question_id, category, title, dims, taken_before, drawn_this_round}）
 *     -> { items:[{question_id, category, title, dims, kind:'weak'|'rand', dim, repeated}], short, empty }
 *     empty＝沒有任何弱項可用（n 不是正整數或 weak 為空），此時 items 為空，網頁應照原流程
 *     short＝弱項題湊不滿（標記不足），不足的部分已用隨機題補
 *     fewCats＝湊不滿 n 題（一場考核每個分類最多一個題組，分類或題組不夠），items 少於 n
 *   同一份清單內，同一分類最多一題（assess_pick 沿用 assess_draw 的限制）
 *   追加題（assess_add_extra 不受每分類一題限制）：pick／swap 另收選填的 opts，opts.allowSameCategory 為 true 時同分類可以出現多題；
 *     預設（不傳 opts 或為 false）行為不變。pick(profile, pool, n[, rng[, opts]])、swap(profile, pool, currentItems, index[, rng[, opts]])
 *   Suggest.swap(profile, pool, currentItems, index[, rng]) -> 新的一題（格式同 items 的元素）或 null
 *   rng 為選填的亂數函式（回傳 0 到 1 之間，預設 Math.random），測試時可傳固定值。
 */
(function (root) {
  var TAG_DIMS = ['資訊正確性', '預設訊息運用', '問題掌握', '主動引導', '風險意識'];
  var ALWAYS_DIMS = ['語氣與禮貌', '文字品質'];

  function dimsOf(q) { return Array.isArray(q && q.dims) ? q.dims : []; }
  var WEAK_BELOW = 85;
  // 取弱項的唯一入口：只留 5 個面向、pct 為數字且 < 85、不重複，由低到高，至多 2 個
  function weakOf(profile) {
    var out = [];
    ((profile && profile.weak) || []).forEach(function (w) {
      var d = w && w.dim, p = w && w.pct == null ? NaN : Number(w && w.pct);
      if (TAG_DIMS.indexOf(d) >= 0 && isFinite(p) && p < WEAK_BELOW && !out.some(function (x) { return x.dim === d; })) out.push({ dim: d, pct: p });
    });
    out.sort(function (a, b) { return a.pct - b.pct; });
    return out.slice(0, 2);
  }
  function weakDims(profile) { return weakOf(profile).map(function (w) { return w.dim; }); }
  function choose(list, rng) {
    if (!list.length) return null;
    var r = typeof rng === 'function' ? rng() : Math.random();
    var i = Math.floor(r * list.length);
    return list[Math.min(Math.max(i, 0), list.length - 1)];
  }
  // used 同時記「已選題組 id」與「已佔用分類」（鍵為 'cat:' 加分類名）
  // used.__same 為真（opts.allowSameCategory）時只記題組 id，不佔用分類
  function take(used, q) { used[q.question_id] = 1; if (!used.__same) used['cat:' + q.category] = 1; }
  function free(pool, used) {
    return pool.filter(function (q) { return !used[q.question_id] && !used['cat:' + q.category]; });
  }
  function toItem(q, kind, dim, repeated) {
    return {
      question_id: q.question_id, category: q.category, title: q.title, dims: dimsOf(q).slice(),
      kind: kind, dim: dim, repeated: !!repeated
    };
  }
  // 隨機題：優先「沒考過且本輪沒被抽過」，再「沒考過」，所有題都考過才允許重複
  function randomOne(pool, used, rng) {
    var open = free(pool, used);
    var fresh = open.filter(function (q) { return !q.taken_before; });
    var t1 = fresh.filter(function (q) { return !q.drawn_this_round; });
    if (t1.length) return toItem(choose(t1, rng), 'rand', null, false);
    if (fresh.length) return toItem(choose(fresh, rng), 'rand', null, false);
    if (open.length) return toItem(choose(open, rng), 'rand', null, true);
    return null;
  }
  function weakCandidates(pool, used, dim) {
    return free(pool, used).filter(function (q) { return !q.taken_before && dimsOf(q).indexOf(dim) >= 0; });
  }

  function pick(profile, pool, n, rng, opts) {
    var weak = weakDims(profile);
    n = Math.floor(Number(n));
    pool = Array.isArray(pool) ? pool : [];
    if (!(n > 0) || !weak.length) return { items: [], short: false, fewCats: false, empty: true };
    var used = opts && opts.allowSameCategory ? { __same: 1 } : {}, items = [], slots = Math.min(n, Math.max(1, n - 1));
    for (var i = 0; i < slots; i++) {
      var dim = weak[i % weak.length], c = weakCandidates(pool, used, dim), useDim = dim;
      if (!c.length) {
        // 該弱項沒題了，改從另一個弱項面向找
        for (var k = 0; k < weak.length && !c.length; k++) {
          if (weak[k] === dim) continue;
          c = weakCandidates(pool, used, weak[k]); useDim = weak[k];
        }
      }
      var q = choose(c, rng);
      if (q) { take(used, q); items.push(toItem(q, 'weak', useDim, false)); }
    }
    var short = items.length < slots;
    while (items.length < n) {
      var r = randomOne(pool, used, rng);
      if (!r) break;
      take(used, r); items.push(r);
    }
    return { items: items, short: short, fewCats: items.length < n, empty: false };
  }

  function swap(profile, pool, currentItems, index, rng, opts) {
    pool = Array.isArray(pool) ? pool : [];
    var cur = currentItems && currentItems[index];
    if (!cur) return null;
    var allow = !!(opts && opts.allowSameCategory), used = allow ? { __same: 1 } : {};
    // 題組 id 全部排除（含被換掉的這題本身）；分類只排除「其他題」佔用的，換入的題可與被換掉那題同分類（allowSameCategory 時分類不限）
    currentItems.forEach(function (it, i) { used[it.question_id] = 1; if (!allow && i !== index) used['cat:' + it.category] = 1; });
    if (cur.kind === 'weak' && cur.dim) {
      var q = choose(weakCandidates(pool, used, cur.dim), rng);
      if (q) return toItem(q, 'weak', cur.dim, false);
    }
    return randomOne(pool, used, rng);
  }

  var api = { TAG_DIMS: TAG_DIMS, ALWAYS_DIMS: ALWAYS_DIMS, WEAK_BELOW: WEAK_BELOW, weakOf: weakOf, pick: pick, swap: swap };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (root) root.Suggest = api;
})(typeof window !== 'undefined' ? window : null);
