import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runNode, runZntc, transpileAndRun } from './helpers';

// #4500 — new callee 체인 silent miscompile 런타임 가드.
//
// 방출 문자열(빠른 1차)은 src/codegen/codegen_test/new_callee_chain.zig 가 본다.
// 여기서는 transpile → 실제 실행으로 "TypeError 없이 원본과 같은 값이 나오는지"를 박제한다.
//
// 수정 전 방출:
//   `new new Inner().C()` → `new new Inner()().C()` → TypeError: not a constructor
//   `new tag`x`.B()`      → `new tag()`x`.B()`      → TypeError: not a function
describe('new callee 체인 (#4500)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('중첩 new 뒤 member 체인: new new Inner().C()', async () => {
    const r = await transpileAndRun(
      `
      class Inner { C: any; constructor(){ this.C = class { ok = 42; }; } }
      const x = new new Inner().C();
      console.log(x.ok);
    `,
      [],
      { ext: 'ts' },
    );
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // 오파싱 시 `new new Inner()().C()` 가 방출돼 실행이 TypeError 로 죽는다(runOutput 빈 문자열).
    expect(r.runOutput.trim()).toBe('42');
  });

  test('중첩 new 뒤 subscript 체인: new new Inner()[k]()', async () => {
    const r = await transpileAndRun(
      `
      class Inner { constructor(){ this.C = class { constructor(){ this.ok = 7; } }; } }
      const k = 'C';
      const z = new new Inner()[k]();
      console.log(z.ok);
    `,
      [],
      { ext: 'js' },
    );
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    expect(r.runOutput.trim()).toBe('7');
  });

  test('new callee 안의 tagged template: new tag`x`.B()', async () => {
    const r = await transpileAndRun(
      `
      function tag(strings){ return { B: class { constructor(){ this.ok = 9; } } }; }
      const x = new tag\`x\`.B();
      console.log(x.ok);
    `,
      [],
      { ext: 'js' },
    );
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    expect(r.runOutput.trim()).toBe('9');
  });

  test('TS 타입 래퍼가 argless-new head 를 가려도 SyntaxError: new a`x`!?.b', async () => {
    const r = await transpileAndRun(
      `
      declare const a: any;
      new a\`x\`!?.b;
    `,
      [],
      { ext: 'ts' },
    );
    cleanup = r.cleanup;
    // 예전엔 exit 0 으로 수용하고 ``new a()`x`?.b`` (의미까지 다름)를 방출했다.
    expect(r.transpileExitCode).not.toBe(0);
    expect(r.transpileStderr).toContain('ZNTC0623');
  });

  test('new callee 안의 call 은 괄호 보존: new (f())`x`.B()', async () => {
    // 실행은 **node(V8)** 로 한다 — bun 1.3.11 의 파서가 이 형태를 잘못 읽어(undefined)
    // `bun run` 기반 transpileAndRun 으로는 의미 검증이 안 된다. zntc 는 V8/tsc 를 따른다.
    const dir = await mkdtemp(join(tmpdir(), 'zntc-4500-paren-'));
    cleanup = async () => rm(dir, { recursive: true, force: true });
    const src = join(dir, 'in.js');
    const out = join(dir, 'out.js');
    await writeFile(
      src,
      `function f(){ return function tag(s){ return { B: class { constructor(){ this.ok = 4; } } }; }; }\n` +
        `const x = new (f())\`x\`.B();\nconsole.log(x.ok);\n`,
    );
    const t = await runZntc([src, '-o', out]);
    expect(t.exitCode).toBe(0);
    // 괄호 유실 시 `new f()`x`.B()` → f 가 *생성*되고 template 결과가 *호출*된다 → TypeError.
    const run = await runNode(out);
    expect(run.stdout.trim()).toBe('4');
  });

  test('es5 spread + new: member/tagged callee 가 컴파일러를 죽이지 않고 1회만 평가된다', async () => {
    // 예전엔 lowerSpreadNew 가 callee 를 identifier 로 가정해 `new a.b(...args)` 가 컴파일러
    // panic 이었다. #4500 파서 수정으로 `` new tag`x`(...args) `` 도 이 경로로 들어온다.
    const r = await transpileAndRun(
      `
      const args = [7];
      let evals = 0;
      const a = { get b(){ evals++; return class { constructor(v){ this.ok = v; } }; } };
      const v = new a.b(...args);
      console.log(v.ok, evals);
    `,
      ['--target=es5'],
      { ext: 'js' },
    );
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // callee 는 정확히 1회 평가돼야 한다(temp 캡처) — 복제로 두 번 평가하면 `2`.
    expect(r.runOutput.trim()).toBe('7 1');
  });

  test('minify: tagged template tag 의 sequence 는 보존된다 (this 바인딩)', async () => {
    const r = await transpileAndRun(
      `
      const o = { tag(s){ return function(){ this.self = (o === undefined); }; }, self: true };
      const v = new (0, o.tag)\`x\`();
      console.log(typeof v);
    `,
      ['--minify'],
      { ext: 'js' },
    );
    cleanup = r.cleanup;
    expect(r.transpileExitCode).toBe(0);
    // sequence 가 풀리면 `o.tag`x`` → tag 가 this=o 로 호출된다(의미 변화).
    expect(r.runOutput.trim()).toBe('object');
  });

  test('idempotency: 방출물을 다시 transpile 해도 의미가 같다', async () => {
    // 파이프라인이 자기 출력을 다시 읽는 경우(2-pass/번들) 가드. `new (new A().b)()` 는
    // `new new A().b()` 로 방출되는데, 그걸 다시 파싱했을 때 callee 가 `new A().b` 로
    // 유지돼야 한다(예전엔 `new new A()()` + `.b()` 로 재해석 → TypeError).
    const dir = await mkdtemp(join(tmpdir(), 'zntc-4500-'));
    cleanup = async () => rm(dir, { recursive: true, force: true });

    const src = join(dir, 'in.js');
    const out1 = join(dir, 'out1.js');
    const out2 = join(dir, 'out2.js');
    await writeFile(
      src,
      `class A { constructor(){ this.b = class { constructor(){ this.ok = 5; } }; } }\n` +
        `const x = new (new A().b)();\nconsole.log(x.ok);\n`,
    );

    const t1 = await runZntc([src, '-o', out1]);
    expect(t1.exitCode).toBe(0);
    const t2 = await runZntc([out1, '-o', out2]);
    expect(t2.exitCode).toBe(0);

    // runNode 는 exit != 0 이면 throw — 오파싱 시 TypeError 로 여기서 잡힌다.
    const run1 = await runNode(out1);
    const run2 = await runNode(out2);
    expect(run1.stdout.trim()).toBe('5');
    expect(run2.stdout.trim()).toBe('5');
  });
});
