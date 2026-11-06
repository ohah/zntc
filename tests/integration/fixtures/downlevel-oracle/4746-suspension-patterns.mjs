const events = [];
function* values() {
  const {
    [yield 'key']: [first = yield 7, ...rest],
  } = { key: [undefined, 20, 22] };
  let assigned;
  ({ value: assigned = yield 9 } = {});
  const [retained = yield 'unreached'] = [42];
  const { [yield 'picked']: selected, ...remaining } = { picked: 11, extra: 13 };
  return [first, rest, assigned, retained, selected, remaining.extra];
}
async function main() {
  const iterator = values();
  let step = iterator.next();
  while (!step.done) {
    events.push(['yield', step.value]);
    step = iterator.next(step.value);
  }
  events.push(['return', step.value]);
  let assigned;
  [assigned = await Promise.resolve(17)] = [];
  const { [await Promise.resolve('value')]: value } = { value: 19 };
  events.push(['async', assigned, value]);
  console.log(JSON.stringify(events));
}
main().then(() => {});
