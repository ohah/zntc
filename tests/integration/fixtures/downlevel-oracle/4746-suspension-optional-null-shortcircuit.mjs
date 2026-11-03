var events = [];
async function test() {
  var object = null;
  var value = object?.method(await (events.push('operand'), Promise.resolve(42)));
  return [value === undefined, events.length];
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
