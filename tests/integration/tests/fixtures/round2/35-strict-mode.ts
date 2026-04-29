"use strict";
function f() { try { (this as any).x = 1; return "no-throw"; } catch (e: any) { return e.constructor.name; } }
console.log(f.call(null));
