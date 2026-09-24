const f = [];
for (const x of [1, 2]) {
  const v = x * 2;
  f.push(() => v);
}
console.log(f.map((g) => g()).join());
