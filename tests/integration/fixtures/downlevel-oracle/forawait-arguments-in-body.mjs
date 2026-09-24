async function f() {
  const out = [];
  for await (const v of [1]) out.push(arguments.length + ':' + v);
  return out.join();
}
f(9, 9).then(console.log);
