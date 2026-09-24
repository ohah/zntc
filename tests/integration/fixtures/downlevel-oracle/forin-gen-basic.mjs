function Base() {
  this.own1 = 1;
}
Base.prototype.inh = 2;
const obj = new Base();
obj.own2 = 3;
function* gLong(oLong) {
  for (const kLong in oLong) yield kLong;
}
console.log([...gLong(obj)].join());
