const log = [];
(async () => {
  for await (const v of [1, Promise.resolve(2), 3]) log.push(v);
  console.log(log.join());
})();
