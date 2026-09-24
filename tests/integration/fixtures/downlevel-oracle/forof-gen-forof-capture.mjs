const f = [];
function* g() {
  for (const x of [1, 2]) {
    yield x;
    f.push(() => x);
  }
}
for (const _ of g());
console.log(f.map((h) => h()).join());
