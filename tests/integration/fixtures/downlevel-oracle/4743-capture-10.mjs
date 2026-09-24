const f = [];
for (var i = 0; i < 2; i++) {
  {
    const v = i;
    f.push(() => v);
  }
}
console.log(f.map((g) => g()).join());
