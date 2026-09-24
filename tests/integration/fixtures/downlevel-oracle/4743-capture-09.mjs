const f = [];
outer: for (var i = 0; i < 2; i++) {
  for (var j = 0; j < 2; j++) {
    const v = i * 10 + j;
    f.push(() => v);
    if (j === 0) continue outer;
  }
}
console.log(f.map((g) => g()).join());
