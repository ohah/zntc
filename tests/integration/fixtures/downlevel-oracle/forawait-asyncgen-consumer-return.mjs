const log = [];
async function* src() {
  try {
    yield 1;
    yield 2;
    yield 3;
  } finally {
    log.push('srcfin');
  }
}
async function* g() {
  try {
    for await (const v of src()) yield v;
  } finally {
    log.push('gfin');
  }
}
(async () => {
  for await (const v of g()) {
    log.push(v);
    if (v === 2) break;
  }
  console.log(log.join());
})();
