const out = [];
for (const xLong of [1, 2]) {
  const x2 = xLong;
  {
    let xLong2 = 'inner' + x2;
    out.push(xLong2);
  }
}
for (let yLong of [3]) {
  let zLong = yLong;
  out.push(zLong);
}
console.log(out.join());
