function* g() {
  for (const k in yield 'first') yield k;
}
const it = g();
const out = [it.next().value];
let r = it.next({ m: 1, n: 2 });
while (!r.done) {
  out.push(r.value);
  r = it.next();
}
console.log(out.join());
