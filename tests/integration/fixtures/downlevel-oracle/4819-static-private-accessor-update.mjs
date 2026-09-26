const log = [];
class Values {
  static #text = '4';
  static #large = 4n;
  static #custom = {
    valueOf() {
      log.push('valueOf');
      return 8;
    },
  };
  static get #asText() {
    log.push('getText');
    return this.#text;
  }
  static set #asText(value) {
    log.push('setText');
    this.#text = value;
  }
  static get #asBigInt() {
    return this.#large;
  }
  static set #asBigInt(value) {
    this.#large = value;
  }
  static get #asObject() {
    log.push('getObject');
    return this.#custom;
  }
  static set #asObject(value) {
    log.push('setObject');
    this.#custom = value;
  }
  static run() {
    return [
      this.#asText++,
      this.#asText,
      ++this.#asBigInt,
      this.#asBigInt,
      this.#asObject++,
      this.#asObject,
    ];
  }
}
console.log(JSON.stringify([Values.run().map((value) => [typeof value, String(value)]), log]));
