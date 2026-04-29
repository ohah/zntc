const result = await (async () => {
  const a = await Promise.resolve(1);
  const b = await Promise.resolve(2);
  return a + b;
})();
console.log(result);
