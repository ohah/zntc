// ECMAScript: instance field init in source order, after super()
class P { x = 1; y = this.x + 1; constructor() { /* fields run before this */ } }
class C extends P { z = (this.x || 0) + 100; }
const c = new C();
console.log(c.x, (c as any).y, (c as any).z);
