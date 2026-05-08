import {
  afterAll,
  beforeAll,
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from './helpers';

describe('@zntc/core buildSync - basic output', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-build-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'import { hello } from "./util";\nconsole.log(hello("world"));',
    );
    writeFileSync(
      join(dir, 'util.ts'),
      'export function hello(name: string): string { return `Hello, ${name}!`; }',
    );
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('기본 번들링', () => {
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('hello');
    expect(result.outputFiles[0].text).toContain('Hello');
  });

  test('browser bundle defaults process.env.NODE_ENV to production', () => {
    const nodeEnvDir = mkdtempSync(join(tmpdir(), 'zntc-napi-node-env-'));
    writeFileSync(join(nodeEnvDir, 'entry.ts'), 'console.log(process.env.NODE_ENV);');
    const result = buildSync({ entryPoints: [join(nodeEnvDir, 'entry.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"production"');
    expect(result.outputFiles[0].text).not.toContain('process.env.NODE_ENV');
    rmSync(nodeEnvDir, { recursive: true, force: true });
  });

  test('react-native bundle defaults __DEV__ and NODE_ENV from devMode', () => {
    const rnDir = mkdtempSync(join(tmpdir(), 'zntc-napi-rn-env-'));
    writeFileSync(join(rnDir, 'entry.ts'), 'console.log(__DEV__, process.env.NODE_ENV);');
    const result = buildSync({
      entryPoints: [join(rnDir, 'entry.ts')],
      platform: 'react-native',
      devMode: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('true');
    expect(result.outputFiles[0].text).toContain('"development"');
    expect(result.outputFiles[0].text).not.toContain('__DEV__');
    expect(result.outputFiles[0].text).not.toContain('process.env.NODE_ENV');
    rmSync(rnDir, { recursive: true, force: true });
  });

  test('CJS 포맷', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      format: 'cjs',
    });
    expect(result.outputFiles[0].text).toContain('use strict');
  });

  test('minify', () => {
    const normal = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    const minified = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      minify: true,
    });
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
  });

  test('소스맵 생성', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
    });
    // 소스맵이 별도 outputFile로 포함
    expect(result.outputFiles.length).toBe(2);
    const smFile = result.outputFiles.find((f) => f.path.endsWith('.map'));
    expect(smFile).toBeDefined();
    const map = JSON.parse(smFile!.text);
    expect(map.version).toBe(3);
  });

  test('metafile 생성', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      metafile: true,
    });
    expect(result.metafile).toBeDefined();
    const meta = JSON.parse(result.metafile!);
    expect(meta.outputs).toBeDefined();
  });

  test('에러 반환', () => {
    const badDir = mkdtempSync(join(tmpdir(), 'zntc-napi-err-'));
    writeFileSync(join(badDir, 'bad.ts'), 'import { x } from "./nonexistent";\nconsole.log(x);');
    const result = buildSync({ entryPoints: [join(badDir, 'bad.ts')] });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(badDir, { recursive: true, force: true });
  });

  test('external', () => {
    const extDir = mkdtempSync(join(tmpdir(), 'zntc-napi-ext-'));
    writeFileSync(join(extDir, 'app.ts'), 'import React from "react";\nconsole.log(React);');
    const result = buildSync({
      entryPoints: [join(extDir, 'app.ts')],
      external: ['react'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('react');
    rmSync(extDir, { recursive: true, force: true });
  });
});
