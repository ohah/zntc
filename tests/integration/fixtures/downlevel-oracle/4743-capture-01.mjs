const f = [];
for (let i = 0; i < 2; i++) {
  const v = i * 10;
  f.push(() => v);
}
console.log(f.map((g) => g()).join());
