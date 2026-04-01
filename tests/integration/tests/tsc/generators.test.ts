import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: generators", () => {
  test("generatorAssignability", async () => {
    await expectPass(
      `
declare let _: any;
declare const g1: Generator<number, void, string>;
declare const g2: Generator<number, void, undefined>;
declare const g3: Generator<number, void, boolean>;
declare const g4: AsyncGenerator<number, void, string>;
declare const g5: AsyncGenerator<number, void, undefined>;
declare const g6: AsyncGenerator<number, void, boolean>;

// spread iterable
[...g1]; // error
[...g2]; // ok

// binding pattern over iterable
let [x1] = g1; // error
let [x2] = g2; // ok

// binding rest pattern over iterable
let [...y1] = g1; // error
let [...y2] = g2; // ok

// assignment pattern over iterable
[_] = g1; // error
[_] = g2; // ok

// assignment rest pattern over iterable
[..._] = g1; // error
[..._] = g2; // ok

// for-of over iterable
for (_ of g1); // error
for (_ of g2); // ok

async function asyncfn() {
    // for-await-of over iterable
    for await (_ of g1); // error
    for await (_ of g2); // ok

    // for-await-of over asynciterable
    for await (_ of g4); // error
    for await (_ of g5); // ok
}

function* f1(): Generator<number, void, boolean> {
    // yield* over iterable
    yield* g1; // error
    yield* g3; // ok
}

async function* f2(): AsyncGenerator<number, void, boolean> {
    // yield* over iterable
    yield* g1; // error
    yield* g3; // ok

    // yield* over asynciterable
    yield* g4; // error
    yield* g6; // ok
}

async function f3() {
    const syncGenerator = function*() {
        yield 1;
        yield 2;
    };

    const o = {[Symbol.asyncIterator]: syncGenerator};

    for await (const x of o) {
    }
}
`,
      [],
    );
  });
  test("generatorExplicitReturnType", async () => {
    await expectPass(
      `
function* g1(): Generator<number, boolean, string> {
    yield; // error
    yield "a"; // error
    const x: number = yield 1; // error
    return 10; // error
}

function* g2(): Generator<number, boolean, string> {
    const x = yield 1;
    return true;
}

declare const generator: Generator<number, symbol, string>;

function* g3(): Generator<number, boolean, string> {
    const x: number = yield* generator; // error
    return true;
}

function* g4(): Generator<number, boolean, string> {
    const x = yield* generator;
    return true;
}`,
      [],
    );
  });
  test("generatorImplicitAny", async () => {
    await expectPass(
      `
function* g() {}

// https://github.com/microsoft/TypeScript/issues/35105
declare function noop(): void;
declare function f<T>(value: T): void;

function* g2() {
    const value = yield; // error: implicit any
}

function* g3() {
    const value: string = yield; // ok, contextually typed by \`value\`.
}

function* g4() {
    yield; // ok, result is unused
    yield, noop(); // ok, result is unused
    noop(), yield, noop(); // ok, result is unused
    (yield); // ok, result is unused
    (yield, noop()), noop(); // ok, result is unused
    for(yield; false; yield); // ok, results are unused
    void (yield); // ok, results are unused
}

function* g5() {
    f(yield); // error: implicit any
}

function* g6() {
    f<string>(yield); // ok, contextually typed by f<string>
}`,
      [],
    );
  });
  test("generatorReturnContextualType", async () => {
    await expectPass(
      `
// #35995

function* f1(): Generator<any, { x: 'x' }, any> {
  return { x: 'x' };
}

function* g1(): Iterator<any, { x: 'x' }, any> {
  return { x: 'x' };
}

async function* f2(): AsyncGenerator<any, { x: 'x' }, any> {
  return { x: 'x' };
}

async function* g2(): AsyncIterator<any, { x: 'x' }, any> {
  return { x: 'x' };
}

async function* f3(): AsyncGenerator<any, { x: 'x' }, any> {
  return Promise.resolve({ x: 'x' });
}

async function* g3(): AsyncIterator<any, { x: 'x' }, any> {
  return Promise.resolve({ x: 'x' });
}

async function* f4(): AsyncGenerator<any, { x: 'x' }, any> {
  const ret = { x: 'x' };
  return Promise.resolve(ret); // Error
}

async function* g4(): AsyncIterator<any, { x: 'x' }, any> {
  const ret = { x: 'x' };
  return Promise.resolve(ret); // Error
}`,
      [],
    );
  });
  test("generatorReturnTypeFallback.1", async () => {
    await expectPass(
      `
// Allow generators to fallback to IterableIterator if they do not need a type for the sent value while in strictNullChecks mode.
function* f() {
    yield 1;
}`,
      [],
    );
  });
  test("generatorReturnTypeFallback.2", async () => {
    await expectPass(
      `
// Allow generators to fallback to IterableIterator if they do not need a type for the sent value while in strictNullChecks mode.
// Report an error if IterableIterator cannot be found.
function* f() {
    yield 1;
}`,
      [],
    );
  });
  test("generatorReturnTypeFallback.3", async () => {
    await expectPass(
      `
function* f() {
    const x: string = yield 1;
}`,
      [],
    );
  });
  test("generatorReturnTypeFallback.4", async () => {
    await expectPass(
      `
// Allow generators to fallback to IterableIterator if they are not in strictNullChecks mode
// NOTE: In non-strictNullChecks mode, \`undefined\` (the default sent value) is assignable to everything.
function* f() {
    const x: string = yield 1;
}`,
      [],
    );
  });
  test("generatorReturnTypeFallback.5", async () => {
    await expectPass(
      `
// Allow generators to fallback to IterableIterator if they do not need a type for the sent value while in strictNullChecks mode.
function* f(): IterableIterator<number> {
    yield 1;
}`,
      [],
    );
  });
  test("generatorReturnTypeIndirectReferenceToGlobalType", async () => {
    await expectPass(
      `
interface I1 extends Iterator<0, 1, 2> {}

function* f1(): I1 {
  const a = yield 0;
  return 1;
}`,
      [],
    );
  });
  test("generatorReturnTypeInference", async () => {
    await expectPass(
      `
declare const iterableIterator: IterableIterator<number>;
declare const generator: Generator<number, string, boolean>;
declare const never: never;

function* g000() { // Generator<never, void, unknown>
}

// 'yield' iteration type inference
function* g001() { // Generator<undefined, void, unknown>
    yield;
}

function* g002() { // Generator<number, void, unknown>
    yield 1;
}

function* g003() { // Generator<never, void, undefined>
    yield* [];
}

function* g004() { // Generator<number, void, undefined>
    yield* iterableIterator;
}

function* g005() { // Generator<number, void, boolean>
    const x = yield* generator;
}

function* g006() { // Generator<1 | 2, void, unknown>
    yield 1;
    yield 2;
}

function* g007() { // Generator<never, void, unknown>
    yield never;
}

// 'return' iteration type inference
function* g102() { // Generator<never, number, unknown>
    return 1;
}

function* g103() { // Generator<never, 1 | 2, unknown>
    if (Math.random()) return 1;
    return 2;
}

function* g104() { // Generator<never, never, unknown>
    return never;
}

// 'next' iteration type inference
function* g201() { // Generator<number, void, string>
    let a: string = yield 1;
}

function* g202() { // Generator<1 | 2, void, never>
    let a: string = yield 1;
    let b: number = yield 2;
}

declare function f1(x: string): void;
declare function f1(x: number): void;

function* g203() { // Generator<number, void, string>
	const x = f1(yield 1);
}

declare function f2<T>(x: T): T;

function* g204() { // Generator<number, void, any>
	const x = f2(yield 1);
}

// mixed iteration types inference

function* g301() { // Generator<undefined, void, unknown>
    yield;
    return;
}

function* g302() { // Generator<number, void, unknown>
    yield 1;
    return;
}

function* g303() { // Generator<undefined, string, unknown>
    yield;
    return "a";
}

function* g304() { // Generator<number, string, unknown>
    yield 1;
    return "a";
}

function* g305() { // Generator<1 | 2, "a" | "b", unknown>
    if (Math.random()) yield 1;
    yield 2;
    if (Math.random()) return "a";
    return "b";
}

function* g306() { // Generator<number, boolean, "hi">
    const a: "hi" = yield 1;
    return true;
}

function* g307<T>() { // Generator<number, T, T>
    const a: T = yield 0;
    return a;
}

function* g308<T>(x: T) { // Generator<T, T, T>
    const a: T = yield x;
    return a;
}

function* g309<T, U, V>(x: T, y: U) { // Generator<T, U, V>
    const a: V = yield x;
    return y;
}

function* g310() { // Generator<undefined, void, [(1 | undefined)?, (2 | undefined)?]>
	const [a = 1, b = 2] = yield;
}

function* g311() { // Generator<undefined, void, string>
	yield* (function*() {
		const y: string = yield;
	})();
}
`,
      [],
    );
  });
  test("generatorReturnTypeInferenceNonStrict", async () => {
    await expectPass(
      `
declare const iterableIterator: IterableIterator<number>;
declare const generator: Generator<number, string, boolean>;
declare const never: never;

function* g000() { // Generator<never, void, unknown>
}

// 'yield' iteration type inference
function* g001() { // Generator<any (implicit), void, unknown>
    yield;
}

function* g002() { // Generator<number, void, unknown>
    yield 1;
}

function* g003() { // Generator<any (implicit), void, unknown>
    // NOTE: In strict mode, \`[]\` produces the type \`never[]\`.
    //       In non-strict mode, \`[]\` produces the type \`undefined[]\` which is implicitly any.
    yield* [];
}

function* g004() { // Generator<number, void, undefined>
    yield* iterableIterator;
}

function* g005() { // Generator<number, void, boolean>
    const x = yield* generator;
}

function* g006() { // Generator<1 | 2, void, unknown>
    yield 1;
    yield 2;
}

function* g007() { // Generator<never, void, unknown>
    yield never;
}

// 'return' iteration type inference
function* g102() { // Generator<never, number, unknown>
    return 1;
}

function* g103() { // Generator<never, 1 | 2, unknown>
    if (Math.random()) return 1;
    return 2;
}

function* g104() { // Generator<never, never, unknown>
    return never;
}

// 'next' iteration type inference
function* g201() { // Generator<number, void, string>
    let a: string = yield 1;
}

function* g202() { // Generator<1 | 2, void, never>
    let a: string = yield 1;
    let b: number = yield 2;
}

declare function f1(x: string): void;
declare function f1(x: number): void;

function* g203() { // Generator<number, void, string>
	const x = f1(yield 1);
}

declare function f2<T>(x: T): T;

function* g204() { // Generator<number, void, any>
	const x = f2(yield 1);
}

// mixed iteration types inference

function* g301() { // Generator<any (implicit), void, unknown>
    yield;
    return;
}

function* g302() { // Generator<number, void, unknown>
    yield 1;
    return;
}

function* g303() { // Generator<any (implicit), string, unknown>
    yield;
    return "a";
}

function* g304() { // Generator<number, string, unknown>
    yield 1;
    return "a";
}

function* g305() { // Generator<1 | 2, "a" | "b", unknown>
    if (Math.random()) yield 1;
    yield 2;
    if (Math.random()) return "a";
    return "b";
}

function* g306() { // Generator<number, boolean, "hi">
    const a: "hi" = yield 1;
    return true;
}

function* g307<T>() { // Generator<number, T, T>
    const a: T = yield 0;
    return a;
}

function* g308<T>(x: T) { // Generator<T, T, T>
    const a: T = yield x;
    return a;
}

function* g309<T, U, V>(x: T, y: U) { // Generator<T, U, V>
    const a: V = yield x;
    return y;
}

function* g310() { // Generator<any (implicit), void, [(1 | undefined)?, (2 | undefined)?]>
	const [a = 1, b = 2] = yield;
}

function* g311() { // Generator<any (implicit), void, string>
	yield* (function*() {
		const y: string = yield;
	})();
}
`,
      [],
    );
  });
  test("generatorYieldContextualType", async () => {
    await expectPass(
      `declare function f1<T, R, S>(gen: () => Generator<R, T, S>): void;
f1<0, 0, 1>(function* () {
	const a = yield 0;
	return 0;
});

declare function f2<T, R, S>(gen: () => Generator<R, T, S> | AsyncGenerator<R, T, S>): void;
f2<0, 0, 1>(async function* () {
	const a = yield 0;
	return 0;
});

// repro from #41428
enum Directive {
  Back,
  Cancel,
  LoadMore,
  Noop,
}

namespace Directive {
  export function is<T>(value: Directive | T): value is Directive {
    return typeof value === "number" && Directive[value] != null;
  }
}

interface QuickPickItem {
  label: string;
  description?: string;
  detail?: string;
  picked?: boolean;
  alwaysShow?: boolean;
}

interface QuickInputStep {
  placeholder?: string;
  prompt?: string;
  title?: string;
}

interface QuickPickStep<T extends QuickPickItem = QuickPickItem> {
  placeholder?: string;
  title?: string;
}

type StepGenerator =
  | Generator<
      QuickPickStep | QuickInputStep,
      StepResult<void | undefined>,
      any | undefined
    >
  | AsyncGenerator<
      QuickPickStep | QuickInputStep,
      StepResult<void | undefined>,
      any | undefined
    >;

type StepItemType<T> = T extends QuickPickStep<infer U>
  ? U[]
  : T extends QuickInputStep
  ? string
  : never;
namespace StepResult {
  export const Break = Symbol("BreakStep");
}
type StepResult<T> = typeof StepResult.Break | T;
type StepResultGenerator<T> =
  | Generator<QuickPickStep | QuickInputStep, StepResult<T>, any | undefined>
  | AsyncGenerator<
      QuickPickStep | QuickInputStep,
      StepResult<T>,
      any | undefined
    >;
type StepSelection<T> = T extends QuickPickStep<infer U>
  ? U[] | Directive
  : T extends QuickInputStep
  ? string | Directive
  : never;
type PartialStepState<T = unknown> = Partial<T> & {
  counter: number;
  confirm?: boolean;
  startingStep?: number;
};
type StepState<T = Record<string, unknown>> = T & {
  counter: number;
  confirm?: boolean;
  startingStep?: number;
};

function canPickStepContinue<T extends QuickPickStep>(
  _step: T,
  _state: PartialStepState,
  _selection: StepItemType<T> | Directive
): _selection is StepItemType<T> {
  return false;
}

function createPickStep<T extends QuickPickItem>(
  step: QuickPickStep<T>
): QuickPickStep<T> {
  return step;
}

function* showStep<
  State extends PartialStepState & { repo: any },
  Context extends { repos: any[]; title: string; status: any }
>(state: State, _context: Context): StepResultGenerator<QuickPickItem> {
  const step: QuickPickStep<QuickPickItem> = createPickStep<QuickPickItem>({
    title: "",
    placeholder: "",
  });
  const selection: StepSelection<typeof step> = yield step;
  return canPickStepContinue(step, state, selection)
    ? selection[0]
    : StepResult.Break;
}
`,
      [],
    );
  });
  test("restParameterInDownlevelGenerator", async () => {
    await expectPass(
      `
// https://github.com/Microsoft/TypeScript/issues/30653
function * mergeStringLists(...strings: string[]) {
    for (var str of strings);
}`,
      [],
    );
  });
  test("yieldStatementNoAsiAfterTransform", async () => {
    await expectPass(
      `declare var a: any;

function *t1() {
    yield (
        // comment
        a as any
    );
}
function *t2() {
    yield (
        // comment
        a as any
    ) + 1;
}
function *t3() {
    yield (
        // comment
        a as any
    ) ? 0 : 1;
}
function *t4() {
    yield (
        // comment
        a as any
    ).b;
}
function *t5() {
    yield (
        // comment
        a as any
    )[a];
}
function *t6() {
    yield (
        // comment
        a as any
    )();
}
function *t7() {
    yield (
        // comment
        a as any
    )\`\`;
}
function *t8() {
    yield (
        // comment
        a as any
    ) as any;
}
function *t9() {
    yield (
        // comment
        a as any
    ) satisfies any;
}
function *t10() {
    yield (
        // comment
        a as any
    )!;
}
`,
      [],
    );
  });
});
