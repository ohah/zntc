namespace A { export namespace B { export const v = 5; export function nest() { return v * 2; } } export const top = B.v + 100; }
console.log(A.B.v, A.B.nest(), A.top);
