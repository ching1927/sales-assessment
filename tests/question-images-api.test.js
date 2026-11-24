/* 題組範例圖片（資料層＋純函式）測試：node tests/question-images-api.test.js
 * 用假的 supabase client 載入 js/question-images-core.js 與 js/questions-api.js（不連網、全是假資料）。
 * 重點：路徑格式、張數上限、副檔名與 mime 相符、失敗回滾（不留孤兒檔）、未啟用處理、刪除流程。 */
var assert = require('node:assert');
var fs = require('fs');
var path = require('path');
var vm = require('vm');

var passed = 0;
function eq(actual, expected, label) {
  actual = JSON.parse(JSON.stringify(actual === undefined ? null : actual)); expected = JSON.parse(JSON.stringify(expected));
  assert.deepStrictEqual(actual, expected, label + '：預期 ' + JSON.stringify(expected) + '，實際 ' + JSON.stringify(actual));
  passed++;
}
function ok(cond, label) { assert.ok(cond, label); passed++; }
function read(f) { return fs.readFileSync(path.join(__dirname, '..', 'js', f), 'utf8'); }

var PATH_RE = /^\d+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$/;

// opts：rpc(name,args)→結果；upload(path)→結果；remove(paths)→結果；from(table)→可 await 的結果
function makeEnv(opts) {
  opts = opts || {};
  var log = { rpcs: [], uploads: [], removes: [], tables: [], signed: [] };
  var sb = {
    from: function (t) {
      log.tables.push(t);
      var res = opts.from ? opts.from(t) : { data: [], error: null };
      var o = { select: function () { return o; }, eq: function () { return o; }, order: function () { return o; }, range: function () { return o; },
        then: function (a, b) { return Promise.resolve(res).then(a, b); } };
      return o;
    },
    rpc: function (name, args) { log.rpcs.push({ name: name, args: args }); return Promise.resolve(opts.rpc ? opts.rpc(name, args) : { data: null, error: null }); },
    storage: { from: function (bucket) {
      return {
        upload: function (p, blob, o) { log.uploads.push({ bucket: bucket, path: p, opts: o }); return Promise.resolve(opts.upload ? opts.upload(p) : { data: { path: p }, error: null }); },
        remove: function (paths) { log.removes.push({ bucket: bucket, paths: paths }); return Promise.resolve(opts.remove ? opts.remove(paths) : { data: paths.map(function (n) { return { name: n }; }), error: null }); },
        createSignedUrl: function (p) { log.signed.push({ bucket: bucket, path: p }); return Promise.resolve({ data: { signedUrl: 'https://x/' + p }, error: null }); }
      };
    } },
    auth: {}
  };
  var win = { APP_CONFIG: { SUPABASE_URL: 'http://localhost', SUPABASE_KEY: 'k' }, supabase: { createClient: function () { return sb; } } };
  var ctx = vm.createContext({ window: win, console: console, setTimeout: setTimeout, Promise: Promise, crypto: require('node:crypto').webcrypto });
  vm.runInContext(read('question-images-core.js'), ctx, { filename: 'question-images-core.js' });
  vm.runInContext(read('questions-api.js'), ctx, { filename: 'questions-api.js' });
  return { api: win.QuestionsApi, core: win.QuestionImagesCore, log: log };
}
async function fails(p) { try { await p; } catch (e) { return e; } return null; }

(async function () {
  var C = makeEnv().core;

  // ---- 純函式 ----
  eq(C.MAX_IMAGES, 8, '每題上限 8 張');
  eq(C.MAX_BYTES, 2097152, '每張上限 2MB');
  var u = C.newUuid();
  ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(u), 'uuid 為小寫 v4：' + u);
  eq(C.newUuid({ randomUUID: function () { return 'ABCDEF12-3456-4789-8ABC-DEF012345678'; } }), 'abcdef12-3456-4789-8abc-def012345678', '大寫 uuid 會轉小寫');
  eq(C.buildPath(12, 'abcdef12-3456-4789-8abc-def012345678', 'image/jpeg'), '12/abcdef12-3456-4789-8abc-def012345678.jpg', 'jpeg → .jpg');
  eq(C.buildPath(12, 'abcdef12-3456-4789-8abc-def012345678', 'image/png'), '12/abcdef12-3456-4789-8abc-def012345678.png', 'png → .png');
  eq(C.buildPath(12, 'ABCDEF12-3456-4789-8ABC-DEF012345678', 'image/webp'), '12/abcdef12-3456-4789-8abc-def012345678.webp', '大寫 uuid 路徑轉小寫');
  eq(C.buildPath(12, 'abcdef12-3456-4789-8abc-def012345678', 'image/gif'), null, 'gif 不收');
  eq(C.buildPath(0, 'abcdef12-3456-4789-8abc-def012345678', 'image/png'), null, '題組 id 不合法');
  eq(C.buildPath(12, 'not-a-uuid', 'image/png'), null, 'uuid 不合法');
  eq(C.slotsLeft(3), 5, '已有 3 張還能傳 5 張'); eq(C.slotsLeft(8), 0, '滿 8 張剩 0'); eq(C.slotsLeft(11), 0, '超過也不會負數');
  eq(C.moveIds(['a', 'b', 'c'], 1, -1), ['b', 'a', 'c'], '第 2 張前移'); eq(C.moveIds(['a', 'b', 'c'], 1, 1), ['a', 'c', 'b'], '第 2 張後移');
  eq(C.moveIds(['a', 'b'], 0, -1), null, '第一張不能前移'); eq(C.moveIds(['a', 'b'], 1, 1), null, '最後一張不能後移');
  ok(C.isUnavailable({ code: 'PGRST202', message: 'x' }), 'PGRST202 視為未啟用');
  ok(C.isUnavailable({ code: 'PGRST205', message: 'x' }), 'PGRST205 視為未啟用');
  ok(C.isUnavailable({ message: 'Could not find the function public.bank_add_question_image' }), '找不到函式視為未啟用');
  ok(!C.isUnavailable({ code: 'P0001', message: '每個題組最多 8 張範例圖片' }), '一般業務錯誤不是未啟用');
  ok(!C.isUnavailable(null), 'null 不是未啟用');

  // ---- 上傳：先 Storage、再 RPC；路徑格式、bucket、參數名稱 ----
  var e = makeEnv({ rpc: function () { return { data: 'img-uuid-1', error: null }; } });
  var r = await e.api.addImage(42, 'BLOB', 'image/jpeg', 12345);
  eq(e.log.uploads.length, 1, '傳了一次 Storage'); eq(e.log.uploads[0].bucket, 'question-samples', 'bucket 是 question-samples');
  ok(PATH_RE.test(e.log.uploads[0].path) && e.log.uploads[0].path.indexOf('42/') === 0 && /\.jpg$/.test(e.log.uploads[0].path), '路徑格式 42/小寫uuid.jpg：' + e.log.uploads[0].path);
  eq(e.log.uploads[0].opts, { contentType: 'image/jpeg', upsert: false }, '不覆蓋、帶 contentType');
  eq(e.log.rpcs, [{ name: 'bank_add_question_image', args: { p_question_id: 42, p_path: e.log.uploads[0].path, p_mime: 'image/jpeg', p_size: 12345 } }], '登記參數名稱與路徑一致');
  eq(r, { id: 'img-uuid-1', path: e.log.uploads[0].path, mime: 'image/jpeg', size: 12345 }, '回傳新圖資料');
  eq(e.log.removes, [], '成功時不刪檔');

  // 格式不合、超過 2MB：不碰網路
  e = makeEnv();
  var err = await fails(e.api.addImage(42, 'B', 'image/gif', 100));
  ok(err && /只收 jpg、png、webp/.test(err.message), 'gif 被擋：' + (err && err.message));
  err = await fails(e.api.addImage(42, 'B', 'image/png', 2097153));
  ok(err && /2MB/.test(err.message), '超過 2MB 被擋');
  eq(e.log.uploads.length + e.log.rpcs.length, 0, '被擋時沒上傳也沒登記');

  // ---- 失敗回滾 ----
  // 張數已滿（資料庫丟 P0001）→ 白話訊息往外丟，剛傳的檔被刪掉
  e = makeEnv({ rpc: function () { return { data: null, error: { code: 'P0001', message: '每個題組最多 8 張範例圖片' } }; } });
  err = await fails(e.api.addImage(42, 'B', 'image/jpeg', 100));
  ok(err && err.message === '每個題組最多 8 張範例圖片', '第 9 張：顯示資料庫的中文訊息');
  eq(e.log.removes.length, 1, 'RPC 失敗有刪檔'); eq(e.log.removes[0].bucket, 'question-samples', '刪的是 question-samples');
  eq(e.log.removes[0].paths, [e.log.uploads[0].path], '刪的正是剛傳的那個檔（不留孤兒檔）');
  // RPC 失敗且刪檔也丟例外 → 仍丟原本的 RPC 錯誤，不吞掉
  e = makeEnv({ rpc: function () { return { data: null, error: { code: 'P0001', message: '圖片路徑不正確' } }; }, remove: function () { throw new Error('boom'); } });
  err = await fails(e.api.addImage(42, 'B', 'image/jpeg', 100));
  ok(err && err.message === '圖片路徑不正確', '刪檔也失敗時，仍回報 RPC 的錯誤');
  // Storage 上傳失敗 → 不呼叫 RPC
  e = makeEnv({ upload: function () { return { data: null, error: { message: 'Failed to fetch' } }; } });
  err = await fails(e.api.addImage(42, 'B', 'image/jpeg', 100));
  ok(err && /網路連線失敗/.test(err.message), '上傳失敗給網路白話訊息'); eq(e.log.rpcs.length, 0, '上傳失敗不登記');

  // ---- 未啟用 ----
  e = makeEnv({ from: function () { return { data: null, error: { code: 'PGRST205', message: "Could not find the table 'public.question_images' in the schema cache" } }; } });
  err = await fails(e.api.listImages(42));
  ok(err && err.unavailable === true && err.message === '範例圖片功能尚未啟用', '讀圖：資料表不存在 → unavailable');
  err = await fails(e.api.loadImageCounts());
  ok(err && err.unavailable === true, '讀張數：未啟用丟 unavailable，由呼叫端忽略');
  e = makeEnv({ upload: function () { return { data: null, error: { message: 'Bucket not found', statusCode: '404' } }; } });
  err = await fails(e.api.addImage(42, 'B', 'image/jpeg', 100));
  ok(err && err.unavailable === true, '上傳：bucket 不存在 → unavailable');
  e = makeEnv({ rpc: function () { return { data: null, error: { code: 'PGRST202', message: 'Could not find the function public.bank_reorder_question_images' } }; } });
  err = await fails(e.api.reorderImages(42, ['a']));
  ok(err && err.unavailable === true && !/bank_reorder/.test(err.message), '排序：函式不存在 → unavailable，不洩漏函式名稱');

  // ---- 讀取 ----
  e = makeEnv({ from: function () { return { data: [
    { id: 'b', question_id: 42, storage_path: '42/b.jpg', mime: 'image/jpeg', size_bytes: '200', sort_order: 2 },
    { id: 'a', question_id: 42, storage_path: '42/a.png', mime: 'image/png', size_bytes: 100, sort_order: 1 }], error: null }; } });
  eq(await e.api.listImages(42), [{ id: 'a', path: '42/a.png', mime: 'image/png', size: 100, sort: 1 }, { id: 'b', path: '42/b.jpg', mime: 'image/jpeg', size: 200, sort: 2 }], '依 sort_order 排序、欄位轉換');
  eq(e.log.tables, ['question_images'], '讀的是 question_images');
  e = makeEnv({ from: function () { return { data: [{ question_id: 5 }, { question_id: 5 }, { question_id: '7' }], error: null }; } });
  eq(await e.api.loadImageCounts(), { 5: 2, 7: 1 }, '各題組張數');

  // ---- 排序 ----
  e = makeEnv();
  await e.api.reorderImages(42, ['b', 'a']);
  eq(e.log.rpcs, [{ name: 'bank_reorder_question_images', args: { p_question_id: 42, p_image_ids: ['b', 'a'] } }], '排序參數名稱');

  // ---- 刪除一張：先資料列、再 Storage 檔 ----
  e = makeEnv({ rpc: function () { return { data: '42/a.jpg', error: null }; } });
  eq(await e.api.removeImage('img-1'), { fileRemoved: true, path: '42/a.jpg' }, '刪除成功');
  eq(e.log.rpcs, [{ name: 'bank_remove_question_image', args: { p_image_id: 'img-1' } }], '刪除參數 p_image_id');
  eq(e.log.removes, [{ bucket: 'question-samples', paths: ['42/a.jpg'] }], '用取回的 path 刪 Storage 檔');
  // 檔案刪除失敗 → fileRemoved=false（不報假成功）；資料列已刪不丟錯
  e = makeEnv({ rpc: function () { return { data: '42/a.jpg', error: null }; }, remove: function () { return { data: null, error: { message: 'denied' } }; } });
  eq(await e.api.removeImage('img-1'), { fileRemoved: false, path: '42/a.jpg' }, 'Storage 刪檔失敗回 fileRemoved=false');
  e = makeEnv({ rpc: function () { return { data: '42/a.jpg', error: null }; }, remove: function () { return { data: [], error: null }; } });
  eq((await e.api.removeImage('img-1')).fileRemoved, false, 'Storage 沒回報刪掉任何檔（被擋）也算失敗');
  e = makeEnv({ rpc: function () { return { data: null, error: { code: 'P0001', message: '找不到這張圖片' } }; } });
  err = await fails(e.api.removeImage('img-1'));
  ok(err && err.message === '找不到這張圖片', '資料列刪除失敗會丟錯'); eq(e.log.removes.length, 0, '資料列沒刪成功就不碰 Storage');

  // ---- 刪題組後清檔 ----
  e = makeEnv();
  eq(await e.api.removeImageFiles(['1/a.jpg', '1/b.png']), { ok: true }, '清檔成功'); eq(e.log.removes[0].paths, ['1/a.jpg', '1/b.png'], '清兩個檔');
  eq(await e.api.removeImageFiles([]), { ok: true }, '沒檔案不呼叫 Storage'); eq(e.log.removes.length, 1, '空清單不呼叫 remove');
  e = makeEnv({ remove: function () { throw new Error('x'); } });
  eq(await e.api.removeImageFiles(['1/a.jpg']), { ok: false }, '清檔丟例外 → ok=false，不往外丟');

  // ---- 簽名網址（快取） ----
  e = makeEnv();
  eq(await e.api.imageUrl('1/a.jpg'), 'https://x/1/a.jpg', '簽名網址'); await e.api.imageUrl('1/a.jpg');
  eq(e.log.signed.length, 1, '第二次用快取'); eq(e.log.signed[0].bucket, 'question-samples', '用 question-samples bucket');
  e.api.forgetImageUrl('1/a.jpg'); await e.api.imageUrl('1/a.jpg'); eq(e.log.signed.length, 2, 'forget 後重取');

  console.log('question-images-api：' + passed + ' 項通過');
})().catch(function (x) { console.error('失敗：' + (x && x.stack || x)); process.exit(1); });
