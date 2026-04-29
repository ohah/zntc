const fns: (() => number)[] = [];
for (let i = 0; i < 3; i++) fns.push(() => i);
console.log(fns.map(f => f()).join(","));
const arr: (() => string)[] = [];
for (const k of ["a","b","c"]) arr.push(() => k);
console.log(arr.map(f => f()).join(","));
