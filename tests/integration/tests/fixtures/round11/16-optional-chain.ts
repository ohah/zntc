type Obj = { a?: { b?: { c?: number; fn?: () => string } } };
const o: Obj = { a: { b: { c: 42, fn: () => "yes" } } };
const empty: Obj = {};
console.log(o?.a?.b?.c, empty?.a?.b?.c, o?.a?.b?.fn?.(), empty?.a?.b?.fn?.());
const arr: number[] | null = null;
console.log(arr?.[0], arr?.length);
