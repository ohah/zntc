/// #2198 회귀 가드:
/// `--bundle` 모드 cycle 모듈에서 const/let → var, class declaration → class
/// expression 강등으로 ESM live binding 의미 보존 (esbuild 호환).
/// scope-hoisted IIFE 안에서 정의 전 참조가 TDZ throw 대신 var 호이스팅으로
/// `undefined` fallback.

import { describe, test, expect, afterEach } from 'bun:test';
import { bundleAndRun } from './helpers';

describe('#2198: bundler circular dependency live binding', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('2-way const cycle: 정의 전 참조는 undefined, 함수 호출은 정상', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { b } from "./b.ts";
          export const a = "A";
          export function ping() { return a + b; }
          console.log("a-loaded:", b);
        `,
        'b.ts': `
          import { a, ping } from "./a.ts";
          export const b = "B";
          export function pong() { return ping() + "!"; }
          console.log("b-loaded a=", a);
        `,
        'entry.ts': `
          import { ping } from "./a.ts";
          import { pong } from "./b.ts";
          console.log(ping(), pong());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('b-loaded a= undefined\na-loaded: B\nAB AB!');
  });

  test('3-way cycle (x→y→z→x): 모든 멤버 marking + var 강등', async () => {
    const result = await bundleAndRun(
      {
        'x.ts': `
          import { y, callY } from "./y.ts";
          import { z } from "./z.ts";
          export const x = 100;
          export function callX() { return y + z; }
          console.log("x.ts: y=", y, "z=", z, "callY=", callY());
        `,
        'y.ts': `
          import { z, callZ } from "./z.ts";
          import { x } from "./x.ts";
          export const y = 200;
          export function callY() { return z + x; }
          console.log("y.ts: z=", z, "x=", x, "callZ=", callZ());
        `,
        'z.ts': `
          import { x, callX } from "./x.ts";
          import { y } from "./y.ts";
          export const z = 300;
          export function callZ() { return x + y; }
          console.log("z.ts: x=", x, "y=", y, "callX=", callX());
        `,
        'entry.ts': `
          import { x, callX } from "./x.ts";
          import { y, callY } from "./y.ts";
          import { z, callZ } from "./z.ts";
          console.log("--- entry ---");
          console.log(x, y, z);
          console.log(callX(), callY(), callZ());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    // 평가 순서: z → y → x → entry. 각 모듈에서 cycle init 시점은 일부 식별자가 undefined.
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe(
      [
        'z.ts: x= undefined y= undefined callX= NaN',
        'y.ts: z= 300 x= undefined callZ= NaN',
        'x.ts: y= 200 z= 300 callY= 400',
        '--- entry ---',
        '100 200 300',
        '500 400 300',
      ].join('\n'),
    );
  });

  test('class declaration cycle: var X = class {} 변환으로 cross-ref 동작', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { B, getB } from "./b.ts";
          export class A {
            static label = "A-class";
            static getBLabel() { return B.label; }
          }
          export const aValue = "a-init";
          console.log("a.ts loaded — B is:", typeof B, " getB():", getB());
        `,
        'b.ts': `
          import { A, aValue } from "./a.ts";
          export class B {
            static label = "B-class";
            static getALabel() { return A.label; }
          }
          export const bValue = "b-init";
          export function getB() { return B.label + ":" + bValue; }
          console.log("b.ts loaded — A is:", typeof A, " aValue:", aValue);
        `,
        'entry.ts': `
          import { A } from "./a.ts";
          import { B } from "./b.ts";
          console.log("--- after init ---");
          console.log("A.getBLabel:", A.getBLabel());
          console.log("B.getALabel:", B.getALabel());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe(
      [
        'b.ts loaded — A is: undefined  aValue: undefined',
        'a.ts loaded — B is: function  getB(): B-class:b-init',
        '--- after init ---',
        'A.getBLabel: B-class',
        'B.getALabel: A-class',
      ].join('\n'),
    );
  });

  test('default export cycle: 함수 default 도 정상 cross-ref', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import b from "./b.ts";
          export default function getA() { return "A:" + b(); }
        `,
        'b.ts': `
          import a from "./a.ts";
          export default function getB() { return "B"; }
        `,
        'entry.ts': `
          import a from "./a.ts";
          import b from "./b.ts";
          console.log(a(), b());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('A:B B');
  });

  test('namespace import cycle: import * as A 도 정상', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import * as B from "./b.ts";
          export const a = "A";
          export function getBValue() { return B.b; }
          console.log("a-loaded, b namespace:", typeof B);
        `,
        'b.ts': `
          import * as A from "./a.ts";
          export const b = "B";
          export function getAValue() { return A.a; }
          console.log("b-loaded, a namespace:", typeof A);
        `,
        'entry.ts': `
          import { getBValue } from "./a.ts";
          import { getAValue } from "./b.ts";
          console.log(getAValue(), getBValue());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe(
      ['b-loaded, a namespace: object', 'a-loaded, b namespace: object', 'A B'].join('\n'),
    );
  });

  test('export default class cycle: default class 도 var = class 변환 + .name 보존', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import B from "./b.ts";
          export default class A {
            static getBName() { return B.name; }
          }
        `,
        'b.ts': `
          import A from "./a.ts";
          export default class B {
            static getAName() { return A.name; }
          }
        `,
        'entry.ts': `
          import A from "./a.ts";
          import B from "./b.ts";
          console.log(A.name, B.name, A.getBName(), B.getAName());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    // class expression 변환 후에도 NamedEvaluation 으로 `.name` 보존
    expect(result.runOutput).toBe('A B B A');
  });

  test('re-export from cycle: barrel 이 cycle 모듈을 re-export 해도 정상', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { b } from "./b.ts";
          export const a = "A";
          console.log("a-load:", b);
        `,
        'b.ts': `
          import { a } from "./a.ts";
          export const b = "B";
          console.log("b-load:", a);
        `,
        'barrel.ts': `
          export { a } from "./a.ts";
          export { b } from "./b.ts";
        `,
        'entry.ts': `
          import { a, b } from "./barrel.ts";
          console.log("entry:", a, b);
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe(['b-load: undefined', 'a-load: B', 'entry: A B'].join('\n'));
  });

  test('legacy decorator + cycle: --experimental-decorators 도 정상 cross-ref', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { B } from "./b.ts";
          function tagit(target: any) { target.tagged = "yes"; return target; }
          @tagit
          export class A { static getB() { return B.label; } }
        `,
        'b.ts': `
          import { A } from "./a.ts";
          export class B { static label = "B"; static getA() { return (A as any).tagged; } }
        `,
        'entry.ts': `
          import { A } from "./a.ts";
          import { B } from "./b.ts";
          console.log(A.getB(), B.getA(), (A as any).tagged);
        `,
      },
      'entry.ts',
      ['--platform=node', '--experimental-decorators'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('B yes yes');
  });

  test('closure-only cycle 참조: cycle init 끝난 후 호출 → 정상 값', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { b } from "./b.ts";
          export const a = 10;
          export const closureUseB = () => b * 2;
        `,
        'b.ts': `
          import { a } from "./a.ts";
          export const b = 20;
          export const closureUseA = () => a * 3;
        `,
        'entry.ts': `
          import { closureUseB } from "./a.ts";
          import { closureUseA } from "./b.ts";
          console.log(closureUseA(), closureUseB());
        `,
      },
      'entry.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('30 40');
  });
});
