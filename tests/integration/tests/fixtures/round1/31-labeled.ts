const out: number[] = [];
outer: for (let i = 0; i < 3; i++) {
  for (let j = 0; j < 3; j++) {
    if (i === 1 && j === 1) continue outer;
    if (i === 2 && j === 2) break outer;
    out.push(i * 10 + j);
  }
}
console.log(out.join(","));
