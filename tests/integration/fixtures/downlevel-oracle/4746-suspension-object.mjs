const events = [];
function* create() {
  return {
    __proto__: null,
    seed: 41,
    [yield 'method']() {
      return this.seed + 1;
    },
    get [yield 'read']() {
      events.push('get');
      return this.seed;
    },
    set [yield 'write'](value) {
      events.push(['set', value]);
      this.seed = value;
    },
  };
}
async function main() {
  const iterator = create();
  let step = iterator.next();
  while (!step.done) {
    events.push(['yield', step.value]);
    step = iterator.next(step.value);
  }
  const object = step.value;
  events.push(['before', object.method(), object.read]);
  object.write = 50;
  const descriptor = Object.getOwnPropertyDescriptor(object, 'read');
  events.push([
    'after',
    object.method(),
    descriptor.enumerable,
    descriptor.configurable,
    descriptor.get.name,
    Object.getOwnPropertyDescriptor(object, 'write').set.name,
    object.method.name,
    Object.getPrototypeOf(object) === null,
  ]);
  await Promise.resolve();
  console.log(JSON.stringify(events));
}
main().then(() => {});
