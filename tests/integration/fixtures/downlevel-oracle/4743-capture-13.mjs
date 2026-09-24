const f = [];
function* g() {
  for (var i = 0; i < 2; i++) {
    const v = i;
    yield 0;
    f.push(() => v);
  }
}
for (const _ of g());
console.log(f.map((h) => h()).join());
