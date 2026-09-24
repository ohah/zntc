async function fLong() {
  const out = [];
  for await (const vLong of [1]) out.push(arguments.length + ':' + vLong);
  return out.join();
}
fLong(9, 9).then(console.log);
