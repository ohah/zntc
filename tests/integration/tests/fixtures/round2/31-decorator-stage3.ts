function trace<T extends (...args: any[]) => any>(target: T, ctx: ClassMethodDecoratorContext): T {
  return function (this: any, ...args: any[]) { return "[" + String(ctx.name) + "]" + target.apply(this, args); } as T;
}
class C { @trace greet(n: string) { return "hi " + n; } }
console.log(new C().greet("x"));
