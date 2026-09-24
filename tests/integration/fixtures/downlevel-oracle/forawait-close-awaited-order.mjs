// 조기 종료 시 iterator 의 return() 결과를 기다린 뒤에 루프 다음 문장이 실행돼야 한다.
const log = [];
async function* src() {
  try {
    yield 1;
    yield 2;
  } finally {
    await 0;
    await 0;
    log.push('srcfin');
  }
}
(async () => {
  for await (const vLong of src()) {
    log.push(vLong);
    break;
  }
  log.push('after');
  console.log(log.join());
})();
