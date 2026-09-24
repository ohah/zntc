const o = {};
const arr = [];
let a, b;
for (o.p of [1, 2]);
for (arr[0] of ['z']);
for ([a, b] of [[5, 6]]);
for ({ a } of [{ a: 7 }]);
console.log(o.p, arr[0], a, b);
