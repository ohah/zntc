const log = [];
(async () => {
  a: for await (const xLong of [1, 2, 3]) {
    for await (const yLong of [1, 2]) {
      if (yLong === 2) continue a;
      if (xLong === 3) break a;
      log.push(xLong + '' + yLong);
    }
  }
  console.log(log.join());
})();
