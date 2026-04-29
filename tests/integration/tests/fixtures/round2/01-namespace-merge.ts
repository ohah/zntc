// TS namespace merging — same name can merge values across declarations
namespace M { export const x = 1; export function inc(n: number) { return n + x; } }
namespace M { export const y = 2; export function dec(n: number) { return n - y; } }
console.log(M.x, M.y, M.inc(10), M.dec(10));
