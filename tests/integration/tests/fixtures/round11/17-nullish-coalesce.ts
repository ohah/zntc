const a: number | null = null;
const b: number | undefined = undefined;
const c = 0;
const d = "";
console.log(a ?? "A", b ?? "B", c ?? "C", d ?? "D");
console.log(a || "A", b || "B", c || "C", d || "D");
let x = a; x ??= 99; console.log(x);
let y = c; y ??= 99; console.log(y);
