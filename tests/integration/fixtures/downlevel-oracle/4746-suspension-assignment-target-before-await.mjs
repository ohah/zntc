var events = [];
async function test() {
  var original = {},
    other = {},
    current = original;
  function getObj() {
    events.push('object');
    return current;
  }
  function getKey() {
    events.push('key');
    return 'value';
  }
  getObj()[getKey()] = await (events.push('rhs'), (current = other), Promise.resolve(42));
  return [original.value, other.value === undefined];
}
test().then(
  function (value) {
    console.log(JSON.stringify({ value: value, events: events }));
  },
  function (error) {
    console.error(error.stack);
    process.exitCode = 1;
  },
);
