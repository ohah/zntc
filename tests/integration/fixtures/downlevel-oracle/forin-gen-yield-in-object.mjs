function* gLong() {
  for (const kLong in yield 'first') yield kLong;
}
const it = gLong();
const out = [it.next().value];
let rLong = it.next({ m: 1, n: 2 });
while (!rLong.done) {
  out.push(rLong.value);
  rLong = it.next();
}
console.log(out.join());
