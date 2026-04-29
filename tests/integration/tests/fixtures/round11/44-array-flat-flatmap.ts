const nested = [1, [2, [3, [4, 5]]]];
console.log(nested.flat());
console.log(nested.flat(2));
console.log(nested.flat(Infinity));
const arr = [1, 2, 3];
console.log(arr.flatMap((x) => [x, x * 10]));
