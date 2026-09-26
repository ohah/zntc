class Box {
  async *#stream(value) {
    yield await Promise.resolve(value + 1);
  }
  read(value) {
    return this.#stream(value);
  }
}
(async () => {
  const values = [];
  for await (const value of new Box().read(3)) values.push(value);
  console.log(values.join(','));
})();
