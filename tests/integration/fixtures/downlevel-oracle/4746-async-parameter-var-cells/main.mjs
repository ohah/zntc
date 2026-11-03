import { initializations, mark } from './sync.mjs';
const shadow = 'module';
async function run(shadow) {
  const closures = [];
  await 0;
  for (var position = 0, limit = 2; position < limit; position++) {
    var shadow = 'loop' + position;
    closures.push(function () {
      return [shadow, position];
    });
    await 0;
  }
  function local(shadow) {
    return shadow + ':local';
  }
  return [
    closures.map(function (read) {
      return read();
    }),
    shadow,
    position,
    limit,
    local('inner'),
  ];
}
console.log(JSON.stringify([shadow, await run('parameter')]));
async function defaults(value = 1, read = () => value) {
  await 0;
  var value = mark(2);
  return [value, read(), initializations];
}
console.log(JSON.stringify(await defaults()));
const arrow = async (value) => {
  await 0;
  var value = 2;
  return value;
};
console.log(await arrow(1));

// Keep the body var in its nested block while sharing the simple formal cell.
async function nested(value) {
  'use strict';
  await 0;
  {
    var { value } = { value: 2 };
  }
  function read() {
    return value;
  }
  return [value, read(), arguments[0]];
}
console.log(JSON.stringify(await nested(1)));
