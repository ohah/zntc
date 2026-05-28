export const name = 'b-patch';
export function apply(o) {
  return { ...o, patched: name, extra: true };
}
