// es5 minify 에서 async generator 기본값 매개변수가 바깥 래퍼·안쪽 함수에 같은 노드로 들어가 이름이 어긋난다 (#4756).
async function* src(nLong, opts = {}) {
  yield nLong + (opts.k || 0);
}
(async () => {
  const it = src(1, { k: 2 });
  console.log((await it.next()).value, (await src(5).next()).value);
})();
