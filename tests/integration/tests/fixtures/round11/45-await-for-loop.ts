async function* source() {
  yield 1; yield 2; yield 3;
}
async function main() {
  for await (const v of source()) {
    console.log("v=" + v);
  }
}
await main();
console.log("done");
