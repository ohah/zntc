const f = [];
for (var i = 0; i < 2; i++) {
  class C {
    m() {
      return i;
    }
  }
  const c = C;
  f.push(() => c === C);
}
console.log(f.map((g) => g()).join());
