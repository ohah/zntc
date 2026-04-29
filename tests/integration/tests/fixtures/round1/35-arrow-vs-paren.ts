const f = (x: number, y: number = 5) => x + y;
const g: (n: number) => number = (n) => n * 2;
const h = <T,>(x: T): T => x;
console.log(f(1), f(1, 2), g(3), h("z"));
