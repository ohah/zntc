const log: string[] = [];
const sym = Symbol("k");
const o: any = { _x: 0, get [sym]() { log.push("g"); return this._x; }, set [sym](v: number) { log.push("s:" + v); this._x = v; } };
o[sym] = 5; o[sym] += 3;
console.log(o[sym], log.join(","));
