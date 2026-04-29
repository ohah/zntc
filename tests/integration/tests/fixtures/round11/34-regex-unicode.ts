const re = /\p{Letter}+/gu;
const matches = "abc123日本語".match(re);
const re2 = /[\u{1F600}-\u{1F64F}]/u;
console.log(matches, re2.test("hello 😀 world"));
