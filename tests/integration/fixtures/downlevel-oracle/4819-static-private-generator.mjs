class Box {
  static *#read(value) {
    yield value;
    yield value + 1;
  }
  static read(value) {
    return [...this.#read(value)].join(',');
  }
}
console.log(Box.read(2));
