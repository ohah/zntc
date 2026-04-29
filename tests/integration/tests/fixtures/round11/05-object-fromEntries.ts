const entries: [string, number][] = [["a", 1], ["b", 2], ["c", 3]];
const obj = Object.fromEntries(entries);
const round = Object.fromEntries(Object.entries(obj));
console.log(JSON.stringify(obj), JSON.stringify(round));
