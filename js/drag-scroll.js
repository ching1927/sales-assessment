/* 表格拖曳捲動：在帶有 class="scroll" 的區塊內，用滑鼠按住空白處往左／右拉就能橫向捲動（觸控裝置本來就能滑，這裡只處理滑鼠）。
 * 用事件委派掛在整頁上，所以頁面之後才產生的表格也有效。
 * 按在按鈕、連結、輸入框、下拉選單上不會觸發拖曳；拖動超過 5px 才算拖曳，放開時會擋掉那一下點擊，避免誤點連結。 */
(function () {
  var SKIP = 'a,button,input,select,textarea,label,summary';
  var st = null;   // 目前進行中的拖曳 { el, startX, startLeft, pid, moved }

  function target(e) {
    var t = e.target;
    if (!t || !t.closest) return null;
    var el = t.closest('.scroll');
    if (!el || t.closest(SKIP) || el.scrollWidth <= el.clientWidth) return null;
    // 按在原生捲軸上（區塊底部那條）不處理，讓瀏覽器自己拉
    if (e.clientY > el.getBoundingClientRect().top + el.clientHeight) return null;
    return el;
  }

  document.addEventListener('pointerover', function (e) {
    if (e.pointerType !== 'mouse' || st) return;
    var el = target(e);
    if (el) el.style.cursor = 'grab';
  });

  document.addEventListener('pointerdown', function (e) {
    if (e.pointerType !== 'mouse' || e.button !== 0) return;
    var el = target(e);
    if (!el) return;
    st = { el: el, startX: e.clientX, startLeft: el.scrollLeft, pid: e.pointerId, moved: false };
  });

  document.addEventListener('pointermove', function (e) {
    if (!st || e.pointerId !== st.pid) return;
    var dx = e.clientX - st.startX;
    if (!st.moved && Math.abs(dx) < 5) return;
    if (!st.moved) {
      st.moved = true;
      try { st.el.setPointerCapture(st.pid); } catch (x) {}
      st.el.style.cursor = 'grabbing';
      st.el.style.userSelect = 'none';
    }
    st.el.scrollLeft = st.startLeft - dx;
  });

  function end(e) {
    if (!st || e.pointerId !== st.pid) return;
    var s = st; st = null;
    s.el.style.cursor = 'grab';
    s.el.style.userSelect = '';
    try { s.el.releasePointerCapture(s.pid); } catch (x) {}
    if (s.moved) {
      // 剛拖完，吃掉緊接著的那一下 click
      var stop = function (ev) { ev.stopPropagation(); ev.preventDefault(); };
      s.el.addEventListener('click', stop, { capture: true, once: true });
      setTimeout(function () { s.el.removeEventListener('click', stop, true); }, 0);
    }
  }
  document.addEventListener('pointerup', end);
  document.addEventListener('pointercancel', end);
})();
