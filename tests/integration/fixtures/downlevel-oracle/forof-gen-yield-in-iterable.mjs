function* g() {
  for (const v of yield 'first') yield v * 2;
}
const it = g();
const out = [it.next().value];
let r = it.next([3, 4]);
while (!r.done) {
  out.push(r.value);
  r = it.next();
}
console.log(out.join());
