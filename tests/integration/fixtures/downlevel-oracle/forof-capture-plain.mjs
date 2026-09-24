const f = [];
for (const x of [1, 2]) f.push(() => x);
for (let [a, b] of [[3, 4]]) f.push(() => a + b);
console.log(f.map((h) => h()).join());
