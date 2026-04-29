const obj = { a: 1, nested: { b: 2 }, arr: [3, 4] };
const clone = structuredClone(obj);
clone.nested.b = 99;
console.log(obj.nested.b, clone.nested.b, JSON.stringify(clone));
