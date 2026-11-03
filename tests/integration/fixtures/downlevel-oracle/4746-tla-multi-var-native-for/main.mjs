import { record } from './sync.mjs';
const events = [];
await 0;
for (
  var cursor = record(events, 'cursor', 0),
    upper = record(events, 'upper', 2),
    offset = record(events, 'offset', 1);
  cursor < upper;
  cursor++
) {
  events.push(cursor + offset);
}
for (
  var empty = record(events, 'empty', 0), stop = record(events, 'stop', 0);
  empty < stop;
  empty++
) {
  events.push('unreachable');
}
function read() {
  return [cursor, upper, offset, empty, stop, events];
}
console.log(JSON.stringify(read()));
