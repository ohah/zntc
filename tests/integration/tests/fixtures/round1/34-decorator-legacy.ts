function tag(label: string) {
  return function (target: any, key?: string) {
    target.__tags = target.__tags || [];
    target.__tags.push(label + ":" + (key || "class"));
  };
}
@tag("cls")
class D {
  @tag("m")
  hi() { return "hi"; }
}
console.log((D.prototype as any).__tags?.join("|"), new D().hi());
