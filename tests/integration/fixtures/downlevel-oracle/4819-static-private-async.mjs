const _read_fn = 40;
class Box {
  static async #read(value) { return await Promise.resolve(value + 1); }
  static read(value) { return this.#read(value); }
}
(async () => console.log(_read_fn, await Box.read(1)))();
