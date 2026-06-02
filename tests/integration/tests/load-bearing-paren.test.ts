import { afterEach, describe, expect, test } from 'bun:test';
import { transpileAndRun } from './helpers';

// load-bearing 괄호 회귀 매트릭스(#4042) — 런타임 의미 검증.
//
// 문자열 생존(빠른 1차)은 src/codegen/codegen_test/load_bearing_paren.zig 가
// 본다. 여기서는 transpile → 실제 실행으로 "괄호가 빠지면 throw 가 undefined 로
// 바뀌거나, this 바인딩/평가순서가 달라지거나, SyntaxError 가 되는" 의미 자체를
// 박제한다. 현재(precedence 전환 전)는 parenthesized_expression 노드로 보존되어
// 전부 통과하고, 전환(PR4) 후에도 precedence 가 동일 괄호를 재유도해 통과해야
// 한다 — 이 스위트가 그 가드다.
//
// 각 케이스는 괄호 유실 시 결과가 *관측 가능하게 달라지도록* 구성한다(비변별
// 케이스는 가드 역할을 못 한다). cleanup 은 afterEach 로 등록해 expect 실패 시에도
// temp dir 이 누수되지 않게 한다(downlevel-edge.test.ts 와 동일 패턴).
describe('load-bearing 괄호 런타임 의미 보존 (#4042)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('optional-chain 끊기: (a?.b).c 는 a=null 이면 throw (≠ undefined)', async () => {
    const r = await transpileAndRun(`
      const a = null;
      let out = 'no-throw';
      try { (a?.b).c; } catch { out = 'throw'; }
      console.log(out);
    `);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // 괄호 유실 시 a?.b.c → 전체 short-circuit → 'no-throw'.
    expect(r.runOutput.trim()).toBe('throw');
  });

  test('indirect call: (0, o.m)() 는 this 가 o 가 아님', async () => {
    const r = await transpileAndRun(`
      const o = { m() { return this === o; } };
      console.log((0, o.m)());
    `);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // 괄호/sequence 유실 시 o.m() → this===o → true.
    expect(r.runOutput.trim()).toBe('false');
  });

  test('numeric-then-dot: (42).toString()', async () => {
    const r = await transpileAndRun(`console.log((42).toString());`);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    expect(r.runOutput.trim()).toBe('42');
  });

  test('음수 단항이 ** 좌측: (-2) ** 2 === 4 (괄호 유실 시 SyntaxError)', async () => {
    const r = await transpileAndRun(`console.log((-2) ** 2);`);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    expect(r.runStderr).toBe('');
    expect(r.runOutput.trim()).toBe('4');
  });

  test('?? 와 || 혼용: (a || b) ?? c (괄호 유실 시 SyntaxError)', async () => {
    const r = await transpileAndRun(`
      const a = 0, b = 2, c = 3;
      console.log((a || b) ?? c);
    `);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    expect(r.runStderr).toBe('');
    expect(r.runOutput.trim()).toBe('2'); // (0||2)??3 → 2
  });

  test('arrow 본문 object literal: () => ({}) 는 객체를 반환', async () => {
    const r = await transpileAndRun(`
      const f = () => ({ x: 1 });
      console.log(f().x);
    `);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // 괄호 유실 시 () => {x:1} 의 {는 블록 → undefined.
    expect(r.runOutput.trim()).toBe('1');
  });

  test('new callee call-chain: new (factory().Ctor)()', async () => {
    const r = await transpileAndRun(`
      function factory() { return { Ctor: class { constructor() { this.ok = true; } } }; }
      console.log(new (factory().Ctor)().ok);
    `);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // 괄호 유실 시 new factory().Ctor() → (new factory()).Ctor() 로 결합이 깨짐.
    expect(r.runOutput.trim()).toBe('true');
  });

  test('assignment 가 binary 피연산자: (a = 2) + 3 — 부수효과로 변별', async () => {
    const r = await transpileAndRun(`
      let a = 0;
      const v = (a = 2) + 3;
      // (a=2)+3: a===2, v===5.  괄호 유실 a=2+3: a===5, v===5(값은 우연히 동일).
      // a 의 부수효과를 관측해 괄호 유실을 변별한다(값만 보면 둘 다 5라 무의미).
      console.log(a === 2 ? v : 'BROKEN');
    `);
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    expect(r.runOutput.trim()).toBe('5'); // a===2 → v(5). 괄호 유실 시 'BROKEN'.
  });
});
