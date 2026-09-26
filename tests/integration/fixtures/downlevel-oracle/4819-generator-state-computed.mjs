let keys = 0;
function key() {
  keys++;
  return 'load';
}
class Box {
  value = 10;
  async [key()](value) {
    return await Promise.resolve(this.value + value);
  }
  async *[key() + 'Async'](value) {
    yield await Promise.resolve(this.value + value + 1);
  }
  *[key() + 'Sync'](value) {
    yield this.value + value + 2;
  }
}
const object = {
  async ['read'](value) {
    return await Promise.resolve(value + 3);
  },
  async *['asyncStream'](value) {
    yield await Promise.resolve(value + 4);
  },
  *['stream'](value) {
    yield value + 5;
  },
};
const box = new Box();
Promise.all([
  box.load(1),
  box.loadAsync(1).next(),
  box.loadSync(1).next(),
  object.read(1),
  object.asyncStream(1).next(),
  object.stream(1).next(),
]).then((values) => console.log(keys, JSON.stringify(values)));
