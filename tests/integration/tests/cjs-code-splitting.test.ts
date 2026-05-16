import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, byContent, writeOutputs } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P3-B (#3321): format=cjs + splitting=true — 진짜 code splitting.
// 디리스크 스파이크(RFC §6)가 Node CJS 에서 증명한 행동을 빌더 산출물로 영구화:
//   (1) 가드 완화 — cjs+splitting 이 더 이상 CodeSplittingRequiresESM 아님
//   (2) 정적 cross-chunk → require() (ESM import 아님)
//   (3) 동적 import → 별도 청크 파일 + 런타임 로드
//   (4) Node 에서 실제 실행 시 cross-chunk + 동적 로드 + 캐시 보존 동작
// ESM splitting / 단일 CJS 번들 / preserve-modules+cjs(P3-A)는 불변(회귀).

describe('cjs + code splitting (P3-B)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('가드 완화: cjs + splitting 이 에러 아님', async () => {
    const fixture = await createFixture({
      'index.ts': `
        export async function load() { return (await import("./page")).render(); }
        load().then((r) => console.log("R:" + r));
      `,
      'page.ts': `import { label } from "./shared";\nexport function render(){ return label; }`,
      'shared.ts': `export const label = "SHARED_OK";`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'cjs',
      splitting: true,
    });
    expect(result.outputFiles).toBeDefined();
    const js = result.outputFiles!.filter((o) => o.path.endsWith('.js'));
    // 동적 import → 최소 2개 청크(entry + dyn page)
    expect(js.length).toBeGreaterThanOrEqual(2);
  });

  test('스파이크 시나리오: 정적 cross-chunk + 동적 청크 로드가 Node 에서 동작', async () => {
    const fixture = await createFixture({
      'index.ts': `
        import { bump, label } from "./shared";
        async function main() {
          const out = [];
          out.push("static:" + label + ":" + bump());      // shared count=1
          const page = await import("./page");
          out.push("dynamic:" + page.render());             // count=2
          out.push("again:" + page.render());               // count=3 (캐시)
          console.log(out.join("\\n"));
        }
        main();
      `,
      // shared 는 entry + page 양쪽에서 import → common 청크. 상태(count) 보존 검증.
      'shared.ts': `let count = 0;\nexport function bump(){ return ++count; }\nexport const label = "S";`,
      'page.ts': `import { bump, label } from "./shared";\nexport function render(){ return label + ":" + bump(); }`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'cjs',
      splitting: true,
    });
    const outs = result.outputFiles!;
    writeOutputs(
      fixture.dir,
      outs.map((o) => ({ path: o.path, text: o.text })),
    );

    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    expect(entry).toBeDefined();
    // 정적 cross-chunk 결합은 ESM import 가 아니라 require/__zntc_require 경유
    expect(entry.text).not.toMatch(/^\s*import\s+[\{*]/m);

    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe(['static:S:1', 'dynamic:S:2', 'again:S:3'].join('\n'));
  });

  test('default + named export 를 동적 import (entry/dynamic 청크는 emitCjsEntryExports 일임)', async () => {
    // gated form 회귀 가드: dynamic 청크는 entry 모듈이 있어 cross-chunk
    // export 블록을 건너뛰고 emitCjsEntryExports 만 → default/__esModule
    // interop 정확. (이중 emit·module.exports= 손상 #3 방지)
    const fixture = await createFixture({
      'index.ts': `
        import { bump } from "./shared";
        async function main() {
          const o = [];
          o.push("st:" + bump());
          const p = await import("./page");
          o.push("def:" + p.default());
          o.push("tag:" + p.tag);
          o.push("again:" + p.default());
          console.log(o.join("|"));
        }
        main();
      `,
      'shared.ts': `let c = 0;\nexport function bump(){ return ++c; }`,
      'page.ts': `import { bump } from "./shared";\nexport default function(){ return "D" + bump(); }\nexport const tag = "PG";`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'cjs',
      splitting: true,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const page = outs.find((o) => o.path.includes('page') && o.path.endsWith('.js'))!;
    // dynamic 청크는 CJS interop: exports.default + __esModule, ESM export 없음
    expect(page.text).toContain('exports.default');
    expect(page.text).toContain('__esModule');
    expect(page.text).not.toMatch(/^\s*export[\s{]/m);

    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe('st:1|def:D2|tag:PG|again:D3');
  });

  test('회귀: esm + splitting 은 native import() 그대로', async () => {
    const fixture = await createFixture({
      'index.ts': `export async function load(){ return (await import("./d")).v; }`,
      'd.ts': `export const v = 1;`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
      splitting: true,
    });
    const idx = byContent(result.outputFiles!, 'load')!;
    expect(idx.text).not.toContain('__zntc_load_chunk');
    expect(idx.text).not.toContain('require(');
  });

  test('회귀: 단일 CJS 번들(splitting 아님)은 불변', async () => {
    const fixture = await createFixture({
      'dep.ts': `export const dep = "DEP_X";`,
      'index.ts': `import { dep } from "./dep";\nconsole.log(dep);`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'cjs',
    });
    const single = byContent(result.outputFiles!, 'DEP_X')!;
    expect(single).toBeDefined();
    expect(single.text).not.toContain('__zntc_load_chunk');
  });
});
