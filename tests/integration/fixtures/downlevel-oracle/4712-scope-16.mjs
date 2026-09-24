const t = 'OUT';
const log = [];
async function f() {
  label: {
    let t = 'IN';
    await 0;
    if (t) break label;
  }
  log.push(t);
}
f().then(() => console.log(log.join()));
