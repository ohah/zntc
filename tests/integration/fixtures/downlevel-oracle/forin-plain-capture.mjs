const fns = [];
for (const k in { a: 1, b: 2 }) fns.push(() => k);
for (var v in { c: 1 });
console.log(fns.map((f) => f()).join(), v);
