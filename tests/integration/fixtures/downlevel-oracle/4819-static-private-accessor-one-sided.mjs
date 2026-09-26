class ReadOnly {
  static get #value() { return 4; }
  static read() { return this.#value; }
  static write() { this.#value = 5; }
}

class WriteOnly {
  static #stored = 0;
  static set #value(value) { this.#stored = value; }
  static read() { return this.#value; }
  static write(value) { this.#value = value; return this.#stored; }
}

let readError = 'none';
let writeError = 'none';
try { ReadOnly.write(); } catch (error) { readError = error.name; }
try { WriteOnly.read(); } catch (error) { writeError = error.name; }
console.log(ReadOnly.read(), WriteOnly.write(7), readError, writeError);
