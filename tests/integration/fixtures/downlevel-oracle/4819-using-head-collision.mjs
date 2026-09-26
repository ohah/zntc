function run(_using, _using2) {
  const log = [];
  const resource = (valueLong) => ({
    [Symbol.dispose]() {
      log.push('dispose' + valueLong);
    },
  });
  outer: for (using itemLong of [resource(1), resource(2)]) {
    log.push(_using + _using2 + String(itemLong !== undefined));
    if (log.length > 2) break outer;
  }
  return log.join(',');
}
console.log(run('user', 'shadow'));
