class Config {
  static #data: Record<string, number> = {};
  static {
    Config.#data["a"] = 1;
    Config.#data["b"] = 2;
  }
  static get(k: string) { return Config.#data[k]; }
}
console.log(Config.get("a"), Config.get("b"));
