function Base() {
  this.own1 = 1;
}
Base.prototype.inh = 2;
const obj = new Base();
obj.own2 = 3;
function* g(o) {
  for (const k in o) yield k;
}
console.log([...g(obj)].join());
