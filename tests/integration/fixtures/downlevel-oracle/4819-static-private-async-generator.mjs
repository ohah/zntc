class Box {
  static async *#stream(value) {
    yield await Promise.resolve(value + 1);
  }
  static read(value) {
    return this.#stream(value);
  }
}
(async () => {
  const values = [];
  for await (const value of Box.read(3)) values.push(value);
  console.log(values.join(','));
})();
