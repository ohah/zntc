export const id = 'b-core';
export function make(x) {
  return { tag: id, value: x * 2 };
}
