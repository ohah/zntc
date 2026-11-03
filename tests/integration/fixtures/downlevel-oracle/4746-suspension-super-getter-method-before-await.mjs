var events = [];
async function test() {
  class Base {
    get method() {
      events.push('getter');
      return function (value) {
        events.push(this instanceof Child ? 'receiver-ok' : 'receiver-bad');
        return value + 1;
      };
    }
  }
  class Child extends Base {
    async read() {
      return super.method(await (events.push('operand'), Promise.resolve(41)));
    }
  }
  return await new Child().read();
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
