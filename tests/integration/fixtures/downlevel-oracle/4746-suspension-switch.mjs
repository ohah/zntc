const events = [];
function drive(iterator) {
  let step = iterator.next();
  while (!step.done) {
    events.push(['yield', step.value]);
    step = iterator.next(step.value);
  }
}
function* matches() {
  let reads = 0;
  switch ((reads++, yield 2)) {
    case (events.push('first'), 2):
      events.push(['matched', reads]);
      break;
    case (events.push('unreached'), yield 3):
      events.push('bad');
  }
  switch (yield 4) {
    case 1:
      events.push('bad');
      break;
    default:
      events.push('default');
    case yield 2:
      events.push('fallthrough');
  }
  outer: for (let count = 0; count < 2; count++) {
    try {
      switch (yield count) {
        case 0:
          events.push('break');
          break outer;
      }
    } finally {
      events.push('finally');
    }
  }
  let value = 2;
  switch (value) {
    case (value = 1):
      events.push('bad');
      break;
    case 2:
      events.push(['fixed-discriminant', value]);
      yield 7;
      break;
  }
}
async function main() {
  drive(matches());
  switch (2) {
    case await Promise.resolve(2):
      events.push('async-case');
      break;
    default:
      events.push('bad');
  }
  console.log(JSON.stringify(events));
}
main().then(() => {});
