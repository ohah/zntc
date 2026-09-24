const xLong = 'OUT';
const log = [];
async function fLong() {
  if (true) {
    const xLong2 = 'IN';
    await 0;
    log.push(xLong2);
  }
  log.push(xLong);
}
fLong().then(() => console.log(log.join()));
