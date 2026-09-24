// 매개변수와 같은 이름의 루프 변수가 var 가 되면 매개변수를 덮는다.
function pick(key, entries) {
  const seen = [];
  for (const [key, value] of entries) seen.push(key + '=' + value);
  return seen.join('&') + '|' + key;
}
console.log(
  pick('orig', [
    ['a', 1],
    ['b', 2],
  ]),
);
