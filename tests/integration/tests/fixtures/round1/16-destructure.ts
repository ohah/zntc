const { a: x = 10, b: { c: y = 20 } = {} } = { a: undefined, b: { c: 5 } } as any;
console.log(x, y);
const [, , z = 99] = [1, 2];
console.log(z);
const { ...rest } = { a: 1, b: 2 };
console.log(JSON.stringify(rest));
