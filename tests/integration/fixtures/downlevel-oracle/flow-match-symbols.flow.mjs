// @flow
function classify(_a, input, expected) {
  return match (input) {
    { kind: expected, payload: const payload } if (payload > 0) => payload,
    [const first, ...const rest] => first + rest.length,
    const item if (item > 2) => item,
    { fallback: const item } => item,
    _ => _a,
  };
}

console.log([
  classify(99, { kind: 1, payload: 4 }, 1),
  classify(99, [2, 3], 1),
  classify(99, 5, 1),
  classify(99, 1, 1),
].join(','));
