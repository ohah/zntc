/// #2209 회귀 가드:
/// `--bundle` default (single-file output) 모드에서 dynamic import 자동 lazy-wrap.
/// `--splitting`, `--preserve-modules`, `--no-inline-dynamic-imports` 명시 시 자동 승격
/// 막히도록 분리 정책 우선.

import { describe, test, expect, afterEach } from 'bun:test';
import { spawn } from 'bun';
import { join } from 'node:path';
import { bundleAndRun, createFixture, runZntc } from './helpers';

describe('#2209: dynamic import default lazy-wrap', () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('default single-file 모드: dynamic import 가 lazy wrap 으로 자동 변환', async () => {
    const result = await bundleAndRun(
      {
        'index.ts': `
          async function run() {
            const m = await import("./dyn.ts");
            return m.value;
          }
          run().then(v => console.log(v));
        `,
        'dyn.ts': `
          export const value = "dynamic-loaded";
          console.log("dyn evaluated");
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runStderr).not.toContain('Cannot find module');
    expect(result.runOutput).toBe('dyn evaluated\ndynamic-loaded');
  });

  test('--splitting 모드: 별도 chunk 로 분리 (자동 승격 안 함)', async () => {
    const fixture = await createFixture({
      'index.ts': `
        async function run() {
          const m = await import("./dyn.ts");
          return m.value;
        }
        run().then(v => console.log(v));
      `,
      'dyn.ts': `
        export const value = "dynamic-loaded";
        console.log("dyn evaluated");
      `,
    });
    cleanup = fixture.cleanup;

    const r = await runZntc([
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '--splitting',
      '--outdir',
      join(fixture.dir, 'out'),
      '--format=esm',
      '--platform=node',
    ]);
    expect(r.exitCode).toBe(0);

    const exec = spawn({
      cmd: ['bun', 'run', join(fixture.dir, 'out', 'index.js')],
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const out = (await new Response(exec.stdout).text()).trimEnd();
    expect(out).toBe('dyn evaluated\ndynamic-loaded');
  });

  test('--no-inline-dynamic-imports + single-file 은 명확한 에러', async () => {
    const fixture = await createFixture({
      'index.ts': `
        async function run() {
          const m = await import("./dyn.ts");
          return m.value;
        }
        run().then(v => console.log(v));
      `,
      'dyn.ts': `export const value = "x";`,
    });
    cleanup = fixture.cleanup;

    const r = await runZntc([
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '-o',
      join(fixture.dir, 'out.js'),
      '--no-inline-dynamic-imports',
    ]);

    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain('--no-inline-dynamic-imports');
    expect(r.stderr).toContain('--splitting');
  });

  test('--no-inline-dynamic-imports + --splitting 은 정상 chunk 분리', async () => {
    const fixture = await createFixture({
      'index.ts': `
        async function run() { return (await import("./dyn.ts")).value; }
        run().then(v => console.log(v));
      `,
      'dyn.ts': `export const value = "split-mode";`,
    });
    cleanup = fixture.cleanup;

    const r = await runZntc([
      '--bundle',
      join(fixture.dir, 'index.ts'),
      '--splitting',
      '--outdir',
      join(fixture.dir, 'out'),
      '--format=esm',
      '--platform=node',
      '--no-inline-dynamic-imports',
    ]);
    expect(r.exitCode).toBe(0);

    const exec = spawn({
      cmd: ['bun', 'run', join(fixture.dir, 'out', 'index.js')],
      stdout: 'pipe',
      stderr: 'pipe',
    });
    const out = (await new Response(exec.stdout).text()).trimEnd();
    expect(out).toBe('split-mode');
  });

  // #2211: dynamic target 의 transitive static dep 도 self-contained 하게 처리.
  // 이전엔 single-file path 에 dynamic import 재작성 헬퍼가 없어 외부 sibling
  // 파일로 fallback 됨 (helper 두 번 평가). 이번 fix 후 `Promise.resolve().then(...)`
  // 변환으로 번들 안에서 한 번만 평가.
  test('dynamic target 의 transitive static dep 가 한 번만 평가된다 (#2211)', async () => {
    const result = await bundleAndRun(
      {
        'helper.ts': `
          export const helper = "H-VAL";
          console.log("helper evaluated");
        `,
        'a.ts': `
          import { helper } from "./helper.ts";
          export const a = "A:" + helper;
          console.log("a evaluated");
        `,
        'index.ts': `
          async function run() { return (await import("./a.ts")).a; }
          run().then(v => console.log("entry:", v));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe(['helper evaluated', 'a evaluated', 'entry: A:H-VAL'].join('\n'));
  });

  // side-effect-only dynamic target. exports 없는 모듈은 exports_kind=.none 이라
  // Pass 4 의 `isEsm()` 체크에 걸려 wrap_kind 가 promote 안 됐었음 → rewriter 의
  // `.none` arm fallback → 외부 sibling 파일 의존. fix: `.commonjs` 만 skip 하고
  // `.none` 도 ESM 으로 승격.
  test('side-effect-only dynamic target 도 lazy wrap (외부 sibling fallback 제거)', async () => {
    const result = await bundleAndRun(
      {
        'sfx.ts': `
          console.log("side-effect");
          (globalThis as any).SFX_LOADED = true;
        `,
        'index.ts': `
          async function run() { await import("./sfx.ts"); return (globalThis as any).SFX_LOADED; }
          run().then(v => console.log("entry:", v));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    // side-effect 가 *한 번만* 출력 — 이전엔 두 번 (eager + sibling fallback).
    expect(result.runOutput).toBe(['side-effect', 'entry: true'].join('\n'));
  });

  // CJS dynamic target — Pass 1 의 require 처리에서 wrap_kind=.cjs 로 set 되고
  // rewriter 의 `.cjs` arm 이 `Promise.resolve().then(()=>require_x())` 변환.
  test('CJS dynamic target: require_X() 호출로 변환', async () => {
    const result = await bundleAndRun(
      {
        'dep.cjs': `
          module.exports = { value: "from-cjs" };
          console.log("cjs evaluated");
        `,
        'index.ts': `
          async function run() { return (await import("./dep.cjs")).value; }
          run().then(v => console.log("entry:", v));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe(['cjs evaluated', 'entry: from-cjs'].join('\n'));
  });

  // JSON dynamic target — module_type=.json 도 정상 lazy wrap (default export 로 접근).
  test('JSON dynamic target: default export 접근', async () => {
    const result = await bundleAndRun(
      {
        'data.json': `{ "value": "json-loaded" }`,
        'index.ts': `
          async function run() { return (await import("./data.json")).default.value; }
          run().then(v => console.log("entry:", v));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe('entry: json-loaded');
  });

  // 3-way static cycle 이 dynamic target 안에서 형성된 케이스. dfs 가 dependencies +
  // dynamic_imports 둘 다 따라가야 cycle 의 모든 멤버 (a, b, c) 에 marking + var 강등.
  test('3-way static cycle + dynamic importer (#2211 확장)', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { b } from "./b.ts";
          export const a = "A";
          console.log("a-load:", b);
        `,
        'b.ts': `
          import { c } from "./c.ts";
          export const b = "B";
          console.log("b-load:", c);
        `,
        'c.ts': `
          import { a } from "./a.ts";
          export const c = "C";
          console.log("c-load:", a);
        `,
        'index.ts': `
          async function run() { return (await import("./a.ts")).a; }
          run().then(v => console.log("entry:", v));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runStderr).not.toContain('Cannot access');
    expect(result.runStderr).not.toContain('Cannot find module');
    expect(result.runOutput).toContain('entry: A');
  });

  // #2211 두 번째 케이스: dynamic target 이 다른 모듈과 *static cycle* 을 형성하면
  // cycle marking 이 dynamic edge 도 따라가야 cycle 멤버 모두에 var 강등 (#2198) 적용.
  test('dynamic target + static cycle: 멤버 var 강등으로 TDZ 회피 (#2211)', async () => {
    const result = await bundleAndRun(
      {
        'a.ts': `
          import { b } from "./b.ts";
          export const a = "A";
          console.log("a-load:", b);
        `,
        'b.ts': `
          import { a } from "./a.ts";
          export const b = "B";
          console.log("b-load:", a);
        `,
        'index.ts': `
          async function run() { return (await import("./a.ts")).a; }
          run().then(v => console.log("entry:", v));
        `,
      },
      'index.ts',
      ['--platform=node'],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runStderr).not.toContain('Cannot access');
    expect(result.runStderr).not.toContain('Cannot find module');
    expect(result.runOutput).toContain('entry: A');
  });
});
