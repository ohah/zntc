const log = [];
function* g() {
  try {
    yield 1;
    throw 'A';
  } catch (e) {
    try {
      yield 2;
      throw 'B';
    } catch (e) {
      yield 3;
      log.push(e);
    }
    log.push(e);
  }
}
for (const v of g());
console.log(log.join());
