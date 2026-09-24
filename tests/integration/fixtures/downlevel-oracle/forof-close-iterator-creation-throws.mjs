// [Symbol.iterator]() 가 던지면 닫지 않고 원래 에러가 그대로 나가야 한다(정상 완료 플래그가
// iterator 생성 전에 참이어야 함).
const log = [];
const bad = {
  [Symbol.iterator]() {
    throw new Error('create');
  },
};
try {
  for (const v of bad) log.push(v);
} catch (e) {
  log.push(e.message);
}
function* g() {
  for (const v of bad) yield v;
}
try {
  for (const v of g()) log.push(v);
} catch (e) {
  log.push('g:' + e.message);
}
console.log(log.join());
