function Base() {
  this.own1 = 1;
}
Base.prototype.inh = 2;
const obj = new Base();
obj.own2 = 3;
const fns = [];
function* g(o) {
  for (const k in o) {
    yield k;
    fns.push(() => k);
  }
}
for (const _ of g(obj));
console.log(fns.map((f) => f()).join());
