const Box = class Named {
  static async #read(value) { return await Promise.resolve(value + 1); }
  static read(value) { return this.#read(value); }
};
(async () => console.log(await Box.read(2)))();
