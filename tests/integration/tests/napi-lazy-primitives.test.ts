import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture, byContent } from './helpers';
import { init, close, build, watch } from '../../../packages/core/index';

// D105 PR-A: NAPI build API 에 lazy on-demand 프리미티브 노출.
// `lazyCompilation` → 동적 import 타겟을 미파싱 seed 로 두고 `lazySeeds: [{pathHash, path}]`
// 반환(entry 의 `__zntc_load_chunk("<stem>-<pathHash>.js")` 와 매칭). `lazyForceParse:[path]`
// → 그 seed 만 즉시 parse(인라인). JS dev 서버가 이 위에서 on-demand 라우팅.

describe('NAPI lazy compilation primitives (D105 PR-A)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  const lazyOpts = (entry: string) => ({
    entryPoints: [entry],
    platform: 'browser' as const,
    devMode: true,
    splitting: true,
    format: 'iife' as const,
    lazyCompilation: true,
  });

  test('lazyCompilation → lazySeeds{pathHash,path} (중복 제거) + entry 가 그 해시로 load_chunk', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_PRA_MARKER';`,
      'entry.ts': `async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();`,
    });
    cleanup = fixture.cleanup;
    const r = await build(lazyOpts(join(fixture.dir, 'entry.ts')));

    expect(r.errors ?? []).toHaveLength(0); // 빌드 성공 가드 — 무음 에러로 false-pass 방지
    expect(r.outputFiles?.length ?? 0).toBeGreaterThan(0);
    expect(r.lazySeeds).toBeDefined();
    expect(r.lazySeeds!.length).toBe(1); // 중복 제거됨
    const seed = r.lazySeeds![0];
    expect(seed.path.endsWith('heavy.ts')).toBe(true);
    expect(seed.pathHash).toMatch(/^[0-9a-f]{8}$/);

    // entry 청크가 그 pathHash 로 동적 청크를 선참조.
    const entry = byContent(r.outputFiles!, '__zntc_load_chunk(');
    expect(entry).toBeDefined();
    const m = entry!.text.match(/__zntc_load_chunk\("([^"]+)"\)/);
    expect(m).not.toBeNull();
    expect(m![1]).toContain(seed.pathHash); // 요청 URL ↔ seed 역참조 정합

    // heavy 본문은 미파싱 seed → 어느 청크에도 인라인 안 됨.
    expect(byContent(r.outputFiles!, 'HEAVY_PRA_MARKER')).toBeUndefined();
  });

  test('lazyForceParse:[seed.path] → 그 seed 즉시 parse(lazySeeds 에서 빠지고 인라인)', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_PRA_MARKER';`,
      'entry.ts': `async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();`,
    });
    cleanup = fixture.cleanup;
    const entry = join(fixture.dir, 'entry.ts');

    const base = await build(lazyOpts(entry));
    expect(base.errors ?? []).toHaveLength(0);
    // force-parse 는 lazySeeds 의 *정확한* path(번들러 해석 절대경로, 예: macOS /private/tmp)
    // 를 받는다. 사용자가 `./heavy` 같은 자기 specifier 를 넘기면 mismatch → 무음 no-op.
    const seedPath = base.lazySeeds![0].path;

    const forced = await build({ ...lazyOpts(entry), lazyForceParse: [seedPath] });
    expect(forced.errors ?? []).toHaveLength(0);
    expect(forced.lazySeeds ?? []).toHaveLength(0); // seed 가 parse 됨 → 목록에서 빠짐
    expect(byContent(forced.outputFiles!, 'HEAVY_PRA_MARKER')).toBeDefined(); // 즉시 parse → 본문 존재
  });

  test('lazyCompilation 미지정 → lazySeeds 없음(기존 단일/스플릿 빌드 불변)', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_PRA_MARKER';`,
      'entry.ts': `async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();`,
    });
    cleanup = fixture.cleanup;
    const r = await build({
      entryPoints: [join(fixture.dir, 'entry.ts')],
      platform: 'browser',
      format: 'iife',
      splitting: true,
    });
    expect(r.lazySeeds ?? []).toHaveLength(0); // 게이트 OFF → seed 노출 안 함
  });

  test('같은 seed 를 두 번 import → lazySeeds 1개 (dedup)', async () => {
    // graph.lazy_seeds 는 같은 타겟을 여러 import record 로 중복 보유할 수 있다.
    // NAPI 경계에서 dedup 하므로 동일 seed 를 여러 번 import 해도 lazySeeds 는 1개여야.
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_PRA_MARKER';`,
      'entry.ts': `async function a(){ return (await import('./heavy')).h; }\nasync function b(){ return (await import('./heavy')).h; }\na(); b();`,
    });
    cleanup = fixture.cleanup;
    const r = await build(lazyOpts(join(fixture.dir, 'entry.ts')));
    expect(r.errors ?? []).toHaveLength(0);
    expect(r.lazySeeds ?? []).toHaveLength(1); // 두 import 가 같은 seed → 1개로 dedup
    expect(r.lazySeeds![0].path.endsWith('heavy.ts')).toBe(true);
  });

  // PR-B-1: watch() 의 onReady 이벤트도 lazySeeds 를 노출(build 결과와 동일 shape/공식,
  // common.buildLazySeedsJs 공용). dev 서버가 watch(lazy)로 HMR 유지하며 on-demand 라우팅하는 토대.
  test('watch() onReady 가 lazySeeds 노출 (HMR 경로용)', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_PRB';`,
      'entry.ts': `async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();`,
    });
    cleanup = fixture.cleanup;

    let handle: ReturnType<typeof watch> | undefined;
    const ready = new Promise<any>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('onReady timeout')), 8000);
      handle = watch({
        entryPoints: [join(fixture.dir, 'entry.ts')],
        platform: 'browser',
        devMode: true,
        splitting: true,
        lazyCompilation: true,
        format: 'iife',
        outdir: join(fixture.dir, 'out'),
        onReady: (e: any) => {
          clearTimeout(t);
          resolve(e);
        },
      });
    });
    try {
      const e = await ready;
      expect(e.lazySeeds).toBeDefined();
      expect(e.lazySeeds.length).toBe(1);
      expect(e.lazySeeds[0].pathHash).toMatch(/^[0-9a-f]{8}$/);
      expect(e.lazySeeds[0].path.endsWith('heavy.ts')).toBe(true);
    } finally {
      handle?.stop();
    }
  });
});
