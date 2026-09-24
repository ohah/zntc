const out = [];
a: for (const x of [1, 2, 3]) {
  b: for (const y of [1, 2]) {
    if (y === 2) continue a;
    if (x === 3) break a;
    out.push(x + '' + y);
  }
}
console.log(out.join());
