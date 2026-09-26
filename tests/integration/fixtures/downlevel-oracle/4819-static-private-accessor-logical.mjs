let receiverCalls = 0;
let rhsCalls = 0;
let getterCalls = 0;
let setterCalls = 0;
class Logic {
  static #stored = null;
  static get #value() {
    getterCalls++;
    return this.#stored;
  }
  static set #value(value) {
    setterCalls++;
    this.#stored = value;
  }
  static receiver() {
    receiverCalls++;
    return this;
  }
  static rhs(value) {
    rhsCalls++;
    return value;
  }
  static run() {
    const results = [];
    results.push((this.receiver().#value ??= this.rhs(0)));
    results.push((this.receiver().#value ??= this.rhs(1)));
    results.push((this.receiver().#value ||= this.rhs(2)));
    results.push((this.receiver().#value ||= this.rhs(3)));
    results.push((this.receiver().#value &&= this.rhs(4)));
    results.push((this.receiver().#value &&= this.rhs(0)));
    results.push((this.receiver().#value &&= this.rhs(5)));
    return results;
  }
}
console.log(JSON.stringify([Logic.run(), receiverCalls, rhsCalls, getterCalls, setterCalls]));
