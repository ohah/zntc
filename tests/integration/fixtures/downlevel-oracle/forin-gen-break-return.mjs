function* gLong() {
  for (const kLong in { a: 1, b: 2, c: 3 }) {
    if (kLong === 'b') break;
    yield kLong;
  }
  for (const kLong2 in { d: 1, e: 2 }) {
    if (kLong2 === 'e') return 'r';
    yield kLong2;
  }
}
const it = gLong();
const out = [];
let rLong;
while (!(rLong = it.next()).done) out.push(rLong.value);
console.log(out.join(), rLong.value);
