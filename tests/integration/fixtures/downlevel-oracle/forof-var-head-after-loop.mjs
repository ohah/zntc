for (var v of [1, 2, 3]);
function* g() {
  for (var w of [4, 5]) yield w;
}
console.log(v, [...g()].join());
