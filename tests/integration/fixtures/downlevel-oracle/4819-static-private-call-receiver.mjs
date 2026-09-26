let receiverCalls = 0;
let argCalls = 0;
const log = [];
class Example {
  static #method(value) { log.push('method'); return [this === Example, value]; }
  static get #callable() { log.push('getter'); return function (value) { log.push('callable'); return [this === Example, value]; }; }
  static receiver() { receiverCalls++; log.push('receiver'); return this; }
  static argument() { argCalls++; log.push('argument'); return 7; }
  static run() {
    const first = this.#method;
    const second = this.#method;
    const detached = first.call(null, 1);
    const method = this.receiver().#method(this.argument());
    const getter = this.receiver().#callable(this.argument());
    return [first === second, detached, method, getter];
  }
}
console.log(JSON.stringify([Example.run(), receiverCalls, argCalls, log]));
