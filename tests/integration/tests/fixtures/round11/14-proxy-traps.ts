const target: Record<string, number> = { a: 1, b: 2 };
const trace: string[] = [];
const p: any = new Proxy(target, {
  get(t, k: string) { trace.push(`get:${k}`); return t[k]; },
  set(t, k: string, v: number) { trace.push(`set:${k}=${v}`); t[k] = v; return true; },
  has(t, k: string) { trace.push(`has:${k}`); return k in t; },
  deleteProperty(t, k: string) { trace.push(`del:${k}`); delete t[k]; return true; },
});
p.a; p.c = 3; "a" in p; delete p.b;
console.log(trace.join("|"), JSON.stringify(target));
