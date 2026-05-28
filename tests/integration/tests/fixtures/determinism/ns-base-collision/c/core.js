export const id = 'c-core';
export function make(x) {
  return { tag: id, value: x + 100 };
}
