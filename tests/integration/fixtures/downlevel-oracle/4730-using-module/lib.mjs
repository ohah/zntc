const log = (globalThis.LOG = []);
const R = (n) => ({
  [Symbol.dispose]() {
    log.push('d' + n);
  },
});
export function g() {
  return 'g' + k;
}
using a = R(1);
export const k = 1;
export class C {
  static v = 2;
}
export default 7;
