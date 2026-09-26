class Base {
  value() {
    return 5;
  }
}
class Box extends Base {
  constructor() {
    super();
    this.offset = 2;
  }
  *#read() {
    yield super.value() + this.offset;
  }
  read() {
    return [...this.#read()].join(',');
  }
}
console.log(new Box().read());
