let a: number | null = null;
let b: number = 0;
let c: number | null = 5;
a ||= 10; b ||= 20; c ||= 30;
console.log(a, b, c);
let x = 0; x &&= 99; console.log(x);
let y = 1; y &&= 99; console.log(y);
let z: number | null = null; z ??= 7; console.log(z);
let w = 5; w ??= 99; console.log(w);
