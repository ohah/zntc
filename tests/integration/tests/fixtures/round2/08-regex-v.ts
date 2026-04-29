// ES2024 /v flag — set notation
const re = /[\p{L}--[a-z]]/v;
console.log(re.test("A"), re.test("a"), re.test("Δ"));
