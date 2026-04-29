const a = { x: 1, y: 2 };
const b = { y: 99, z: 3 };
const merged = { ...a, ...b, w: 4 };
const arr = [1, 2, 3];
const arr2 = [0, ...arr, 4];
console.log(JSON.stringify(merged), arr2);
