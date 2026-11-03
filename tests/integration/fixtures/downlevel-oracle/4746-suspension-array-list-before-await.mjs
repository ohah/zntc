var events = [];
async function test() {
  function first() {
    events.push('first');
    return 20;
  }
  var value = [first(), await (events.push('second'), Promise.resolve(22))];
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
