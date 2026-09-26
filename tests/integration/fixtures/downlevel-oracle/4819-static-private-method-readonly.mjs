let receiverCalls = 0;
let rhsCalls = 0;
class Example {
  static #method() { return 3; }
  static receiver() { receiverCalls++; return this; }
  static rhs() { rhsCalls++; return 5; }
  static plain() { this.receiver().#method = this.rhs(); }
  static compound() { this.receiver().#method += this.rhs(); }
  static logical() { this.receiver().#method &&= this.rhs(); }
  static update() { this.receiver().#method++; }
  static shortCircuit() { return this.receiver().#method ||= this.rhs(); }
  static has(value) { return #method in value; }
}
class Child extends Example {}
const errors = [];
for (const name of ['plain', 'compound', 'logical', 'update']) {
  try { Example[name](); errors.push('none'); }
  catch (error) { errors.push(error.name); }
}
console.log(JSON.stringify([errors, Example.shortCircuit()(), receiverCalls, rhsCalls, Example.has(Example), Example.has(Child)]));
