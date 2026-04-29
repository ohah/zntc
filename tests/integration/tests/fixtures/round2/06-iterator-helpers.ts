// ES2025 Iterator helpers
function* gen() { yield 1; yield 2; yield 3; yield 4; yield 5; }
const r = (gen() as any).filter((x: number) => x % 2).map((x: number) => x * 10).toArray();
console.log(r);
