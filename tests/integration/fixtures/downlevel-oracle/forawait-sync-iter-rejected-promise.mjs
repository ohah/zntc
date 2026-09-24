const log = [];
(async () => {
  try {
    for await (const vLong of [1, Promise.reject(new Error('rej')), 3]) log.push(vLong);
  } catch (eLong) {
    log.push(eLong.message);
  }
  console.log(log.join());
})();
