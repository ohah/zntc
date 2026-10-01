namespace N {
  export const N = 1;
  export const _N = 2;
  export const _N1 = 3;
  export const _N2 = 4;
  export function read() {
    const local = { N: 99 };
    return N + _N + _N1 + _N2 + local.N;
  }
}

namespace A.B {
  export let A = 1;
  export let B = 2;
  export function read() {
    const _B = { A: 99 };
    return A + B + _B.A;
  }
}

console.log(JSON.stringify([N.read(), A.B.read()]));
