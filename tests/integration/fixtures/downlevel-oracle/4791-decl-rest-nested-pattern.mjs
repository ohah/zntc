// 배열 선언의 rest 가 패턴이면 풀어야 한다 — 그대로 두면 es5 에 구조 분해 문법이 남는다 (#4791)
const [firstLong, ...[secondLong, thirdLong]] = new Set([4, 5, 6]);
const [...{ length: sizeLong, 0: zeroLong }] = 'abc';
const [headLong, ...[innerLong, ...deepLong]] = [1, 2, 3, 4];
console.log(
  firstLong,
  secondLong,
  thirdLong,
  sizeLong,
  zeroLong,
  headLong,
  innerLong,
  deepLong.join('/'),
);
