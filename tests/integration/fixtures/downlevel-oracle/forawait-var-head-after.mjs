(async () => {
  for await (var v of [1, 2, 3]);
  console.log(v);
})();
