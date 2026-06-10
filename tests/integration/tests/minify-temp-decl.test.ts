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
