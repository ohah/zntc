const log = [];
try {
  {
    using a = {
      [Symbol.dispose]() {
        throw new Error('D');
      },
    };
    throw new Error('B');
  }
} catch (e) {
  log.push(e.constructor.name, e.error && e.error.message, e.suppressed && e.suppressed.message);
}
console.log(log.join());
