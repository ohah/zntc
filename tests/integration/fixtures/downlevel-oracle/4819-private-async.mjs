const _load_fn = 40;
class Box {
  async #load(value) {
    return await Promise.resolve(value + 1);
  }
  read(value) {
    return this.#load(value);
  }
}
(async () => console.log(_load_fn, await new Box().read(1)))();
