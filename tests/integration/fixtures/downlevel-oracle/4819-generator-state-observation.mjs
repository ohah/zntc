function* outer() {
  const value = 1;
  yield value;
  const inner = function* () {
    yield value + 1;
  };
  yield inner().next().value;
}

const iterator = outer();
console.log([iterator.next().value, iterator.next().value].join(','));
