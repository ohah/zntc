// 같은 함수 안에서 for-await 가 다시 실행될 때, 앞 실행에서 잡힌 에러·중단 상태가 남아
// 에러 없이 끝난 실행의 finally 가 옛 에러를 다시 던지거나 새 iterator 를 닫으면 안 된다.
const log = [];
async function run() {
  for (let round = 0; round < 2; round++) {
    try {
      for await (const v of [1, 2]) {
        if (round === 0) throw new Error('r0');
        log.push('r' + round + ':' + v);
      }
      log.push('done' + round);
    } catch (e) {
      log.push('caught:' + e.message);
    }
  }
}
run().then(() => console.log(log.join()));
