const KEY = "dynamic";
class Foo {
  [KEY]() { return "hello"; }
  static [`${KEY}_static`]() { return "world"; }
  ["literal"]() { return "literal"; }
}
const f = new Foo();
console.log((f as any)[KEY](), (Foo as any)[`${KEY}_static`](), (f as any).literal());
