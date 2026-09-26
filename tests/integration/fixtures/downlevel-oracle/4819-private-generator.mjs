class Box {
  *#read(value) {
    yield value;
    yield value + 1;
  }
  read(value) {
    return [...this.#read(value)].join(',');
  }
}
console.log(new Box().read(2));
