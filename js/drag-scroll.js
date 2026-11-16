/* 表格拖曳捲動：在帶有 class="scroll" 的區塊內，用滑鼠按住空白處往左／右拉就能橫向捲動（觸控裝置本來就能滑，這裡只處理滑鼠）。
 * 按在按鈕、連結、輸入框、下拉選單上不會觸發拖曳；拖動超過 5px 才算拖曳，放開時會擋掉那一下點擊，避免誤點連結。 */
(function () {
  var box = document.querySelectorAll('.scroll');
  var SKIP = 'a,button,input,select,textarea,label,summary';
  Array.prototype.forEach.call(box, function (el) {
    var down = false, moved = false, startX = 0, startLeft = 0, pid = null;
    el.style.cursor = 'grab';
    el.addEventListener('pointerdown', function (e) {
      if (e.pointerType !== 'mouse' || e.button !== 0) return;
      if (e.target.closest(SKIP)) return;
      if (el.scrollWidth <= el.clientWidth) return;
      down = true; moved = false; startX = e.clientX; startLeft = el.scrollLeft; pid = e.pointerId;
    });
    el.addEventListener('pointermove', function (e) {
      if (!down || e.pointerId !== pid) return;
      var dx = e.clientX - startX;
      if (!moved && Math.abs(dx) < 5) return;
      if (!moved) {
        moved = true;
        try { el.setPointerCapture(pid); } catch (x) {}
        el.style.cursor = 'grabbing';
        el.style.userSelect = 'none';
      }
      el.scrollLeft = startLeft - dx;
    });
    function end(e) {
      if (!down || (e && e.pointerId !== pid)) return;
      down = false;
      el.style.cursor = 'grab';
      el.style.userSelect = '';
      try { el.releasePointerCapture(pid); } catch (x) {}
      if (moved) {
        // 剛拖完，吃掉緊接著的那一下 click
        var stop = function (ev) { ev.stopPropagation(); ev.preventDefault(); };
        el.addEventListener('click', stop, { capture: true, once: true });
        setTimeout(function () { el.removeEventListener('click', stop, true); }, 0);
      }
    }
    el.addEventListener('pointerup', end);
    el.addEventListener('pointercancel', end);
  });
})();
