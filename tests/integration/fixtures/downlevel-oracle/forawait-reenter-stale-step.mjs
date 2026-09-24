// 앞 실행이 break 로 끝나 step 이 남은 상태에서, 다음 실행의 next() 가 실패하면 새 iterator 를
// 닫으면 안 된다(아직 한 번도 값을 받지 않았다).
const log = [];
function it(name, fail) {
  return {
    [Symbol.asyncIterator]() {
      return {
        next() {
          return fail
            ? Promise.reject(new Error('next:' + name))
            : Promise.resolve({ value: name, done: false });
        },
        return() {
          log.push('close:' + name);
          return Promise.resolve({ done: true });
        },
      };
    },
  };
}
(async () => {
  for (const [name, fail] of [
    ['a', false],
    ['b', true],
  ]) {
    try {
      for await (const vLong of it(name, fail)) {
        log.push(vLong);
        break;
      }
    } catch (eLong) {
      log.push(eLong.message);
    }
  }
  console.log(log.join());
})();
