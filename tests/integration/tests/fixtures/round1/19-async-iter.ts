async function run() {
  async function* gen() { yield 1; yield 2; yield 3; }
  let sum = 0;
  for await (const v of gen()) sum += v;
  return sum;
}
run().then(s => console.log(s));
