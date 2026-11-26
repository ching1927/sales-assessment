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
 *   StoreDimCore.fileBase(year, period)       下載檔名（不含副檔名）：各門市面向分析_2026_第4季（舊版，年度／期間用）
 *
 * 月份期間與星狀圖（老闆 2026-11-26 改版）：
 *   StoreDimCore.SHORT                        七面向簡稱（星狀圖軸標籤）
 *   StoreDimCore.monthRange(from, to)         'YYYY-MM' 起訖 -> { from:'YYYY-MM-01', to:'YYYY-MM-最後一天', label }；空值、格式錯、迄早於起回 null
 *   StoreDimCore.monthLabel(from, to)         '2026年11月'（同月）或 '2026年10月～2026年12月'
 *   StoreDimCore.monthFileBase(from, to)      各門市面向分析_2026-11（同月）或 各門市面向分析_2026-10_2026-12
 *   StoreDimCore.taipeiToday(nowMs)           台北今天 'YYYY-MM-DD'
 *   StoreDimCore.presetRange(kind, today)     快速鈕 'cur'本月／'prev'上月／'q'本季／'y'今年 -> { from, to }（'YYYY-MM'）；today 為台北今天
 *   StoreDimCore.companyTotal(ranked)         全公司彙總列（各門市 weak 與 counts 加總），格式同 rank 的列，store_name＝'全公司'
 *   StoreDimCore.pickItem(ranked, code)       code 為空或找不到＝全公司彙總，否則該門市那一列
 *   StoreDimCore.radii(item)                  星狀圖七軸半徑＝1 − 被勾比例（0~1）；weak 為 0（沒資料）回 null
 *   StoreDimCore.weakest(item)                { idx:[…], names:[…], rate }：比例最高的面向（並列全列）；沒資料或最高比例為 0 時 idx 為 []
 *   StoreDimCore.storeOptions(rows)           門市下拉選項 [{code,name}]，依門市固定順序
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

  // ===== 月份期間 =====
  var SHORT = ['資訊正確', '預設訊息', '問題掌握', '主動引導', '風險意識', '語氣禮貌', '文字品質'];
  function p2(n) { return (n < 10 ? '0' : '') + n; }
  function parseMonth(s) {
    var m = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(String(s == null ? '' : s));
    return m ? { y: Number(m[1]), m: Number(m[2]) } : null;
  }
  function ym(y, m) { return y + '-' + p2(m); }
  function monthLabel(from, to) {
    var a = parseMonth(from), b = parseMonth(to);
    if (!a || !b) return '';
    var x = a.y + '年' + a.m + '月', y = b.y + '年' + b.m + '月';
    return x === y ? x : x + '～' + y;
  }
  function monthRange(from, to) {
    var a = parseMonth(from), b = parseMonth(to);
    if (!a || !b || a.y * 12 + a.m > b.y * 12 + b.m) return null;
    var last = new Date(Date.UTC(b.y, b.m, 0)).getUTCDate();   // 迄月最後一天（閏年自動處理）
    return { from: ym(a.y, a.m) + '-01', to: ym(b.y, b.m) + '-' + p2(last), label: monthLabel(from, to) };
  }
  function monthFileBase(from, to) {
    return '各門市面向分析_' + from + (from === to ? '' : '_' + to);
  }
  function taipeiToday(nowMs) {
    return new Date((typeof nowMs === 'number' ? nowMs : Date.now()) + 8 * 3600000).toISOString().slice(0, 10);
  }
  function presetRange(kind, today) {
    var t = parseMonth(String(today || '').slice(0, 7)) || parseMonth(taipeiToday().slice(0, 7));
    var cur = ym(t.y, t.m);
    if (kind === 'prev') { var py = t.m === 1 ? t.y - 1 : t.y, pm = t.m === 1 ? 12 : t.m - 1; return { from: ym(py, pm), to: ym(py, pm) }; }
    if (kind === 'y') return { from: ym(t.y, 1), to: cur };
    if (kind === 'q') return { from: ym(t.y, Math.floor((t.m - 1) / 3) * 3 + 1), to: cur };
    return { from: cur, to: cur };
  }

  // ===== 星狀圖 =====
  function companyTotal(ranked) {
    var counts = DIMS.map(function () { return 0; }), weak = 0;
    (ranked || []).forEach(function (r) {
      weak += r.weak;
      r.counts.forEach(function (c, i) { counts[i] += c; });
    });
    var o = { store_code: '', store_name: '全公司', weak: weak, counts: counts, mine: false, rank: null };
    o.total = counts.reduce(function (a, v) { return a + v; }, 0);
    o.rates = counts.map(function (c) { return weak > 0 ? c / weak : null; });
    o.avg = weak > 0 ? o.total / weak : null;
    o.tops = topsOf(counts);
    return o;
  }
  function pickItem(ranked, code) {
    if (code) {
      var hit = (ranked || []).filter(function (r) { return r.store_code === code; })[0];
      if (hit) return hit;
    }
    return companyTotal(ranked);
  }
  function radii(item) {
    if (!item || !(item.weak > 0)) return null;
    return item.rates.map(function (r) { return Math.max(0, Math.min(1, 1 - r)); });
  }
  function weakest(item) {
    if (!item || !(item.weak > 0)) return { idx: [], names: [], rate: 0 };
    var mx = item.rates.reduce(function (a, v) { return v > a ? v : a; }, 0);
    if (!(mx > 0)) return { idx: [], names: [], rate: 0 };
    var idx = [];
    item.rates.forEach(function (v, i) { if (v === mx) idx.push(i); });
    return { idx: idx, names: idx.map(function (i) { return DIMS[i]; }), rate: mx };
  }
  function storeOptions(rows) {
    var list = (rows || []).map(function (r) { return { store_code: r.store_code, store_name: r.store_name || r.store_code }; });
    return CheckupCore.sortStores(list, 'store_code').map(function (r) { return { code: r.store_code, name: r.store_name }; });
  }

  var api = {
    SHORT: SHORT, monthRange: monthRange, monthLabel: monthLabel, monthFileBase: monthFileBase, taipeiToday: taipeiToday,
    presetRange: presetRange, companyTotal: companyTotal, pickItem: pickItem, radii: radii, weakest: weakest, storeOptions: storeOptions,
    DIMS: DIMS, normKey: normKey, keyLabel: keyLabel, rank: rank, summary: summary, maxRate: maxRate,
    formatPct: formatPct, formatAvg: formatAvg, fileBase: fileBase
  };
  if (isNode) module.exports = api;
  else root.StoreDimCore = api;
})(typeof window !== 'undefined' ? window : this);
