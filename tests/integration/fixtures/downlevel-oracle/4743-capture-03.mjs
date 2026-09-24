const f = [];
let i = 0;
while (i < 2) {
  const v = i++;
  f.push(() => v);
}
console.log(f.map((g) => g()).join());
