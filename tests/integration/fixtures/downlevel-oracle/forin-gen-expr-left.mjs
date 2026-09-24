const o = {};
function* g() {
  for (o.p in { u: 1, v: 2 }) yield o.p;
}
console.log([...g()].join(), o.p);
