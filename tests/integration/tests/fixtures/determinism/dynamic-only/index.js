async function main() {
  const [a, b, c, d, e] = await Promise.all([
    import('./lazyA.js'),
    import('./lazyB.js'),
    import('./lazyC.js'),
    import('./lazyD.js'),
    import('./lazyE.js'),
  ]);
  console.log(a.value, b.value, c.value, d.value, e.value);
}
main();
