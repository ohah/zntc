const events = [];

class Host {
  static #field = 3;
  static #method() {
    return 4;
  }
  static get #readOnly() {
    return 5;
  }
  static set #writeOnly(value) {
    events.push(value);
  }

  static run() {
    const result = [this.#field, this.#method(), this.#readOnly];
    try {
      result.push(this.#writeOnly);
    } catch (error) {
      result.push(error.name);
    }
    try {
      this.#readOnly = 9;
    } catch (error) {
      result.push(error.name);
    }
    try {
      this.#method = 9;
    } catch (error) {
      result.push(error.name);
    }
    this.#field = 7;
    this.#writeOnly = 8;
    result.push(this.#field, events);
    return result;
  }
}

const oldHasOwnProperty = Object.prototype.hasOwnProperty;
Object.prototype.kind = 1;
Object.prototype.get = function () {
  throw new Error('inherited get');
};
Object.prototype.set = function () {
  throw new Error('inherited set');
};
Object.prototype.writable = true;
Object.prototype.value = 99;
Object.prototype.hasOwnProperty = function () {
  throw new Error('poisoned hasOwnProperty');
};

let result;
try {
  result = Host.run();
} catch (error) {
  result = ['unexpected', error.message];
} finally {
  Object.prototype.hasOwnProperty = oldHasOwnProperty;
  delete Object.prototype.kind;
  delete Object.prototype.get;
  delete Object.prototype.set;
  delete Object.prototype.writable;
  delete Object.prototype.value;
}
console.log(JSON.stringify(result));
