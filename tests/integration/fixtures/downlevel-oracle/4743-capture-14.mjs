const f = [];
function* g() {
  for (let i = 0; i < 2; i++) {
    try {
      throw i;
    } catch (e) {
      yield 0;
      f.push(() => e);
    }
  }
}
for (const _ of g());
console.log(f.map((h) => h()).join());
