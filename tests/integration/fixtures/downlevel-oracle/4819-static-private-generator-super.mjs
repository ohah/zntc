class Base {
  static value() {
    return 5;
  }
}
class Box extends Base {
  static offset = 2;
  static *#read() {
    yield super.value() + this.offset;
  }
  static read() {
    return [...this.#read()].join(',');
  }
}
console.log(Box.read());
