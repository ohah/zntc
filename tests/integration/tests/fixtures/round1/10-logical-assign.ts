let a: any = null;
let b: any = 0;
let c: any = undefined;
a ??= 1; b ||= 2; c &&= 3;
console.log(a, b, c);
let o: any = {};
o.x ??= 10;
o.x ??= 99;
console.log(o.x);
