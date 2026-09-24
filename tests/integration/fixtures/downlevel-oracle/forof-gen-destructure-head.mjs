function* gLong() {
  for (const [aLong, { b: bLong }] of [
    [1, { b: 2 }],
    [3, { b: 4 }],
  ])
    yield aLong + bLong;
  for (const { x: xLong = 9, ...rest } of [{ y: 1 }, { x: 2, z: 3 }])
    yield xLong + ':' + Object.keys(rest).join('');
  for (let [pLong, , qLong = 'd'] of [[1, 2]]) yield pLong + qLong;
}
console.log([...gLong()].join());
