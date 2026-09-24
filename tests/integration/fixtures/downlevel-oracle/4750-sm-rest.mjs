// 상태 기계(generator/async) 안 구조분해의 rest (#4750)
const log = [];
let nLong = 0;
const key = () => (nLong++, 'k');
function* gLong(src) {
  const { a: aLong, ...r1 } = src;
  yield 1;
  log.push(aLong, Object.keys(r1).join(''));
  const [xLong, ...r2] = [1, 2, 3];
  yield 2;
  log.push(xLong, r2.join(''));
  const [yLong, ...[zLong, wLong]] = [4, 5, 6];
  yield 3;
  log.push(yLong, zLong, wLong);
  const { [key()]: kv, ...r3 } = { k: 'K', m: 'M' };
  yield 4;
  log.push(kv, Object.keys(r3).join(''), nLong);
  try {
    yield 5;
    throw { e: 'E', f: 'F', g: 'G' };
  } catch ({ e: eLong, ...rest }) {
    yield 6;
    log.push(eLong, Object.keys(rest).join(''));
  }
  for (const { p: pLong, ...qLong } of [{ p: 1, s: 2, t: 3 }]) {
    yield 7;
    log.push(pLong, Object.keys(qLong).join(''));
  }
}
for (const _Long of gLong({ a: 0, b: 1, c: 2 }));
(async () => {
  const { u: uLong, ...vLong } = await Promise.resolve({ u: 'U', w: 'W' });
  log.push(uLong, Object.keys(vLong).join(''));
  console.log(log.join());
})();
