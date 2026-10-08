namespace X {
  export class MyPromise<T> extends Promise<T> {}
}

async function qualifiedReturn(): X.MyPromise<void> {}

declare class C {}
declare const p: Promise<typeof C>;

async function classAfterAwait(): Promise<void> {
  class D extends (await p) {}
}

async function classExpressionsAfterAwait(): Promise<void> {
  const First = class extends (await p) {};
  const Second = class extends (await p) {};
}

namespace M {
  export async function f1() {}
}
