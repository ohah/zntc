const tLong = 'OUT';
const log = [];
async function fLong() {
  label: {
    let tLong2 = 'IN';
    await 0;
    if (tLong2) break label;
  }
  log.push(tLong);
}
fLong().then(() => console.log(log.join()));
