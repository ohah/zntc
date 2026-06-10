// #4218: bundle + minify 에서 ?\./??/논리할당 lowering 의 합성 temp (`var _a`)
// 선언이 tree-shake 로 오삭제되거나(--minify-syntax) 선언만 rename 되던
// (--minify-identifiers) 회귀 가드. bun 은 출력을 ESM(strict)으로 실행하므로
// 미선언 `_a` 할당이 즉시 ReferenceError 로 드러난다 (node CJS sloppy 는 은폐).
import { describe, test, expect, afterEach } from 'bun:test';
import { bundleAndRun } from './helpers';

describe('#4218: bundle+minify 합성 temp 선언 보존', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  const SRC = [
    'const o = { a: { b: 1 } } as any;',
    'console.log(o.a?.b);',
    "console.log(o.x ?? 'd');",
  ].join('\n');

  for (const flag of ['--minify', '--minify-syntax', '--minify-identifiers']) {
    test(`optional chain + nullish (es2017, ${flag})`, async () => {
      const result = await bundleAndRun({ 'index.ts': SRC }, 'index.ts', ['--target=es2017', flag]);
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('1\nd');
    });
  }

  test('논리할당 ??= (es2020, --minify)', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': [
          'const g = () => ({} as any);',
          'g().x ??= 5;',
          'const h: any = {};',
          'h.y ||= 7;',
          'console.log(h.y);',
        ].join('\n'),
      },
      'index.ts',
      ['--target=es2020', '--minify'],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('7');
  });

  test('es5 destructuring temp 관례 가드 (--minify)', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': [
          'const o = { a: 1, b: 2, c: 3 } as any;',
          'const { a, ...rest } = o;',
          'console.log(a, Object.keys(rest).length);',
        ].join('\n'),
      },
      'index.ts',
      ['--target=es5', '--minify'],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('1 2');
  });

  test('사용자 _a/_b 식별자와 temp 충돌 회피 (#4220)', async () => {
    // 회귀: makeTempVarSpan 이 private-field 만 회피 — 사용자 const _a 에
    // temp 대입(TypeError) / minify 시 선언·사용 오결합.
    const result = await bundleAndRun(
      {
        'index.ts': [
          'const _a = 99;',
          'const o = { a: { b: 1 } } as any;',
          'console.log(o.a?.b, _a);',
          'function f(x: any) { const _b = 5; return (x?.y ?? -1) + _b; }',
          'console.log(f({ y: 2 }), f(null));',
        ].join('\n'),
      },
      'index.ts',
      ['--target=es2017', '--minify'],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('1 99\n7 4');
  });

  for (const flags of [['--target=es2017'], ['--target=es2017', '--minify']] as string[][]) {
    test(`함수가 outer _a 를 읽을 때 hoist shadow 금지 (#4220, ${flags.join(' ')})`, async () => {
      // 회귀: hoist 가 skip 된 인덱스 이름(var _a)을 함수 본문에 선언해
      // outer 사용자 _a 를 shadow → undefined 읽기 silent miscompile.
      const result = await bundleAndRun(
        {
          'index.ts': [
            'let _a = 90; _a += 9;',
            "function g(o: any) { return _a + ':' + (o.a?.b ?? 'd'); }",
            'console.log(g({ a: { b: 1 } }), g({}));',
          ].join('\n'),
        },
        'index.ts',
        flags,
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('99:1 99:d');
    });
  }

  test('private field WeakMap _a 와 hoist shadow 금지 (#1485 보완)', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': [
          'class C { #a = 5; m(o: any) { return String(this.#a) + ":" + (o.a?.b ?? "d"); } }',
          'const c = new C();',
          'console.log(c.m({ a: { b: 1 } }), c.m({}));',
        ].join('\n'),
      },
      'index.ts',
      ['--target=es2017'],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('5:1 5:d');
  });

  test('함수 스코프 내부 temp + --minify (es2017)', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': [
          'function f(o: any) { return o.a?.b ?? -1; }',
          'console.log(f({ a: { b: 2 } }), f({}));',
        ].join('\n'),
      },
      'index.ts',
      ['--target=es2017', '--minify'],
    );
    cleanup = result.cleanup;
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('2 -1');
  });
});
