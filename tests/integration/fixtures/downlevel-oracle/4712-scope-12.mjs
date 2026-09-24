const i = 'OUT';
const log = [];
function* g() {
  for (let i = 0; i < 1; i++) {
    yield i;
  }
  log.push(i);
}
for (const x of g());
console.log(log.join());
