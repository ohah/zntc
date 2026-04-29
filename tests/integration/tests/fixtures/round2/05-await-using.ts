async function run() {
  const log: string[] = [];
  class R { async [Symbol.asyncDispose]() { log.push("async-disposed"); } }
  { await using r = new R(); log.push("inside"); }
  return log.join(",");
}
run().then(s => console.log(s));
