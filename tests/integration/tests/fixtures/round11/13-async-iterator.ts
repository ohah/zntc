async function* asyncRange(start: number, end: number) {
  for (let i = start; i <= end; i++) {
    await Promise.resolve();
    yield i;
  }
}
const collected: number[] = [];
for await (const n of asyncRange(1, 5)) collected.push(n);
console.log(collected);
