class Base {
  static value() {
    return 5;
  }
}
class Box extends Base {
  static offset = 2;
  static async *#read() {
    yield await Promise.resolve(super.value() + this.offset);
  }
  static read() {
    return this.#read();
  }
}
(async () => {
  const values = [];
  for await (const value of Box.read()) values.push(value);
  console.log(values.join(','));
})();
