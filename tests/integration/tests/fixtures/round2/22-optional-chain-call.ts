const o: any = { f: () => 42, g: null };
console.log(o?.f?.());
console.log(o?.g?.());
console.log((o?.h as any)?.());
console.log(o?.f?.()?.toFixed?.(2));
