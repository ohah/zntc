const err = 'OUTER';
const log = [];
async function fLong() {
  try {
    await 0;
    throw new Error('A');
  } catch (err) {
    await 0;
    log.push(err.message);
  }
  log.push(String(err));
}
fLong().then(() => console.log(log.join()));
