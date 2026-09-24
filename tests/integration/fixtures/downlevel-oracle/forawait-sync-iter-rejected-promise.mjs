const log = [];
(async () => {
  try {
    for await (const v of [1, Promise.reject(new Error('rej')), 3]) log.push(v);
  } catch (e) {
    log.push(e.message);
  }
  console.log(log.join());
})();
