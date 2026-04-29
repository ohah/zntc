async function main() {
  const { promise, resolve } = Promise.withResolvers<string>();
  setTimeout(() => resolve("done"), 10);
  console.log(await promise);
}
await main();
