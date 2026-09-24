const f = [];
for (const k in { a: 1, b: 2 }) {
  const v = k + '!';
  f.push(() => v);
}
console.log(f.map((g) => g()).join());
