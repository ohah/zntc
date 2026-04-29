function* gen(): Generator<number> {
  yield 1; yield 2; yield 3; yield 4; yield 5;
}
const result = (gen() as any).filter((n: number) => n % 2 === 1).map((n: number) => n * 10).toArray();
console.log(result);
