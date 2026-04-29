class MyArray {
  get [Symbol.toStringTag]() { return "MyArray"; }
}
const a = new MyArray();
console.log(Object.prototype.toString.call(a));
console.log(Object.prototype.toString.call(new Map()));
console.log(Object.prototype.toString.call(new Set()));
