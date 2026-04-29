class C { #x = 1; static has(o: any) { return #x in o; } }
const c1 = new C(); const c2: any = {};
console.log(C.has(c1), C.has(c2), C.has({ x: 1 }));
