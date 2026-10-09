// Captured for-in bindings move this body into a per-iteration generator.
// Its nested for-of temps must belong to that generated generator wrapper.
const captured = [];
function* values(object) {
  for (const key in object) {
    yield key;
    captured.push(() => key);
    for (const value of [object[key]]) {
      yield value;
    }
  }
}
console.log([...values({ a: 1, b: 2 })].join(), captured.map((read) => read()).join());
