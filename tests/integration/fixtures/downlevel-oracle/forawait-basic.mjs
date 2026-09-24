const log = [];
(async () => {
  for await (const vLong of [1, Promise.resolve(2), 3]) log.push(vLong);
  console.log(log.join());
})();
