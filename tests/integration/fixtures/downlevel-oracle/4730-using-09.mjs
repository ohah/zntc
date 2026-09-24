const log = [];
try {
  {
    using aLong = {
      [Symbol.dispose]() {
        throw new Error('D');
      },
    };
    throw new Error('B');
  }
} catch (eLong) {
  log.push(
    eLong.constructor.name,
    eLong.error && eLong.error.message,
    eLong.suppressed && eLong.suppressed.message,
  );
}
console.log(log.join());
