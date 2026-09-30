function* scalar(value) {
  yield value;
}

function* branched(value) {
  switch (value) {
    case 0:
      yield value;
      break;
    default:
      yield -value;
  }
}

console.log([...scalar(1)].join(), [...branched(0)].join());
