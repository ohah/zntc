const run = (
  capture = () => value,
  { nested: { ...value } } = { nested: { n: 7, ignored: 9 } },
) => [capture(), value];
console.log(JSON.stringify(run()));
