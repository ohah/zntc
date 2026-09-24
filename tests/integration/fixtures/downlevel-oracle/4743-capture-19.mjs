const f = [];
for (let i = 0; i < 2; i++) {
  var w = i;
  f.push(() => i);
}
console.log(f.map((g) => g()).join(), w);
