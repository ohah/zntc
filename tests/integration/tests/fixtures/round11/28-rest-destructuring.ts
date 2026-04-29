const { a, ...rest } = { a: 1, b: 2, c: 3 };
const [x, ...tail] = [1, 2, 3, 4];
console.log(a, JSON.stringify(rest), x, tail);
function fn({ a, b, ...rest }: any) {
  return [a, b, rest];
}
console.log(JSON.stringify(fn({ a: 1, b: 2, c: 3, d: 4 })));
