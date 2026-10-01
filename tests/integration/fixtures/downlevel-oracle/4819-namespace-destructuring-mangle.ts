namespace M {
  export const value = 7;
}

namespace M {
  export const next = value + 1;
}

namespace N {
  const _a = 99;
  export const { value } = { value: 1 };
  export function local() {
    const value = _a;
    return value;
  }
}

namespace N {
  export const next = value + 2;
}

console.log(JSON.stringify([N.value, N.next, N.local(), M.value, M.next]));
