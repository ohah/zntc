const log = [];
function* g() {
  for (const v of [1, 2]) {
    try {
      if (v === 2) return 'r';
      yield v;
    } finally {
      log.push('f' + v);
    }
  }
}
console.log([...g()].join(), log.join());
