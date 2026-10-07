function* whileCaptured() {
  const _loop = 'while';
  let index = 0;
  while (index < 3) {
    let value = index++;
    yield () => value + ':' + _loop;
  }
}

function* doWhileCaptured() {
  const _loop = 'do';
  let index = 0;
  do {
    let value = index++;
    yield () => value + ':' + _loop;
  } while (index < 3);
}

function collect(generator) {
  const values = [];
  let item = generator.next();
  while (!item.done) {
    values.push(item.value());
    item = generator.next();
  }
  return values.join(',');
}

console.log(collect(whileCaptured()) + '|' + collect(doWhileCaptured()));
