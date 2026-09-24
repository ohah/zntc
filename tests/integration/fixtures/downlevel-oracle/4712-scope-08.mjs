const e = 'OUT';
const log = [];
function* g() {
  try {
    yield 1;
    throw 'X';
  } catch {
    yield 2;
    log.push(e);
  }
}
for (const v of g());
console.log(log.join());
