const out = [];
function* sg() {
  yield 'g1';
  yield 'g2';
}
for (const v of sg()) out.push(v);
for (const v of new Set(['s1'])) out.push(v);
for (const [k, x] of new Map([['k', 'v']])) out.push(k + x);
for (const c of 'ab') out.push(c);
for (const v of new Uint8Array([7])) out.push(v);
(function () {
  for (const a of arguments) out.push('a' + a);
})(1, 2);
console.log(out.join());
