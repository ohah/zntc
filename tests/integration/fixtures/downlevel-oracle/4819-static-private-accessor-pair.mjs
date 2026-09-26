let receiverCalls = 0;
let rhsCalls = 0;
let getterCalls = 0;
let setterCalls = 0;

class Forward {
  static #value = 1;
  static get #access() { getterCalls++; return this.#value; }
  static set #access(value) { setterCalls++; this.#value = value; }
  static receiver() { receiverCalls++; return this; }
  static rhs() { rhsCalls++; return 2; }
  static run() {
    this.receiver().#access += this.rhs();
    this.receiver().#access ??= this.rhs();
    this.receiver().#access &&= this.rhs();
    this.receiver().#access ||= this.rhs();
    this.receiver().#access **= this.rhs();
    return [this.#access++, ++this.#access, this.#access];
  }
}

class Reverse {
  static #value = 5;
  static set #access(value) { this.#value = value; }
  static get #access() { return this.#value; }
  static run() { this.#access += 3; return this.#access; }
}

console.log(JSON.stringify([Forward.run(), Reverse.run(), receiverCalls, rhsCalls, getterCalls, setterCalls]));
