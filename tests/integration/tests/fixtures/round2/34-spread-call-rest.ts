function f(...args: number[]) { return args.reduce((a, b) => a + b, 0); }
const arr = [1, 2, 3];
console.log(f(...arr, 4, 5, ...[6]));
const [a, , ...rest] = [10, 20, 30, 40, 50];
console.log(a, rest.join(","));
