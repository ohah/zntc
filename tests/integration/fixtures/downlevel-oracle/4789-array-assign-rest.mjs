// 배열 패턴 대입의 나머지 요소 — 멤버·중첩·구멍·객체 패턴·이터러블·for-of 헤더·식 값 (#4789)
const out = [];
let firstLong,
  restLong,
  objLong = {},
  deepLong,
  tailLong,
  lenLong;
[firstLong, ...objLong.items] = [1, 2, 3];
out.push(firstLong, objLong.items.join('/'));
[firstLong, ...[deepLong, ...tailLong]] = new Set([4, 5, 6, 7]);
out.push(firstLong, deepLong, tailLong.join('/'));
[, , ...restLong] = 'abcd';
out.push(restLong.join('/'));
[...{ length: lenLong }] = [9, 9, 9];
out.push(lenLong);
function* gen() {
  yield 'x';
  yield 'y';
  yield 'z';
}
[firstLong, ...restLong] = gen();
out.push(firstLong, restLong.join('/'));
for ([firstLong, ...restLong] of [[1, 2], [3]]) out.push(firstLong + ':' + restLong.length);
const res = ([firstLong, ...restLong] = [7, 8]);
out.push(Array.isArray(res) && res.length);
console.log(out.join(','));
