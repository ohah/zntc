function tag(target: any, key?: string) {
  target.__tagged = true;
}
class Foo {
  @tag bar() { return 1; }
}
console.log((Foo.prototype as any).__tagged, new Foo().bar());
