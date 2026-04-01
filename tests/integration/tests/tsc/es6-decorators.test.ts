import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/decorators", () => {
  test("decoratorOnClassAccessor1.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

export default class {
    @dec get accessor() { return 1; }
}`,
      [],
    );
  });
  test("decoratorOnClass1.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
class C {
}

let c = new C();`,
      [],
    );
  });
  test("decoratorOnClass2.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
export class C {
}

let c = new C();`,
      [],
    );
  });
  test("decoratorOnClass3.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
export default class C {
}

let c = new C();`,
      [],
    );
  });
  test("decoratorOnClass4.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
export default class {
}`,
      [],
    );
  });
  test("decoratorOnClass5.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
class C {
    static x() { return C.y; }
    static y = 1;
}

let c = new C();`,
      [],
    );
  });
  test("decoratorOnClass6.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
export class C {
    static x() { return C.y; }
    static y = 1;
}

let c = new C();`,
      [],
    );
  });
  test("decoratorOnClass7.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
export default class C {
    static x() { return C.y; }
    static y = 1;
}

let c = new C();`,
      [],
    );
  });
  test("decoratorOnClass8.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: T): T;

@dec
export default class {
    static y = 1;
}`,
      [],
    );
  });
  test("decoratorOnClassMethod1.es6", async () => {
    await expectPass(
      `declare function dec<T>(target: any, propertyKey: string, descriptor: TypedPropertyDescriptor<T>): TypedPropertyDescriptor<T>;

export default class {
    @dec method() {}
}`,
      [],
    );
  });
  test("decoratorOnClassMethodParameter1.es6", async () => {
    await expectPass(
      `declare function dec(target: Object, propertyKey: string | symbol, parameterIndex: number): void;

export default class {
    method(@dec p: number) {}
}`,
      [],
    );
  });
  test("decoratorOnClassProperty1.es6", async () => {
    await expectPass(
      `declare function dec(target: any, propertyKey: string): void;

export default class {
    @dec prop;
}`,
      [],
    );
  });
});
