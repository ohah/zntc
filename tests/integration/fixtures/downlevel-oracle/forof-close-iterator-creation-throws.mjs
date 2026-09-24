// [Symbol.iterator]() 가 던지면 닫지 않고 원래 에러가 그대로 나가야 한다(정상 완료 플래그가
// iterator 생성 전에 참이어야 함).
const log = [];
const bad = {
  [Symbol.iterator]() {
    throw new Error('create');
  },
};
try {
  for (const vLong of bad) log.push(vLong);
} catch (eLong) {
  log.push(eLong.message);
}
function* gLong() {
  for (const vLong2 of bad) yield vLong2;
}
try {
  for (const vLong3 of gLong()) log.push(vLong3);
} catch (eLong2) {
  log.push('g:' + eLong2.message);
}
console.log(log.join());
