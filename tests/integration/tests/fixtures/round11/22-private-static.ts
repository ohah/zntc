class Cache {
  static #store = new Map<string, number>();
  static #count = 0;
  static get size() { return Cache.#store.size; }
  static set(k: string, v: number) {
    Cache.#store.set(k, v);
    Cache.#count++;
  }
  static get count() { return Cache.#count; }
}
Cache.set("a", 1); Cache.set("b", 2); Cache.set("a", 3);
console.log(Cache.size, Cache.count);
