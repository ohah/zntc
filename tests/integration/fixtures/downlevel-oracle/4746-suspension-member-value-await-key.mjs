var events = [];
async function test() {
  var original = { key: 42 },
    other = { key: 900 },
    current = original;
  function getObj() {
    events.push('object');
    return current;
  }
  var value = getObj()[await (events.push('key'), (current = other), Promise.resolve('key'))];
  return [value, current === other];
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
