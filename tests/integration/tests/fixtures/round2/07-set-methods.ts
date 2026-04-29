// ES2025 Set methods
const a = new Set([1, 2, 3, 4]);
const b = new Set([3, 4, 5, 6]);
console.log([...(a as any).intersection(b)].sort().join(","));
console.log([...(a as any).union(b)].sort((x: any, y: any) => x - y).join(","));
console.log([...(a as any).difference(b)].sort().join(","));
