import { values } from './sync.mjs';
await 0;
var events = [];
for (var value of [1, 2]) {
  for (var inner of [3]) events.push(value + inner);
}
function read() {
  return [value, inner, events.join()];
}
console.log(JSON.stringify(read()));
const captured = [];
for (var outer of values(events, 'outer', [4, 5])) {
  for (var item of values(events, 'inner', [6, 7])) {
    captured.push(function () {
      return [outer, item];
    });
    break;
  }
  break;
}
console.log(
  JSON.stringify([
    captured.map(function (read) {
      return read();
    }),
    events,
  ]),
);
