(async () => {
  for await (var vLong of [1, 2, 3]);
  console.log(vLong);
})();
