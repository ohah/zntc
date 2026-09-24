const f = [];
let i = 0;
do {
  const v = i++;
  f.push(() => v);
} while (i < 2);
console.log(f.map((g) => g()).join());
