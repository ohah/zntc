var events = [];
async function test() {
  function original(strings, value) {
    events.push('original');
    return value + 1;
  }
  function replacement(strings, value) {
    events.push('replacement');
    return value + 100;
  }
  var tag = original;
  var value = tag`prefix${await (events.push('operand'), (tag = replacement), Promise.resolve(41))}suffix`;
  return value;
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
