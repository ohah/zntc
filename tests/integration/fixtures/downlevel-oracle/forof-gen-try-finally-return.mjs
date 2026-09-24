const log = [];
function* gLong() {
  for (const vLong of [1, 2]) {
    try {
      if (vLong === 2) return 'r';
      yield vLong;
    } finally {
      log.push('f' + vLong);
    }
  }
}
console.log([...gLong()].join(), log.join());
