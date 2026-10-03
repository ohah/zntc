// Independently implement the fixture's match arms in standard JavaScript.
// This reference must run directly in Node, without passing through ZNTC.
function classify(_a, input, expected) {
  if (
    input !== null &&
    typeof input === 'object' &&
    'kind' in input &&
    input.kind === expected &&
    'payload' in input &&
    input.payload > 0
  ) {
    return input.payload;
  }
  if (Array.isArray(input) && input.length > 0) {
    const [first, ...rest] = input;
    return first + rest.length;
  }
  if (input > 2) return input;
  if (input !== null && typeof input === 'object' && 'fallback' in input) {
    return input.fallback;
  }
  return _a;
}

console.log(
  [
    classify(99, { kind: 1, payload: 4 }, 1),
    classify(99, [2, 3], 1),
    classify(99, 5, 1),
    classify(99, 1, 1),
  ].join(','),
);
