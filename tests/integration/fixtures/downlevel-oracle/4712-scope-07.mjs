const log = [];
function* g() {
  for (let i = 0; i < 2; i++) {
    const v = i * 10;
    yield 0;
    log.push(() => v);
  }
}
for (const _ of g());
console.log(log.map((f) => f()).join());
