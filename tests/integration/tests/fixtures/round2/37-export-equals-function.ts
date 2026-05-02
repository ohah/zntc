// TS-only: export = function (CJS interop)
function add(a: number, b: number): number {
  return a + b;
}
console.log(add(2, 3));
export = add;
