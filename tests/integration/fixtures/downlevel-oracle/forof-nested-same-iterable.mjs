const sLong = new Set([1, 2]);
const out = [];
for (const aLong of sLong) for (const bLong of sLong) out.push(aLong + '' + bLong);
console.log(out.join());
