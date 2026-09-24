const f = [];
for (var i = 0; i < 2; i++) {
  const v = i;
  f.push(
    function () {
      return this.k + v;
    }.bind({ k: 'k' }),
  );
}
console.log(f.map((g) => g()).join());
