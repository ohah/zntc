const out = [];
for (const x of [1, 2]) {
  const x2 = x;
  {
    let x = 'inner' + x2;
    out.push(x);
  }
}
for (let y of [3]) {
  let z = y;
  out.push(z);
}
console.log(out.join());
