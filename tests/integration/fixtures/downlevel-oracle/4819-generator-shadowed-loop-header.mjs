function* collect(value, values) {
  for (let value = 0; value < values.length; value++) {
    const captured = values[value] + value;
    if (value === 1) continue;
    yield () => value + ':' + captured;
  }
  return value;
}
const iterator = collect(99, [10, 20, 30]);
const readers = [];
let completion;
while (true) {
  const step = iterator.next();
  if (step.done) {
    completion = step.value;
    break;
  }
  readers.push(step.value);
}
console.log(readers.map((read) => read()).join(',') + ':' + completion);
