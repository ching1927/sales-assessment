/*
 * 各門市黃單排名的純函式（不連資料庫、不碰畫面）。資料來源是資料庫函式 checkup_yellow_ranking（supabase/yellow_ranking_schema.sql）。
 * 瀏覽器：window.StoreRankingCore；Node：module.exports。
 *
 * 用法：
 *   StoreRankingCore.PERIODS / SORTS                  期間（Q1~Q4、Y 全年）與排序方式（avg 平均每人、tot 黃單總張數）
 *   StoreRankingCore.periodRange(year, period)        { start:'YYYY-MM-DD', end:'YYYY-MM-DD' }（日曆季／全年，含頭尾）；不合法回 null
 *   StoreRankingCore.periodLabel(year, period)        '2026 年 第4季'／'2026 年 全年'
 *   StoreRankingCore.defaultPeriod(nowMs)             台北今天所在的 { year, period }（period 為 'Q1'~'Q4'）
 *   StoreRankingCore.yearOptions(nowMs)               年度下拉選項（新到舊；2026 起到今年）
 *   StoreRankingCore.rank(rows, sortKey, myStore)     整理資料庫回傳的列 -> 排名後的列
 *        每列 { store_code, store_name, tickets, headcount, avg(null＝人數為 0), rank(null＝沒有名次), mine, barPct }
 *        sortKey 'avg'（預設）：平均每人少的在前；人數為 0 的門市沒有平均、沒有名次，排最後
 *        sortKey 'tot'：黃單總張數少的在前
 *        名次：同值並列（1、2、2、4）；同名次的門市依門市固定順序排
 *   StoreRankingCore.summary(ranked, sortKey)         { best, worst, total }；best／worst 為 { names:[…], value:'0.29 張／人' } 或 null
 *   StoreRankingCore.formatAvg(row)                   平均每人（小數 2 位）；沒有人數回 '—'
 *   StoreRankingCore.fileBase(year, period)           下載檔名（不含副檔名）：門市黃單排名_2026_第4季
 */
(function (root) {
  var isNode = typeof module !== 'undefined' && module.exports;
  var CheckupCore = isNode ? require('./checkup-core.js') : root.CheckupCore;

  var PERIODS = ['Q1', 'Q2', 'Q3', 'Q4', 'Y'];
  var SORTS = ['avg', 'tot'];
  var FIRST_YEAR = 2026;           // 排名功能上線年度
  var TZ_MS = 8 * 3600000;         // 台北固定 UTC+8

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function num(n) { n = Number(n); return isFinite(n) ? n : 0; }

  // ---- 期間 ----
  var QEND = { 1: '03-31', 2: '06-30', 3: '09-30', 4: '12-31' };
  function periodRange(year, period) {
    var y = Math.floor(Number(year));
    if (!(y >= 2000 && y <= 2999)) return null;
    if (period === 'Y') return { start: y + '-01-01', end: y + '-12-31' };
    var m = /^Q([1-4])$/.exec(String(period));
    if (!m) return null;
    var q = Number(m[1]);
    return { start: y + '-' + pad((q - 1) * 3 + 1) + '-01', end: y + '-' + QEND[q] };
  }
  function periodLabel(year, period) {
    return year + ' 年 ' + (period === 'Y' ? '全年' : '第' + String(period).slice(1) + '季');
  }
  function defaultPeriod(nowMs) {
    var t = new Date((typeof nowMs === 'number' ? nowMs : Date.now()) + TZ_MS);
    return { year: t.getUTCFullYear(), period: 'Q' + (Math.floor(t.getUTCMonth() / 3) + 1) };
  }
  function yearOptions(nowMs) {
    var y = defaultPeriod(nowMs).year, out = [];
    for (var i = Math.max(y, FIRST_YEAR); i >= FIRST_YEAR; i--) out.push(i);
    return out;
  }

  // ---- 排名 ----
  function avgOf(r) { return r.headcount > 0 ? r.tickets / r.headcount : null; }
  function formatAvg(r) {
    var a = r && r.headcount > 0 ? r.tickets / r.headcount : null;
    return a == null ? '—' : a.toFixed(2);
  }
  // 兩列「平均每人」比大小：用交叉相乘，避免小數誤差造成該並列的沒並列
  function cmpAvg(a, b) { return a.tickets * b.headcount - b.tickets * a.headcount; }

  function rank(rows, sortKey, myStore) {
    var key = sortKey === 'tot' ? 'tot' : 'avg';
    var list = (rows || []).map(function (r) {
      var o = { store_code: r.store_code, store_name: r.store_name || r.store_code, tickets: num(r.tickets), headcount: num(r.headcount) };
      o.avg = avgOf(o);
      o.mine = !!myStore && r.store_code === myStore;
      return o;
    });
    list = CheckupCore.sortStores(list, 'store_code');   // 先照門市固定順序排，之後的穩定排序讓同名次維持這個順序
    function same(a, b) { return key === 'tot' ? a.tickets === b.tickets : cmpAvg(a, b) === 0; }
    function order(a, b) {
      if (key === 'tot') return a.tickets - b.tickets;
      if (a.avg == null || b.avg == null) return a.avg == null ? (b.avg == null ? 0 : 1) : -1;   // 沒有人數的排最後
      return cmpAvg(a, b);
    }
    // 穩定排序（Array.prototype.sort 在現行瀏覽器與 Node 都是穩定的；這裡仍以原位置補一個比較值，確保一致）
    list.forEach(function (r, i) { r._i = i; });
    list.sort(function (a, b) { return order(a, b) || a._i - b._i; });
    var prev = null;
    list.forEach(function (r, i) {
      delete r._i;
      if (key === 'avg' && r.avg == null) { r.rank = null; return; }
      if (!prev || !same(prev, r)) r.rank = i + 1; else r.rank = prev.rank;
      prev = r;
    });
    // 橫條：依排序方式的數值，最大值為 100%；有數值但很小也至少留 4% 讓人看得到
    var vals = list.map(function (r) { return key === 'tot' ? r.tickets : (r.avg == null ? null : r.avg); });
    var mx = vals.reduce(function (a, v) { return v != null && v > a ? v : a; }, 0);
    list.forEach(function (r, i) {
      r.barPct = vals[i] == null ? 0 : (mx > 0 ? Math.max(4, Math.round(vals[i] / mx * 1000) / 10) : 4);
    });
    return list;
  }

  // 摘要：黃單最少（第一名並列都列出）、黃單最多（最後名次並列都列出）、全公司黃單總張數
  function summary(ranked, sortKey) {
    var key = sortKey === 'tot' ? 'tot' : 'avg';
    var ranks = (ranked || []).filter(function (r) { return r.rank != null; });
    var total = (ranked || []).reduce(function (a, r) { return a + r.tickets; }, 0);
    function pick(rk) {
      var g = ranks.filter(function (r) { return r.rank === rk; });
      if (!g.length) return null;
      return { names: g.map(function (r) { return r.store_name; }), value: key === 'tot' ? g[0].tickets + ' 張' : '每人 ' + formatAvg(g[0]) + ' 張' };
    }
    if (!ranks.length) return { best: null, worst: null, total: total };
    var lastRank = ranks[ranks.length - 1].rank;
    return { best: pick(ranks[0].rank), worst: ranks.length > 1 && lastRank !== ranks[0].rank ? pick(lastRank) : null, total: total };
  }

  function fileBase(year, period) {
    return '門市黃單排名_' + year + '_' + (period === 'Y' ? '全年' : '第' + String(period).slice(1) + '季');
  }

  var api = {
    PERIODS: PERIODS, SORTS: SORTS, FIRST_YEAR: FIRST_YEAR,
    periodRange: periodRange, periodLabel: periodLabel, defaultPeriod: defaultPeriod, yearOptions: yearOptions,
    rank: rank, summary: summary, formatAvg: formatAvg, fileBase: fileBase
  };
  if (isNode) module.exports = api;
  else root.StoreRankingCore = api;
})(typeof window !== 'undefined' ? window : this);
