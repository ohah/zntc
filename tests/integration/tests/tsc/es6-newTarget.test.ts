import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/newTarget", () => {
  test("invalidNewTarget.es5", async () => {
    await expectError(
      `const a = new.target;
const b = () => new.target;

class C {
    [new.target]() { }
    c() { return new.target; }
    get d() { return new.target; }
    set e(_) { _ = new.target; }
    f = () => new.target;

    static [new.target]() { }
    static g() { return new.target; }
    static get h() { return new.target; }
    static set i(_) { _ = new.target; }
    static j = () => new.target;
}

const O = {
    [new.target]: undefined,
    k() { return new.target; },
    get l() { return new.target; },
    set m(_) { _ = new.target; },
    n: new.target,
};`,
      [],
    );
  });
  test("invalidNewTarget.es6", async () => {
    await expectError(
      `const a = new.target;
const b = () => new.target;

class C {
    [new.target]() { }
    c() { return new.target; }
    get d() { return new.target; }
    set e(_) { _ = new.target; }
    f = () => new.target;

    static [new.target]() { }
    static g() { return new.target; }
    static get h() { return new.target; }
    static set i(_) { _ = new.target; }
    static j = () => new.target;
}

const O = {
    [new.target]: undefined,
    k() { return new.target; },
    get l() { return new.target; },
    set m(_) { _ = new.target; },
    n: new.target,
};`,
      [],
    );
  });
  test("newTarget.es5", async () => {
    await expectPass(
      `class A {
    constructor() {
        const a = new.target;
        const b = () => new.target;
    }
    static c = function () { return new.target; }
    d = function () { return new.target; }
}

class B extends A {
    constructor() {
        super();
        const e = new.target;
        const f = () => new.target;
    }
}

function f1() {
    const g = new.target;
    const h = () => new.target;
}

const f2 = function () {
    const i = new.target;
    const j = () => new.target;
}

const O = {
    k: function () { return new.target; }
};

`,
      [],
    );
  });
  test("newTarget.es6", async () => {
    await expectPass(
      `class A {
    constructor() {
        const a = new.target;
        const b = () => new.target;
    }
    static c = function () { return new.target; }
    d = function () { return new.target; }
}

class B extends A {
    constructor() {
        super();
        const e = new.target;
        const f = () => new.target;
    }
}

function f1() {
    const g = new.target;
    const h = () => new.target;
}

const f2 = function () {
    const i = new.target;
    const j = () => new.target;
}

const O = {
    k: function () { return new.target; }
};

`,
      [],
    );
  });
  test("newTargetNarrowing", async () => {
    await expectPass(
      `
function foo(x: true) { }

function f() {
  if (new.target.marked === true) {
    foo(new.target.marked);
  }
}

f.marked = true;`,
      [],
    );
  });
});
