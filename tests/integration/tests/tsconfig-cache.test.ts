// TsconfigCache (#2367) — autodiscover walk 결과 per-process 캐시 검증.
// 다수 파일 in-process transpile 시 같은 답을 매번 재계산하지 않도록.

import { afterAll, afterEach, beforeAll, describe, expect, test } from 'bun:test';
import { join } from 'node:path';
import { TsconfigCache, close, init, transpile } from '../../../packages/core/index';
import { createFixture } from './helpers';

describe('TsconfigCache (#2367)', () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('같은 entry_dir 의 다수 파일은 1 회만 walk', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'src/a.ts': 'export const a = 1;',
      'src/b.ts': 'export const b = 2;',
      'src/c.ts': 'export const c = 3;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    expect(cache.size).toBe(0);

    transpile('export const a = 1;', { filename: join(fixture.dir, 'src/a.ts'), cache });
    transpile('export const b = 2;', { filename: join(fixture.dir, 'src/b.ts'), cache });
    transpile('export const c = 3;', { filename: join(fixture.dir, 'src/c.ts'), cache });

    expect(cache.size).toBe(1); // 같은 dirname → 1 entry
  });

  test('다른 entry_dir 는 각각 캐시', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'src/a.ts': 'export const a = 1;',
      'lib/b.ts': 'export const b = 2;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    transpile('export const a = 1;', { filename: join(fixture.dir, 'src/a.ts'), cache });
    transpile('export const b = 2;', { filename: join(fixture.dir, 'lib/b.ts'), cache });

    expect(cache.size).toBe(2);
  });

  test('clear() 후 size 0', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'src/a.ts': 'export const a = 1;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    transpile('export const a = 1;', { filename: join(fixture.dir, 'src/a.ts'), cache });
    expect(cache.size).toBe(1);

    cache.clear();
    expect(cache.size).toBe(0);
  });

  test('cache 미사용 시 종전 동작 그대로 (regression)', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es5' } }),
      'src/a.ts': 'const x: number = 1;',
    });
    cleanup = fixture.cleanup;

    // cache 인자 없이 호출 — 종전 path 통과 (autodiscover 매번 walk).
    const result = transpile('const x: number = 1;', {
      filename: join(fixture.dir, 'src/a.ts'),
    });
    // es5 downlevel 적용되어야 — autodiscover 가 정상 작동했다는 증거
    expect(result.code).toContain('var x');
  });

  test('tsconfigPath 명시 시 cache 무시', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'alt.json': JSON.stringify({ compilerOptions: { target: 'es5' } }),
      'src/a.ts': 'const x: number = 1;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    // 첫 호출 — cache miss + autodiscover (root tsconfig.json 사용)
    transpile('const x: number = 1;', {
      filename: join(fixture.dir, 'src/a.ts'),
      cache,
    });
    expect(cache.size).toBe(1);

    // 두번째 호출 — tsconfigPath 명시 시 cache 자체가 스킵됨 (size 그대로 1)
    const result = transpile('const x: number = 1;', {
      filename: join(fixture.dir, 'src/a.ts'),
      tsconfigPath: join(fixture.dir, 'alt.json'),
      cache,
    });
    expect(cache.size).toBe(1); // cache 내용 변하지 않음
    expect(result.code).toBeDefined();
  });

  test('tsconfig 없는 디렉토리도 negative 결과 캐시', async () => {
    const fixture = await createFixture({
      // tsconfig 없음
      'a.ts': 'const x: number = 1;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    transpile('const x: number = 1;', { filename: join(fixture.dir, 'a.ts'), cache });
    transpile('const x: number = 1;', { filename: join(fixture.dir, 'a.ts'), cache });

    // negative 도 캐시되므로 1 entry. 두번째 호출은 hit (실제 fs walk 없음).
    expect(cache.size).toBe(1);
  });

  test('transpile 결과는 cache 사용 여부와 무관 (정확성)', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es5' } }),
      'src/a.ts': 'const arrow = (x: number) => x + 1;',
    });
    cleanup = fixture.cleanup;

    const filename = join(fixture.dir, 'src/a.ts');
    const source = 'const arrow = (x: number) => x + 1;';

    const cache = new TsconfigCache();
    const without_cache = transpile(source, { filename });
    const with_cache = transpile(source, { filename, cache });

    expect(with_cache.code).toBe(without_cache.code);
    // es5 target 이 적용되어야 함 (autodiscover 경로가 cache 통해 잘 잡힌 검증)
    expect(with_cache.code).toContain('function');
  });

  test('여러 TsconfigCache 인스턴스는 독립적 state', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'src/a.ts': 'export const a = 1;',
    });
    cleanup = fixture.cleanup;

    const cacheA = new TsconfigCache();
    const cacheB = new TsconfigCache();

    transpile('export const a = 1;', { filename: join(fixture.dir, 'src/a.ts'), cache: cacheA });
    expect(cacheA.size).toBe(1);
    expect(cacheB.size).toBe(0);

    cacheA.clear();
    expect(cacheA.size).toBe(0);

    transpile('export const a = 1;', { filename: join(fixture.dir, 'src/a.ts'), cache: cacheB });
    expect(cacheA.size).toBe(0);
    expect(cacheB.size).toBe(1);
  });

  test('tsconfigRaw 명시 시 cache 미동작 (tsconfigPath 와 같은 정책)', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es5' } }),
      'src/a.ts': 'const x = 1;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    const result = transpile('const x = 1;', {
      filename: join(fixture.dir, 'src/a.ts'),
      tsconfigRaw: '{"compilerOptions":{"target":"es2020"}}',
      cache,
    });

    // tsconfigRaw 가 우선 적용 (raw 가 단일 진실 원천) — autodiscover 자체 미발생.
    // raw 의 target=es2020 이라 const 가 그대로 보존. autodiscover (cache) 의 es5 가
    // 적용됐다면 var 로 변환됐을 것.
    expect(result.code).toContain('const x');
    // raw 경로는 autodiscover 가 트리거되지 않으므로 cache 비어 있어야 함.
    expect(cache.size).toBe(0);
  });

  test('dirname 없는 bare filename 도 안전 처리', async () => {
    // dirname() orelse "." fallback 검증. transpile 자체가 통과하고 cache 가 entry 1 개로 쌓이는지.
    const cache = new TsconfigCache();
    const result = transpile('const x = 1;', { filename: 'input.js', cache });
    expect(result.code).toBeDefined();
    expect(cache.size).toBe(1);
  });

  test('[Symbol.dispose] 사용 시 size 0 (using 구문 호환)', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'src/a.ts': 'export const a = 1;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    transpile('export const a = 1;', { filename: join(fixture.dir, 'src/a.ts'), cache });
    expect(cache.size).toBe(1);

    cache[Symbol.dispose]();
    expect(cache.size).toBe(0);
  });

  test('연속 transpile 100 회 + clear 반복 (메모리 안정성)', async () => {
    const fixture = await createFixture({
      'tsconfig.json': JSON.stringify({ compilerOptions: { target: 'es2020' } }),
      'src/a.ts': 'export const a = 1;',
    });
    cleanup = fixture.cleanup;

    const cache = new TsconfigCache();
    const filename = join(fixture.dir, 'src/a.ts');
    for (let i = 0; i < 100; i++) {
      transpile('export const a = 1;', { filename, cache });
      if (i % 10 === 0) cache.clear();
    }
    // 마지막 clear 가 i=90 이라 그 이후 9 회 채워짐 — 같은 dir 이므로 1.
    expect(cache.size).toBe(1);
  });
});
