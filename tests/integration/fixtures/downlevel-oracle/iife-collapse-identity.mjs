// IIFE 접기가 반환식을 복사하면 이후 상수 인라인이 원본만 고치고 선언을 지워 ReferenceError (minify 없는 번들 포함)
const out = [];
function caseA() {
  const valueLong = 'A';
  return (() => valueLong)();
}
function caseB() {
  const objLong = { k: 1 };
  return (() => objLong)().k;
}
function caseC() {
  const numLong = 2;
  return (() => (() => numLong)())();
}
function caseD() {
  (() => ({ x: 1 }))();
  (() => function () {})();
  (() => class {})();
  return 'D';
}
function caseE() {
  const textLong = 'T';
  return (() => `${textLong}!`)();
}
function caseF() {
  const fnLong = () => 3;
  return (() => fnLong)()();
}
function caseG() {
  let mutLong = 1;
  const readLong = (() => mutLong)();
  mutLong = 2;
  return readLong + mutLong;
}
function caseH() {
  return (() => {
    return 'H';
  })();
}
out.push(caseA(), caseB(), caseC(), caseD(), caseE(), caseF(), caseG(), caseH());
console.log(out.join(','));
