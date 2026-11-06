const key = Symbol.iterator;
class Direct {
  [key]() {
    return [11][Symbol.iterator]();
  }
}
function createClass() {
  const key = 'read';
  class Captured {
    [key]() {
      return 42;
    }
    [Symbol.iterator]() {
      return [this.read()][Symbol.iterator]();
    }
  }
  return Captured;
}
function createDefaultClass(
  Box = class {
    [Symbol.iterator]() {
      return [43][Symbol.iterator]();
    }
  },
) {
  return Box;
}
async function main() {
  const Captured = createClass();
  const Default = createDefaultClass();
  const descriptor = Object.getOwnPropertyDescriptor(Direct.prototype, key);
  await Promise.resolve();
  console.log(
    JSON.stringify([
      Array.from(new Direct()),
      Array.from(new Captured()),
      descriptor.enumerable,
      descriptor.configurable,
      descriptor.writable,
      new Captured().read(),
      typeof key,
      Array.from(new Default()),
    ]),
  );
}
main().then(() => {});
