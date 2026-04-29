const log: string[] = [];
const get = (k: string, v: any) => { log.push(k); return { [k]: v }; };
const o = { a: 1, ...get("b", 2), c: 3, ...get("a", 99) };
console.log(JSON.stringify(o), log.join(","));
const arr = [...[1,2], 3, ...[4,5]];
console.log(arr.join(","));
