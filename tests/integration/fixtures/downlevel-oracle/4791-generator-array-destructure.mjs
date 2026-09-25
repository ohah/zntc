// 상태 기계 안 배열 구조 분해 — 구멍·기본값·중첩·rest·이터러블
const out = [];
function* gen() {
  yield 'p';
  yield 'q';
  yield 'r';
}
function* g() {
  const [firstLong, , thirdLong = 9, ...tailLong] = yield 0;
  out.push(firstLong, thirdLong, tailLong.join('/'));
  const [headLong, ...[midLong, lastLong]] = yield 1;
  out.push(headLong, midLong, lastLong);
  const [[innerLong, ...innerRestLong], { keyLong }] = yield 2;
  out.push(innerLong, innerRestLong.join('/'), keyLong);
  const {
    listLong: [aLong, ...bLong],
  } = yield 3;
  out.push(aLong, bLong.join('/'));
  const [, , ...onlyRestLong] = yield 4;
  out.push(onlyRestLong.join('/'));
  let [xLong, yLong] = gen();
  out.push(xLong, yLong);
}
const it = g();
it.next();
it.next([1, 2, undefined, 4, 5]);
it.next(new Set([6, 7, 8]));
it.next([new Set([9, 10, 11]), { keyLong: 'k' }]);
it.next({ listLong: new Set(['s', 't', 'u']) });
it.next(gen());
console.log(out.join(','));
