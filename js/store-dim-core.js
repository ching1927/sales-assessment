/*
 * 各門市面向分析的純函式（不連資料庫、不碰畫面）。資料來源是資料庫函式 checkup_store_dims。
 * 瀏覽器：window.StoreDimCore；Node：module.exports。
 *
 * 資料列（資料庫回傳）：{ store_code, store_name, weak_records（有勾面向的待加強回覆筆數）, dim_counts（7 個整數，順序同 DIMS）}
 * 用法：
 *   StoreDimCore.DIMS                         七面向名稱（順序固定）
 *   StoreDimCore.normKey(key)                 排序鍵：'total'（全部面向合計）或 0~6（單一面向）；不合法一律當 'total'
 *   StoreDimCore.keyLabel(key)                排序鍵的中文名稱
 *   StoreDimCore.rank(rows, sortKey, myStore) -> 排名後的列
 *        每列 { store_code, store_name, weak, counts[7], total, rates[7]（weak 為 0 時為 null）, avg（合計÷weak，weak 為 0 時 null）,
 *               tops（最常被勾的面向名稱，並列全列，全 0 為 []）, mine, rank（null＝沒有名次）}
 *        名次越前＝比例越低；同比例並列（1、2、2、4）；weak 為 0 的門市排最後、沒有名次
 *        dim_counts 長度不是 7 或有缺值、非數字時，該格當 0
 *   StoreDimCore.summary(ranked, sortKey)     { best, worst, topDim }
 *        best／worst：{ names:[…], value:'1.3 個' 或 '12%' } 或 null；topDim：{ names:[…], count } 或 null（全公司都沒有被勾）
 *   StoreDimCore.maxRate(ranked)              全表最大的單格比例（紅色深淺的基準）
 *   StoreDimCore.formatPct(count, weak)       '12%'；weak 為 0 回 '—'
 *   StoreDimCore.formatAvg(row)               '1.3'（平均每筆勾幾個面向，小數 1 位）；weak 為 0 回 '—'
 *   StoreDimCore.fileBase(year, period)       下載檔名（不含副檔名）：各門市面向分析_2026_第4季
 */
(function (root) {
  var isNode = typeof module !== 'undefined' && module.exports;
  var CheckupCore = isNode ? require('./checkup-core.js') : root.CheckupCore;

  var DIMS = ['資訊正確性', '預設訊息運用', '問題掌握', '主動引導', '風險意識', '語氣與禮貌', '文字品質'];

  function cnt(n) { n = Math.floor(Number(n)); return isFinite(n) && n > 0 ? n : 0; }

  function normKey(key) {
    if (key === 'total' || key == null || key === '') return 'total';
    var n = Number(key);
    return Math.floor(n) === n && n >= 0 && n < DIMS.length ? n : 'total';
  }
  function keyLabel(key) { var k = normKey(key); return k === 'total' ? '全部面向合計' : DIMS[k]; }

  function topsOf(counts) {
    var mx = counts.reduce(function (a, v) { return v > a ? v : a; }, 0);
    return mx > 0 ? DIMS.filter(function (d, i) { return counts[i] === mx; }) : [];
  }
  function formatPct(count, weak) {
    return weak > 0 ? Math.round(count / weak * 100) + '%' : '—';
  }
  function formatAvg(r) {
    return r && r.weak > 0 ? (r.total / r.weak).toFixed(1) : '—';
  }

  function rank(rows, sortKey, myStore) {
    var key = normKey(sortKey);
    var list = (rows || []).map(function (r) {
      var src = r && Array.isArray(r.dim_counts) ? r.dim_counts : [];
      var counts = DIMS.map(function (d, i) { return cnt(src[i]); });
      var o = { store_code: r.store_code, store_name: r.store_name || r.store_code, weak: cnt(r.weak_records), counts: counts };
      o.total = counts.reduce(function (a, v) { return a + v; }, 0);
      o.rates = counts.map(function (c) { return o.weak > 0 ? c / o.weak : null; });
      o.avg = o.weak > 0 ? o.total / o.weak : null;
      o.tops = topsOf(counts);
      o.mine = !!myStore && r.store_code === myStore;
      return o;
    });
    list = CheckupCore.sortStores(list, 'store_code');   // 先照門市固定順序排，穩定排序讓同名次維持這個順序
    function numer(r) { return key === 'total' ? r.total : r.counts[key]; }
    // 比例用交叉相乘比大小，避免小數誤差讓該並列的沒並列
    function cmp(a, b) { return numer(a) * b.weak - numer(b) * a.weak; }
    function order(a, b) {
      if (a.weak === 0 || b.weak === 0) return a.weak === 0 ? (b.weak === 0 ? 0 : 1) : -1;   // weak 為 0 的排最後
      return cmp(a, b);
    }
    list.forEach(function (r, i) { r._i = i; });
    list.sort(function (a, b) { return order(a, b) || a._i - b._i; });
    var prev = null;
    list.forEach(function (r, i) {
      delete r._i;
      if (r.weak === 0) { r.rank = null; return; }
      r.rank = prev && cmp(prev, r) === 0 ? prev.rank : i + 1;
      prev = r;
    });
    return list;
  }

  function maxRate(ranked) {
    var mx = 0;
    (ranked || []).forEach(function (r) { r.rates.forEach(function (v) { if (v != null && v > mx) mx = v; }); });
    return mx;
  }

  function summary(ranked, sortKey) {
    var key = normKey(sortKey), list = ranked || [];
    var ranks = list.filter(function (r) { return r.rank != null; });
    function pick(rk) {
      var g = ranks.filter(function (r) { return r.rank === rk; });
      if (!g.length) return null;
      var v = key === 'total' ? formatAvg(g[0]) + ' 個' : formatPct(g[0].counts[key], g[0].weak);
      return { names: g.map(function (r) { return r.store_name; }), value: v };
    }
    var all = DIMS.map(function (d, i) { return list.reduce(function (a, r) { return a + r.counts[i]; }, 0); });
    var mx = all.reduce(function (a, v) { return v > a ? v : a; }, 0);
    var topDim = mx > 0 ? { names: DIMS.filter(function (d, i) { return all[i] === mx; }), count: mx } : null;
    if (!ranks.length) return { best: null, worst: null, topDim: topDim };
    var first = ranks[0].rank, last = ranks[ranks.length - 1].rank;
    return { best: pick(first), worst: last !== first ? pick(last) : null, topDim: topDim };
  }

  function fileBase(year, period) {
    return '各門市面向分析_' + year + '_' + (period === 'Y' ? '全年' : '第' + String(period).slice(1) + '季');
  }

  var api = {
    DIMS: DIMS, normKey: normKey, keyLabel: keyLabel, rank: rank, summary: summary, maxRate: maxRate,
    formatPct: formatPct, formatAvg: formatAvg, fileBase: fileBase
  };
  if (isNode) module.exports = api;
  else root.StoreDimCore = api;
})(typeof window !== 'undefined' ? window : this);
