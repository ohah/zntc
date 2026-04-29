type C = Record<string, number | string>;
const data = { a: 1, b: "two", c: 3 } satisfies C;
console.log(data.a + 1, data.b.toUpperCase());
