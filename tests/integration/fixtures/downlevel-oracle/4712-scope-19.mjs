const message = 'OUT';
const log = [];
function* gLong(eLong) {
  {
    let { message } = eLong;
    yield 1;
    log.push(message);
  }
  log.push(message);
}
for (const vLong of gLong({ message: 'M' }));
console.log(log.join());
