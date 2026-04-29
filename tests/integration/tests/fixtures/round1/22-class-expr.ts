const Foo = class Bar {
  static name2 = "Bar-static";
  who() { return Bar.name2; }
};
const f = new Foo();
console.log(f.who(), Foo.name);
