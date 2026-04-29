async function run() {
  const obj = { async *[Symbol.asyncIterator]() { yield 1; yield 2; yield 3; } };
  let sum = 0;
  for await (const v of obj) sum += v;
  return sum;
}
run().then(n => console.log(n));
