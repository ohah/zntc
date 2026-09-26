class Base { static value() { return 5; } }
class Box extends Base {
  static offset = 2;
  static async #read() { return await Promise.resolve(super.value() + this.offset); }
  static read() { return this.#read(); }
}
(async () => console.log(await Box.read()))();
