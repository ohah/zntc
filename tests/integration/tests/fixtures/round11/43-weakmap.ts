const wm = new WeakMap<object, string>();
const ws = new WeakSet<object>();
const k1 = { id: 1 };
const k2 = { id: 2 };
wm.set(k1, "alpha");
ws.add(k1);
console.log(wm.get(k1), wm.has(k1), wm.has(k2));
console.log(ws.has(k1), ws.has(k2));
