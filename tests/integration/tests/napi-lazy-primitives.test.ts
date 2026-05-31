import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
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

  // #4071 회귀: watch() 가 *디스크에 쓰는* entry 출력이 build() 와 동일하게 동적 import 를
  // `__zntc_load_chunk` 로 재작성해야 한다(raw `import("./heavy")` 가 남으면 안 됨). 버그
  // 원인은 `module_store` 가 주입되는 watch 경로가 `graph.buildIncremental` 을 타는데 거기서
  // `materializeLazySeeds` 가 호출되지 않아 동적 청크가 안 생기던 것. lazySeeds 노출(위 테스트)
  // 만으론 못 잡는다 — 실제 emit 산출물을 검증해야 함.
  test('watch() 가 쓰는 entry 출력이 __zntc_load_chunk 로 재작성됨 (raw import 잔존 금지)', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_4071';`,
      'entry.ts': `async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();`,
    });
    cleanup = fixture.cleanup;
    const outdir = join(fixture.dir, 'out');

    let handle: ReturnType<typeof watch> | undefined;
    const ready = new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('onReady timeout')), 8000);
      handle = watch({
        entryPoints: [join(fixture.dir, 'entry.ts')],
        platform: 'browser',
        devMode: true,
        splitting: true,
        lazyCompilation: true,
        format: 'iife',
        outdir,
        onReady: () => {
          clearTimeout(t);
          resolve();
        },
      });
    });
    try {
      await ready;
      // onReady 이후 디스크에 emit 된 .js 들을 읽어 entry 청크를 찾는다.
      const files = readdirSync(outdir).filter((f) => f.endsWith('.js'));
      const contents = files.map((f) => readFileSync(join(outdir, f), 'utf8'));
      const entry = contents.find((c) => c.includes('__zntc_load_chunk('));
      expect(entry).toBeDefined(); // 동적 청크 로더로 재작성됨 (#4071 핵심 가드)
      // 어떤 청크에도 raw 동적 import 가 남으면 안 된다(런타임에 존재하지 않는 ./heavy fetch).
      for (const c of contents) {
        expect(c).not.toMatch(/import\(["']\.\/heavy["']\)/);
      }
      // heavy 본문은 미파싱 seed → 어느 청크에도 인라인 안 됨.
      expect(contents.some((c) => c.includes('HEAVY_4071'))).toBe(false);
    } finally {
      handle?.stop();
    }
  });

  // PR-C-1: watch() 의 onRebuild 이벤트도 lazySeeds 를 노출(onReady 한정이던 PR-B-1 확장).
  // dev 서버가 rebuild 중 *새로 추가된* 동적 import 의 seed 집합을 갱신할 수 있는 토대 —
  // 없으면 mid-session 에 추가된 lazy 청크가 full-reload 전까지 404.
  test('watch() onRebuild 가 lazySeeds 노출 + 신규 동적 import 가 seed 로 추가됨', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_PRC1';`,
      'extra.ts': `export const x = 'EXTRA_PRC1';`,
      'entry.ts': `async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();`,
    });
    cleanup = fixture.cleanup;
    const entryPath = join(fixture.dir, 'entry.ts');

    let rebuildResolve: ((e: any) => void) | undefined;
    let rebuildEvent: Promise<any> = new Promise((r) => {
      rebuildResolve = r;
    });
    let handle: ReturnType<typeof watch> | undefined;

    const ready = new Promise<any>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('onReady timeout')), 8000);
      handle = watch({
        entryPoints: [entryPath],
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
        onRebuild: (e: any) => {
          rebuildResolve?.(e);
        },
      });
    });
    try {
      const readyEvent = await ready;
      // 초기엔 seed 1개(heavy).
      expect(readyEvent.lazySeeds?.length).toBe(1);

      // entry 에 두 번째 동적 import 추가 → rebuild 트리거.
      writeFileSync(
        entryPath,
        `async function go(){ const m = await import('./heavy'); console.log(m.h); }\n` +
          `async function go2(){ const e = await import('./extra'); console.log(e.x); }\n` +
          `go(); go2();`,
      );

      const rebuild = await Promise.race([
        rebuildEvent,
        new Promise((_r, rej) => setTimeout(() => rej(new Error('onRebuild timeout')), 8000)),
      ]);
      expect(rebuild.success).toBe(true);
      // onRebuild 가 lazySeeds 를 노출해야 함(PR-C-1 핵심).
      expect(Array.isArray(rebuild.lazySeeds)).toBe(true);
      // 이제 동적 import 가 2개 → seed 2개(heavy, extra). 신규 seed 가 갱신돼야.
      expect(rebuild.lazySeeds.length).toBe(2);
      const paths = rebuild.lazySeeds.map((s: any) => s.path);
      expect(paths.some((p: string) => p.endsWith('heavy.ts'))).toBe(true);
      expect(paths.some((p: string) => p.endsWith('extra.ts'))).toBe(true);
      for (const s of rebuild.lazySeeds) {
        expect(s.pathHash).toMatch(/^[0-9a-f]{8}$/);
      }
    } finally {
      handle?.stop();
    }
  });

  // #4074: rebuild 후에도 lazy seed 는 미파싱·emit-skip 으로 유지돼야 한다. cache-hit rebuild 의
  // replay 경로(resolve_imports.replayCachedResolvedDeps)가 동적 import 타겟을 일반 모듈로
  // addModule→파싱→emit 하던 버그 — replay 에도 miss 경로의 lazy 게이트를 적용해 수정. 없으면
  // 무관한 파일 한 번만 편집해도 미요청 lazy 청크가 디스크에 떨어져 laziness 가 사라진다.
  test('#4074: 무관한 파일 편집 rebuild 후에도 lazy seed 청크가 emit-skip 유지', async () => {
    const fixture = await createFixture({
      'heavy.ts': `export const h = 'HEAVY_4074';`,
      'sidecar.ts': `export const s = 'SIDE_A';`,
      'entry.ts':
        `import { s } from './sidecar';\n` +
        `async function go(){ const m = await import('./heavy'); console.log(m.h, s); }\ngo();`,
    });
    cleanup = fixture.cleanup;
    const outdir = join(fixture.dir, 'out');
    const heavyChunkOnDisk = () =>
      readdirSync(outdir).some((f) => /heavy-[0-9a-f]{8}\.js$/.test(f));

    let rebuildResolve: ((e: any) => void) | undefined;
    const rebuilt: Promise<any> = new Promise((r) => {
      rebuildResolve = r;
    });
    let handle: ReturnType<typeof watch> | undefined;
    const ready = new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('onReady timeout')), 8000);
      handle = watch({
        entryPoints: [join(fixture.dir, 'entry.ts')],
        platform: 'browser',
        devMode: true,
        splitting: true,
        lazyCompilation: true,
        format: 'iife',
        outdir,
        onReady: () => {
          clearTimeout(t);
          resolve();
        },
        onRebuild: (e: any) => rebuildResolve?.(e),
      });
    });
    try {
      await ready;
      // 초기: heavy seed 는 emit-skip(디스크에 없음).
      expect(heavyChunkOnDisk()).toBe(false);

      // 동적 import 와 무관한 sidecar.ts 편집 → cache-hit rebuild(entry 는 replay 경로).
      writeFileSync(join(fixture.dir, 'sidecar.ts'), `export const s = 'SIDE_B';`);
      await Promise.race([
        rebuilt,
        new Promise((_r, rej) => setTimeout(() => rej(new Error('onRebuild timeout')), 8000)),
      ]);
      // rebuild flush 여유.
      await new Promise((r) => setTimeout(r, 300));

      // rebuild 가 실제로 돌고 *emit 했음* 을 명시 증명 — entry 청크에 sidecar 새 본문(SIDE_B)이
      // 반영돼야 한다. (이게 없으면 "rebuild 가 아예 안 돌아 heavy 가 없을 뿐" 의 거짓통과 가능.)
      const entryChunk = readdirSync(outdir).find((f) => /^entry.*\.js$/.test(f));
      expect(entryChunk).toBeDefined();
      expect(readFileSync(join(outdir, entryChunk!), 'utf8')).toContain('SIDE_B');

      // 핵심 가드: rebuild 후에도 heavy seed 는 여전히 emit-skip(디스크에 없어야 함).
      expect(heavyChunkOnDisk()).toBe(false);
    } finally {
      handle?.stop();
    }
  });
});
