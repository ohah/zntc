var events = [];
async function test() {
  var object = { value: 20 };
  object.value += await (events.push('rhs'), (object.value = 100), Promise.resolve(22));
  return object.value;
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
