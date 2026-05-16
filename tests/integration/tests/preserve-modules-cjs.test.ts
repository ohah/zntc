import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P3-A (#3321): preserve-modules + format=cjs — 모듈 1:1 파일, cross-module
// 결합은 require()/module.exports (Node 네이티브 require 가 경로로 해석).
// code splitting 없음(전부 빌드타임 known). ESM preserve-modules / 단일
// CJS 번들 경로는 불변(회귀).

const byContent = (outs: { path: string; text: string }[], needle: string) =>
  outs.find((o) => o.text.includes(needle));

describe('preserve-modules + cjs (P3-A)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  const files = {
    'dep.ts': `export const dep = "DEP_MARKER";`,
    'index.ts': `import { dep } from "./dep";\nexport function main(){ return dep + "!"; }\nconsole.log(main());`,
  };

  test('모듈당 파일 분리 + cross-module require() + exports', async () => {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      preserveModules: true,
      format: 'cjs',
    });
    const outs = result.outputFiles!;
    const js = outs.filter((o) => o.path.endsWith('.js'));
    // 모듈 1:1 → index, dep 두 파일
    expect(js.length).toBeGreaterThanOrEqual(2);

    const idx = byContent(outs, 'function main');
    const dep = byContent(outs, 'DEP_MARKER');
    expect(idx).toBeDefined();
    expect(dep).toBeDefined();

    // index: cross-module 는 ESM import 아닌 require()
    expect(idx!.text).toContain('require("');
    expect(idx!.text).not.toMatch(/^\s*import\s/m);
    expect(idx!.text).toContain('exports.main');
    // dep: CJS export
    expect(dep!.text).toContain('exports.dep');
    expect(dep!.text).not.toMatch(/^\s*export\s/m);
  });

  test('minify + side-effect import: require("..."); 가 닫힘(괄호 누락 없음)', async () => {
    const fixture = await createFixture({
      'side.ts': `console.log("SIDE_FX");`,
      'index.ts': `import "./side";\nexport const ok = 1;`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      preserveModules: true,
      format: 'cjs',
      minifyWhitespace: true,
    });
    const idx = byContent(result.outputFiles!, 'exports.ok')!;
    expect(idx).toBeDefined();
    // side-effect require 가 well-formed: require("...."); (괄호+세미콜론)
    expect(idx.text).toMatch(/require\("[^"]+"\);/);
    // 잘못된 형태 require("...."; (괄호 누락) 가 없어야 함
    expect(idx.text).not.toMatch(/require\("[^"]+";/);
  });

  test('회귀: preserve-modules + esm 는 ESM import/export 그대로', async () => {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      preserveModules: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    const idx = byContent(outs, 'function main')!;
    expect(idx.text).toMatch(/import\s*\{\s*dep\s*\}\s*from/);
    expect(idx.text).not.toContain('require("');
  });

  test('회귀: 단일 CJS 번들(preserve-modules 아님)은 불변', async () => {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'cjs',
    });
    const outs = result.outputFiles!;
    // 단일 번들 — DEP_MARKER 와 main 이 한 파일에
    const single = byContent(outs, 'DEP_MARKER')!;
    expect(single).toBeDefined();
    expect(single.text).toContain('function main');
  });
});
