async function* take(n: number) {
  let i = 0;
  while (i < n) {
    yield i++;
    await Promise.resolve();
  }
}
const out: number[] = [];
for await (const v of take(4)) out.push(v);
console.log(out);
