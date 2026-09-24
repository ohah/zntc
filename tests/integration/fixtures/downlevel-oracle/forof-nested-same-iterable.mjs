const s = new Set([1, 2]);
const out = [];
for (const a of s) for (const b of s) out.push(a + '' + b);
console.log(out.join());
