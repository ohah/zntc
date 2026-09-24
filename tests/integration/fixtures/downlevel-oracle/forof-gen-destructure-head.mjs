function* g() {
  for (const [a, { b }] of [
    [1, { b: 2 }],
    [3, { b: 4 }],
  ])
    yield a + b;
  for (const { x = 9, ...rest } of [{ y: 1 }, { x: 2, z: 3 }])
    yield x + ':' + Object.keys(rest).join('');
  for (let [p, , q = 'd'] of [[1, 2]]) yield p + q;
}
console.log([...g()].join());
