const sym = Symbol("k");
const o = {
  [sym]: 1,
  ["a" + "b"]: 2,
  [Symbol.iterator]() { let i = 0; return { next: () => ({ value: i++, done: i > 3 }) }; }
};
console.log((o as any)[sym], (o as any).ab, [...(o as any)].join(","));
