const m = new Map<string, number>([["a", 1], ["b", 2], ["c", 3]]);
const s = new Set([10, 20, 30]);
const mEntries = [...m.entries()];
const sEntries = [...s];
console.log(mEntries, sEntries);
const mKeys = [...m.keys()].join(",");
const mVals = [...m.values()].join(",");
console.log(mKeys, mVals);
