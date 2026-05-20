async function main() {
  const shared = await import('./shared.js');
  const heavy = await import('./heavy.js');
  console.log(shared.greet(), heavy.compute());
}
main();
