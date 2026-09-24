const z = 'OUT';
const log = [];
function* g(v) {
  switch (v) {
    case 1: {
      let z = 'IN';
      yield 1;
      log.push(z);
    }
  }
  log.push(z);
}
for (const x of g(1));
console.log(log.join());
