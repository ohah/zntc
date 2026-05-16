import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P2: minChunkSize — 너무 작은 common 청크를 도달성 상위집합 청크로 병합
// (Rollup experimentalMinChunkSize 류). over-fetch 없는 안전 규칙
// (src.bits ⊆ dst.bits): 중첩 common ({e1,e2} ⊆ {e1,e2,e3}) 에서 동작.
// 관련: #3321 P2.

// 3 진입점: shared_ab 는 e1,e2 공유(common {e1,e2}),
// shared_abc 는 e1,e2,e3 공유(common {e1,e2,e3}). {e1,e2} ⊆ {e1,e2,e3}.
const fixtureFiles = {
  'shared_ab.ts': `export const ab = "AB_MARKER";`,
  'shared_abc.ts': `export const abc = "ABC_MARKER";`,
  'e1.ts': `import { ab } from './shared_ab';\nimport { abc } from './shared_abc';\nconsole.log(ab, abc, "E1");`,
  'e2.ts': `import { ab } from './shared_ab';\nimport { abc } from './shared_abc';\nconsole.log(ab, abc, "E2");`,
  'e3.ts': `import { abc } from './shared_abc';\nconsole.log(abc, "E3");`,
};

const chunkWith = (outs: { path: string; text: string }[], marker: string) =>
  outs.filter((o) => o.path.endsWith('.js') && o.text.includes(marker));

describe('minChunkSize (small common chunk merging)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  const entryPoints = (dir: string) => [join(dir, 'e1.ts'), join(dir, 'e2.ts'), join(dir, 'e3.ts')];

  test('기본(minChunkSize 미지정): shared_ab 와 shared_abc 는 별도 청크', async () => {
    const fixture = await createFixture(fixtureFiles);
    cleanup = fixture.cleanup;
    const result = await build({ entryPoints: entryPoints(fixture.dir), splitting: true });
    const outs = result.outputFiles!;
    const abChunk = chunkWith(outs, 'AB_MARKER')[0];
    const abcChunk = chunkWith(outs, 'ABC_MARKER')[0];
    expect(abChunk).toBeDefined();
    expect(abcChunk).toBeDefined();
    // 별도 common 청크 → AB 만 든 청크엔 ABC 없음
    expect(abChunk.text).not.toContain('ABC_MARKER');
  });

  test('minChunkSize 큰 값: 작은 common(shared_ab)이 상위 common(shared_abc)으로 병합', async () => {
    const fixture = await createFixture(fixtureFiles);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: entryPoints(fixture.dir),
      splitting: true,
      minChunkSize: 100000,
    });
    const outs = result.outputFiles!;
    // AB 코드는 이제 ABC 와 같은 청크에 — 별도 tiny 청크 사라짐
    const abChunks = chunkWith(outs, 'AB_MARKER');
    expect(abChunks.length).toBeGreaterThanOrEqual(1);
    for (const c of abChunks) expect(c.text).toContain('ABC_MARKER');
    // 두 마커가 함께 있는 단일 청크 존재
    expect(outs.some((o) => o.text.includes('AB_MARKER') && o.text.includes('ABC_MARKER'))).toBe(
      true,
    );
  });

  test('회귀: minChunkSize 가 entry 출력을 깨지 않는다 (E1/E2/E3 모두 실행 가능)', async () => {
    const fixture = await createFixture(fixtureFiles);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: entryPoints(fixture.dir),
      splitting: true,
      minChunkSize: 100000,
    });
    const outs = result.outputFiles!;
    // 세 entry 마커가 모두 출력에 존재 (병합이 코드 누락을 만들지 않음)
    for (const m of ['E1', 'E2', 'E3', 'AB_MARKER', 'ABC_MARKER']) {
      expect(outs.some((o) => o.text.includes(m))).toBe(true);
    }
    // 빈 청크가 OutputFile 로 새지 않음 (병합된 src 는 emit 안 됨)
    expect(outs.every((o) => o.text.trim().length > 0)).toBe(true);
  });

  test('minChunkSize + sourcemap: 병합 후 dangling/빈 청크 참조 없음', async () => {
    const fixture = await createFixture(fixtureFiles);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: entryPoints(fixture.dir),
      splitting: true,
      minChunkSize: 100000,
      sourcemap: true,
    });
    const outs = result.outputFiles!;
    // 모든 출력 비어있지 않음
    expect(outs.every((o) => o.text.trim().length > 0)).toBe(true);
    const allFull = new Set(outs.map((o) => o.path));
    // 각 .map 은 대응 출력이 실제 존재 (병합돼 사라진 청크용 .map 잔존 금지)
    for (const o of outs) {
      if (o.path.endsWith('.map')) {
        expect(allFull.has(o.path.replace(/\.map$/, ''))).toBe(true);
      }
    }
    // cross-chunk import 가 사라진(빈) 청크 파일을 가리키지 않음
    const allPaths = new Set(
      outs.map((o) => o.path.split('/').pop()).filter((p): p is string => !!p),
    );
    for (const o of outs) {
      if (!o.path.endsWith('.js')) continue;
      const specs = [...o.text.matchAll(/from\s*["']\.\/([^"']+)["']/g)].map((m) => m[1]);
      for (const s of specs) {
        if (s.endsWith('.js')) expect(allPaths.has(s)).toBe(true);
      }
    }
    for (const m of ['E1', 'E2', 'E3']) expect(outs.some((o) => o.text.includes(m))).toBe(true);
  });
});
