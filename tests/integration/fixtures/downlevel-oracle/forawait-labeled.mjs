const log = [];
(async () => {
  a: for await (const x of [1, 2, 3]) {
    for await (const y of [1, 2]) {
      if (y === 2) continue a;
      if (x === 3) break a;
      log.push(x + '' + y);
    }
  }
  console.log(log.join());
})();
