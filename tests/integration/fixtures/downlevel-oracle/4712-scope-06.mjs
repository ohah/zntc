const x = 'OUT';
const log = [];
async function f() {
  if (true) {
    const x = 'IN';
    await 0;
    log.push(x);
  }
  log.push(x);
}
f().then(() => console.log(log.join()));
