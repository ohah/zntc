// TS-only: export = class (CJS interop, rolldown/oxc 패턴 — module.exports = class)
const Foo = class {
  greet() {
    return "hi-from-export-equals-class";
  }
};
console.log(new Foo().greet());
export = Foo;
