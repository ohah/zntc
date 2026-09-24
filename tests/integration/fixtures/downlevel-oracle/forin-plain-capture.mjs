const fns = [];
for (const kLong in { a: 1, b: 2 }) fns.push(() => kLong);
for (var vLong in { c: 1 });
console.log(fns.map((fLong) => fLong()).join(), vLong);
