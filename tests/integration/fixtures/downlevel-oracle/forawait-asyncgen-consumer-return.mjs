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
async function* gLong() {
  try {
    for await (const vLong of src()) yield vLong;
  } finally {
    log.push('gfin');
  }
}
(async () => {
  for await (const vLong2 of gLong()) {
    log.push(vLong2);
    if (vLong2 === 2) break;
  }
  console.log(log.join());
})();
