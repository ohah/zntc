var events = [];
async function test() {
  var left = 20;
  var value = left + (await (events.push('rhs'), (left = 100), Promise.resolve(22)));
  return [value, left];
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
