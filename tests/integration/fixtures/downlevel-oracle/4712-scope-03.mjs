const log = [];
function* g() {
  for (let i = 0; i < 2; i++) {
    try {
      throw i;
    } catch (e) {
      yield 0;
      log.push(() => e);
    }
  }
}
for (const v of g());
console.log(log.map((f) => f()).join());
