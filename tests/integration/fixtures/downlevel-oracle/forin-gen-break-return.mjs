function* g() {
  for (const k in { a: 1, b: 2, c: 3 }) {
    if (k === 'b') break;
    yield k;
  }
  for (const k in { d: 1, e: 2 }) {
    if (k === 'e') return 'r';
    yield k;
  }
}
const it = g();
const out = [];
let r;
while (!(r = it.next()).done) out.push(r.value);
console.log(out.join(), r.value);
