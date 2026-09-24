const f = [];
for (var i = 0; i < 2; i++) {
  let v = i;
  f.push(() => v);
  v += 100;
}
console.log(f.map((g) => g()).join());
