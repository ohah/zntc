const out = [];
function* sg() {
  yield 'g1';
  yield 'g2';
}
for (const vLong of sg()) out.push(vLong);
for (const vLong2 of new Set(['s1'])) out.push(vLong2);
for (const [kLong, xLong] of new Map([['k', 'v']])) out.push(kLong + xLong);
for (const cLong of 'ab') out.push(cLong);
for (const vLong3 of new Uint8Array([7])) out.push(vLong3);
(function () {
  for (const aLong of arguments) out.push('a' + aLong);
})(1, 2);
console.log(out.join());
