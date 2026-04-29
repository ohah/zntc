// ES2026 explicit resource management
const log: string[] = [];
class R { [Symbol.dispose]() { log.push("disposed"); } }
{ using r = new R(); log.push("inside"); }
console.log(log.join(","));
