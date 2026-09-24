function* gLong() {
  for (const vLong of yield 'first') yield vLong * 2;
}
const it = gLong();
const out = [it.next().value];
let rLong = it.next([3, 4]);
while (!rLong.done) {
  out.push(rLong.value);
  rLong = it.next();
}
console.log(out.join());
