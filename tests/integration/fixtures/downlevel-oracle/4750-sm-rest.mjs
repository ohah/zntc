// 상태 기계(generator/async) 안 구조분해의 rest (#4750)
const log = [];
let n = 0;
const key = () => (n++, 'k');
function* g(src) {
  const { a, ...r1 } = src;
  yield 1;
  log.push(a, Object.keys(r1).join(''));
  const [x, ...r2] = [1, 2, 3];
  yield 2;
  log.push(x, r2.join(''));
  const [y, ...[z, w]] = [4, 5, 6];
  yield 3;
  log.push(y, z, w);
  const { [key()]: kv, ...r3 } = { k: 'K', m: 'M' };
  yield 4;
  log.push(kv, Object.keys(r3).join(''), n);
  try {
    yield 5;
    throw { e: 'E', f: 'F', g: 'G' };
  } catch ({ e, ...rest }) {
    yield 6;
    log.push(e, Object.keys(rest).join(''));
  }
  for (const { p, ...q } of [{ p: 1, s: 2, t: 3 }]) {
    yield 7;
    log.push(p, Object.keys(q).join(''));
  }
}
for (const _ of g({ a: 0, b: 1, c: 2 }));
(async () => {
  const { u, ...v } = await Promise.resolve({ u: 'U', w: 'W' });
  log.push(u, Object.keys(v).join(''));
  console.log(log.join());
})();
