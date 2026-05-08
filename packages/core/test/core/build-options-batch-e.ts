import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  buildSync,
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('배치 E: S급 BuildOptions', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-batch-e-'));
    writeFileSync(join(dir, 'entry.ts'), 'DEV: { console.log("dev only"); }\nexport const x = 1;');
    writeFileSync(
      join(dir, 'pure-test.ts'),
      'import { pureUtil } from "./util";\nconst unused = pureUtil();\nexport const y = 2;',
    );
    writeFileSync(join(dir, 'util.ts'), 'export function pureUtil() { return 42; }');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('packagesExternal: bare import를 external 처리', () => {
    writeFileSync(join(dir, 'ext-entry.ts'), 'import React from "react";\nexport default React;');
    const result = buildSync({
      entryPoints: [join(dir, 'ext-entry.ts')],
      packagesExternal: true,
    });
    expect(result.errors.length).toBe(0);
    // react가 external이므로 번들에 포함되지 않고 import 문이 유지됨
    expect(result.outputFiles[0].text).toMatch(/import.*react|require.*react/);
  });

  test('dropLabels: DEV 라벨 제거', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      dropLabels: ['DEV'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('dev only');
    expect(result.outputFiles[0].text).toContain('x = 1');
  });

  test('pure: 미사용 순수 함수 호출 제거', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'pure-test.ts')],
      pure: ['pureUtil'],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('2');
  });

  test('lineLimit: 줄 길이 제한', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      lineLimit: 40,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('preserveSymlinks: 옵션 파싱 확인', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      preserveSymlinks: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('ignoreAnnotations: @__PURE__ annotation 무시', () => {
    writeFileSync(
      join(dir, 'ignore-annotations.ts'),
      "function side(){ console.log('PURE_CALL'); }\n/* @__PURE__ */ side();\nconsole.log('live');",
    );
    const result = buildSync({
      entryPoints: [join(dir, 'ignore-annotations.ts')],
      ignoreAnnotations: true,
      minifySyntax: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('side()');
    expect(result.outputFiles[0].text).toContain('PURE_CALL');
  });

  test('jsxSideEffects: unused JSX expression 보존', () => {
    writeFileSync(
      join(dir, 'jsx-side-effects.tsx'),
      [
        'const React = { createElement(type) { console.log(type); } };',
        '<div />;',
        "console.log('live');",
      ].join('\n'),
    );
    const result = buildSync({
      entryPoints: [join(dir, 'jsx-side-effects.tsx')],
      jsxSideEffects: true,
      minifySyntax: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('React.createElement');
  });

  test('analyze: metafile 강제 활성화', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      analyze: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
  });

  test('nodePaths: 추가 탐색 경로', () => {
    const vendor = join(dir, 'vendor');
    mkdirSync(join(vendor, 'pkg'), { recursive: true });
    writeFileSync(join(vendor, 'pkg', 'package.json'), JSON.stringify({ main: 'index.js' }));
    writeFileSync(join(vendor, 'pkg', 'index.js'), "export const value = 'NODE_PATH_VALUE';");
    writeFileSync(join(dir, 'node-paths.ts'), "import { value } from 'pkg'; console.log(value);");
    const result = buildSync({
      entryPoints: [join(dir, 'node-paths.ts')],
      nodePaths: [vendor],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('NODE_PATH_VALUE');
  });

  test('intro/outro/globals: output wrapper 옵션 적용', () => {
    writeFileSync(
      join(dir, 'globals.ts'),
      "import { useState } from 'react'; console.log(useState);",
    );
    const result = buildSync({
      entryPoints: [join(dir, 'globals.ts')],
      format: 'iife',
      globalName: 'Lib',
      external: ['react'],
      globals: { react: 'React' },
      intro: "console.log('intro');",
      outro: "console.log('outro');",
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain("console.log('intro');");
    expect(text).toContain("console.log('outro');");
    expect(text).toContain('})(React);');
  });

  test('outbase: 엔트리 공통 기준 경로', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outbase: dir,
    });
    expect(result.errors.length).toBe(0);
  });

  test('sourceRoot: 소스맵 sourceRoot', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
      sourceRoot: 'https://example.com/src',
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain('https://example.com/src');
  });
});

// ─── 나머지 BundleOptions 전체 노출 테스트 ───
