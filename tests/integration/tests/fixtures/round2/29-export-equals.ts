// TS-only: export = identifier (CJS interop, rolldown/oxc 패턴 — module.exports = value)
const value = { name: "exp-eq", n: 42 };
console.log(JSON.stringify(value));
export = value;
