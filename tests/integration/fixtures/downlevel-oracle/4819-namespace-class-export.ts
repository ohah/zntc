function identity(value: any) {
  return value;
}
const C = class Outer {};

namespace Plain {
  export class C {}
  export function create() {
    return new C();
  }
}

namespace Decorated {
  @identity
  export class C {}
  export function create() {
    return new C();
  }
}

console.log(
  JSON.stringify([
    Plain.C === C,
    Plain.create() instanceof Plain.C,
    Decorated.C === C,
    Decorated.create() instanceof Decorated.C,
  ]),
);
