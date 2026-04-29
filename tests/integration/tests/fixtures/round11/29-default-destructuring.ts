const { a = 10, b = 20 } = { a: 1 } as { a?: number; b?: number };
const [x = 100, y = 200] = [1] as [number?, number?];
function fn({ x = 1, y = 2 }: { x?: number; y?: number } = {}) {
  return x + y;
}
console.log(a, b, x, y, fn(), fn({ x: 9 }), fn({ y: 99 }));
