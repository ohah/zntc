const o: any = { a: { b: { c: () => 42 } } };
console.log(o?.a?.b?.c?.());
console.log(o?.x?.y?.z);
console.log(o?.a?.["b"]?.c?.());
const fn: any = null;
console.log(fn?.(1, 2));
