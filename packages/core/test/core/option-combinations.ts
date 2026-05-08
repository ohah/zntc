import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  vitePlugin,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('옵션 조합 통합 테스트', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-combo-'));
    writeFileSync(
      join(dir, 'app.ts'),
      'import { util } from "./lib";\nDEV: { console.log("debug"); }\nconsole.log(util());',
    );
    writeFileSync(join(dir, 'lib.ts'), 'export function util() { return 42; }');
    writeFileSync(join(dir, 'logo.txt'), 'LOGO_TEXT');
    writeFileSync(
      join(dir, 'with-license.ts'),
      '/** @license Apache-2.0 */\nexport const licensed = "yes";',
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('minify + target + dropLabels 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'app.ts')],
      minify: true,
      target: 'es2020',
      dropLabels: ['DEV'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('debug');
    expect(result.outputFiles[0].text).toContain('42');
  });

  test('sourcemap + sourceRoot + outfile 조합', () => {
    const outfile = join(dir, 'combo-out', 'bundle.js');
    buildSync({
      entryPoints: [join(dir, 'app.ts')],
      sourcemap: true,
      sourceRoot: '/src',
      outfile,
      dropLabels: ['DEV'],
    });
    const map = readFileSync(outfile + '.map', 'utf-8');
    expect(map).toContain('/src');
    expect(map).toContain('mappings');
    rmSync(join(dir, 'combo-out'), { recursive: true, force: true });
  });

  test('loader + packagesExternal 조합', () => {
    writeFileSync(
      join(dir, 'asset-entry.ts'),
      'import logo from "./logo.txt";\nimport React from "react";\nexport { logo, React };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'asset-entry.ts')],
      loader: { '.txt': 'text' },
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('LOGO_TEXT');
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test('splitting + entryNames + chunkNames 조합', async () => {
    writeFileSync(join(dir, 'dyn-entry.ts'), 'export const lazy = () => import("./lib");');
    const result = await build({
      entryPoints: [join(dir, 'dyn-entry.ts')],
      splitting: true,
      entryNames: '[name]',
      chunkNames: 'chunks/[name]-[hash]',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test('legalComments: none + minify 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'with-license.ts')],
      legalComments: 'none',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('@license');
  });

  test('format: cjs + platform: node 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'cjs',
      platform: 'node',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('use strict');
  });

  test('format: iife + globalName 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'iife',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MyLib');
  });

  test('define + alias + inject 조합', () => {
    writeFileSync(join(dir, 'shim.ts'), 'globalThis.__INJECTED__ = true;');
    writeFileSync(
      join(dir, 'define-entry.ts'),
      'import { foo } from "@alias/mod";\nconsole.log(__DEV__, foo);',
    );
    writeFileSync(join(dir, 'real.ts'), 'export const foo = "real";');
    const result = buildSync({
      entryPoints: [join(dir, 'define-entry.ts')],
      define: { __DEV__: 'false' },
      alias: { '@alias/mod': join(dir, 'real.ts') },
      inject: [join(dir, 'shim.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('false');
    expect(result.outputFiles[0].text).toContain('real');
    expect(result.outputFiles[0].text).toContain('__INJECTED__');
  });

  test('write + outdir + metafile 조합', () => {
    const outdir = join(dir, 'meta-out');
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      outdir,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written.length).toBeGreaterThan(0);
    rmSync(outdir, { recursive: true, force: true });
  });

  test('async build + 모든 플러그인 훅 조합', async () => {
    const hooks: string[] = [];
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      dropLabels: ['DEV'],
      plugins: [
        vitePlugin({
          name: 'full-lifecycle',
          resolveId(source) {
            if (source === './lib') {
              hooks.push('resolveId');
              return join(dir, 'lib.ts');
            }
          },
          load(id) {
            if (id.endsWith('lib.ts')) hooks.push('load');
          },
          transform(_code) {
            hooks.push('transform');
          },
          renderChunk(code) {
            hooks.push('renderChunk');
            return `/* built */\n${code}`;
          },
          generateBundle(_outputs) {
            hooks.push('generateBundle');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(hooks).toContain('resolveId');
    expect(hooks).toContain('renderChunk');
    expect(hooks).toContain('generateBundle');
    expect(result.outputFiles[0].text).toContain('/* built */');
  });

  test('allowOverwrite: false → 입력=출력 시 에러', () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'lib.ts')],
        outfile: join(dir, 'lib.ts'),
      }),
    ).toThrow('overwrite');
  });

  test('format: umd + globalName → 글로벌 변수로 실행 가능', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    // 구조 확인
    expect(text).toContain('typeof define === "function"');
    expect(text).toContain('root.MyLib = factory()');
    // 실제 런타임 실행: 글로벌 변수로 접근
    const ctx: Record<string, any> = { self: {} };
    new Function('self', text)(ctx.self);
    expect((ctx.self as any).MyLib).toBeDefined();
    expect((ctx.self as any).MyLib.util()).toBe(42);
  });

  test('format: umd → CJS 모드로 실행 가능', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
      globalName: 'MyLib',
    });
    // CJS 시뮬레이션: module.exports에 할당
    const mod: any = { exports: {} };
    new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.util()).toBe(42);
  });

  test('format: amd → define 콜백으로 실행 가능', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'amd',
    });
    expect(result.errors.length).toBe(0);
    // AMD 시뮬레이션: define(deps, factory) 호출 캡처
    let amdResult: any = null;
    const define: any = (_deps: any, factory: () => any) => {
      amdResult = factory();
    };
    define.amd = true;
    new Function('define', result.outputFiles[0].text)(define);
    expect(amdResult).toBeDefined();
    expect(amdResult.util()).toBe(42);
  });

  test('format: umd (globalName 없음) → factory 직접 실행', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
    });
    expect(result.errors.length).toBe(0);
    // globalName 없으면 "else factory()" 경로
    expect(result.outputFiles[0].text).toContain('else factory()');
    // 에러 없이 실행 가능한지 확인
    const ctx: Record<string, any> = { self: {} };
    expect(() => new Function('self', result.outputFiles[0].text)(ctx.self)).not.toThrow();
  });

  test('format: umd + minify → 압축 후 런타임 실행', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
      globalName: 'M',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    const mod: any = { exports: {} };
    new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.util()).toBe(42);
  });

  test('format: amd + minify → 압축 후 런타임 실행', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'amd',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    let amdResult: any = null;
    const define: any = (_: any, factory: () => any) => {
      amdResult = factory();
    };
    define.amd = true;
    new Function('define', result.outputFiles[0].text)(define);
    expect(amdResult.util()).toBe(42);
  });

  test('format: umd + 다중 export → 모든 export 접근 가능', async () => {
    writeFileSync(
      join(dir, 'multi.ts'),
      'export const a = 1;\nexport const b = 2;\nexport function sum() { return a + b; }',
    );
    const result = await build({
      entryPoints: [join(dir, 'multi.ts')],
      format: 'umd',
      globalName: 'Multi',
    });
    expect(result.errors.length).toBe(0);
    const mod: any = { exports: {} };
    new Function('module', 'exports', result.outputFiles[0].text)(mod, mod.exports);
    expect(mod.exports.a).toBe(1);
    expect(mod.exports.b).toBe(2);
    expect(mod.exports.sum()).toBe(3);
  });

  test('format: umd + sourcemap → 소스맵 생성', async () => {
    const result = await build({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'umd',
      globalName: 'Lib',
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain('mappings');
  });

  test('format: umd + external → 외부 모듈 제외', async () => {
    writeFileSync(join(dir, 'ext.ts'), 'import React from "react";\nexport default React;');
    const result = await build({
      entryPoints: [join(dir, 'ext.ts')],
      format: 'umd',
      globalName: 'App',
      external: ['react'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('require');
  });

  test('format: iife + globalName → 런타임 실행 검증', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'iife',
      globalName: 'ILib',
    });
    expect(result.errors.length).toBe(0);
    new Function('var ILib; ' + result.outputFiles[0].text + ' return ILib;').call(null);
    // IIFE는 var ILib = (function() { ... })(); 형태
    const fn = new Function(result.outputFiles[0].text + '\nreturn ILib;');
    const lib = fn();
    expect(lib.util()).toBe(42);
  });

  test('format: cjs → use strict + 함수 선언 출력', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      format: 'cjs',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
    expect(result.outputFiles[0].text).toContain('function util()');
  });

  test('allowOverwrite: true → 입력=출력 허용', () => {
    const outfile = join(dir, 'overwrite-test.ts');
    writeFileSync(outfile, 'export const z = 1;');
    const result = buildSync({
      entryPoints: [outfile],
      outfile,
      allowOverwrite: true,
    });
    expect(result.errors.length).toBe(0);
    rmSync(outfile, { force: true });
  });
});

// ─── 실제 라이브러리 번들링 테스트 ───
