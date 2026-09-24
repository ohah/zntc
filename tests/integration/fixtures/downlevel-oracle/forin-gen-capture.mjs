function Base() {
  this.own1 = 1;
}
Base.prototype.inh = 2;
const obj = new Base();
obj.own2 = 3;
const fns = [];
function* gLong(oLong) {
  for (const kLong in oLong) {
    yield kLong;
    fns.push(() => kLong);
  }
}
for (const _Long of gLong(obj));
console.log(fns.map((fLong) => fLong()).join());
