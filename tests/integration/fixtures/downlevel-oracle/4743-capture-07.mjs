const f = [];
for (var i = 0; i < 3; i++) {
  if (i === 1) continue;
  const v = i;
  f.push(() => v);
  if (i === 2) break;
}
console.log(f.map((g) => g()).join());
