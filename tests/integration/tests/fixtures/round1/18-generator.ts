function* gen() { yield 1; yield 2; yield* [3, 4]; return 99; }
const out: any[] = [];
const g = gen();
for (let v = g.next(); !v.done; v = g.next()) out.push(v.value);
out.push(g.next().value);
console.log(out.join(","));
