const arr = [1, 2, 3, 4, 5];
const last = arr.findLast((x) => x % 2 === 0);
const lastIdx = arr.findLastIndex((x) => x % 2 === 0);
const at1 = arr.at(-1);
const at2 = arr.at(0);
console.log(last, lastIdx, at1, at2);
