class Example {
  static #method() {
    return 1;
  }
  static destructure() {
    [this.#method] = [3];
  }
  static forOf() {
    for (this.#method of [3]) {
    }
  }
  static forIn() {
    for (this.#method in { x: 1 }) {
    }
  }
  static read() {
    return this.#method();
  }
}
const result = [];
for (const name of ['destructure', 'forOf', 'forIn']) {
  try {
    Example[name]();
    result.push('none');
  } catch (error) {
    result.push(error.name);
  }
}
console.log(JSON.stringify([result, Example.read()]));
