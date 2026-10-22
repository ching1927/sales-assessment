/* 雷達圖（蜘蛛網圖）：多個放射狀軸線顯示各面向得分率。
   Radar.svg(rows, label)：rows = [{name, pct(0~100 或 null＝無資料), weak(是否最弱)}]，回傳 SVG 字串。 */
var Radar = (function () {
  var W = 460, H = 380, CX = 230, CY = 190, R = 118, RINGS = [25, 50, 75, 100];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function fmt(x) { return String(Math.round(Number(x) * 10) / 10); }
  function pt(i, n, r) {
    var a = -Math.PI / 2 + (2 * Math.PI * i) / n;
    return [CX + r * Math.cos(a), CY + r * Math.sin(a), a];
  }
  function poly(points) { return points.map(function (p) { return p[0].toFixed(1) + ',' + p[1].toFixed(1); }).join(' '); }

  function svg(rows, label) {
    var n = rows.length, s = '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + esc(label) + '"><title>' + esc(label) + '</title>';
    if (n < 3) return s + '</svg>';
    // 同心環（25／50／75／100%）
    RINGS.forEach(function (g) {
      var ring = rows.map(function (_, i) { return pt(i, n, R * g / 100); });
      s += '<polygon points="' + poly(ring) + '" fill="' + (g === 100 ? 'var(--surface-solid, #fff)' : 'none') + '" stroke="var(--ink-line)" stroke-width="1"/>';
    });
    // 放射軸線
    rows.forEach(function (_, i) {
      var p = pt(i, n, R);
      s += '<line x1="' + CX + '" y1="' + CY + '" x2="' + p[0].toFixed(1) + '" y2="' + p[1].toFixed(1) + '" stroke="var(--ink-line)" stroke-width="1"/>';
    });
    // 環上刻度（沿正上方軸線）
    RINGS.forEach(function (g) {
      if (g === 100) return;
      s += '<text x="' + (CX + 4) + '" y="' + (CY - R * g / 100 + 11) + '" font-size="10" fill="var(--ink-3)">' + g + '</text>';
    });
    // 資料區塊（無資料的面向以 0 畫，標示「—」）
    var data = rows.map(function (r, i) { return pt(i, n, R * (r.pct === null ? 0 : Math.max(0, Math.min(100, r.pct))) / 100); });
    s += '<polygon points="' + poly(data) + '" fill="var(--accent-soft)" stroke="var(--accent)" stroke-width="2.5" stroke-linejoin="round"/>';
    rows.forEach(function (r, i) {
      if (r.pct === null) return;
      s += '<circle cx="' + data[i][0].toFixed(1) + '" cy="' + data[i][1].toFixed(1) + '" r="' + (r.weak ? 5.5 : 4) + '" fill="' + (r.weak ? 'var(--warning)' : 'var(--accent)') + '" stroke="var(--surface-solid, #fff)" stroke-width="2"/>';
    });
    // 軸名稱與數值
    rows.forEach(function (r, i) {
      var p = pt(i, n, R + 16), c = Math.cos(p[2]);
      var anchor = Math.abs(c) < 0.2 ? 'middle' : (c > 0 ? 'start' : 'end');
      var dy = Math.sin(p[2]) > 0.5 ? 12 : (Math.sin(p[2]) < -0.5 ? -4 : 4);
      s += '<text x="' + p[0].toFixed(1) + '" y="' + (p[1] + dy).toFixed(1) + '" text-anchor="' + anchor + '" font-size="13" font-weight="600" fill="' + (r.weak ? 'var(--warning)' : 'var(--ink)') + '">' + esc(r.name) + '</text>' +
        '<text x="' + p[0].toFixed(1) + '" y="' + (p[1] + dy + 15).toFixed(1) + '" text-anchor="' + anchor + '" font-size="13" font-weight="700" fill="' + (r.weak ? 'var(--warning)' : 'var(--accent-deep)') + '">' + (r.pct === null ? '—' : fmt(r.pct) + '%') + '</text>';
    });
    return s + '</svg>';
  }

  return { svg: svg };
})();
if (typeof module !== 'undefined') module.exports = Radar;
