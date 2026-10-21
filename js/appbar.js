/* 導覽列頭像：取登入信箱第一個字母（信箱由各頁原本的程式寫入 #whoEmail） */
(function () {
  var email = document.getElementById('whoEmail');
  var av = document.getElementById('whoAvatar');
  if (!email || !av) return;
  function sync() { av.textContent = (email.textContent || '').trim().charAt(0).toUpperCase(); }
  sync();
  new MutationObserver(sync).observe(email, { childList: true, characterData: true, subtree: true });
})();
