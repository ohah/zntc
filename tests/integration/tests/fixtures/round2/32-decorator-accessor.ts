function autoinc(_t: ClassAccessorDecoratorTarget<any, any>, _c: ClassAccessorDecoratorContext): ClassAccessorDecoratorResult<any, any> {
  return { get() { return (this as any).__c++; }, init(_v: any) { (this as any).__c = 0; return _v; } };
}
class C { @autoinc accessor v = 100; }
const c = new C(); console.log(c.v, c.v, c.v);
