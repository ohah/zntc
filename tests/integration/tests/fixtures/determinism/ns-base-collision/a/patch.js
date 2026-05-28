export const name = 'a-patch';
export function apply(o) {
  return { ...o, patched: name };
}
