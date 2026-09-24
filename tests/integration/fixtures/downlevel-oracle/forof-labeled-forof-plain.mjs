const out = [];
a: for (const xLong of [1, 2, 3]) {
  b: for (const yLong of [1, 2]) {
    if (yLong === 2) continue a;
    if (xLong === 3) break a;
    out.push(xLong + '' + yLong);
  }
}
console.log(out.join());
