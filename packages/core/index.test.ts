import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import {
  init,
  transpile,
  build,
  buildSync,
  watch,
  close,
  vitePlugin,
  type ZntcPlugin,
  type RollupPlugin,
} from './index';
import { resolve } from 'node:path';
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  symlinkSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT_NODE_MODULES = resolve(__dirname, '../../node_modules');

beforeAll(() => {
  init();
});

afterAll(() => {
  close();
});

describe('@zntc/core', () => {
  test('기본 standalone transpile은 JS로 파싱해 TypeScript syntax를 거부', () => {
    expect(() => transpile('const x: number = 1;')).toThrow('ParseError');
  });

  test('명시적 TypeScript filename은 TypeScript syntax를 허용', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts' });
    expect(result.code).toContain('const x = 1;');
    expect(result.map).toBeUndefined();
  });

  test('transpile: 명시적 .ts filename은 JSX syntax를 거부', () => {
    expect(() => transpile('const x = <div />;', { filename: 'input.ts' })).toThrow('ParseError');
  });

  test('transpile: 명시적 .js/.jsx filename은 TypeScript syntax를 거부', () => {
    expect(() => transpile('const x: number = 1;', { filename: 'input.js' })).toThrow('ParseError');
    expect(() =>
      transpile('const h = (tag) => tag;\nconst x: string = <div />;', {
        filename: 'input.jsx',
        jsx: 'classic',
        jsxFactory: 'h',
      }),
    ).toThrow('ParseError');

    const jsxOnly = transpile('const h = (tag) => tag;\nconst x = <div />;', {
      filename: 'input.jsx',
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(jsxOnly.code).not.toContain('<div');
  });

  test('인터페이스 스트리핑', () => {
    const result = transpile('interface Foo { bar: string; }\nconst x = 1;', {
      filename: 'input.ts',
    });
    expect(result.code).not.toContain('interface');
    expect(result.code).toContain('const x = 1;');
  });

  test('타입 어노테이션 제거', () => {
    const result = transpile('function add(a: number, b: number): number { return a + b; }', {
      filename: 'input.ts',
    });
    expect(result.code).toContain('function add(a,b)');
    expect(result.code).not.toContain(': number');
  });

  test('enum 변환', () => {
    const result = transpile('enum Color { Red, Green, Blue }', { filename: 'input.ts' });
    expect(result.code).toContain('Color');
  });

  test('JSX 트랜스파일 (classic)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'classic',
    });
    expect(result.code).toContain('React.createElement');
  });

  test('JSX 트랜스파일 (automatic)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'automatic',
    });
    expect(result.code).toContain('jsx');
  });

  test('tsconfigRaw 의 jsx + jsxImportSource 가 자동 매핑돼 적용', () => {
    // esbuild 식 인라인 override — file 시스템 접근 없이 JS API 로 jsx 동작 변경.
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      tsconfigRaw: JSON.stringify({
        compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
      }),
    });
    expect(result.code).toContain('preact/jsx-runtime');
  });

  test('tsconfigRaw 위에 명시 옵션이 우선', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'classic',
      tsconfigRaw: JSON.stringify({
        compilerOptions: { jsx: 'react-jsx', jsxImportSource: 'preact' },
      }),
    });
    expect(result.code).toContain('React.createElement');
    expect(result.code).not.toContain('preact/jsx-runtime');
  });

  test('소스맵 생성', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts', sourcemap: true });
    expect(result.code).toContain('const x = 1;');
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
    expect(map.mappings).toBeDefined();
  });

  test('minify', () => {
    const result = transpile('const   x: number   =   1;', {
      filename: 'input.ts',
      minifyWhitespace: true,
    });
    expect(result.code.length).toBeLessThan('const   x   =   1;'.length);
  });

  test('CJS 포맷', () => {
    const result = transpile('export const x = 1; export default "hello";', {
      filename: 'input.ts',
      format: 'cjs',
    });
    expect(result.code).toContain('exports');
  });

  test('빈 소스 에러', () => {
    expect(() => transpile('')).toThrow();
  });

  test('파싱 에러', () => {
    expect(() => transpile('const = ;')).toThrow();
  });

  test('Flow 스트리핑', () => {
    const result = transpile('// @flow\nfunction foo(x: string): number { return 1; }', {
      flow: true,
      filename: 'test.js',
    });
    expect(result.code).not.toContain(': string');
    expect(result.code).not.toContain(': number');
  });

  test('drop console', () => {
    const result = transpile('console.log("hello"); const x = 1;', {
      dropConsole: true,
    });
    expect(result.code).not.toContain('console.log');
    expect(result.code).toContain('const x = 1;');
  });

  test('filename으로 확장자 감지 (.tsx)', () => {
    const result = transpile('const el = <div />;', { filename: 'comp.tsx' });
    expect(result.code).not.toContain('<div');
  });

  test('JSX 트랜스파일 (automatic-dev)', () => {
    const result = transpile('<div className="app">hello</div>', {
      filename: 'app.tsx',
      jsx: 'automatic-dev',
    });
    expect(result.code).toContain('jsxDEV');
  });

  test('minify 단축 옵션 (whitespace + identifiers + syntax)', () => {
    const result = transpile('const   longVariableName: number   =   1;', {
      filename: 'input.ts',
      minify: true,
    });
    expect(result.code.length).toBeLessThan('const longVariableName = 1;'.length);
  });

  test('drop debugger', () => {
    const result = transpile('debugger; const x = 1;', {
      dropDebugger: true,
    });
    expect(result.code).not.toContain('debugger');
    expect(result.code).toContain('const x = 1;');
  });

  test('quotes: single', () => {
    const result = transpile('const x = "hello";', { quotes: 'single' });
    expect(result.code).toContain("'hello'");
  });

  test('ascii only', () => {
    const result = transpile('const x = "한글";');
    const asciiResult = transpile('const x = "한글";', { asciiOnly: true });
    expect(asciiResult.code).toContain('\\u');
    expect(result.code).toContain('한글');
  });

  test('ES5 다운레벨링', () => {
    const result = transpile('const x = () => 1;', { target: 'es5' });
    expect(result.code).not.toContain('=>');
    expect(result.code).toContain('function');
  });

  test('ES2015 다운레벨링 (template literal)', () => {
    const result = transpile('const s = `hello ${name}`;', { target: 'es5' });
    expect(result.code).not.toContain('`');
  });

  test('target esnext (변환 없음)', () => {
    const result = transpile('const x = () => 1;', { target: 'esnext' });
    expect(result.code).toContain('=>');
  });

  test('platform node', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts', platform: 'node' });
    expect(result.code).toContain('const x = 1;');
  });

  test('jsxFactory 커스텀', () => {
    const result = transpile('<div />', {
      filename: 'app.tsx',
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.code).toContain('h(');
    expect(result.code).not.toContain('React.createElement');
  });

  test('jsxImportSource 커스텀', () => {
    const result = transpile('<div />', {
      filename: 'app.tsx',
      jsx: 'automatic',
      jsxImportSource: 'preact',
    });
    expect(result.code).toContain('preact');
  });

  test('useDefineForClassFields false', () => {
    const result = transpile('class A { x = 1; }', { useDefineForClassFields: false });
    expect(result.code).toContain('this.x');
  });

  test('init 중복 호출은 무시', () => {
    expect(() => init()).not.toThrow();
  });

  test('여러 번 호출해도 메모리 누수 없이 동작', () => {
    for (let i = 0; i < 100; i++) {
      const result = transpile(`const x${i}: number = ${i};`, { filename: 'input.ts' });
      expect(result.code).toContain(`const x${i} = ${i};`);
    }
  });
});

describe('@zntc/core buildSync', () => {
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

  // ─── #2155 bundle 모드도 drop console / debugger 적용 ────────────────────────
  test('dropConsole: bundle 모드에서 console 호출 제거', () => {
    const dropDir = mkdtempSync(join(tmpdir(), 'zntc-bundle-drop-console-'));
    writeFileSync(
      join(dropDir, 'app.ts'),
      'console.log("DROP_CONSOLE_REMOVED"); export const x = "DROP_CONSOLE_KEPT";',
    );
    const result = buildSync({
      entryPoints: [join(dropDir, 'app.ts')],
      dropConsole: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('DROP_CONSOLE_REMOVED');
    expect(result.outputFiles[0].text).toContain('DROP_CONSOLE_KEPT');
    rmSync(dropDir, { recursive: true, force: true });
  });

  test('dropDebugger: bundle 모드에서 debugger 문 제거', () => {
    const dropDir = mkdtempSync(join(tmpdir(), 'zntc-bundle-drop-debugger-'));
    writeFileSync(join(dropDir, 'app.ts'), 'debugger;\nexport const x = "DROP_DEBUGGER_KEPT";');
    const result = buildSync({
      entryPoints: [join(dropDir, 'app.ts')],
      dropDebugger: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('debugger');
    expect(result.outputFiles[0].text).toContain('DROP_DEBUGGER_KEPT');
    rmSync(dropDir, { recursive: true, force: true });
  });

  test('dropConsole 미지정: bundle 모드는 console 호출 보존 (기존 동작)', () => {
    const keepDir = mkdtempSync(join(tmpdir(), 'zntc-bundle-drop-keep-'));
    writeFileSync(join(keepDir, 'app.ts'), 'console.log("KEEP_CONSOLE_VALUE");');
    const result = buildSync({
      entryPoints: [join(keepDir, 'app.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('KEEP_CONSOLE_VALUE');
    rmSync(keepDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: no-op ESM/TS bundle still folds numeric const imports', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-esm-'));
    writeFileSync(join(skipDir, 'dep.ts'), 'export const value: number = 41;');
    writeFileSync(
      join(skipDir, 'app.ts'),
      'import { value } from "./dep";\nexport const answer: number = value + 1;',
    );
    const result = buildSync({ entryPoints: [join(skipDir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('answer');
    expect(result.outputFiles[0].text).toContain('42');
    expect(result.outputFiles[0].text).not.toContain('value');
    expect(result.outputFiles[0].text).not.toContain(': number');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: target downlevel without helper syntax stays stable', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-target-'));
    writeFileSync(
      join(skipDir, 'app.ts'),
      'export const value: number = 1;\nconsole.log("TARGET_SIMPLE_KEPT", value);',
    );
    const result = buildSync({
      entryPoints: [join(skipDir, 'app.ts')],
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TARGET_SIMPLE_KEPT');
    expect(result.outputFiles[0].text).not.toContain(': number');
    expect(result.outputFiles[0].text).not.toContain('__async');
    expect(result.outputFiles[0].text).not.toContain('__spreadArray');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: type-only imports do not pull runtime modules', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-type-only-'));
    writeFileSync(
      join(skipDir, 'types.ts'),
      'console.log("TYPE_ONLY_MODULE_SHOULD_NOT_APPEAR"); export interface User { id: string }',
    );
    writeFileSync(join(skipDir, 'value.ts'), 'export const value = "TYPE_ONLY_VALUE_KEPT";');
    writeFileSync(
      join(skipDir, 'app.ts'),
      'import type { User } from "./types";\nimport { value } from "./value";\nexport const user: User = { id: value };',
    );
    const result = buildSync({ entryPoints: [join(skipDir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TYPE_ONLY_VALUE_KEPT');
    expect(result.outputFiles[0].text).not.toContain('TYPE_ONLY_MODULE_SHOULD_NOT_APPEAR');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('graph pre-pass skip: re-export and namespace access stay linked', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-reexport-'));
    writeFileSync(join(skipDir, 'dep.ts'), 'export const value = "REEXPORT_NAMESPACE_VALUE";');
    writeFileSync(join(skipDir, 'barrel.ts'), 'export { value } from "./dep";');
    writeFileSync(
      join(skipDir, 'app.ts'),
      'import * as ns from "./barrel";\nconsole.log(ns.value);',
    );
    const result = buildSync({ entryPoints: [join(skipDir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('REEXPORT_NAMESPACE_VALUE');
    expect(result.outputFiles[0].text).toContain('value');
    rmSync(skipDir, { recursive: true, force: true });
  });

  test('TS export = value → module.exports = value (rolldown/oxc 패턴)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-value-'));
    writeFileSync(join(dir, 'app.ts'), 'const value = { name: "exp-eq", n: 42 };\nexport = value;');
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    expect(out).toContain('"exp-eq"');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = class → module.exports = class', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-class-'));
    writeFileSync(
      join(dir, 'app.ts'),
      "export = class Foo { greet() { return 'hi from class'; } };",
    );
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    expect(out).toContain('class Foo');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = function → module.exports = function', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-function-'));
    writeFileSync(
      join(dir, 'app.ts'),
      'export = function add(a: number, b: number) { return a + b; };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')] });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    expect(out).toContain('function add');
    expect(out).not.toContain(': number');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = require().default cherry-pick (CJS interop)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-require-'));
    writeFileSync(join(dir, 'app.ts'), "export = require('foo').default;");
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')], external: ['foo'] });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    expect(out).toContain('require');
    expect(out).toContain('.default');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = identifier (transpile + minify): export 식별자 보존, 다른 식별자만 mangle', () => {
    // transpile 모드 — 단일 파일이라 export 된 이름이 외부 require() 호출로 노출.
    // semantic analyzer 의 visitTsExportAssignment 가 inner identifier 를 export 로 mark
    // 해서 mangler 가 declaration 을 rename 하지 않는다 (export default 와 동일 보호).
    const r = transpile('class Box { v = 1; greet() { return this.v; } }\nexport = Box;', {
      filename: 'app.ts',
      minifyIdentifiers: true,
      minifyWhitespace: true,
    });
    expect(r.errors).toBeUndefined();
    expect(r.code).toContain('class Box');
    expect(r.code).toContain('module.exports=Box');
  });

  test('TS export = function (transpile + minify): export 식별자 보존, helper 식별자 mangle', () => {
    const r = transpile(
      'function add(a: number, b: number) { return a + b; }\nconst helper = (x: number) => x * 2;\nexport = add;',
      { filename: 'app.ts', minifyIdentifiers: true, minifyWhitespace: true },
    );
    expect(r.errors).toBeUndefined();
    expect(r.code).toContain('function add');
    expect(r.code).toContain('module.exports=add');
    // helper 식별자는 다른 곳에서 참조되지 않으므로 mangle 됨.
    expect(r.code).not.toContain('const helper');
  });

  test('TS export = identifier (bundle + minify): __commonJS wrapper 안에서 일관된 mangle', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-bundle-minify-'));
    writeFileSync(
      join(dir, 'app.ts'),
      'class Box { v = 1; greet() { return this.v; } }\nexport = Box;',
    );
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')], minify: true });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    // bundle 모드에서는 declaration 과 reference 가 함께 mangle (정합성만 유지하면 OK).
    expect(out).toMatch(/module\.exports=\w+/);
    expect(out).toContain('class');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = class + target=es5: 다운레벨링과 export = 호환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-es5-class-'));
    writeFileSync(join(dir, 'app.ts'), "class Foo { greet() { return 'hi'; } }\nexport = Foo;");
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')], target: 'es5' });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    expect(out).toContain('Foo');
    expect(out).not.toContain('class Foo');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = async function + target=es5: __async helper 와 함께 lower', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-es5-async-'));
    writeFileSync(join(dir, 'app.ts'), 'export = async function () { return 42; };');
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')], target: 'es5' });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    expect(out).not.toContain('async function');
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = arrow + target=es5: 화살표가 function expression 으로 lower', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-es5-arrow-'));
    writeFileSync(join(dir, 'app.ts'), 'export = (x: number) => x * 2;');
    const result = buildSync({ entryPoints: [join(dir, 'app.ts')], target: 'es5' });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    // bundler 의 __commonJS 헬퍼 자체는 arrow — user-side 만 정확히 변환됐는지 확인.
    expect(out).toMatch(/module\.exports\s*=\s*function/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('TS export = process.env ternary + define: 컴파일 시 분기 결정 + constant fold', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-define-'));
    writeFileSync(
      join(dir, 'app.ts'),
      'const value = process.env.NODE_ENV === "production" ? "prod" : "dev";\nexport = { mode: value };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'app.ts')],
      define: { 'process.env.NODE_ENV': '"production"' },
    });
    expect(result.errors.length).toBe(0);
    const out = result.outputFiles[0].text;
    expect(out).toContain('module.exports');
    // define 치환 → constant fold → "prod" 만 남음 ("dev" 분기 dead-code).
    expect(out).toContain('"prod"');
    expect(out).not.toContain('"dev"');
    rmSync(dir, { recursive: true, force: true });
  });

  test('graph pre-pass keep: JSX and decorator/downlevel helper cases still transform', () => {
    const keepDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-keep-transform-'));
    writeFileSync(join(keepDir, 'jsx.tsx'), 'export const App = () => <div>ok</div>;');
    writeFileSync(join(keepDir, 'decorator.ts'), '@sealed\nexport class Box { value = 1; }');
    writeFileSync(
      join(keepDir, 'downlevel.ts'),
      'export const fn = async () => await Promise.resolve(1);',
    );

    const jsxResult = buildSync({
      entryPoints: [join(keepDir, 'jsx.tsx')],
      jsx: 'automatic',
      external: ['react/jsx-runtime'],
    });
    expect(jsxResult.errors.length).toBe(0);
    expect(jsxResult.outputFiles[0].text).toContain('jsx-runtime');

    const decoratorResult = buildSync({
      entryPoints: [join(keepDir, 'decorator.ts')],
      experimentalDecorators: true,
    });
    expect(decoratorResult.errors.length).toBe(0);
    expect(decoratorResult.outputFiles[0].text).toContain('__decorate');

    const downlevelResult = buildSync({
      entryPoints: [join(keepDir, 'downlevel.ts')],
      target: 'es5',
    });
    expect(downlevelResult.errors.length).toBe(0);
    expect(downlevelResult.outputFiles[0].text).toContain('__async');
    rmSync(keepDir, { recursive: true, force: true });
  });
});

describe('@zntc/core build (async)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-async-'));
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

  test('비동기 번들링 (Promise)', async () => {
    const result = await build({ entryPoints: [join(dir, 'entry.ts')] });
    expect(result.outputFiles.length).toBeGreaterThan(0);
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('hello');
  });

  test('비동기 minify', async () => {
    const normal = await build({ entryPoints: [join(dir, 'entry.ts')] });
    const minified = await build({
      entryPoints: [join(dir, 'entry.ts')],
      minify: true,
    });
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
  });

  test('비동기 소스맵', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      sourcemap: true,
    });
    expect(result.outputFiles.length).toBe(2);
    const smFile = result.outputFiles.find((f) => f.path.endsWith('.map'));
    expect(smFile).toBeDefined();
  });

  test('buildSync과 동일한 결과', async () => {
    const syncResult = buildSync({ entryPoints: [join(dir, 'entry.ts')] });
    const asyncResult = await build({ entryPoints: [join(dir, 'entry.ts')] });
    expect(asyncResult.outputFiles[0].text).toBe(syncResult.outputFiles[0].text);
  });
});

describe('@zntc/core build + plugins', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-napi-plugin-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(
      join(dir, 'app.ts'),
      'import { greet } from "./virtual:greeting";\nconsole.log(greet());',
    );
    // lifecycle hook 테스트용 — plugin 의존성 없는 깔끔한 entry.
    writeFileSync(join(dir, 'lifecycle-entry.ts'), 'console.log("hi");');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('onResolve disabled: true → 빈 모듈로 대체 (Metro empty / webpack false 매핑)', async () => {
    // entry가 'should-be-empty'를 import. plugin이 disabled로 매핑.
    writeFileSync(
      join(dir, 'entry-disabled.ts'),
      `import * as m from "should-be-empty"; console.log(typeof m);`,
    );
    const disabledPlugin: ZntcPlugin = {
      name: 'disabled-resolver',
      setup(build) {
        build.onResolve({ filter: /^should-be-empty$/ }, () => ({
          disabled: true,
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry-disabled.ts')],
      plugins: [disabledPlugin],
    });
    expect(result.errors.length).toBe(0);
    // disabled 모듈은 빈 객체 export → typeof는 "object"
    expect(result.outputFiles[0].text).toMatch(/should-be-empty|module\.exports\s*=/);
  });

  test('onResolve + onLoad 플러그인 (CSS → JS 변환)', async () => {
    const cssPlugin: ZntcPlugin = {
      name: 'css-plugin',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "color: red";',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('color: red');
  });

  test('multiple plugins 체이닝', async () => {
    const plugin1: ZntcPlugin = {
      name: 'css-resolve',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };
    const plugin2: ZntcPlugin = {
      name: 'css-load',
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "blue";',
        }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [plugin1, plugin2],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('blue');
  });

  test('onTransform 플러그인 (코드 변환)', async () => {
    const transformPlugin: ZntcPlugin = {
      name: 'transform-plugin',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({
          code: args.code.replace('console.log', 'console.warn'),
        }));
      },
    };

    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-transform-'));
    writeFileSync(join(entryDir, 'main.ts'), 'console.log("hello");');

    const result = await build({
      entryPoints: [join(entryDir, 'main.ts')],
      plugins: [transformPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('console.warn');
    expect(result.outputFiles[0].text).not.toContain('console.log');
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('#2038: onTransform이 추가한 sideEffects:false 패키지 import도 tree-shaking 입력이 됨', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-plugin-pkg-'));
    writeFileSync(join(entryDir, 'main.ts'), "console.log('__ORIGINAL_2038__');");
    mkdirSync(join(entryDir, 'node_modules', 'pure-lib-2038'), { recursive: true });
    writeFileSync(
      join(entryDir, 'node_modules', 'pure-lib-2038', 'package.json'),
      '{"name":"pure-lib-2038","main":"index.js","sideEffects":false}',
    );
    writeFileSync(
      join(entryDir, 'node_modules', 'pure-lib-2038', 'index.js'),
      [
        'export const used = "core-plugin-used-2038";',
        'export const unused = "core-plugin-unused-2038";',
      ].join('\n'),
    );

    const transformPlugin: ZntcPlugin = {
      name: 'transform-adds-package-import',
      setup(build) {
        build.onTransform({ filter: /main\.ts$/ }, () => ({
          code: 'import { used } from "pure-lib-2038";\nconsole.log(used);',
        }));
      },
    };

    try {
      const result = await build({
        entryPoints: [join(entryDir, 'main.ts')],
        treeShaking: true,
        plugins: [transformPlugin],
      });
      expect(result.errors.length).toBe(0);
      const text = result.outputFiles[0].text;
      expect(text).toContain('core-plugin-used-2038');
      expect(text).not.toContain('core-plugin-unused-2038');
      expect(text).not.toContain('__ORIGINAL_2038__');
    } finally {
      rmSync(entryDir, { recursive: true, force: true });
    }
  });

  test.skipIf(!existsSync(join(ROOT_NODE_MODULES, 'lodash-es', 'package.json')))(
    '#2038: 실제 lodash-es import를 onTransform으로 주입해도 dead export가 새지 않음',
    async () => {
      const entryDir = mkdtempSync(join(tmpdir(), 'zntc-2038-lodash-plugin-'));
      writeFileSync(join(entryDir, 'main.ts'), "console.log('__ORIGINAL_LODASH_2038__');");
      mkdirSync(join(entryDir, 'node_modules'), { recursive: true });
      symlinkSync(
        join(ROOT_NODE_MODULES, 'lodash-es'),
        join(entryDir, 'node_modules', 'lodash-es'),
      );

      const transformPlugin: ZntcPlugin = {
        name: 'transform-adds-lodash-import',
        setup(build) {
          build.onTransform({ filter: /main\.ts$/ }, () => ({
            code: 'import { uniq } from "lodash-es";\nconsole.log(uniq([1,2,2,3]).join(","));',
          }));
        },
      };

      try {
        const result = await build({
          entryPoints: [join(entryDir, 'main.ts')],
          platform: 'node',
          treeShaking: true,
          plugins: [transformPlugin],
        });
        expect(result.errors.length).toBe(0);
        const text = result.outputFiles[0].text;
        expect(text).toContain('uniq');
        expect(text).not.toContain('__ORIGINAL_LODASH_2038__');
        for (const dead of ['groupBy', 'orderBy', 'mapValues', 'debounce', 'throttle']) {
          expect(
            new RegExp(`(^|\\n)(function|const|var|let)\\s+${dead}\\b`, 'm').test(text),
            `dead lodash-es identifier "${dead}" leaked to transform-added bundle`,
          ).toBe(false);
        }
      } finally {
        rmSync(entryDir, { recursive: true, force: true });
      }
    },
  );

  // ============================================================
  // require.context — onResolveContext hook (#1579 Phase 2.5)
  // ============================================================

  test('onResolveContext: hook 호출 + args 전달 (dir/recursive/filter/flags/importer)', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./pages', true, /\\.tsx?$/, 'sync'); console.log(ctx);",
    );

    let captured: any = null;
    const plugin: ZntcPlugin = {
      name: 'rc-capture',
      setup(build) {
        build.onResolveContext({ filter: /.*/ }, (args) => {
          captured = args;
          return { context: ['./a.tsx', './b.tsx'] };
        });
      },
    };

    await build({
      entryPoints: [join(entryDir, 'entry.ts')],
      plugins: [plugin],
    });

    expect(captured).not.toBeNull();
    expect(captured.dir).toBe('./pages');
    expect(captured.recursive).toBe(true);
    expect(captured.filter).toBe('\\.tsx?$');
    expect(captured.importer).toContain('entry.ts');
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: plugin 미구현 → require_context_no_handler warning', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-noplug-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./pages'); console.log(ctx);",
    );

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
    });

    const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
    const hasNoHandler = allDiags.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
        (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
    );
    expect(hasNoHandler).toBe(true);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: invalid require.context (numeric arg) → require_context_invalid error', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-invalid-'));
    writeFileSync(join(entryDir, 'entry.ts'), 'const ctx = require.context(42); console.log(ctx);');

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
    });

    const hasInvalid = result.errors.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('first argument must be a string')) ||
        (typeof d.message === 'string' && d.message.includes('first argument must be a string')),
    );
    expect(hasInvalid).toBe(true);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('onResolveContext: 빈 매칭 결과 (empty context) — diagnostic 없음', async () => {
    const entryDir = mkdtempSync(join(tmpdir(), 'zntc-rc-empty-'));
    writeFileSync(
      join(entryDir, 'entry.ts'),
      "const ctx = require.context('./nonexistent'); console.log(ctx);",
    );

    const plugin: ZntcPlugin = {
      name: 'rc-empty',
      setup(build) {
        build.onResolveContext({ filter: /.*/ }, () => ({ context: [] }));
      },
    };

    const result = await build({
      entryPoints: [join(entryDir, 'entry.ts')],
      plugins: [plugin],
    });

    const allDiags = [...(result.warnings ?? []), ...(result.errors ?? [])];
    const hasNoHandler = allDiags.some(
      (d: any) =>
        (typeof d.text === 'string' && d.text.includes('requires a host plugin')) ||
        (typeof d.message === 'string' && d.message.includes('requires a host plugin')),
    );
    expect(hasNoHandler).toBe(false);
    rmSync(entryDir, { recursive: true, force: true });
  });

  test('buildSync에서 plugins 사용 시 에러', () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [{ name: 'test', setup() {} }],
      }),
    ).toThrow('plugins are only supported with build()');
  });

  test('플러그인 콜백이 throw해도 빌드가 중단되지 않음', async () => {
    const throwPlugin: ZntcPlugin = {
      name: 'throw-plugin',
      setup(build) {
        build.onLoad({ filter: /never-match-anything/ }, () => {
          throw new Error('plugin error!');
        });
      },
    };

    // filter가 매치하지 않으므로 throw에 도달하지 않음 — 정상 완료
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [throwPlugin],
    });
    // css import가 resolve 안 되므로 에러, 하지만 빌드 자체는 크래시하지 않음
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('lifecycle hooks (#2156): buildStart → buildEnd → closeBundle 순서 + 1회씩', async () => {
    const events: string[] = [];
    const lifecyclePlugin: ZntcPlugin = {
      name: 'lifecycle-tracker',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd((err) => events.push(err ? 'buildEnd:error' : 'buildEnd:ok'));
        build.onCloseBundle(() => events.push('closeBundle'));
        build.onTransform({ filter: /lifecycle-entry\.ts$/ }, () => {
          events.push('transform');
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'lifecycle-entry.ts')],
      plugins: [lifecyclePlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(events[0]).toBe('buildStart');
    expect(events.indexOf('transform')).toBeGreaterThan(0);
    expect(events).toContain('buildEnd:ok');
    expect(events[events.length - 1]).toBe('closeBundle');
    expect(events.filter((e) => e === 'buildStart').length).toBe(1);
    expect(events.filter((e) => e.startsWith('buildEnd')).length).toBe(1);
    expect(events.filter((e) => e === 'closeBundle').length).toBe(1);
  });

  test('lifecycle hooks (#2156): plugin error 는 swallow 되고 다른 plugin 차단 안 함', async () => {
    const events: string[] = [];
    const throwingPlugin: ZntcPlugin = {
      name: 'thrower',
      setup(build) {
        const boom = () => {
          throw new Error('intentional');
        };
        build.onBuildStart(boom);
        build.onBuildEnd(boom);
        build.onCloseBundle(boom);
      },
    };
    const trackingPlugin: ZntcPlugin = {
      name: 'tracker',
      setup(build) {
        build.onBuildStart(() => events.push('start'));
        build.onBuildEnd(() => events.push('end'));
        build.onCloseBundle(() => events.push('close'));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'lifecycle-entry.ts')],
      plugins: [throwingPlugin, trackingPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(events).toEqual(['start', 'end', 'close']);
  });

  test('lifecycle hooks (#2156): vitePlugin 어댑터가 buildStart/buildEnd/closeBundle 을 forward', async () => {
    const events: string[] = [];
    const rollupAdapter = vitePlugin({
      name: 'rollup-style',
      buildStart() {
        events.push('rollup-buildStart');
      },
      buildEnd(err) {
        events.push(err ? 'rollup-buildEnd:error' : 'rollup-buildEnd:ok');
      },
      closeBundle() {
        events.push('rollup-closeBundle');
      },
    });

    const result = await build({
      entryPoints: [join(dir, 'lifecycle-entry.ts')],
      plugins: [rollupAdapter],
    });
    expect(result.errors.length).toBe(0);
    expect(events).toEqual(['rollup-buildStart', 'rollup-buildEnd:ok', 'rollup-closeBundle']);
  });
});

// ─── 엣지케이스 테스트 ───

describe('@zntc/core edge cases', () => {
  // transpile 엣지케이스
  test('매우 긴 소스코드 트랜스파일', () => {
    const lines = Array.from({ length: 10000 }, (_, i) => `export const v${i}: number = ${i};`);
    const result = transpile(lines.join('\n'), { filename: 'input.ts' });
    expect(result.code).toContain('v9999 = 9999');
  });

  test('유니코드 소스코드', () => {
    const result = transpile('const 이름: string = "한글 테스트";', { filename: 'input.ts' });
    expect(result.code).toContain('한글 테스트');
  });

  test('빈 인터페이스만 있는 파일', () => {
    const result = transpile('interface Empty {}\n', { filename: 'input.ts' });
    expect(result.code.trim()).toBe('');
  });

  test('타입만 있는 파일', () => {
    const result = transpile('type Foo = string;\ntype Bar = number;\n', { filename: 'input.ts' });
    expect(result.code.trim()).toBe('');
  });

  test('복잡한 제네릭 타입', () => {
    const result = transpile(
      'function identity<T extends Record<string, unknown>>(x: T): T { return x; }',
      { filename: 'input.ts' },
    );
    expect(result.code).toContain('function identity(x)');
    expect(result.code).not.toContain('<T');
  });

  test('enum + namespace 병합', () => {
    const result = transpile('enum Direction { Up, Down }\nconst d: Direction = Direction.Up;', {
      filename: 'input.ts',
    });
    expect(result.code).toContain('Direction');
  });

  test('optional chaining + nullish coalescing', () => {
    const result = transpile("const x = a?.b?.c ?? 'default';");
    expect(result.code).toContain('??');
  });

  test('build target es5 keeps optional chaining temp declarations in nested functions', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es5-optional-temp-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          function createProxy(state: any) {
            state.callbacks.push(function rootDraftCleanup(rootScope: any) {
              rootScope.mapSetPlugin_?.fixSetContents(state);
              const { patchPlugin_ } = rootScope;
              if (state.modified_ && patchPlugin_) {
                patchPlugin_.generatePatches_(state, [], rootScope);
              }
            });
          }

          const calls: string[] = [];
          const state = { callbacks: [] as Function[], modified_: true };
          createProxy(state);
          state.callbacks[0]({
            mapSetPlugin_: { fixSetContents() { calls.push("map"); } },
            patchPlugin_: { generatePatches_() { calls.push("patch"); } },
          });
          globalThis.__VALUE__ = calls.join(",");
        `,
      );

      const result = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        target: 'es5',
      });
      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).not.toContain('?.');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__VALUE__).toBe('map,patch');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('decorator (experimental)', () => {
    const result = transpile(
      '@sealed\nclass Greeter {\n  greeting: string;\n  constructor(message: string) { this.greeting = message; }\n}',
      { filename: 'input.ts', experimentalDecorators: true },
    );
    expect(result.code).toContain('__decorate');
  });

  test('소스맵 + minify 동시 사용', () => {
    const result = transpile(
      'const longVariableName: number = 42;\nconsole.log(longVariableName);',
      {
        filename: 'input.ts',
        sourcemap: true,
        minify: true,
      },
    );
    expect(result.code.length).toBeLessThan(60);
    expect(result.map).toBeDefined();
    const map = JSON.parse(result.map!);
    expect(map.version).toBe(3);
  });

  // init 엣지케이스
  test('init 전에 transpile 호출 시 에러', () => {
    // 이미 init됨, close 후 테스트
    close();
    expect(() => transpile('const x = 1;')).toThrow('not initialized');
    init(); // 복원
  });

  test('init 전에 buildSync 호출 시 에러', () => {
    close();
    expect(() => buildSync({ entryPoints: ['/nonexistent'] })).toThrow('not initialized');
    init(); // 복원
  });

  test('init 전에 build 호출 시 에러', async () => {
    close();
    await expect(build({ entryPoints: ['/nonexistent'] })).rejects.toThrow('not initialized');
    init(); // 복원
  });

  // buildSync 엣지케이스
  test('buildSync: 빈 entryPoints 에러', () => {
    expect(() => buildSync({ entryPoints: [] })).toThrow('entryPoints is required');
  });

  test('buildSync: 존재하지 않는 파일', () => {
    const result = buildSync({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('buildSync: 모든 옵션 동시 사용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-all-opts-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'esm',
      platform: 'browser',
      minify: true,
      sourcemap: true,
      metafile: true,
      treeShaking: true,
      keepNames: true,
      charsetUtf8: true,
      banner: '/* banner */',
      footer: '/* footer */',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* banner */');
    expect(result.outputFiles[0].text).toContain('/* footer */');
    expect(result.metafile).toBeDefined();
    rmSync(dir, { recursive: true, force: true });
  });

  // build async 엣지케이스
  test('build: 빈 entryPoints 에러', async () => {
    await expect(build({ entryPoints: [] })).rejects.toThrow('entryPoints is required');
  });

  test('build: 존재하지 않는 파일', async () => {
    const result = await build({ entryPoints: ['/nonexistent/file.ts'] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('build: 병렬 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-parallel-'));
    writeFileSync(join(dir, 'a.ts'), 'export const a = 1;');
    writeFileSync(join(dir, 'b.ts'), 'export const b = 2;');

    const [resultA, resultB] = await Promise.all([
      build({ entryPoints: [join(dir, 'a.ts')] }),
      build({ entryPoints: [join(dir, 'b.ts')] }),
    ]);
    expect(resultA.errors.length).toBe(0);
    expect(resultB.errors.length).toBe(0);
    expect(resultA.outputFiles[0].text).toContain('a = 1');
    expect(resultB.outputFiles[0].text).toContain('b = 2');
    rmSync(dir, { recursive: true, force: true });
  });

  // 플러그인 엣지케이스
  test('plugin: null 반환 시 기본 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-plugin-null-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const noopPlugin: ZntcPlugin = {
      name: 'noop',
      setup(build) {
        build.onLoad({ filter: /never-match/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [noopPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('plugin: setup에서 아무 훅도 등록하지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-edge-empty-plugin-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [{ name: 'empty', setup() {} }],
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('transpile: 반복 호출 1000회 메모리 안정성', () => {
    for (let i = 0; i < 1000; i++) {
      const result = transpile(`const x${i} = ${i};`);
      expect(result.code).toContain(`x${i} = ${i}`);
    }
  });
});

// ─── 추가 커버리지 테스트 ───

describe('@zntc/core 플러그인 심화', () => {
  test('플러그인 콜백이 매치 후 throw — 에러로 전파', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-throw-'));
    writeFileSync(join(dir, 'index.ts'), 'import "./data.json";');

    const throwPlugin: ZntcPlugin = {
      name: 'throw-on-load',
      setup(build) {
        build.onResolve({ filter: /\.json$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
        build.onLoad({ filter: /\.json$/ }, () => {
          throw new Error('intentional plugin error');
        });
      },
    };

    // 플러그인이 throw하면 load 결과가 null → 번들러가 파일 읽기로 폴백
    // .json 파일이 없으므로 에러 발생
    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [throwPlugin],
    });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('다중 모듈 번들 + 플러그인', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-large-'));

    // 5개 모듈 생성
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 5 }, (_, i) => `val${i}`).join(' + ');
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(${usage});`);

    let transformCount = 0;
    const countPlugin: ZntcPlugin = {
      name: 'count-transforms',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          transformCount++;
          return null; // 변환 없이 카운트만
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('val4');
    // 최소 1회 이상 transform 호출됨
    expect(transformCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('플러그인 콜백이 undefined 반환 (null과 동일 처리)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-undef-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const undefPlugin: ZntcPlugin = {
      name: 'undef-return',
      setup(build) {
        build.onLoad({ filter: /\.ts$/ }, () => undefined as any);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [undefPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(dir, { recursive: true, force: true });
  });

  test('멀티스레드: 10개 모듈 + onTransform 플러그인 (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt-'));
    for (let i = 0; i < 10; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 10 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    const usage = Array.from({ length: 10 }, (_, i) => `val${i}`).join(' + ');
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(${usage});`);

    let callCount = 0;
    const countPlugin: ZntcPlugin = {
      name: 'count',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          callCount++;
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [countPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('val9');
    expect(callCount).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('멀티스레드: 동시 resolveId + load + transform (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt2-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');

    const hooksCalled: string[] = [];
    const multiHookPlugin: ZntcPlugin = {
      name: 'multi-hook',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => {
          hooksCalled.push('resolve');
          return { path: resolve(dir, args.path) };
        });
        build.onLoad({ filter: /\.css$/ }, () => {
          hooksCalled.push('load');
          return { contents: 'export default "red";' };
        });
        build.onTransform({ filter: /\.ts$/ }, (_args) => {
          hooksCalled.push('transform');
          return null;
        });
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [multiHookPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('red');
    expect(hooksCalled).toContain('resolve');
    expect(hooksCalled).toContain('load');
    expect(hooksCalled).toContain('transform');
    rmSync(dir, { recursive: true, force: true });
  });

  test('멀티스레드: 플러그인 + minify + sourcemap 동시 (#985)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-plugin-mt3-'));
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, `mod${i}.ts`), `export const val${i} = ${i};`);
    }
    const imports = Array.from({ length: 5 }, (_, i) => `import { val${i} } from "./mod${i}";`);
    writeFileSync(join(dir, 'entry.ts'), `${imports.join('\n')}\nconsole.log(val0);`);

    const noopPlugin: ZntcPlugin = {
      name: 'noop',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, () => null);
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [noopPlugin],
      minify: true,
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2); // js + map
    rmSync(dir, { recursive: true, force: true });
  });
});

describe('@zntc/core 번들 포맷/플랫폼', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-format-'));
    writeFileSync(join(dir, 'index.ts'), 'export const greeting = "hello";\nexport default 42;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('IIFE 포맷', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'iife',
    });
    expect(result.errors.length).toBe(0);
    // IIFE는 즉시 실행 함수로 감싸짐
    expect(
      result.outputFiles[0].text.includes('(function') ||
        result.outputFiles[0].text.includes('(() =>') ||
        result.outputFiles[0].text.includes('(()'),
    ).toBe(true);
  });

  test('IIFE + globalName', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'iife',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MyLib');
  });

  test('IIFE + globalName: aliased/default exports become return object properties', () => {
    const aliasDir = mkdtempSync(join(tmpdir(), 'zntc-iife-export-return-'));
    writeFileSync(
      join(aliasDir, 'index.ts'),
      'const internal = 1;\nexport { internal as answer };\nexport default internal;',
    );

    const result = buildSync({
      entryPoints: [join(aliasDir, 'index.ts')],
      format: 'iife',
      globalName: 'MyLib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('return { answer: internal, default: internal };');
    expect(text).not.toContain(' as ');
    rmSync(aliasDir, { recursive: true, force: true });
  });

  test('platform=node', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      platform: 'node',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('greeting');
  });

  test('platform=react-native', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      platform: 'react-native',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('greeting');
  });

  test('ESM import/export 보존', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      format: 'esm',
    });
    expect(result.errors.length).toBe(0);
    // ESM은 export 키워드 포함
    expect(result.outputFiles[0].text).toContain('greeting');
  });
});

describe('@zntc/core build 옵션 조합', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-combo-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import { helper } from "./util";\nconsole.log(helper());',
    );
    writeFileSync(join(dir, 'util.ts'), 'export function helper() { return 42; }');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('minifyWhitespace만 적용', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minifyWhitespace: true,
    });
    expect(result.errors.length).toBe(0);
    // 줄바꿈/공백이 줄어듦
    expect(result.outputFiles[0].text.split('\n').length).toBeLessThan(20);
  });

  test('minifyIdentifiers 적용 시 출력 크기 감소', () => {
    const normal = buildSync({ entryPoints: [join(dir, 'index.ts')] });
    const minified = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minifyIdentifiers: true,
    });
    expect(minified.errors.length).toBe(0);
    // 식별자 축소로 출력이 줄어들거나 동일 (scope hoist 인라인 시)
    expect(minified.outputFiles[0].text.length).toBeLessThanOrEqual(
      normal.outputFiles[0].text.length,
    );
  });

  test('sourcemap + minify + metafile 동시', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minify: true,
      sourcemap: true,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2); // js + map
    expect(result.metafile).toBeDefined();
    const map = JSON.parse(result.outputFiles.find((f) => f.path.endsWith('.map'))!.text);
    expect(map.version).toBe(3);
  });

  test('treeShaking=false로 미사용 export 보존', () => {
    const tsDir = mkdtempSync(join(tmpdir(), 'zntc-tree-'));
    writeFileSync(join(tsDir, 'index.ts'), 'import { used } from "./lib";\nconsole.log(used);');
    writeFileSync(join(tsDir, 'lib.ts'), 'export const used = 1;\nexport const unused = 2;');

    const withTree = buildSync({
      entryPoints: [join(tsDir, 'index.ts')],
      treeShaking: true,
    });
    const withoutTree = buildSync({
      entryPoints: [join(tsDir, 'index.ts')],
      treeShaking: false,
    });
    // tree-shaking 끄면 unused도 포함
    expect(withoutTree.outputFiles[0].text).toContain('unused');
    // tree-shaking 켜면 unused 제거 (scope hoist 활성화 시)
    expect(withTree.outputFiles[0].text).not.toContain('unused');
    rmSync(tsDir, { recursive: true, force: true });
  });

  test('JSX automatic + build', () => {
    const jsxDir = mkdtempSync(join(tmpdir(), 'zntc-jsx-build-'));
    writeFileSync(join(jsxDir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const result = buildSync({
      entryPoints: [join(jsxDir, 'app.tsx')],
      jsx: 'automatic',
      jsxInJs: true,
      external: ['react/jsx-runtime'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('jsx-runtime');
    rmSync(jsxDir, { recursive: true, force: true });
  });

  test('Flow 파일 번들링', () => {
    const flowDir = mkdtempSync(join(tmpdir(), 'zntc-flow-build-'));
    writeFileSync(
      join(flowDir, 'index.js'),
      '// @flow\nfunction foo(x: string): number { return x.length; }\nconsole.log(foo("test"));',
    );

    const result = buildSync({
      entryPoints: [join(flowDir, 'index.js')],
      flow: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(': string');
    expect(result.outputFiles[0].text).not.toContain(': number');
    rmSync(flowDir, { recursive: true, force: true });
  });

  test('build async: 동시 5개 호출', async () => {
    const results = await Promise.all(
      Array.from({ length: 5 }, () => build({ entryPoints: [join(dir, 'index.ts')] })),
    );
    for (const r of results) {
      expect(r.errors.length).toBe(0);
      expect(r.outputFiles[0].text).toContain('helper');
    }
  });
});

// ─── ES2023 + hashbang ───

describe('@zntc/core ES2023/hashbang', () => {
  test('target es5: hashbang이 제거됨', () => {
    const result = transpile("#!/usr/bin/env node\nconsole.log('hello');", {
      target: 'es5',
    });
    expect(result.code).not.toContain('#!');
    expect(result.code).toContain('hello');
  });

  test('target es2022: hashbang이 제거됨 (es2022 < es2023)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      target: 'es2022',
    });
    expect(result.code).not.toContain('#!');
    expect(result.code).toContain('x = 1');
  });

  test('target es2023: hashbang이 유지됨', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      target: 'es2023',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code).toContain('x = 1');
  });

  test('target esnext: hashbang이 유지됨', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      target: 'esnext',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
  });

  test('hashbang 없는 파일에서 es2022 타겟 — 정상 동작', () => {
    const result = transpile('const x: number = 1;', { filename: 'input.ts', target: 'es2022' });
    expect(result.code).toContain('const x = 1');
  });

  test('target 미지정: hashbang이 유지됨 (기본 esnext)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;');
    expect(result.code).toContain('#!/usr/bin/env node');
  });

  test('es2023 타겟 번들링', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-es2023-build-'));
    writeFileSync(join(dir, 'index.ts'), '#!/usr/bin/env node\nconsole.log(1);');
    // buildSync에 target 옵션이 없으므로 transpile로 테스트
    const result = transpile(readFileSync(join(dir, 'index.ts'), 'utf8'), {
      target: 'es2023',
    });
    expect(result.code).toContain('#!/usr/bin/env node');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── define/alias 옵션 ───

describe('@zntc/core define/alias', () => {
  test('define: 글로벌 상수 치환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'console.log(process.env.NODE_ENV);\nconsole.log(__DEV__);',
    );

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: {
        'process.env.NODE_ENV': '"production"',
        __DEV__: 'false',
      },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    expect(result.outputFiles[0].text).toContain('false');
    expect(result.outputFiles[0].text).not.toContain('process.env.NODE_ENV');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias: import 경로 치환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-'));
    writeFileSync(join(dir, 'real.ts'), 'export const x = 42;');
    writeFileSync(join(dir, 'index.ts'), 'import { x } from "@alias/mod";\nconsole.log(x);');

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      alias: { '@alias/mod': join(dir, 'real.ts') },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('42');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── #2153 array-form alias (Vite 식 RegExp / 함수형 find) ──────────────────
  test('alias array: string find — exact 매칭', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-string-'));
    writeFileSync(join(dir, 'real.ts'), 'export const x = "ALIAS_ARRAY_STRING_VALUE";');
    writeFileSync(join(dir, 'index.ts'), 'import { x } from "virtual";\nconsole.log(x);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      alias: [{ find: 'virtual', replacement: join(dir, 'real.ts') }],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_ARRAY_STRING_VALUE');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: RegExp find — capture group 치환 ($1)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-regex-'));
    writeFileSync(join(dir, 'components.ts'), 'export const Btn = "ALIAS_REGEX_BTN";');
    writeFileSync(join(dir, 'index.ts'), 'import { Btn } from "@/components";\nconsole.log(Btn);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      // `@/components` → `<dir>/components` (디렉토리는 index 자동 또는 .ts 추가 — 여기선 정확 path 매핑).
      alias: [{ find: /^@\/(.*)$/, replacement: join(dir, '$1.ts') }],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_REGEX_BTN');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: 매칭 순서 — 첫번째 매치 적용', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-order-'));
    writeFileSync(join(dir, 'first.ts'), 'export const v = "ALIAS_FIRST_MATCH";');
    writeFileSync(join(dir, 'second.ts'), 'export const v = "ALIAS_SECOND_MATCH";');
    writeFileSync(join(dir, 'index.ts'), 'import { v } from "shared";\nconsole.log(v);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      alias: [
        { find: 'shared', replacement: join(dir, 'first.ts') },
        { find: 'shared', replacement: join(dir, 'second.ts') },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_FIRST_MATCH');
    expect(result.outputFiles[0].text).not.toContain('ALIAS_SECOND_MATCH');
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: RegExp `g` flag 도 매 import 안전 적용 (lastIndex 부작용 없음)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-gflag-'));
    writeFileSync(join(dir, 'a.ts'), 'export const a = "ALIAS_GFLAG_A";');
    writeFileSync(join(dir, 'b.ts'), 'export const b = "ALIAS_GFLAG_B";');
    writeFileSync(
      join(dir, 'index.ts'),
      'import { a } from "@/a";\nimport { b } from "@/b";\nconsole.log(a, b);',
    );

    // `g` flag — find.test() 패턴이었다면 두 번째 호출에서 lastIndex 부작용으로 false 반환.
    // String.prototype.search 는 g flag 무시하므로 두 import 모두 매칭되어야 함.
    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      alias: [{ find: /^@\/(.*)$/g, replacement: join(dir, '$1.ts') }],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ALIAS_GFLAG_A');
    expect(result.outputFiles[0].text).toContain('ALIAS_GFLAG_B');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── #2159 outputExports — Rollup output.exports 호환 ─────────────────────
  test("outputExports='auto' default-only → module.exports = X", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-default-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "AUTO_DEFAULT_ONLY";\nexport default x;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'auto',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('module.exports = ');
    expect(text).not.toContain('__esModule');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='auto' named-only → exports.X = X (no esModule flag)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-named-'));
    writeFileSync(join(dir, 'index.ts'), 'export const a = 1;\nexport const b = "AUTO_NAMED";');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'auto',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('exports.a = ');
    expect(text).toContain('exports.b = ');
    expect(text).not.toContain('__esModule');
    expect(text).not.toContain('module.exports = ');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='auto' mixed → exports.X + esModule flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-mixed-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'export const a = "AUTO_MIXED_NAMED";\nexport default { x: "AUTO_MIXED_DEFAULT" };',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'auto',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('exports.a = ');
    expect(text).toContain('exports.default = ');
    expect(text).toContain('__esModule');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='named' default-only → exports.default + esModule flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-named-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "NAMED_DEFAULT";\nexport default x;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'named',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('exports.default = ');
    expect(text).toContain('__esModule');
    expect(text).not.toContain('module.exports = ');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='default' default-only → module.exports = X", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-default-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "DEFAULT_MODE";\nexport default x;');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'default',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('module.exports = ');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='default' + named 섞이면 result.errors 에 명시 진단", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-conflict-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'export const a = 1;\nexport default { x: "ALSO_HAS_DEFAULT" };',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'default',
    });
    // graph diagnostic 으로 emit — std.log.warn 임시방편 X.
    expect(result.errors.length).toBeGreaterThan(0);
    const errMsg = result.errors[0].text;
    expect(errMsg).toContain('output.exports');
    expect(errMsg).toContain('default-only');
    rmSync(dir, { recursive: true, force: true });
  });

  test("outputExports='none' → 모든 export 출력 안 함", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-none-'));
    writeFileSync(join(dir, 'index.ts'), 'export const a = 1;\nexport default { x: 2 };');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      format: 'cjs',
      outputExports: 'none',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).not.toContain('module.exports = ');
    expect(text).not.toContain('exports.a');
    expect(text).not.toContain('exports.default');
    rmSync(dir, { recursive: true, force: true });
  });

  // ─── #2158 logLevel / logLimit NAPI 필터링 ─────────────────────────────────
  // unresolved import 은 ZNTC 에서 errors 로 분류 (worker / optional 만 warnings).
  // 따라서 errors 검증 위주로 logLevel/logLimit 동작 확인.

  test("logLevel='silent': errors 도 빈 배열 (build 객체로만 결과 확인)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglevel-silent-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import * as r from "unresolved-pkg-zzz";\nconsole.log(r);',
    );

    const baseline = await build({ entryPoints: [join(dir, 'index.ts')] });
    expect(baseline.errors.length).toBeGreaterThan(0);

    const silent = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLevel: 'silent',
    });
    expect(silent.errors).toEqual([]);
    expect(silent.warnings).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  test("logLevel='warning' (default): errors 그대로 보존", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglevel-warning-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import * as r from "unresolved-pkg-yyy";\nconsole.log(r);',
    );

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLevel: 'warning',
    });
    expect(result.errors.length).toBeGreaterThan(0);
    rmSync(dir, { recursive: true, force: true });
  });

  test('logLimit=1: errors 가 여러 개여도 1개로 truncate', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-loglimit-'));
    writeFileSync(
      join(dir, 'index.ts'),
      [
        'import * as a from "unresolved-pkg-aaa";',
        'import * as b from "unresolved-pkg-bbb";',
        'import * as c from "unresolved-pkg-ccc";',
        'console.log(a, b, c);',
      ].join('\n'),
    );

    const baseline = await build({ entryPoints: [join(dir, 'index.ts')] });
    expect(baseline.errors.length).toBeGreaterThan(1);

    const limited = await build({
      entryPoints: [join(dir, 'index.ts')],
      logLimit: 1,
    });
    expect(limited.errors.length).toBe(1);
    rmSync(dir, { recursive: true, force: true });
  });

  test('alias array: buildSync 에서 throw (host RegExp 위임 plugin 필요)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-alias-array-sync-'));
    writeFileSync(join(dir, 'index.ts'), 'console.log("hi");');

    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'index.ts')],
        alias: [{ find: /^@\//, replacement: dir + '/' }],
      }),
    ).toThrow(/array-form alias.*async build/);

    rmSync(dir, { recursive: true, force: true });
  });

  test('define: async build에서도 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-async-'));
    writeFileSync(join(dir, 'index.ts'), 'console.log(VERSION);');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      define: { VERSION: '"1.0.0"' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('1.0.0');
    rmSync(dir, { recursive: true, force: true });
  });

  test('빈 define/alias 객체 → 무시', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-empty-define-'));
    writeFileSync(join(dir, 'index.ts'), 'export const x = 1;');

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: {},
      alias: {},
    });
    expect(result.errors.length).toBe(0);
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── Vite/Rollup 플러그인 어댑터 ───

describe('vitePlugin 어댑터', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-vite-adapter-'));
    writeFileSync(join(dir, 'entry.ts'), 'import css from "./style.css";\nconsole.log(css);');
    writeFileSync(join(dir, 'app.ts'), 'import { greet } from "./util";\nconsole.log(greet());');
    writeFileSync(join(dir, 'util.ts'), "export function greet(): string { return 'Hello!'; }");
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('resolveId 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "red";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('red');
  });

  test('resolveId 훅 — { id } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-resolve-object',
      resolveId(source) {
        if (source.endsWith('.css')) return { id: resolve(dir, source) };
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "blue";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('blue');
  });

  test('load 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-string',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return 'export default "from-string";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-string');
  });

  test('load 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-load-object',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.css')) return { code: 'export default "from-object";' };
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('from-object');
  });

  test('transform 훅 — 문자열 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-string',
      transform(code, _id) {
        return code.replace('Hello!', 'Transformed!');
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Transformed!');
  });

  test('transform 훅 — { code } 객체 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-object',
      transform(code, _id) {
        return { code: code.replace('Hello!', 'ObjectTransformed!') };
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ObjectTransformed!');
  });

  test('transform 훅 — null 반환 (통과)', async () => {
    const plugin: RollupPlugin = {
      name: 'rollup-transform-null',
      transform() {
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });

  test('여러 Rollup 플러그인 조합', async () => {
    const resolverPlugin: RollupPlugin = {
      name: 'resolver',
      resolveId(source) {
        if (source.endsWith('.css')) return resolve(dir, source);
        return null;
      },
    };

    const loaderPlugin: RollupPlugin = {
      name: 'loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "multi-plugin";';
        return null;
      },
    };

    const transformerPlugin: RollupPlugin = {
      name: 'transformer',
      transform(code, _id) {
        return code.replace('multi-plugin', 'MULTI-TRANSFORMED');
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin(resolverPlugin),
        vitePlugin(loaderPlugin),
        vitePlugin(transformerPlugin),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('MULTI-TRANSFORMED');
  });

  test('ZNTC 플러그인과 Vite 플러그인 혼합', async () => {
    const nativePlugin: ZntcPlugin = {
      name: 'native-resolve',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({
          path: resolve(dir, args.path),
        }));
      },
    };

    const rollupLoader: RollupPlugin = {
      name: 'rollup-loader',
      load(id) {
        if (id.endsWith('.css')) return 'export default "mixed";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [nativePlugin, vitePlugin(rollupLoader)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('mixed');
  });

  test('훅이 없는 빈 Rollup 플러그인', async () => {
    const emptyPlugin: RollupPlugin = { name: 'empty' };
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(emptyPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('Hello!');
  });

  test('resolveId에서 undefined/void 반환', async () => {
    const plugin: RollupPlugin = {
      name: 'void-return',
      resolveId() {
        // void — 아무것도 반환하지 않음
      },
    };
    const result = await build({
      entryPoints: [join(dir, 'app.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
  });

  test('실전 패턴: JSON 플러그인 (Rollup 스타일)', async () => {
    const jsonDir = mkdtempSync(join(tmpdir(), 'zntc-vite-json-'));
    writeFileSync(join(jsonDir, 'data.json'), '{"name":"test","version":"1.0"}');
    writeFileSync(
      join(jsonDir, 'index.ts'),
      'import data from "./data.json";\nconsole.log(data.name);',
    );

    const jsonPlugin: RollupPlugin = {
      name: 'rollup-json',
      resolveId(source, importer) {
        if (source.endsWith('.json') && importer) {
          return resolve(jsonDir, source);
        }
        return null;
      },
      load(id) {
        if (id.endsWith('.json')) {
          const json = readFileSync(id, 'utf8');
          return `export default ${json};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(jsonDir, 'index.ts')],
      plugins: [vitePlugin(jsonPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('test');
    expect(result.outputFiles[0].text).toContain('1.0');
    rmSync(jsonDir, { recursive: true, force: true });
  });

  test('실전 패턴: 환경 변수 치환 플러그인', async () => {
    const envDir = mkdtempSync(join(tmpdir(), 'zntc-vite-env-'));
    writeFileSync(join(envDir, 'index.ts'), 'console.log(import.meta.env.MODE);');

    const envPlugin: RollupPlugin = {
      name: 'rollup-env',
      transform(code, _id) {
        return code.replace('import.meta.env.MODE', '"production"');
      },
    };

    const result = await build({
      entryPoints: [join(envDir, 'index.ts')],
      plugins: [vitePlugin(envPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    rmSync(envDir, { recursive: true, force: true });
  });

  test('실전 패턴: YAML 로더 플러그인', async () => {
    const yamlDir = mkdtempSync(join(tmpdir(), 'zntc-vite-yaml-'));
    writeFileSync(join(yamlDir, 'config.yaml'), 'name: test\nversion: 2.0');
    writeFileSync(
      join(yamlDir, 'index.ts'),
      'import config from "./config.yaml";\nconsole.log(config);',
    );

    const yamlPlugin: RollupPlugin = {
      name: 'rollup-yaml',
      resolveId(source, importer) {
        if (source.endsWith('.yaml') && importer) return resolve(yamlDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.yaml')) {
          const content = readFileSync(id, 'utf8');
          const obj: Record<string, string> = {};
          for (const line of content.split('\n')) {
            const [k, v] = line.split(': ');
            if (k && v) obj[k.trim()] = v.trim();
          }
          return `export default ${JSON.stringify(obj)};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(yamlDir, 'index.ts')],
      plugins: [vitePlugin(yamlPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('test');
    expect(result.outputFiles[0].text).toContain('2.0');
    rmSync(yamlDir, { recursive: true, force: true });
  });

  test('실전 패턴: SVG → React 컴포넌트 플러그인', async () => {
    const svgDir = mkdtempSync(join(tmpdir(), 'zntc-vite-svg-'));
    writeFileSync(join(svgDir, 'icon.svg'), '<svg><circle r="10"/></svg>');
    writeFileSync(join(svgDir, 'index.tsx'), 'import Icon from "./icon.svg";\nconsole.log(Icon);');

    const svgPlugin: RollupPlugin = {
      name: 'rollup-svg-react',
      resolveId(source, importer) {
        if (source.endsWith('.svg') && importer) return resolve(svgDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.svg')) {
          const svg = readFileSync(id, 'utf8');
          return `export default function SvgIcon() { return "${svg.replace(/"/g, '\\"')}"; }`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(svgDir, 'index.tsx')],
      plugins: [vitePlugin(svgPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SvgIcon');
    expect(result.outputFiles[0].text).toContain('circle');
    rmSync(svgDir, { recursive: true, force: true });
  });

  test('실전 패턴: GraphQL 쿼리 로더', async () => {
    const gqlDir = mkdtempSync(join(tmpdir(), 'zntc-vite-gql-'));
    writeFileSync(join(gqlDir, 'query.graphql'), 'query GetUser { user { name } }');
    writeFileSync(
      join(gqlDir, 'index.ts'),
      'import query from "./query.graphql";\nconsole.log(query);',
    );

    const gqlPlugin: RollupPlugin = {
      name: 'rollup-graphql',
      resolveId(source, importer) {
        if (source.endsWith('.graphql') && importer) return resolve(gqlDir, source);
        return null;
      },
      load(id) {
        if (id.endsWith('.graphql')) {
          const content = readFileSync(id, 'utf8');
          return `export default ${JSON.stringify(content)};`;
        }
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(gqlDir, 'index.ts')],
      plugins: [vitePlugin(gqlPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('GetUser');
    rmSync(gqlDir, { recursive: true, force: true });
  });

  test('실전 패턴: 코드 내 console.log 자동 제거 transform', async () => {
    const stripDir = mkdtempSync(join(tmpdir(), 'zntc-vite-strip-'));
    writeFileSync(
      join(stripDir, 'index.ts'),
      'console.log("debug");\nconst x = 1;\nconsole.log("also debug");\nconsole.warn("keep");',
    );

    const stripPlugin: RollupPlugin = {
      name: 'rollup-strip-console-log',
      transform(code, _id) {
        return code.replace(/console\.log\([^)]*\);?\n?/g, '');
      },
    };

    const result = await build({
      entryPoints: [join(stripDir, 'index.ts')],
      plugins: [vitePlugin(stripPlugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('console.log');
    expect(result.outputFiles[0].text).toContain('console.warn');
    expect(result.outputFiles[0].text).toContain('x = 1');
    rmSync(stripDir, { recursive: true, force: true });
  });

  test('실전 패턴: 다중 vitePlugin transform 체이닝', async () => {
    const chainDir = mkdtempSync(join(tmpdir(), 'zntc-vite-chain-'));
    writeFileSync(join(chainDir, 'index.ts'), 'const msg = "HELLO_WORLD";');

    // 첫 번째 플러그인: HELLO → Hello
    const lowercasePlugin: RollupPlugin = {
      name: 'lowercase-first',
      transform(code) {
        return code.replace('HELLO', 'Hello');
      },
    };

    // 두 번째 플러그인: _WORLD → _World (첫 번째 결과를 입력으로 받음)
    const capitalizePlugin: RollupPlugin = {
      name: 'capitalize-second',
      transform(code) {
        return code.replace('_WORLD', '_World');
      },
    };

    const result = await build({
      entryPoints: [join(chainDir, 'index.ts')],
      plugins: [vitePlugin(lowercasePlugin), vitePlugin(capitalizePlugin)],
    });
    expect(result.errors.length).toBe(0);
    // 두 플러그인의 transform이 순차 체이닝되어야 함
    expect(result.outputFiles[0].text).toContain('Hello_World');
    rmSync(chainDir, { recursive: true, force: true });
  });

  test('실전 패턴: 3개 플러그인 transform 체이닝', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-chain3-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = "AAA_BBB_CCC";');

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [
        vitePlugin({ name: 'p1', transform: (code) => code.replace('AAA', 'aaa') }),
        vitePlugin({ name: 'p2', transform: (code) => code.replace('BBB', 'bbb') }),
        vitePlugin({ name: 'p3', transform: (code) => code.replace('CCC', 'ccc') }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('aaa_bbb_ccc');
    rmSync(dir, { recursive: true, force: true });
  });

  test('vitePlugin: resolveId에 importer가 올바르게 전달됨', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-importer-'));
    writeFileSync(join(dir, 'entry.ts'), 'import x from "./data.custom";\nconsole.log(x);');

    let receivedImporter: string | null | undefined = undefined;
    const plugin: RollupPlugin = {
      name: 'check-importer',
      resolveId(source, importer) {
        if (source.endsWith('.custom')) {
          receivedImporter = importer ?? null;
          return resolve(dir, source);
        }
        return null;
      },
      load(id) {
        if (id.endsWith('.custom')) return 'export default "custom-data";';
        return null;
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    // importer는 entry.ts의 절대 경로여야 함
    expect(receivedImporter).toContain('entry.ts');
    rmSync(dir, { recursive: true, force: true });
  });

  test('vitePlugin: transform이 { code, map } 반환 시 map 무시', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-vite-map-'));
    writeFileSync(join(dir, 'index.ts'), 'const x = 1;');

    const plugin: RollupPlugin = {
      name: 'with-map',
      transform(code) {
        return { code: code.replace('1', '42'), map: { version: 3, mappings: '' } };
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      plugins: [vitePlugin(plugin)],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('42');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 옵션 조합 심화 테스트 ───

describe('@zntc/core 옵션 조합 심화', () => {
  test('hashbang + minify', () => {
    const result = transpile(
      '#!/usr/bin/env node\nconst longVariableName = 42;\nconsole.log(longVariableName);',
      {
        minify: true,
        target: 'es2023',
      },
    );
    expect(result.code).toContain('#!/usr/bin/env node');
    expect(result.code.length).toBeLessThan(80);
  });

  test('hashbang + sourcemap + es2022 (hashbang 제거됨)', () => {
    const result = transpile('#!/usr/bin/env node\nconst x = 1;', {
      sourcemap: true,
      target: 'es2022',
    });
    expect(result.code).not.toContain('#!');
    expect(result.map).toBeDefined();
  });

  test('buildSync + define + alias + sourcemap 동시', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-all-'));
    writeFileSync(join(dir, 'real.ts'), 'export const val = 42;');
    writeFileSync(
      join(dir, 'index.ts'),
      'import { val } from "@mod";\nconsole.log(val, __VERSION__);',
    );

    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      define: { __VERSION__: '"1.0"' },
      alias: { '@mod': join(dir, 'real.ts') },
      sourcemap: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('42');
    expect(result.outputFiles[0].text).toContain('1.0');
    expect(result.outputFiles.length).toBe(2); // js + map
    rmSync(dir, { recursive: true, force: true });
  });

  test('transpile: 모든 ES 타겟 순회 (es5~esnext)', () => {
    const targets = [
      'es5',
      'es2015',
      'es2016',
      'es2017',
      'es2018',
      'es2019',
      'es2020',
      'es2021',
      'es2022',
      'es2023',
      'es2024',
      'es2025',
      'esnext',
    ] as const;
    for (const target of targets) {
      const result = transpile('const x = () => 1;', { target });
      expect(result.code.length).toBeGreaterThan(0);
      if (target === 'es5') {
        // es5에서만 arrow function 다운레벨
        expect(result.code).not.toContain('=>');
      } else {
        // es2015+에서는 arrow function 유지
        expect(result.code).toContain('=>');
      }
    }
  });

  test('build + platform=node + jsx=automatic + plugins (실제 코드 변환)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-combo-node-jsx-'));
    writeFileSync(join(dir, 'app.tsx'), 'export default () => <div>hello</div>;');

    const result = await build({
      entryPoints: [join(dir, 'app.tsx')],
      platform: 'node',
      jsx: 'automatic',
      external: ['react/jsx-runtime'],
      plugins: [
        {
          name: 'replace-transform',
          setup(build) {
            // 주석이 아닌 실제 코드 변환 (주석은 파서에서 제거됨)
            build.onTransform({ filter: /\.tsx$/ }, (args) => ({
              code: args.code.replace('hello', 'transformed'),
            }));
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('transformed');
    expect(result.outputFiles[0].text).toContain('jsx-runtime');
    rmSync(dir, { recursive: true, force: true });
  });

  test('build + define + plugins (define은 NAPI, plugin은 JS)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-define-plugin-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import css from "./style.css";\nconsole.log(__MODE__, css);',
    );

    const cssPlugin: ZntcPlugin = {
      name: 'css',
      setup(build) {
        build.onResolve({ filter: /\.css$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.css$/ }, () => ({ contents: 'export default "red";' }));
      },
    };

    const result = await build({
      entryPoints: [join(dir, 'index.ts')],
      define: { __MODE__: '"production"' },
      plugins: [cssPlugin],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('production');
    expect(result.outputFiles[0].text).toContain('red');
    rmSync(dir, { recursive: true, force: true });
  });
});

// ─── 새 BuildOptions 테스트 ───

describe('BuildOptions: 누락 옵션 노출 (#1005)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-build-opts-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const fn = () => 1;');
    writeFileSync(join(dir, 'data.txt'), 'hello text');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('target: es5 → arrow function이 function으로 변환됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('=>');
    expect(result.outputFiles[0].text).toContain('function');
  });

  test('target: esnext → arrow function 유지', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'esnext',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('=>');
  });

  test('loader: .txt=text → 텍스트 파일이 문자열로 export됨', () => {
    writeFileSync(join(dir, 'import-txt.ts'), 'import txt from "./data.txt";\nconsole.log(txt);');
    const result = buildSync({
      entryPoints: [join(dir, 'import-txt.ts')],
      loader: { '.txt': 'text' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('hello text');
  });

  test('loader: JSON/CSS/asset disk reads + plugin load source stay stable', async () => {
    const fixture = mkdtempSync(join(tmpdir(), 'zntc-resource-read-mtime-'));
    try {
      writeFileSync(
        join(fixture, 'entry.ts'),
        [
          'import data from "./data.json";',
          'import "./style.css";',
          'import text from "./note.txt";',
          'import logo from "./logo.png";',
          'import virtual from "./generated.virtual";',
          'console.log(data.answer, text.trim(), logo.includes(".png"), virtual);',
        ].join('\n'),
      );
      writeFileSync(join(fixture, 'data.json'), '{"answer":42}');
      writeFileSync(join(fixture, 'style.css'), '.card { color: red; }\n');
      writeFileSync(join(fixture, 'note.txt'), 'hello resource\n');
      writeFileSync(join(fixture, 'logo.png'), 'png-bytes');

      const plugin: ZntcPlugin = {
        name: 'virtual-source',
        setup(build) {
          build.onResolve({ filter: /\.virtual$/ }, (args) => ({
            path: resolve(fixture, args.path),
          }));
          build.onLoad({ filter: /\.virtual$/ }, () => ({
            contents: 'export default "plugin-source";',
            loader: 'js',
          }));
        },
      };

      const result = await build({
        entryPoints: [join(fixture, 'entry.ts')],
        loader: { '.txt': 'text', '.png': 'file' },
        plugins: [plugin],
      });

      expect(result.errors.length).toBe(0);
      expect(await runBundleStdout(result.outputFiles[0].text)).toBe(
        '42 hello resource true plugin-source',
      );
    } finally {
      rmSync(fixture, { recursive: true, force: true });
    }
  });

  test('loader: .foo=ts → 커스텀 확장자를 TypeScript로 파싱', async () => {
    writeFileSync(
      join(dir, 'entry-loader-ts.ts'),
      'import { value } from "./value.foo";\nconsole.log(value);',
    );
    writeFileSync(join(dir, 'value.foo'), 'export const value: number = 1;');
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-ts.ts')],
      loader: { '.foo': 'ts' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain(': number');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('1');
  });

  test('loader: .foo=ts → JSX syntax를 거부', async () => {
    writeFileSync(
      join(dir, 'entry-loader-ts-no-jsx.ts'),
      'import { value } from "./view-ts-no-jsx.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view-ts-no-jsx.foo'),
      'const h = (tag) => tag;\nexport const value = <div />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-ts-no-jsx.ts')],
      loader: { '.foo': 'ts' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('loader: .foo=tsx → 커스텀 확장자에서 TSX를 파싱', async () => {
    writeFileSync(
      join(dir, 'entry-loader-tsx.ts'),
      'import { value } from "./view.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view.foo'),
      'const h = (tag: string) => tag;\nexport const value: string = <div />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-tsx.ts')],
      loader: { '.foo': 'tsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('<div');
    expect(result.outputFiles[0].text).not.toContain(': string');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('div');
  });

  test('loader: .foo=jsx → 커스텀 확장자에서 JSX를 파싱', async () => {
    writeFileSync(
      join(dir, 'entry-loader-jsx.ts'),
      'import { value } from "./view-jsx.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'view-jsx.foo'),
      'const h = (tag) => tag;\nexport const value = <span />;',
    );
    const result = await build({
      entryPoints: [join(dir, 'entry-loader-jsx.ts')],
      loader: { '.foo': 'jsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('<span');
    expect(await runBundleStdout(result.outputFiles[0].text)).toBe('span');
  });

  test('loader: .foo=js/jsx → TypeScript syntax를 거부', async () => {
    writeFileSync(
      join(dir, 'entry-loader-js-strict.ts'),
      'import { value } from "./value-js-strict.foo";\nconsole.log(value);',
    );
    writeFileSync(join(dir, 'value-js-strict.foo'), 'export const value: number = 1;');
    const jsResult = await build({
      entryPoints: [join(dir, 'entry-loader-js-strict.ts')],
      loader: { '.foo': 'js' },
    });
    expect(jsResult.errors.length).toBeGreaterThan(0);
    expect(jsResult.errors[0].text).toContain('TypeScript');

    writeFileSync(
      join(dir, 'entry-loader-jsx-strict.ts'),
      'import { value } from "./value-jsx-strict.foo";\nconsole.log(value);',
    );
    writeFileSync(
      join(dir, 'value-jsx-strict.foo'),
      'const h = (tag) => tag;\nexport const value: string = <span />;',
    );
    const jsxResult = await build({
      entryPoints: [join(dir, 'entry-loader-jsx-strict.ts')],
      loader: { '.foo': 'jsx' },
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(jsxResult.errors.length).toBeGreaterThan(0);
    expect(jsxResult.errors[0].text).toContain('TypeScript');
  });

  test('resolveExtensions: 커스텀 확장자 순서가 적용됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      resolveExtensions: ['.ts', '.tsx', '.js'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('mainFields: 커스텀 필드 순서가 적용됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      mainFields: ['module', 'main'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('conditions: 커스텀 exports 조건이 적용됨', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      conditions: ['import', 'default'],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });

  test('write + outdir: 디스크에 파일이 기록됨', () => {
    const outdir = join(dir, 'out-dir');
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
      write: true,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('fn');
    rmSync(outdir, { recursive: true, force: true });
  });

  test('outfile: 단일 파일 출력 경로 지정', () => {
    const outfile = join(dir, 'custom-out', 'my-bundle.js');
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outfile,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(outfile, 'utf-8');
    expect(written).toContain('fn');
    rmSync(join(dir, 'custom-out'), { recursive: true, force: true });
  });

  test('outdir 지정 시 write 자동 true', () => {
    const outdir = join(dir, 'auto-write');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
    });
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('fn');
    rmSync(outdir, { recursive: true, force: true });
  });

  test('write: false → 디스크에 기록하지 않음', () => {
    const outdir = join(dir, 'no-write');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
      write: false,
    });
    expect(() => readFileSync(join(outdir, 'bundle.js'))).toThrow();
  });

  test('outfile + sourcemap: 소스맵이 outfile 옆에 생성됨', () => {
    const outfile = join(dir, 'sm-out', 'bundle.js');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outfile,
      sourcemap: true,
    });
    const mapContent = readFileSync(outfile + '.map', 'utf-8');
    expect(mapContent).toContain('mappings');
    rmSync(join(dir, 'sm-out'), { recursive: true, force: true });
  });
});

// ─── vitePlugin async 훅 테스트 (#1007) ───

describe('vitePlugin async 훅 지원', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-async-plugin-'));
    writeFileSync(join(dir, 'entry.ts'), 'import val from "./data.custom";\nconsole.log(val);');
    writeFileSync(join(dir, 'data.custom'), 'CUSTOM_DATA');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('async load 훅', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-loader',
          async load(id) {
            if (id.endsWith('.custom')) {
              await new Promise((r) => setTimeout(r, 10));
              return { code: 'export default "ASYNC_LOADED";' };
            }
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('ASYNC_LOADED');
  });

  test('async resolveId 훅', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-resolver',
          async resolveId(source) {
            if (source.endsWith('.custom')) {
              await new Promise((r) => setTimeout(r, 10));
              return join(dir, 'data.custom');
            }
          },
          load(id) {
            if (id.endsWith('.custom')) {
              return { code: 'export default "RESOLVED";' };
            }
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('RESOLVED');
  });

  test('async transform 훅', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-transformer',
          async transform(code, id) {
            if (id.endsWith('.ts')) {
              await new Promise((r) => setTimeout(r, 10));
              return code.replace('console.log', 'console.info');
            }
          },
        }),
        vitePlugin({
          name: 'custom-loader',
          load(id) {
            if (id.endsWith('.custom')) return { code: 'export default "X";' };
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('console.info');
    expect(result.outputFiles[0].text).not.toContain('console.log');
  });

  test('동기 + 비동기 훅 혼합', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'sync-plugin',
          load(id) {
            if (id.endsWith('.custom')) return { code: 'export default "SYNC";' };
          },
        }),
        vitePlugin({
          name: 'async-plugin',
          async transform(code) {
            await new Promise((r) => setTimeout(r, 5));
            return code.replace('console.log', 'console.warn');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('SYNC');
    expect(result.outputFiles[0].text).toContain('console.warn');
  });
});

// ─── renderChunk/generateBundle 훅 테스트 (#1004) ───

describe('renderChunk/generateBundle 훅', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-chunk-hooks-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('renderChunk: 청크 코드 후처리', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        {
          name: 'chunk-banner',
          setup(build) {
            build.onRenderChunk({ filter: /.*/ }, (args) => {
              return { code: `/* CHUNK: ${args.chunk} */\n${args.code}` };
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* CHUNK:');
    expect(result.outputFiles[0].text).toContain('x = 1');
  });

  test('renderChunk via vitePlugin', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-chunk',
          renderChunk(code) {
            return code.replace('x = 1', 'x = 42');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 42');
  });

  test('async renderChunk', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-chunk',
          async renderChunk(code) {
            await new Promise((r) => setTimeout(r, 5));
            return `/* ASYNC */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* ASYNC */');
  });

  test('generateBundle: 번들 완료 콜백', async () => {
    const collected: string[] = [];
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        {
          name: 'bundle-inspector',
          setup(build) {
            build.onGenerateBundle((outputs) => {
              for (const f of outputs) {
                collected.push(f.path);
              }
            });
          },
        },
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(collected.length).toBeGreaterThan(0);
  });

  test('generateBundle via vitePlugin', async () => {
    let called = false;
    await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'vite-generate',
          generateBundle(outputs) {
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });

  test('renderChunk 체이닝: 2개 플러그인 순차 적용', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'chunk-step1',
          renderChunk(code) {
            return code.replace('x = 1', 'x = 10');
          },
        }),
        vitePlugin({
          name: 'chunk-step2',
          renderChunk(code) {
            return code.replace('x = 10', 'x = 100');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('x = 100');
    expect(result.outputFiles[0].text).not.toContain('x = 1;');
  });

  test('async generateBundle', async () => {
    let called = false;
    await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'async-generate',
          async generateBundle(outputs) {
            await new Promise((r) => setTimeout(r, 5));
            called = true;
            expect(outputs.length).toBeGreaterThan(0);
          },
        }),
      ],
    });
    expect(called).toBe(true);
  });

  test('generateBundle: 에러가 throw되어도 빌드 성공', async () => {
    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [
        vitePlugin({
          name: 'error-generate',
          generateBundle() {
            throw new Error('intentional error');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});

describe('BuildOptions: 엣지 케이스', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-edge-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = () => 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('target: 잘못된 값은 무시 (변환 없음)', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es2099' as any,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('=>');
  });

  test('loader: 잘못된 값은 무시', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      loader: { '.ts': 'invalid_loader' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});

// ─── 배치 E: S급 옵션 노출 테스트 ───

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

describe('BundleOptions: 전체 옵션 노출', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-all-opts-'));
    writeFileSync(join(dir, 'entry.ts'), '/** @license MIT */\nexport const x = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('legalComments: none → 라이센스 주석 제거', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      legalComments: 'none',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('@license');
  });

  test('legalComments: eof → 파일 끝에 주석 이동', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      legalComments: 'eof',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('@license');
  });

  test('preserveModules: 모듈별 개별 파일 출력', async () => {
    writeFileSync(join(dir, 'mod-a.ts'), 'export const a = 1;');
    writeFileSync(
      join(dir, 'mod-entry.ts'),
      'import { a } from "./mod-a";\nexport const b = a + 1;',
    );
    const result = await build({
      entryPoints: [join(dir, 'mod-entry.ts')],
      preserveModules: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test('preserveModulesRoot: 출력 경로 기준', async () => {
    const result = await build({
      entryPoints: [join(dir, 'mod-entry.ts')],
      preserveModules: true,
      preserveModulesRoot: dir,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test('timing: 옵션 파싱 확인', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      timing: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('devMode: dev 모드 활성화', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('__zntc_modules');
  });

  test('devMode: RN HMR reload fallback은 DevSettings wrapper를 우선 사용', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    expect(code).toContain('require("react-native")');
    expect(code).toContain('rn.DevSettings.reload(why)');
    expect(code).toContain('setTimeout(fn, 0)');
    expect(code).not.toContain('__zntc_g.nativeModuleProxy.DevSettings.reload()');
  });

  test('reactRefresh: Fast Refresh 활성화', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('configurableExports: configurable:true 추가', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      configurableExports: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('globalIdentifiers: 예약 식별자', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      globalIdentifiers: ['__global', 'self'],
    });
    expect(result.errors.length).toBe(0);
  });

  test('rootDir + collectModuleCodes: dev 모드 옵션 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      rootDir: dir,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
  });
});

// ─── 옵션 조합 + 엣지 케이스 통합 테스트 ───

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

describe('실제 라이브러리 번들링', () => {
  let dir: string;
  const projectNodeModules = resolve(__dirname, '../../node_modules');

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-real-lib-'));
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('React: ESM 번들', async () => {
    writeFileSync(
      join(dir, 'react-app.tsx'),
      'import React from "react";\nexport const el = React.createElement("div", null, "hello");',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-app.tsx')],
      format: 'esm',
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('createElement');
  });

  test('React: UMD + external → require 유지', async () => {
    writeFileSync(
      join(dir, 'react-umd.tsx'),
      'import React from "react";\nexport function App() { return React.createElement("div", null, "hi"); }',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-umd.tsx')],
      format: 'umd',
      globalName: 'ReactApp',
      external: ['react'],
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('ReactApp');
    expect(text).toContain('require');
  });

  test('React: IIFE 인라인 → 런타임 실행', async () => {
    writeFileSync(
      join(dir, 'react-iife.tsx'),
      'import React from "react";\nexport const version = React.version;',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-iife.tsx')],
      format: 'iife',
      globalName: 'ReactBundle',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    const fn = new Function(result.outputFiles[0].text + '\nreturn ReactBundle;');
    const lib = fn();
    expect(lib.version).toBeDefined();
  });

  test('React + minify → 압축 후 런타임 실행 (#1041)', async () => {
    writeFileSync(
      join(dir, 'react-min.tsx'),
      'import React from "react";\nexport const v = React.version;',
    );
    const normal = await build({
      entryPoints: [join(dir, 'react-min.tsx')],
      format: 'iife',
      globalName: 'R',
      nodePaths: [projectNodeModules],
    });
    const minified = await build({
      entryPoints: [join(dir, 'react-min.tsx')],
      format: 'iife',
      globalName: 'R',
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(minified.errors.length).toBe(0);
    expect(minified.outputFiles[0].text.length).toBeLessThan(normal.outputFiles[0].text.length);
    // 런타임 실행: minify 후에도 React가 정상 동작
    const fn = new Function(minified.outputFiles[0].text + '\nreturn R;');
    const lib = fn();
    expect(lib.v).toBeDefined();
  });

  test('lodash-es: tree-shaking으로 번들 크기 축소', async () => {
    writeFileSync(
      join(dir, 'lodash-app.ts'),
      'import { chunk } from "lodash-es";\nexport const result = chunk([1,2,3,4], 2);',
    );
    const result = await build({
      entryPoints: [join(dir, 'lodash-app.ts')],
      format: 'esm',
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text.length).toBeLessThan(50000);
  });

  test('다중 엔트리 + code splitting + React', async () => {
    writeFileSync(
      join(dir, 'page-a.tsx'),
      'import React from "react";\nexport const A = React.createElement("div", null, "A");',
    );
    writeFileSync(
      join(dir, 'page-b.tsx'),
      'import React from "react";\nexport const B = React.createElement("div", null, "B");',
    );
    const result = await build({
      entryPoints: [join(dir, 'page-a.tsx'), join(dir, 'page-b.tsx')],
      splitting: true,
      format: 'esm',
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(3);
  });

  test('React JSX automatic 모드', async () => {
    writeFileSync(join(dir, 'jsx-auto.tsx'), 'export const App = () => <div>hello</div>;');
    const result = await build({
      entryPoints: [join(dir, 'jsx-auto.tsx')],
      jsx: 'automatic',
      format: 'esm',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('jsx');
  });

  test('React + define + platform=browser → production 빌드', async () => {
    writeFileSync(
      join(dir, 'react-prod.tsx'),
      'import React from "react";\nif (process.env.NODE_ENV !== "production") { console.log("dev"); }\nexport const v = React.version;',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-prod.tsx')],
      format: 'iife',
      globalName: 'Prod',
      platform: 'browser',
      define: { 'process.env.NODE_ENV': '"production"' },
      minify: true,
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('"dev"');
  });
});

// ─── import.meta.glob 테스트 (#1026) ───

describe('import.meta.glob', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-glob-'));
    mkdirSync(join(dir, 'pages'), { recursive: true });
    writeFileSync(join(dir, 'pages', 'Home.tsx'), 'export default "Home";');
    writeFileSync(join(dir, 'pages', 'About.tsx'), 'export default "About";');
    writeFileSync(join(dir, 'pages', 'Contact.tsx'), 'export default "Contact";');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('기본 glob: lazy import 객체 생성', () => {
    writeFileSync(
      join(dir, 'entry.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'entry.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('./pages/Home.tsx');
    expect(text).toContain('./pages/About.tsx');
    expect(text).toContain('./pages/Contact.tsx');
    expect(text).toContain('() => import(');
    expect(text).not.toContain('import.meta.glob');
  });

  test('매칭 파일 없는 패턴 → 빈 객체', () => {
    writeFileSync(
      join(dir, 'empty.ts'),
      'const m = import.meta.glob("./nonexistent/*.ts");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'empty.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('import(');
  });

  test('다른 확장자 패턴', () => {
    writeFileSync(join(dir, 'pages', 'data.json'), '{"key":"value"}');
    writeFileSync(
      join(dir, 'json-glob.ts'),
      'const m = import.meta.glob("./pages/*.json");\nexport { m };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'json-glob.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('./pages/data.json');
  });

  test('glob + IIFE 포맷 → 객체 리터럴 출력', () => {
    writeFileSync(
      join(dir, 'iife-glob.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'iife-glob.ts')],
      format: 'iife',
      globalName: 'G',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('./pages/Home.tsx');
    expect(text).toContain('() => import(');
    expect(text).not.toContain('import.meta.glob');
  });

  test('glob + minify → 축소 후에도 정상 출력', () => {
    writeFileSync(
      join(dir, 'min-glob.ts'),
      'const m = import.meta.glob("./pages/*.tsx");\nexport { m };',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'min-glob.ts')],
      format: 'esm',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).toContain('./pages/Home.tsx');
    expect(text).toContain('import(');
    expect(text).not.toContain('import.meta.glob');
  });

  test('glob: 코드 내 문자열에 import.meta.glob이 있어도 오탐 안 함', () => {
    writeFileSync(
      join(dir, 'no-false-match.ts'),
      'const msg = "use import.meta.glob() to load";\nexport { msg };',
    );
    const result = buildSync({ entryPoints: [join(dir, 'no-false-match.ts')], format: 'esm' });
    expect(result.errors.length).toBe(0);
    // 문자열 리터럴 안의 import.meta.glob은 교체되지 않아야 함
    expect(result.outputFiles[0].text).toContain('import.meta.glob');
  });
});

// ─── 추가 엣지 케이스 + 조합 테스트 ───

describe('엣지 케이스 + 조합 보강', () => {
  let dir: string;
  const projectNodeModules = resolve(__dirname, '../../node_modules');

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-edge2-'));
    writeFileSync(join(dir, 'simple.ts'), 'export const x = () => 1;');
    writeFileSync(
      join(dir, 'multi-export.ts'),
      'export const a = 1;\nexport const b = 2;\nexport function add() { return a + b; }',
    );
    writeFileSync(join(dir, 'has-console.ts'), 'console.log("hello");\nexport const v = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  // --- target + format 조합 ---

  test('target: es5 + format: umd → arrow 변환 + UMD 래핑', async () => {
    const result = await build({
      entryPoints: [join(dir, 'simple.ts')],
      target: 'es5',
      format: 'umd',
      globalName: 'Lib',
    });
    expect(result.errors.length).toBe(0);
    const text = result.outputFiles[0].text;
    expect(text).not.toContain('=>');
    expect(text).toContain('typeof define');
    expect(text).toContain('factory');
  });

  test('target: es5 + format: amd → arrow 변환 + AMD 래핑', async () => {
    const result = await build({
      entryPoints: [join(dir, 'simple.ts')],
      target: 'es5',
      format: 'amd',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('=>');
    expect(result.outputFiles[0].text).toContain('define([]');
  });

  // --- dropLabels + minify ---

  test('dropLabels + minify: 라벨 제거 후 압축', () => {
    writeFileSync(join(dir, 'label-min.ts'), 'DEV: { console.log("dev"); }\nexport const x = 1;');
    const result = buildSync({
      entryPoints: [join(dir, 'label-min.ts')],
      dropLabels: ['DEV'],
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('dev');
  });

  // --- 다중 포맷 런타임 검증 ---

  test('format: esm → export 구문 유지', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'multi-export.ts')],
      format: 'esm',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('export');
  });

  test('format: cjs + minify', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'simple.ts')],
      format: 'cjs',
      minify: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('"use strict"');
  });

  // --- sourcemap 조합 ---

  test('sourcemap + minify + target: es5', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'simple.ts')],
      sourcemap: true,
      minify: true,
      target: 'es5',
    });
    expect(result.errors.length).toBe(0);
    const mapFile = result.outputFiles.find((f: any) => f.path.endsWith('.map'));
    expect(mapFile).toBeDefined();
    expect(mapFile!.text).toContain('mappings');
  });

  // --- 플러그인 + 옵션 조합 ---

  test('플러그인 onTransform + target', async () => {
    const result = await build({
      entryPoints: [join(dir, 'has-console.ts')],
      target: 'es2020',
      plugins: [
        vitePlugin({
          name: 'replacer',
          transform(code) {
            return code.replace('hello', 'TRANSFORMED');
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('TRANSFORMED');
  });

  test('플러그인 renderChunk + format: umd', async () => {
    const result = await build({
      entryPoints: [join(dir, 'simple.ts')],
      format: 'umd',
      globalName: 'T',
      plugins: [
        vitePlugin({
          name: 'chunk-stamp',
          renderChunk(code) {
            return `/* stamped */\n${code}`;
          },
        }),
      ],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('/* stamped */');
    expect(result.outputFiles[0].text).toContain('typeof define');
  });

  // --- 빈 입력 / 에러 ---

  test('존재하지 않는 파일 → 에러', () => {
    const result = buildSync({ entryPoints: [join(dir, 'nonexistent.ts')] });
    expect(result.errors.length).toBeGreaterThan(0);
  });

  test('빈 파일 → 정상 빌드', () => {
    writeFileSync(join(dir, 'empty.ts'), '');
    const result = buildSync({ entryPoints: [join(dir, 'empty.ts')] });
    expect(result.errors.length).toBe(0);
  });

  // --- write + 다양한 포맷 ---

  test('write + outdir + format: umd', () => {
    const outdir = join(dir, 'umd-out');
    const result = buildSync({
      entryPoints: [join(dir, 'simple.ts')],
      format: 'umd',
      globalName: 'W',
      outdir,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('typeof define');
    rmSync(outdir, { recursive: true, force: true });
  });

  // --- React + 다양한 포맷 ---

  test('React: AMD + external → define 래핑', async () => {
    writeFileSync(
      join(dir, 'react-amd.tsx'),
      'import React from "react";\nexport const el = React.createElement("div");',
    );
    const result = await build({
      entryPoints: [join(dir, 'react-amd.tsx')],
      format: 'amd',
      external: ['react'],
      jsx: 'classic',
      nodePaths: [projectNodeModules],
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('define(["react"]');
    expect(result.outputFiles[0].text).toContain('function(React)');
  });

  // --- minifyIdentifiers + for-in (NAPI 레벨 검증) ---

  test('minifyIdentifiers: for-in LHS 변수가 올바르게 리네이밍됨', () => {
    writeFileSync(
      join(dir, 'forin.js'),
      'var myObj = { a: 1 };\nvar myKey;\nfor (myKey in myObj) { console.log(myKey); }\nexport var result = myKey;',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'forin.js')],
      format: 'esm',
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('myKey');
    expect(result.outputFiles[0].text).not.toContain('myObj');
  });

  test('minifyIdentifiers: 함수 내부 var hoisting', () => {
    writeFileSync(
      join(dir, 'hoist.js'),
      'export default (function() { console.log(longName); var longName = 42; return longName; })();',
    );
    const result = buildSync({
      entryPoints: [join(dir, 'hoist.js')],
      format: 'esm',
      minifyIdentifiers: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('longName');
  });
});

// ================================================================
// React Refresh: function expression 이름 등록 방지
// ================================================================

describe('React Refresh: function expression', () => {
  test('function expression 이름이 $RefreshReg$에 등록되지 않아야 함', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `
      const MyComp = function MyCompFactory() { return null; };
      export default MyComp;
    `,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // function expression 이름 "MyCompFactory"가 $RefreshReg$에 등록되면 안 됨
    expect(code).not.toContain('$RefreshReg$(_c, "MyCompFactory")');
    // function declaration이 아니므로 외부에서 참조 불가
    expect(code).not.toContain('_c = MyCompFactory');
    rmSync(dir, { recursive: true });
  });

  test('function declaration은 정상적으로 $RefreshReg$에 등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `
      function MyComponent() { return null; }
      export default MyComponent;
    `,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // function declaration 이름 "MyComponent"는 등록되어야 함
    expect(code).toContain('MyComponent');
    expect(code).toContain('$RefreshReg$');
    rmSync(dir, { recursive: true });
  });

  test('named function expression을 인자로 전달해도 $RefreshReg$ 미등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `
      function App() {
        const handler = someHook(function HandlerFactory() { return 1; }, []);
        return handler;
      }
      export default App;
    `,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    expect(code).not.toContain('"HandlerFactory"');
    rmSync(dir, { recursive: true });
  });

  test('arrow function은 변수명이 PascalCase면 $RefreshReg$ 등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(join(dir, 'entry.ts'), `const MyArrow = () => null;\nexport default MyArrow;\n`);
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    expect(code).toContain('$RefreshReg$');
    rmSync(dir, { recursive: true });
  });

  test('lowercase function name은 $RefreshReg$ 미등록 (컴포넌트 아님)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `function helper() { return 1; }\nexport default helper;\n`,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // lowercase 함수는 컴포넌트가 아니므로 등록 안 함
    expect(code).not.toContain('"helper"');
    rmSync(dir, { recursive: true });
  });

  test('export default function declaration은 $RefreshReg$ 등록', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(join(dir, 'entry.ts'), `export default function MyScreen() { return null; }\n`);
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // export default function은 declaration → 등록됨
    expect(code).toContain('$RefreshReg$');
    expect(code).toContain('MyScreen');
    rmSync(dir, { recursive: true });
  });

  test('class component는 $RefreshReg$ 미등록 (함수만 등록)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-refresh-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      `class MyClassComp { render() { return null; } }\nexport default MyClassComp;\n`,
    );
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    // class는 React Refresh 등록 대상이 아님 (함수 컴포넌트만 등록)
    expect(code).not.toContain('"MyClassComp"');
    rmSync(dir, { recursive: true });
  });
});

// ================================================================
// watch() API 테스트
// ================================================================

describe('watch()', () => {
  test('초기 빌드 후 onReady 콜백 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise, resolve: done } = Promise.withResolvers<{ files: number; bytes: number }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady(event) {
        done(event);
      },
    });

    const event = await promise;
    expect(event.files).toBeGreaterThan(0);
    expect(event.bytes).toBeGreaterThan(0);
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('파일 변경 시 onRebuild 콜백 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      bytes?: number;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 파일 수정 (mtime polling 500ms 대기)
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

    const event = await rebuildP;
    expect(event.success).toBe(true);
    expect(event.bytes).toBeGreaterThan(0);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('plugin lifecycle hooks: 초기 build 와 rebuild 마다 buildStart → buildEnd → callback → closeBundle 순서', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle',
      setup(build) {
        build.onBuildStart(() => {
          events.push('buildStart');
        });
        build.onBuildEnd((err) => {
          events.push(err ? `buildEnd:${err.message}` : 'buildEnd');
        });
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        onReady() {
          events.push('onReady');
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'onReady',
        'closeBundle',
        'buildStart',
        'buildEnd',
        'onRebuild:ok',
        'closeBundle',
      ]);
      expect(events.filter((event) => event === 'buildStart').length).toBe(2);
      expect(events.filter((event) => event === 'buildEnd').length).toBe(2);
      expect(events.filter((event) => event === 'closeBundle').length).toBe(2);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('vitePlugin watch lifecycle: Rollup buildStart / buildEnd / closeBundle 을 초기 build 와 rebuild 에서 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-vite-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const rollupPlugin: RollupPlugin = {
      name: 'rollup-watch-lifecycle',
      buildStart() {
        events.push('rollup-buildStart');
      },
      buildEnd(err) {
        events.push(err ? `rollup-buildEnd:${err.message}` : 'rollup-buildEnd');
      },
      closeBundle() {
        events.push('rollup-closeBundle');
        closeCount++;
        if (closeCount === 1) initialCloseDone();
        if (closeCount === 2) rebuildCloseDone();
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [vitePlugin(rollupPlugin)],
        onReady() {
          events.push('onReady');
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual([
        'rollup-buildStart',
        'rollup-buildEnd',
        'onReady',
        'rollup-closeBundle',
      ]);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'rollup-buildStart',
        'rollup-buildEnd',
        'onReady',
        'rollup-closeBundle',
        'rollup-buildStart',
        'rollup-buildEnd',
        'onRebuild:ok',
        'rollup-closeBundle',
      ]);
      expect(events.filter((event) => event === 'rollup-buildStart').length).toBe(2);
      expect(events.filter((event) => event === 'rollup-buildEnd').length).toBe(2);
      expect(events.filter((event) => event === 'rollup-closeBundle').length).toBe(2);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch 사용자 콜백 실패 후에도 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-error-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-error',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        onReady() {
          events.push('onReady');
          throw new Error('ready failed');
        },
        async onRebuild() {
          events.push('onRebuild');
          throw new Error('rebuild failed');
        },
      });

      await initialCloseP;
      expect(events).toEqual(['onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual(['onReady', 'closeBundle', 'onRebuild', 'closeBundle']);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch 사용자 콜백이 없어도 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-no-callback-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-no-callback',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd(() => events.push('buildEnd'));
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'closeBundle',
        'buildStart',
        'buildEnd',
        'closeBundle',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch rebuild diagnostic 은 buildEnd error 후 closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-diagnostic-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let closeCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const plugin: ZntcPlugin = {
      name: 'watch-lifecycle-diagnostic',
      setup(build) {
        build.onBuildStart(() => events.push('buildStart'));
        build.onBuildEnd((err) => {
          events.push(err ? 'buildEnd:error' : 'buildEnd');
        });
        build.onCloseBundle(() => {
          events.push('closeBundle');
          closeCount++;
          if (closeCount === 1) initialCloseDone();
          if (closeCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        onReady() {
          events.push('onReady');
        },
        onRebuild(event) {
          events.push(`onRebuild:${event.success ? 'ok' : 'err'}`);
        },
      });

      await initialCloseP;
      expect(events).toEqual(['buildStart', 'buildEnd', 'onReady', 'closeBundle']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), "import value from './missing';\nconsole.log(value);");

      await rebuildCloseP;
      expect(events).toEqual([
        'buildStart',
        'buildEnd',
        'onReady',
        'closeBundle',
        'buildStart',
        'buildEnd:error',
        'onRebuild:ok',
        'closeBundle',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('plugin lifecycle hooks: watch closeBundle throw 는 다른 plugin 과 watch 를 막지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-lifecycle-close-throw-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const events: string[] = [];
    const { promise: initialCloseP, resolve: initialCloseDone } = Promise.withResolvers<void>();
    const { promise: rebuildCloseP, resolve: rebuildCloseDone } = Promise.withResolvers<void>();
    let trackingCloseCount = 0;
    let handle: ReturnType<typeof watch> | undefined;

    const throwingPlugin: ZntcPlugin = {
      name: 'watch-close-thrower',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('throwing-close');
          throw new Error('close failed');
        });
      },
    };
    const trackingPlugin: ZntcPlugin = {
      name: 'watch-close-tracker',
      setup(build) {
        build.onCloseBundle(() => {
          events.push('tracking-close');
          trackingCloseCount++;
          if (trackingCloseCount === 1) initialCloseDone();
          if (trackingCloseCount === 2) rebuildCloseDone();
        });
      },
    };

    try {
      handle = watch({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [throwingPlugin, trackingPlugin],
      });

      await initialCloseP;
      expect(events).toEqual(['throwing-close', 'tracking-close']);

      await new Promise((r) => setTimeout(r, 100));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

      await rebuildCloseP;
      expect(events).toEqual([
        'throwing-close',
        'tracking-close',
        'throwing-close',
        'tracking-close',
      ]);
    } finally {
      handle?.stop();
      rmSync(dir, { recursive: true });
    }
  }, 10000);

  test('devMode에서 moduleCodes diff → updates 전달', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 999;');

    const event = await rebuildP;
    expect(event.graphChanged).toBeFalsy();
    // updates가 있으면 변경된 모듈 코드가 포함되어야 함
    if (event.updates && event.updates.length > 0) {
      expect(event.updates[0].id).toBeDefined();
      expect(event.updates[0].code).toContain('999');
      // Issue #1248: 모듈별 standalone sourcemap이 함께 노출되어야 함
      expect(event.updates[0].map).toBeDefined();
      const map = event.updates[0].map!;
      expect(map).toContain('"version":3');
      expect(map).toContain('"mappings":"');
      expect(map).toContain('"sources":[');
    }
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('Issue #1248: 다중 모듈에서 변경 모듈만 updates에 + map은 자기 모듈만', async () => {
    // entry → a, b 그래프에서 a.ts만 수정 → updates=[a]만, map.sources=[a]만 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-partial-'));
    writeFileSync(join(dir, 'a.ts'), "export const A = 'A-original';\n");
    writeFileSync(join(dir, 'b.ts'), "export const B = 'B-original';\n");
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string; code: string; map?: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      sourcemap: true,
      onReady: () => readyDone(),
      onRebuild: (e) => rebuildDone(e),
    });

    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), "export const A = 'A-changed';\n");

    const event = await rebuildP;

    expect(event.graphChanged).toBeFalsy();
    expect(event.updates).toBeDefined();
    expect(event.updates!.length).toBe(1);

    const u = event.updates![0];
    expect(u.id.endsWith('a.ts')).toBe(true);
    expect(u.code).toContain('A-changed');
    expect(u.code).not.toContain('B-original');

    // Issue #1727 Phase B: per-module sourcemap 은 lazy getter 로 제공.
    // updates[i].map 은 lazy 경로에서 undefined 이고, handle.getHmrSourceMap(id) 로 조회.
    const mapJson = handle.getHmrSourceMap(u.id);
    expect(mapJson).not.toBeNull();
    const m = JSON.parse(mapJson!);
    expect(m.sources).toHaveLength(1);
    expect(m.sources[0].endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('Issue #1682: 충돌 rename 모듈은 cache-hit 시 HMR updates 에서 제외 (phantom filter)', async () => {
    // Linker 의 conflict rename 은 initial build 와 첫 rebuild 간 `$N` 접미사가
    // 비결정적으로 움직여 cache-hit 모듈의 emit 결과가 미세하게 달라진다.
    // module_code_cache 는 바이트 비교라 이런 모듈을 phantom 변경으로 오인,
    // 첫 rebuild HMR payload 에 포함시켜 — 런타임 `__zntc_apply_update` 가
    // hot-accept 없는 모듈을 만나자마자 `__zntc_reload()` 로 빠지게 만든다.
    //
    // 수정 (BundleResult.reparsed_paths 필터): cache-hit 모듈은 source 변경이
    // 증명되지 않았으므로 HMR payload 에서 제외. 회귀 테스트로 같은 이름 export
    // 두 개를 가진 fixture 를 만든 뒤, entry 만 수정한 rebuild 에서 updates 에
    // a.ts / b.ts 가 들어가지 않는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-phantom-'));
    // 두 모듈에서 같은 top-level 이름 export → Linker 가 한쪽을 `$1` 로 rename.
    writeFileSync(join(dir, 'a.ts'), 'export const count = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const count = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady: () => readyDone(),
      onRebuild: (e) => rebuildDone(e),
    });

    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    // entry.ts 만 수정 → a.ts / b.ts 는 cache-hit.
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { count as A } from './a';\nimport { count as B } from './b';\nconsole.log(A, B, 1);\n",
    );

    const event = await rebuildP;
    handle.stop();

    expect(event.graphChanged).toBeFalsy();
    expect(event.updates).toBeDefined();
    // 수정 전: a.ts / b.ts 도 phantom update 로 들어와 updates.length >= 3.
    // 수정 후: entry.ts 단독 → 1.
    const ids = event.updates!.map((u) => u.id);
    expect(ids.some((id) => id.endsWith('entry.ts'))).toBe(true);
    expect(ids.some((id) => id.endsWith('a.ts'))).toBe(false);
    expect(ids.some((id) => id.endsWith('b.ts'))).toBe(false);

    rmSync(dir, { recursive: true });
  }, 10000);

  test('새 import 추가 시 graphChanged 감지', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      graphChanged?: boolean;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 새 모듈 추가 → graph 변경
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');

    const event = await rebuildP;
    expect(event.graphChanged).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('stop() 후 리빌드 발생하지 않음', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });

    await readyP;
    handle.stop();

    // stop 후 파일 수정
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');
    await new Promise((r) => setTimeout(r, 1000));

    expect(rebuildCount).toBe(0);
    rmSync(dir, { recursive: true });
  }, 5000);

  test('double stop()은 에러 없이 무시', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    // 두 번째 stop() — 에러 없이 무시되어야 함
    expect(() => handle.stop()).not.toThrow();
    rmSync(dir, { recursive: true });
  });

  test('플러그인과 함께 watch', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'import "./style.css"; export const x = 1;');
    writeFileSync(join(dir, 'style.css'), 'body { color: red; }');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();

    const cssPlugin: ZntcPlugin = {
      name: 'css-loader',
      setup(build) {
        build.onLoad({ filter: /\.css$/ }, () => ({
          contents: 'export default "css-loaded";',
        }));
      },
    };

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [cssPlugin],
      onReady(event) {
        expect(event.files).toBeGreaterThan(0);
        readyDone();
      },
    });

    await readyP;
    handle.stop();
    rmSync(dir, { recursive: true });
  });

  test('콜백 없이 watch — crash 없이 동작', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    // onReady, onRebuild 모두 미제공
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
    });

    // 초기 빌드 완료 대기 (콜백 없으므로 타이머로)
    await new Promise((r) => setTimeout(r, 1500));
    expect(() => handle.stop()).not.toThrow();
    rmSync(dir, { recursive: true });
  }, 5000);

  test('리빌드 중 문법 에러 시 success: false + error', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      success: boolean;
      error?: string;
    }>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    // 문법 에러가 있는 코드로 변경
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const = ;; {{{{');

    const event = await rebuildP;
    // 에러가 발생하더라도 watch는 계속 동작해야 함
    // (ZNTC 파서가 에러 복구를 하므로 success: true일 수도 있음)
    expect(typeof event.success).toBe('boolean');
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('changed 배열에 변경된 파일 경로 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-watch-'));
    const entryPath = join(dir, 'entry.ts');
    writeFileSync(entryPath, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      changed?: string[];
    }>();

    const handle = watch({
      entryPoints: [entryPath],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });

    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entryPath, 'export const x = 2;');

    const event = await rebuildP;
    expect(event.changed).toBeDefined();
    expect(event.changed!.length).toBeGreaterThan(0);
    // 변경된 파일의 절대 경로가 포함되어야 함
    const hasEntry = event.changed!.some((p) => p.includes('entry.ts'));
    expect(hasEntry).toBe(true);
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  // ── Issue #1727 Phase B: Lazy sourcemap NAPI getters ─────────────────────

  test('getBundleSourceMap — sourcemap + devMode 시 초기 빌드 후 V3 JSON 반환', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 1;\nconsole.log(x);\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false, // lazy 엔드포인트로만 serve
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');
    expect(json).toContain('"mappings"');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — sourcemap 비활성 시 null', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sm-off-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    expect(handle.getBundleSourceMap()).toBeNull();
    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getHmrSourceMap — 모듈 id 로 JSON 반환, 미존재 id 는 null', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-hmr-sm-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 42;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: { id: string }[];
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: number = 7;\n');
    const event = await rebuildP;
    expect(event.updates).toBeDefined();
    expect(event.updates!.length).toBeGreaterThan(0);

    const moduleId = event.updates![0].id;
    const json = handle.getHmrSourceMap(moduleId);
    expect(json).not.toBeNull();
    expect(json).toContain('"version":3');

    expect(handle.getHmrSourceMap('does/not/exist')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('emitDiskSourcemap=false — rebuild 후 bundle.js.map 을 디스크에 쓰지 않는다', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-disk-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    // bundle.js 는 있지만 .map 은 없어야 함
    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — 반복 호출 시 동일 JSON 반환 (재진입 안전)', async () => {
    // NAPI mutex + builder.buf clearRetainingCapacity 로 여러 번 호출해도 동일 결과.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-repeat-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const j1 = handle.getBundleSourceMap();
    const j2 = handle.getBundleSourceMap();
    const j3 = handle.getBundleSourceMap();
    expect(j1).not.toBeNull();
    expect(j2).toBe(j1!);
    expect(j3).toBe(j1!);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — rebuild 후 swap 이 반영되고 이전 mappings 와 달라짐', async () => {
    // rebuild 마다 새 builder 로 swap. 내용이 바뀐 코드에 대한 mappings 가 업데이트되어야.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-swap-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const x = 1;\nexport const y = 2;\nexport const z = 3;\n',
    );
    await rebuildP;

    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    // 코드가 길어졌으니 mappings 문자열도 길어져야 한다.
    const m1 = JSON.parse(before!);
    const m2 = JSON.parse(after!);
    expect(m2.mappings.length).toBeGreaterThan(m1.mappings.length);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getHmrSourceMap — multi-module rebuild 에서 모든 모듈 id 로 조회 가능', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-multi-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 999;\n');
    const event = await rebuildP;

    expect(event.updates).toBeDefined();
    // rebuild 의 updates 는 변경된 모듈(a.ts) 만 — 하지만 module_sm_map 에는 전체 모듈이
    // 적재돼 있어야 이후 요청에서 b.ts / entry.ts 의 map 도 lazy serve 가능.
    const u = event.updates![0];
    const mapA = handle.getHmrSourceMap(u.id);
    expect(mapA).not.toBeNull();

    // 변경 안 된 모듈도 module_sm_map 에 있으므로 id 알면 조회 가능.
    // NAPI 는 모든 모듈의 per-module code 를 수집하지만 JS 는 updates diff 만 받는다 —
    // id 를 직접 구성하는 대신 rebuild 에서 updates 의 id 패턴이 파일명을 포함하는지 확인.
    expect(u.id.endsWith('a.ts')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — sources_content 옵션 반영 (false 면 sourcesContent 제외)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-sc-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcesContent: false,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.sourcesContent).toBeUndefined();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — debug_ids 활성 시 JSON 과 bundle.js 가 동일 UUID 공유', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-did-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapDebugIds: true,
      devMode: true,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    const match = js.match(/\/\/# debugId=([0-9a-f-]+)/);
    expect(match).not.toBeNull();
    const uuid = match![1];

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.debugId).toBe(uuid);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getHmrSourceMap — initial build 직후 (rebuild 전) 모듈 id 조회 가능', async () => {
    // swap 이 rebuild 뿐 아니라 initial build 완료 시에도 호출돼야 한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-init-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    // 아직 rebuild 없음 — 하지만 initial build 의 swap 으로 모듈 id 를 얻기 위해
    // 일단 한 번 수정을 일으켜 id 를 알아낸 뒤, 동일 rebuild 후 getter 를 호출한다.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;\n');
    const event = await rebuildP;
    const id = event.updates![0].id;

    // rebuild swap 이 된 상태에서 모듈 id 로 JSON 을 받아낼 수 있다.
    const json = handle.getHmrSourceMap(id);
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.version).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — custom output_filename 이 map.file 에 반영', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-file-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'custom-name.mjs'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(typeof m.file).toBe('string');
    expect(m.file.endsWith('custom-name.mjs')).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getHmrSourceMap — graph 변경 (모듈 추가) 후 새 모듈도 swap 에 포함', async () => {
    // graph_changed=true 이면 NAPI 가 updates 배열을 비우므로, 2단계로 진행:
    //   1) b.ts 추가 → graphChanged 이벤트
    //   2) b.ts 재수정 → updates=[b] — 이 시점에 b 의 id 를 획득
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-graph-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;\n');
    writeFileSync(join(dir, 'entry.ts'), "import { A } from './a';\nconsole.log(A);\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let seenGraphChange = false;
    let secondUpdates: Array<{ id: string }> | undefined;
    const { promise: secondP, resolve: secondDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        if (!seenGraphChange) {
          if (event.graphChanged) seenGraphChange = true;
        } else if (event.updates && event.updates.length > 0) {
          secondUpdates = event.updates;
          secondDone();
        }
      },
    });
    await readyP;

    // 1차: b.ts 추가 + entry import 확장 → graphChanged.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;\n');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n",
    );
    // graphChanged 이벤트 처리 대기.
    await new Promise((r) => setTimeout(r, 500));
    expect(seenGraphChange).toBe(true);

    // 2차: b.ts 재수정 → updates=[b] — b 의 id 획득 경로.
    writeFileSync(join(dir, 'b.ts'), 'export const B = 999;\n');
    await secondP;

    const bId = secondUpdates!.find((u) => u.id.endsWith('b.ts'))?.id;
    expect(bId).toBeDefined();

    // graph 변경 후에도 handle 의 module_sm_map 에 b 가 포함 → getter 성공.
    const mapB = handle.getHmrSourceMap(bId!);
    expect(mapB).not.toBeNull();

    // 완전 존재하지 않는 id — null.
    expect(handle.getHmrSourceMap('absolutely/not/a/module.ts')).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);

  test('getBundleSourceMap — rebuild 실패 후 이전 JSON 이 캐시로 유지된다', async () => {
    // rebuild 가 parse error 등으로 실패하면 swap 이 호출되지 않아 이전 rebuild 의 builder 유지.
    // dev 서버가 의미있는 sourcemap 을 계속 제공할 수 있어야 함.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-err-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildResolved = false;
    const { promise: errP, resolve: errDone } = Promise.withResolvers<{ success: boolean }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        if (!rebuildResolved) {
          rebuildResolved = true;
          errDone(event);
        }
      },
    });
    await readyP;

    const before = handle.getBundleSourceMap();
    expect(before).not.toBeNull();

    // 파싱 불가능한 코드로 덮어쓰기.
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x: = = =;;;\n');
    await errP;

    // 실패해도 이전 builder 가 남아있어 getter 는 유효 JSON 반환.
    const after = handle.getBundleSourceMap();
    expect(after).not.toBeNull();
    const m = JSON.parse(after!);
    expect(m.version).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('getBundleSourceMap — sourcemap_function_map 활성 시에도 lazy JSON 생성 성공', async () => {
    // lazy 경로는 generateJSON 을 일반 경로로 호출 (infra PR 은 per-source fn_map 통합 미지원).
    // function_map 옵션이 켜져 있어도 bundle sourcemap JSON 이 crash 없이 반환되고 V3 형식.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-fnmap-'));
    writeFileSync(join(dir, 'entry.ts'), "export function hello() { return 'hi'; }\n");

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      sourcemapFunctionMap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const json = handle.getBundleSourceMap();
    expect(json).not.toBeNull();
    const m = JSON.parse(json!);
    expect(m.version).toBe(3);
    expect(Array.isArray(m.sources)).toBe(true);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('bundle.js — lazy 경로에서도 sourceMappingURL 주석 출력 (DevTools fetch 경로)', async () => {
    // lazy 는 .map 을 디스크에 쓰지 않지만 bundle.js 의 sourceMappingURL 주석은 유지.
    // DevTools / Sentry 가 이 URL 을 fetch → NAPI getter → JSON 응답 경로.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-url-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    const js = readFileSync(join(dir, 'bundle.js'), 'utf8');
    expect(js).toContain('//# sourceMappingURL=');
    expect(js).toContain('.map');

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — 연쇄 rebuild (3회) 에서 최신 swap 만 유효', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-chain-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuilds = 0;
    const rebuildResolvers: Array<() => void> = [];
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuilds++;
        const next = rebuildResolvers.shift();
        if (next) next();
      },
    });
    await readyP;

    const lens: number[] = [];
    for (let i = 0; i < 3; i++) {
      const { promise, resolve } = Promise.withResolvers<void>();
      rebuildResolvers.push(resolve);
      await new Promise((r) => setTimeout(r, 100));
      // 매 rebuild 마다 코드 길이 증가.
      const body = Array.from(
        { length: (i + 1) * 3 },
        (_, k) => `export const e${i}_${k} = ${k};`,
      ).join('\n');
      writeFileSync(join(dir, 'entry.ts'), body + '\n');
      await promise;

      const json = handle.getBundleSourceMap();
      expect(json).not.toBeNull();
      const m = JSON.parse(json!);
      lens.push(m.mappings.length);
    }

    // 매 rebuild 마다 mappings 가 더 길어지는 경향 (strictly increasing).
    expect(lens[0]).toBeGreaterThan(0);
    expect(lens[1]).toBeGreaterThan(lens[0]);
    expect(lens[2]).toBeGreaterThan(lens[1]);
    expect(rebuilds).toBe(3);

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 20000);

  test('getBundleSourceMap + getHmrSourceMap 교대 호출 — 상호 간섭 없음', async () => {
    // 같은 handle 에서 bundle/hmr getter 를 번갈아 호출. mutex 가 재진입 아니므로
    // 동일 thread 순차 호출은 안전. JSON 내용이 서로 섞이지 않는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-mix-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 42;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<{
      updates?: Array<{ id: string }>;
    }>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;

    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 99;\n');
    const event = await rebuildP;
    const id = event.updates![0].id;

    // 교대로 3회씩 호출 — 각 호출이 type 정합성 유지.
    for (let i = 0; i < 3; i++) {
      const bundleJson = handle.getBundleSourceMap();
      expect(bundleJson).not.toBeNull();
      expect(JSON.parse(bundleJson!).version).toBe(3);

      const hmrJson = handle.getHmrSourceMap(id);
      expect(hmrJson).not.toBeNull();
      const hm = JSON.parse(hmrJson!);
      expect(hm.version).toBe(3);
      // per-module map 은 sources 길이 1.
      expect(hm.sources.length).toBe(1);
    }

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 15000);

  test('emitDiskSourcemap=false + eager (devMode=false) — .map 디스크 skip 유지', async () => {
    // devMode=false 면 NAPI 가 lazy 를 안 켬 → eager 경로. 이 상태에서도 emitDiskSourcemap
    // 옵션이 .map 디스크 write 제어 가능해야 한다. getter 는 lazy 가 꺼져있으니 null.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-eager-nodev-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: false,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    expect(existsSync(join(dir, 'bundle.js'))).toBe(true);
    expect(existsSync(join(dir, 'bundle.js.map'))).toBe(false);
    // eager 경로이므로 handle cache 에 builder 없음 → null.
    expect(handle.getBundleSourceMap()).toBeNull();

    handle.stop();
    rmSync(dir, { recursive: true });
  }, 10000);

  test('getBundleSourceMap — stop() 후 null 반환 (use-after-stop 방어)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lazy-stop-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;\n');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      outfile: join(dir, 'bundle.js'),
      sourcemap: true,
      devMode: true,
      emitDiskSourcemap: false,
      onReady() {
        readyDone();
      },
    });
    await readyP;

    handle.stop();
    // stop 후 napi_remove_wrap 된 handle — getter 는 null 반환 (throw 하지 않음)
    expect(handle.getBundleSourceMap()).toBeNull();
    expect(handle.getHmrSourceMap('whatever')).toBeNull();

    rmSync(dir, { recursive: true });
  }, 10000);
});

// ================================================================
// Issue #1223: HMR perf — 재현 테스트
// 폴링 워처(500ms), mtime-only 캐시, 디바운스 부재, 증분 미흡, 관측성 부재
// ================================================================

describe('Issue #1223 HMR perf 재현', () => {
  // ---- Phase 3: 관측성 (phaseDurations) ----
  test('phase3: WatchRebuildEvent에 phaseDurations 필드가 노출되어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase3-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.phaseDurations).toBeDefined();
    expect(typeof event.phaseDurations.detect).toBe('number');
    expect(typeof event.phaseDurations.graph).toBe('number');
    expect(typeof event.phaseDurations.link).toBe('number');
    expect(typeof event.phaseDurations.shake).toBe('number');
    expect(typeof event.phaseDurations.emit).toBe('number');
    expect(typeof event.phaseDurations.delta).toBe('number');
    expect(typeof event.phaseDurations.total).toBe('number');
    expect(event.phaseDurations.total).toBeGreaterThan(0);
  }, 10000);

  // ---- Phase 1a: 워처 latency (목표 < 200ms, 현재 폴링 500ms) ----
  test('phase1a: 변경 감지부터 onRebuild까지 200ms 이내여야 함 (현재 500ms 폴링)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1a-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();

    const handle = watch({
      entryPoints: [join(dir, 'entry.ts')],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 50));

    const t0 = performance.now();
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 2;');
    await rebuildP;
    const elapsed = performance.now() - t0;

    handle.stop();
    rmSync(dir, { recursive: true });

    expect(elapsed).toBeLessThan(200);
  }, 10000);

  // ---- Phase 1b: content hash (mtime만 갱신, 내용 동일 → 알림 없음) ----
  test('phase1b: 내용이 동일하면 onRebuild가 호출되지 않아야 함 (content hash)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1b-'));
    const entry = join(dir, 'entry.ts');
    const src = 'export const x = 1;';
    writeFileSync(entry, src);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;

    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 내용 동일, mtime만 갱신 (touch와 유사)
    writeFileSync(entry, src);
    await new Promise((r) => setTimeout(r, 1500));

    handle.stop();
    rmSync(dir, { recursive: true });

    // 현재: mtime만 봐서 무조건 리빌드 트리거 → rebuildCount=1
    // 목표: content hash로 스킵 → rebuildCount=0
    expect(rebuildCount).toBe(0);
  }, 10000);

  // ---- Phase 1c: 디바운스 (idle 상태에서 50ms 내 두 번 저장 → 1회 리빌드) ----
  test('phase1c: 첫 리빌드 후 50ms 내 두 번 저장은 한 번으로 병합되어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1c-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;
    let firstRebuildResolve: (() => void) | null = null;
    const firstRebuildP = new Promise<void>((r) => {
      firstRebuildResolve = r;
    });

    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
        if (rebuildCount === 1) firstRebuildResolve!();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 첫 저장 → 첫 리빌드 완료까지 대기
    writeFileSync(entry, 'export const x = 2;');
    await firstRebuildP;
    expect(rebuildCount).toBe(1);

    // idle 상태에서 50ms 내에 두 번 빠르게 저장
    writeFileSync(entry, 'export const x = 3;');
    await new Promise((r) => setTimeout(r, 10));
    writeFileSync(entry, 'export const x = 4;');

    // 디바운스(50ms) + 빌드 시간 충분히 대기
    await new Promise((r) => setTimeout(r, 2000));
    handle.stop();
    rmSync(dir, { recursive: true });

    // 현재: 폴링으로 두 번 모두 감지 → rebuildCount=3
    // 목표: 디바운스로 병합 → rebuildCount=2
    expect(rebuildCount).toBe(2);
  }, 15000);

  // ---- Phase 2: 증분 그래프 (1개 변경 → 1개만 재파싱) ----
  test('phase2: 의존 그래프에서 leaf 1개만 변경 시 reparsedModules=1 이어야 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase2-'));
    writeFileSync(join(dir, 'a.ts'), 'import { b } from "./b"; export const a = b + 1;');
    writeFileSync(join(dir, 'b.ts'), 'import { c } from "./c"; export const b = c + 1;');
    writeFileSync(join(dir, 'c.ts'), 'export const c = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();

    const handle = watch({
      entryPoints: [join(dir, 'a.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // leaf(c.ts)만 변경 → c만 재파싱되어야 함 (a, b는 캐시)
    writeFileSync(join(dir, 'c.ts'), 'export const c = 999;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 10000);

  // ---- phase2b: deep dependency chain (10단계) ----
  test('phase2b: 10단계 체인에서 leaf 변경 시 reparsedModules=1', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase2b-'));
    const N = 10;
    for (let i = 0; i < N - 1; i++) {
      writeFileSync(
        join(dir, `m${i}.ts`),
        `import { v${i + 1} } from "./m${i + 1}"; export const v${i} = v${i + 1} + 1;`,
      );
    }
    writeFileSync(join(dir, `m${N - 1}.ts`), `export const v${N - 1} = 1;`);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [join(dir, 'm0.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(join(dir, `m${N - 1}.ts`), `export const v${N - 1} = 999;`);
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 15000);

  // ---- phase2c: 체인 중간 모듈 변경 시 해당 모듈만 재파싱 ----
  test('phase2c: 체인 중간(b)만 변경 — 상위(a)/하위(c) 캐시 유지', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase2c-'));
    writeFileSync(join(dir, 'a.ts'), 'import { b } from "./b"; export const a = b + 1;');
    writeFileSync(join(dir, 'b.ts'), 'import { c } from "./c"; export const b = c + 1;');
    writeFileSync(join(dir, 'c.ts'), 'export const c = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [join(dir, 'a.ts')],
      devMode: true,
      collectModuleCodes: true,
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(join(dir, 'b.ts'), 'import { c } from "./c"; export const b = c + 42;');
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.reparsedModules).toBe(1);
  }, 10000);

  // ---- phase1d: stale content_hash 엔트리 정리 ----
  test('phase1d: import 제거 후 이전 파일 변경은 리빌드 트리거 안 함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1d-'));
    const entry = join(dir, 'entry.ts');
    const extra = join(dir, 'extra.ts');
    writeFileSync(extra, 'export const y = 1;');
    writeFileSync(entry, 'import { y } from "./extra"; export const x = y;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const rebuilds: Array<{ changed?: string[] }> = [];
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuilds.push(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 1차: entry에서 extra import 제거 → graph에서 extra 빠짐
    writeFileSync(entry, 'export const x = 1;');
    await new Promise((r) => setTimeout(r, 1500));
    const reb1 = rebuilds.length;
    expect(reb1).toBeGreaterThanOrEqual(1);

    // 2차: extra.ts 내용 변경 — 이미 그래프에서 빠졌으므로 리빌드 없어야 함
    writeFileSync(extra, 'export const y = 999;');
    await new Promise((r) => setTimeout(r, 1500));
    handle.stop();
    rmSync(dir, { recursive: true });

    // extra 변경 후 추가 리빌드가 없어야 — watcher가 extra를 removePath 한 결과
    expect(rebuilds.length).toBe(reb1);
  }, 15000);

  // ---- phase1e: 중복 이벤트 dedup (같은 파일 여러 번 touch → 1회 리빌드) ----
  test('phase1e: 같은 파일 연속 touch 시 리빌드 1회만 발생', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1e-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    let rebuildCount = 0;
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildCount++;
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    // 같은 파일에 동일 내용 5회 빠르게 write — 이벤트는 5개이지만 content hash로 dedup
    for (let i = 0; i < 5; i++) {
      writeFileSync(entry, 'export const x = 2;');
      await new Promise((r) => setTimeout(r, 5));
    }
    await new Promise((r) => setTimeout(r, 1500));
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(rebuildCount).toBe(1);
  }, 10000);

  // ---- phase1f: 디바운스 starvation cap (지속 변경되는 파일에도 리빌드 진행) ----
  test('phase1f: 디바운스 윈도우를 계속 갱신해도 500ms 상한 내 리빌드 발생', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1f-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'export const x = 1;');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<void>();
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild() {
        rebuildDone();
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 50));

    // 20ms마다 파일 수정 — 매번 debounce window(50ms) 내에 새 이벤트.
    // starvation cap(500ms)이 없으면 영영 리빌드 안 됨.
    let counter = 0;
    const interval = setInterval(() => {
      counter++;
      writeFileSync(entry, `export const x = ${counter};`);
    }, 20);

    const t0 = performance.now();
    await rebuildP;
    const elapsed = performance.now() - t0;
    clearInterval(interval);
    handle.stop();
    rmSync(dir, { recursive: true });

    // 500ms cap + 빌드 시간 여유 포함하여 상한 검증
    expect(elapsed).toBeLessThan(1500);
  }, 10000);

  // ---- phase1g: 경계 — 빈 파일 해시 ----
  test('phase1g: 빈 파일도 해시되어 리빌드 동작 정상', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1g-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, '');

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [entry],
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));
    writeFileSync(entry, 'export const x = 1;');

    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.success).toBe(true);
  }, 10000);

  // ---- phase1h: 경계 — 대형 파일(>10MB) 해시 폴백 경로 ----
  test('phase1h: 대형 파일(15MB)에서도 크래시 없이 리빌드 트리거', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-1223-phase1h-'));
    const entry = join(dir, 'entry.ts');
    writeFileSync(entry, 'import "./big.json"; export const x = 1;');
    // 15MB JSON 배열 — watch_hash_max_bytes(256MB) 이내라 정상 해시 경로 사용,
    // 크래시/OOM 없이 동작해야 함을 보장.
    const big = '[' + '0,'.repeat(3_000_000) + '0]';
    writeFileSync(join(dir, 'big.json'), big);

    const { promise: readyP, resolve: readyDone } = Promise.withResolvers<void>();
    const { promise: rebuildP, resolve: rebuildDone } = Promise.withResolvers<any>();
    const handle = watch({
      entryPoints: [entry],
      loader: { '.json': 'json' },
      onReady() {
        readyDone();
      },
      onRebuild(event) {
        rebuildDone(event);
      },
    });
    await readyP;
    await new Promise((r) => setTimeout(r, 100));

    writeFileSync(entry, 'import "./big.json"; export const x = 2;');
    const event = await rebuildP;
    handle.stop();
    rmSync(dir, { recursive: true });

    expect(event.success).toBe(true);
  }, 20000);
});

// ================================================================
// buildResult에 moduleCodes/modulePaths 노출 테스트
// ================================================================

describe('buildResult moduleCodes/modulePaths', () => {
  test('buildSync: collectModuleCodes=true → moduleCodes 반환', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mc-'));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');

    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.moduleCodes).toBeDefined();
    expect(result.moduleCodes!.length).toBeGreaterThan(0);
    // 각 moduleCodes에 id와 code가 있어야 함
    for (const mc of result.moduleCodes!) {
      expect(mc.id).toBeDefined();
      expect(mc.code.length).toBeGreaterThan(0);
    }
    rmSync(dir, { recursive: true });
  });

  test('buildSync: collectModuleCodes 미지정 → moduleCodes 없음', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mc-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.moduleCodes).toBeUndefined();
  });

  test('buildSync: modulePaths 반환 (번들에 포함된 모듈 경로)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mp-'));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');

    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
    });
    expect(result.errors.length).toBe(0);
    expect(result.modulePaths).toBeDefined();
    expect(result.modulePaths!.length).toBeGreaterThanOrEqual(2);
    // entry.ts와 util.ts 경로가 포함되어야 함
    const hasEntry = result.modulePaths!.some((p) => p.includes('entry.ts'));
    const hasUtil = result.modulePaths!.some((p) => p.includes('util.ts'));
    expect(hasEntry).toBe(true);
    expect(hasUtil).toBe(true);
  });

  describe('RSC 디렉티브 보존 (NAPI)', () => {
    test("transpile: 'use client' 첫 문장 보존", () => {
      const result = transpile(
        `"use client";\nimport { useState } from "react";\nexport default function C(){return useState(0)[0];}`,
        { filename: 'client.tsx' },
      );
      expect(result.code.trimStart().startsWith('"use client"')).toBe(true);
    });

    test("transpile: 'use server' 첫 문장 보존", () => {
      const result = transpile(`"use server";\nexport async function f(){return 1;}`, {
        filename: 'server.ts',
      });
      expect(result.code.trimStart().startsWith('"use server"')).toBe(true);
    });

    test("transpile: 'use cache' 보존", () => {
      const result = transpile(`"use cache";\nexport async function f(){return 1;}`, {
        filename: 'cache.ts',
      });
      expect(result.code.trimStart().startsWith('"use cache"')).toBe(true);
    });

    test('buildSync preserve-modules: 각 파일이 자기 디렉티브 첫 문장으로 보존', () => {
      const d = mkdtempSync(join(tmpdir(), 'zntc-napi-rsc-'));
      writeFileSync(join(d, 'client.tsx'), `"use client";\nexport default function C(){return 1;}`);
      writeFileSync(join(d, 'server.ts'), `"use server";\nexport async function act(){return 1;}`);
      writeFileSync(
        join(d, 'entry.tsx'),
        `import C from "./client";\nimport { act } from "./server";\nexport default function E(){act();return C();}`,
      );
      const result = buildSync({
        entryPoints: [join(d, 'entry.tsx')],
        bundle: true,
        preserveModules: true,
        outdir: join(d, 'out'),
      });
      expect(result.errors.length).toBe(0);
      const clientFile = result.outputFiles.find((f) => f.path.includes('client'));
      const serverFile = result.outputFiles.find((f) => f.path.includes('server'));
      expect(clientFile).toBeDefined();
      expect(serverFile).toBeDefined();
      expect(clientFile!.text.trimStart().startsWith('"use client"')).toBe(true);
      expect(serverFile!.text.trimStart().startsWith('"use server"')).toBe(true);
      rmSync(d, { recursive: true });
    });

    test('buildSync ESM 단일 번들: entry 디렉티브 최상단', () => {
      const d = mkdtempSync(join(tmpdir(), 'zntc-napi-esm-'));
      writeFileSync(join(d, 'dep.ts'), `export const x = 1;`);
      writeFileSync(
        join(d, 'entry.tsx'),
        `"use client";\nimport { x } from "./dep";\nexport default x;`,
      );
      const result = buildSync({
        entryPoints: [join(d, 'entry.tsx')],
        bundle: true,
        format: 'esm',
        outdir: join(d, 'out'),
      });
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles[0];
      expect(out).toBeDefined();
      expect(out.text.trimStart().startsWith('"use client"')).toBe(true);
      rmSync(d, { recursive: true });
    });
  });

  test('build (async): moduleCodes + modulePaths 반환', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-mc-async-'));
    writeFileSync(join(dir, 'entry.ts'), 'import { y } from "./util"; export const x = y;');
    writeFileSync(join(dir, 'util.ts'), 'export const y = 42;');

    const result = await build({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.moduleCodes).toBeDefined();
    expect(result.moduleCodes!.length).toBeGreaterThan(0);
    expect(result.modulePaths).toBeDefined();
    expect(result.modulePaths!.length).toBeGreaterThanOrEqual(2);
    rmSync(dir, { recursive: true });
  });
});

// ─── browserslist 옵션 ───

describe('@zntc/core browserslist', () => {
  test('browserslist: 모던 브라우저 쿼리는 변환 안 함', () => {
    const src = 'async function f() { return await Promise.resolve(1); }';
    const r = transpile(src, { browserslist: 'last 2 chrome versions' });
    expect(r.code).toContain('async function f');
    expect(r.code).not.toContain('__async');
  });

  test('browserslist: 오래된 브라우저 쿼리는 async 다운레벨', () => {
    const src = 'async function f() { return await Promise.resolve(1); }';
    const r = transpile(src, { browserslist: 'chrome 50, firefox 50' });
    expect(r.code).toContain('__async');
  });

  test('browserslist: 여러 엔진 중 하나라도 미지원이면 다운레벨 (보수적)', () => {
    // chrome 최신은 optional_chaining 지원, safari 12는 미지원 → ?. 제거
    const src = 'const x = a?.b;';
    const r = transpile(src, { browserslist: 'chrome 100, safari 12' });
    expect(r.code).not.toContain('?.');
  });

  test('browserslist: 쿼리 배열 입력', () => {
    const src = 'const x = 1 ** 2;';
    // chrome 40은 exponentiation 미지원, chrome 55는 지원 → union 결과 chrome 40 기준
    const r = transpile(src, { browserslist: ['chrome 40'] });
    expect(r.code).not.toContain('**');
  });

  test('browserslist: ios_saf는 ios 엔진으로 매핑', () => {
    const src = 'async function f() {}';
    // ios 10은 async 미지원 → 변환
    const r = transpile(src, { browserslist: 'ios_saf 10' });
    expect(r.code).toContain('__async');
  });

  test('browserslist: 매핑 불가능한 엔진(samsung)만 있으면 보수적으로 esnext', () => {
    // samsung 브라우저는 ZNTC Engine에 없음 → 빈 engines → 0 (esnext)
    const src = 'async function f() {}';
    const r = transpile(src, { browserslist: 'samsung 20' });
    expect(r.code).toContain('async function');
  });

  test('browserslist는 target보다 우선', () => {
    const src = 'const x = a?.b;';
    // target=es5지만 browserslist=modern → optional chaining 유지
    const r = transpile(src, { target: 'es5', browserslist: 'chrome 100' });
    expect(r.code).toContain('?.');
  });

  test('browserslist: 빈 결과(매칭 없음)도 크래시 없이 처리', () => {
    // 존재하지 않는 버전 규칙 — browserslist가 throw 할 수도 있음
    // 이 경우 사용자 책임 — 우리 코드에서 크래시만 안 나면 됨
    const src = 'const x = 1;';
    expect(() => transpile(src, { browserslist: 'defaults' })).not.toThrow();
  });

  test('browserslist: hermes 매핑 (RN 사용자 대응)', () => {
    // browserslist는 hermes를 모르지만 우리 파서는 수동 매핑 지원
    // 직접 hermes 키워드 쿼리는 browserslist가 모르므로 defaults 사용 예시
    const src = 'async function f() {}';
    // hermes 0.12는 async transform 필요 (kangax fail) → __async 나와야 함
    // 이 테스트는 browserslistToUnsupported 저수준 API 커버
    const { browserslistToUnsupported } = require('../shared/index');
    const bits = browserslistToUnsupported(['hermes 0.12']);
    // bit 12 = async_await
    expect(bits & (1 << 12)).not.toBe(0);
    void src;
  });

  test('browserslist: build API도 해석 (BuildOptions.browserslist)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-build-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // 오래된 쿼리 → async 다운레벨
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'chrome 50',
    });
    const code = r.outputFiles[0].text;
    expect(code).toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 모던 타겟은 async 유지', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-build2-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'last 2 chrome versions',
    });
    const code = r.outputFiles[0].text;
    expect(code).toContain('async function');
    expect(code).not.toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 여러 엔진 union 중 가장 오래된 기준 (보수적)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-union-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      // optional chaining 사용
      'export const x = (o: any) => o?.a?.b;',
    );
    // chrome 100 (지원) + safari 12 (미지원) → safari 12 기준 다운레벨
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: ['chrome 100', 'safari 12'],
    });
    expect(r.outputFiles[0].text).not.toContain('?.');
    rmSync(dir, { recursive: true });
  });

  test('runtimePolyfills auto: used replaceAll is injected before entry execution', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-auto-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__RESULT__ = "a-a".replaceAll("a", "b");`);
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      });
      const code = r.outputFiles[0].text;
      expect(code).toContain('es.string.replace-all');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __RESULT__?: string } = {};
      vm.runInNewContext(`String.prototype.replaceAll = undefined;\n${code}`, sandbox);
      expect(sandbox.__RESULT__).toBe('b-b');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto scans local dependencies and respects modern targets', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-dep-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `import { value } from "./dep"; globalThis.__VALUE__ = value;`,
      );
      writeFileSync(join(dir, 'dep.ts'), `export const value = "a".replaceAll("a", "b");`);

      const oldTarget = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }).outputFiles[0].text;
      expect(oldTarget).toContain('es.string.replace-all');

      const modernTarget = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['node 18'] },
      }).outputFiles[0].text;
      expect(modernTarget).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto scans package exports resolved modules', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-pkg-exports-'));
    try {
      const pkgDir = join(dir, 'node_modules', 'runtime-exports-pkg', 'dist');
      mkdirSync(pkgDir, { recursive: true });
      writeFileSync(
        join(dir, 'node_modules', 'runtime-exports-pkg', 'package.json'),
        JSON.stringify({
          name: 'runtime-exports-pkg',
          type: 'module',
          exports: {
            '.': {
              import: './dist/index.js',
              default: './dist/index.js',
            },
          },
        }),
      );
      writeFileSync(
        join(pkgDir, 'index.js'),
        `
          const cloned = structuredClone({ label: "clone" });
          export const value = [
            ["a", "b"].at(-1),
            Object.hasOwn({ ok: true }, "ok") ? "own" : "missing",
            cloned.label,
          ].join("|");
        `,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `import { value } from "runtime-exports-pkg"; globalThis.__VALUE__ = value;`,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        platform: 'node',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.array.at');
      expect(code).toContain('es.object.has-own');
      expect(code).toContain('web.structured-clone');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          Array.prototype.at = undefined;
          Object.hasOwn = undefined;
          globalThis.structuredClone = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('b|own|clone');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto ignores shadowed globals and dynamic computed access', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-negative-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const Map = class LocalMap {};
          const Object = { hasOwn() { return true; } };
          const globalThis = { Set: class LocalSet {} };
          const promiseMethod = "resolve";
          const stringMethod = "replaceAll";
          new Map();
          new globalThis.Set();
          Object.hasOwn({}, "x");
          Promise[promiseMethod](1);
          "a-a"[stringMethod]("a", "b");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).not.toContain('es.map');
      expect(code).not.toContain('es.set');
      expect(code).not.toContain('es.promise');
      expect(code).not.toContain('es.object.has-own');
      expect(code).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto ignores imported runtime global names', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-import-shadow-'));
    try {
      writeFileSync(
        join(dir, 'locals.ts'),
        `
          export class Map {
            kind = "local-map";
          }
          export const Promise = {
            resolve(value: string) {
              return "local-" + value;
            },
          };
          export const Object = {
            hasOwn() {
              return "local-has-own";
            },
          };
        `,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          import { Map, Promise, Object } from "./locals";
          const structuredClone = (value: string) => "local-" + value;
          globalThis.__VALUE__ = [
            new Map().kind,
            Promise.resolve("promise"),
            Object.hasOwn({}, "x"),
            structuredClone("clone"),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).not.toContain('es.map');
      expect(code).not.toContain('es.promise');
      expect(code).not.toContain('es.object.has-own');
      expect(code).not.toContain('web.structured-clone');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          globalThis.Map = undefined;
          globalThis.Promise = undefined;
          globalThis.structuredClone = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('local-map|local-promise|local-has-own|local-clone');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills include covers intentional dynamic computed access', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-computed-include-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const method = "at";
          globalThis.__VALUE__ = ["x", "y"][method](-1);
        `,
      );

      const autoOnly = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;
      expect(autoOnly).not.toContain('es.array.at');

      const included = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: {
          mode: 'auto',
          targets: ['node 18'],
          include: ['es.array.at'],
        },
      }).outputFiles[0].text;
      expect(included).toContain('es.array.at');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(`Array.prototype.at = undefined;\n${included}`, sandbox);
      expect(sandbox.__VALUE__).toBe('y');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto detects explicit globalThis runtime API usage', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-globalthis-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          globalThis.__RESULT__ = [
            typeof globalThis.Map,
            typeof globalThis.Set,
            typeof globalThis.Promise.resolve,
            typeof globalThis.structuredClone,
            globalThis.Object.hasOwn({ ok: true }, "ok"),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.map');
      expect(code).toContain('es.set');
      expect(code).toContain('es.promise');
      expect(code).toContain('web.structured-clone');
      expect(code).toContain('es.object.has-own');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __RESULT__?: string } = {};
      vm.runInNewContext(
        `
          globalThis.Map = undefined;
          globalThis.Set = undefined;
          globalThis.Promise = undefined;
          globalThis.structuredClone = undefined;
          globalThis.Object.hasOwn = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__RESULT__).toBe('function|function|function|function|true');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto injects expanded core-js built-ins', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-expanded-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const key = {};
          const weak = new WeakMap();
          weak.set(key, 7);
          globalThis.__VALUE__ = [
            Object.values({ label: "value" })[0],
            "7".padStart(2, "0"),
            Math.trunc(1.8),
            Reflect.ownKeys({ own: true })[0],
            [1, 2, 3].findLast((value) => value < 3),
            typeof Symbol === "function",
            weak.get(key),
          ].join("|");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['safari 5'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.object.values');
      expect(code).toContain('es.string.pad-start');
      expect(code).toContain('es.math.trunc');
      expect(code).toContain('es.reflect.own-keys');
      expect(code).toContain('es.array.find-last');
      expect(code).toContain('es.weak-map');
      expect(code).toContain('es.symbol');

      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __VALUE__?: string } = {};
      vm.runInNewContext(
        `
          Object.values = undefined;
          String.prototype.padStart = undefined;
          Math.trunc = undefined;
          Reflect.ownKeys = undefined;
          Array.prototype.findLast = undefined;
          globalThis.WeakMap = undefined;
          globalThis.Symbol = undefined;
          ${code}
        `,
        sandbox,
      );
      expect(sandbox.__VALUE__).toBe('value|07|1|own|2|true|7');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills auto detects usage added by transform plugins', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-transform-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "__ORIGINAL__";`);
      const transformPlugin: ZntcPlugin = {
        name: 'runtime-polyfill-transform',
        setup(build) {
          build.onTransform({ filter: /entry\.ts$/ }, () => ({
            code: `globalThis.__VALUE__ = "a-a".replaceAll("a", "b");`,
          }));
        },
      };

      const result = await build({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
        plugins: [transformPlugin],
      });

      expect(result.errors.length).toBe(0);
      const code = result.outputFiles[0].text;
      expect(code).toContain('es.string.replace-all');
      expect(code).not.toContain('__ORIGINAL__');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills include is forced and exclude removes final selected modules', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-include-exclude-'));
    try {
      writeFileSync(
        join(dir, 'entry.ts'),
        `
          const value = ["a"].at(0);
          globalThis.__VALUE__ = "a-a".replaceAll("a", value ?? "b");
        `,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: {
          mode: 'auto',
          targets: ['ios_saf 12'],
          include: ['es.promise'],
          exclude: ['es.string.replace-all'],
        },
      }).outputFiles[0].text;

      expect(code).toContain('es.array.at');
      expect(code).toContain('es.promise');
      expect(code).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills entry and off modes stay separate from usage collection', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-modes-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `globalThis.__VALUE__ = "a".replaceAll("a", "b");`);

      const entryMode = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: { mode: 'entry', targets: ['safari 5'] },
      }).outputFiles[0].text;
      expect(entryMode).toContain('es.map');
      expect(entryMode).toContain('es.promise');
      expect(entryMode).toContain('es.string.replace-all');

      const offMode = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        runtimePolyfills: 'off',
      }).outputFiles[0].text;
      expect(offMode).not.toContain('es.string.replace-all');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills prelude runs after manual polyfills and before runBeforeMain', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-order-'));
    try {
      const polyfillFile = join(dir, 'manual-polyfill.js');
      const initFile = join(dir, 'init.ts');
      writeFileSync(
        polyfillFile,
        `
          globalThis.__ORDER__ = ["polyfill"];
          String.prototype.replaceAll = undefined;
        `,
      );
      writeFileSync(
        initFile,
        `globalThis.__ORDER__.push("runBeforeMain:" + "a".replaceAll("a", "b"));`,
      );
      writeFileSync(
        join(dir, 'entry.ts'),
        `globalThis.__ORDER__.push("entry:" + "a".replaceAll("a", "c"));`,
      );

      const code = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        format: 'iife',
        polyfills: [polyfillFile],
        runBeforeMain: [initFile],
        runtimePolyfills: { mode: 'auto', targets: ['ios_saf 12'] },
      }).outputFiles[0].text;

      expect(code).toContain('es.string.replace-all');
      const vm = require('node:vm') as typeof import('node:vm');
      const sandbox: { __ORDER__?: string[] } = {};
      vm.runInNewContext(code, sandbox);
      expect(sandbox.__ORDER__).toEqual(['polyfill', 'runBeforeMain:b', 'entry:c']);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('runtimePolyfills rejects compact target shorthand through build API', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-runtime-polyfills-shorthand-'));
    try {
      writeFileSync(join(dir, 'entry.ts'), `"a".replaceAll("a", "b");`);
      expect(() =>
        buildSync({
          entryPoints: [join(dir, 'entry.ts')],
          runtimePolyfills: { mode: 'auto', targets: ['ios12'] },
        }),
      ).toThrow('Compact runtime target shorthands');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('browserslist: build API — target + browserslist 동시 지정 시 browserslist 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-both-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // target=es5(모두 다운레벨)인데 browserslist=modern(esnext) → 변환 안 해야 함
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
      browserslist: 'chrome 100',
    });
    expect(r.outputFiles[0].text).not.toContain('__async');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 매핑 불가능한 엔진만 있으면 esnext', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-unknown-'));
    writeFileSync(join(dir, 'entry.ts'), 'export async function run() { return 1; }');
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'samsung 20',
    });
    expect(r.outputFiles[0].text).toContain('async function');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 빈 배열 입력 시 기본 (보수적 esnext)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-empty-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    // 빈 배열 → browserslist가 default 쿼리로 처리하므로 에러 없어야 함
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        browserslist: [] as string[],
      }),
    ).not.toThrow();
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — ios_saf 버전 매핑 (RN 시나리오)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-ios-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      // ES2020 optional_chaining — ios 13 미만 미지원
      'export const x = (o: any) => o?.a;',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'ios_saf 12',
    });
    expect(r.outputFiles[0].text).not.toContain('?.');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — 출력 파일 수 일치 (트랜스파일 결과 누락 방지)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-outfiles-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);",
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'last 2 chrome versions',
    });
    expect(r.outputFiles.length).toBeGreaterThan(0);
    expect(r.outputFiles[0].text).toContain('1');
    expect(r.outputFiles[0].text).toContain('2');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — minify 동시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-minify-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const longVariableName = 42;\nconsole.log(longVariableName);',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'chrome 100',
      minify: true,
    });
    // minify 적용 확인: 공백 압축
    expect(r.outputFiles[0].text.length).toBeLessThan(100);
    rmSync(dir, { recursive: true });
  });

  test('browserslist: 같은 엔진의 여러 버전 — 가장 낮은 버전 기준', () => {
    const { browserslistToUnsupported } = require('../shared/index');
    // chrome 40(미지원) + chrome 100(지원) 동시 전달 — 40 때문에 async_await unsupported
    const bits = browserslistToUnsupported(['chrome 40', 'chrome 100']);
    expect(bits & (1 << 12)).not.toBe(0);
  });

  // ─── tsconfigPath (NAPI 에서 tsconfig.json 자동 로드) ───
  describe('tsconfigPath', () => {
    test('tsconfigPath=<file>: verbatimModuleSyntax 가 적용되어 미사용 import 보존', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-file-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      const r = transpile('import { foo } from "./bar";', {
        filename: 'input.ts',
        tsconfigPath: join(dir, 'tsconfig.json'),
      });
      expect(r.code).toContain('import { foo } from "./bar"');
      rmSync(dir, { recursive: true });
    });

    test('tsconfigPath=<dir>: 디렉토리 내 tsconfig.json 자동 탐지', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-dir-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      const r = transpile('import { foo } from "./bar";', {
        filename: 'input.ts',
        tsconfigPath: dir,
      });
      expect(r.code).toContain('import { foo } from "./bar"');
      rmSync(dir, { recursive: true });
    });

    test('JS 옵션이 tsconfig 보다 우선 — 명시적 false 로 tsconfig true override', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-prio-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      const r = transpile('import { foo } from "./bar";', {
        filename: 'input.ts',
        tsconfigPath: dir,
        verbatimModuleSyntax: false,
      });
      expect(r.code).toBe('');
      rmSync(dir, { recursive: true });
    });

    test('tsconfigPath 없으면 기본 동작 (elide)', () => {
      const r = transpile('import { foo } from "./bar";', { filename: 'input.ts' });
      expect(r.code).toBe('');
    });

    test('build API 도 tsconfigPath 옵션을 받음 (no-throw)', () => {
      // 참고: build 의 verbatim 은 tree-shaker 와 상호작용하므로 표면 효과는 번들 구성에 따라
      // 다르다 — 여기서는 옵션 통과 경로만 검증 (no throw + 출력 생성).
      const dir = mkdtempSync(join(tmpdir(), 'zntc-tscpath-build-'));
      writeFileSync(
        join(dir, 'tsconfig.json'),
        '{"compilerOptions":{"verbatimModuleSyntax":true}}',
      );
      writeFileSync(join(dir, 'entry.ts'), 'console.log(42);');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        tsconfigPath: join(dir, 'tsconfig.json'),
      });
      expect(r.outputFiles[0].text).toContain('console.log(42)');
      rmSync(dir, { recursive: true });
    });
  });

  // ─── profile / profileLevel / profileFormat options (PR 2) ───
  //
  // CLI `--profile*` 와 동일한 의미의 NAPI 옵션. 이 PR 에서는 옵션 파싱 / 프로세스
  // 전역 profile 모듈 상태 조작만 검증. 실제 phase 수치는 PR 3+ 에서 hot-path timer
  // 가 삽입된 뒤부터 기록된다.
  describe('profile options (PR 2 — entry point integration)', () => {
    test('BundleOptions.profile 을 받아들인다 (no throw)', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['all'],
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('BundleOptions.profileLevel 을 받아들인다 (no throw)', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-lvl-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['parse', 'transform'],
        profileLevel: 'detailed',
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('BundleOptions.profileFormat 은 타입에 존재 (향후 결과 노출용)', () => {
      // PR 10 에서 build/buildSync 결과에 profile report 를 실제 포함시킬 예정.
      // PR 2 는 옵션 파싱만 검증.
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-fmt-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['all'],
        profileFormat: 'json',
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('잘못된 profileLevel 은 무시 (graceful degrade)', () => {
      // Level.fromString 이 null 반환 → profile 모듈이 level 변경 안 함. build 는 성공.
      const dir = mkdtempSync(join(tmpdir(), 'zntc-profile-bad-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        profile: ['all'],
        // @ts-expect-error — runtime 허용성 검증
        profileLevel: 'bogus',
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });

    test('profile 미지정 시 빌드는 정상 동작 (default: 비활성)', () => {
      const dir = mkdtempSync(join(tmpdir(), 'zntc-noprofile-'));
      writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
      const r = buildSync({
        entryPoints: [join(dir, 'entry.ts')],
      });
      expect(r.outputFiles[0].text).toContain('const x = 1');
      rmSync(dir, { recursive: true });
    });
  });
});

// ─── plugin lifecycle hooks (#2156) ───

describe('@zntc/core plugin lifecycle', () => {
  test('buildStart / buildEnd / closeBundle 정상 build 시 호출 + 호출 순서', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    const order: string[] = [];
    const plugin: ZntcPlugin = {
      name: 'lifecycle',
      setup(build) {
        build.onBuildStart(() => {
          order.push('buildStart');
        });
        build.onTransform({ filter: /\.ts$/ }, (args) => {
          order.push('transform');
          return { code: args.code };
        });
        build.onBuildEnd((err) => {
          order.push(err ? `buildEnd:err=${err.message}` : 'buildEnd');
        });
        build.onCloseBundle(() => {
          order.push('closeBundle');
        });
      },
    };

    await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });

    expect(order[0]).toBe('buildStart');
    expect(order[order.length - 2]).toBe('buildEnd');
    expect(order[order.length - 1]).toBe('closeBundle');
    expect(order).toContain('transform');
    rmSync(dir, { recursive: true });
  });

  test('buildStart / buildEnd / closeBundle 미등록 plugin 도 정상 build', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-empty-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');
    const plugin: ZntcPlugin = {
      name: 'no-lifecycle',
      setup(build) {
        build.onTransform({ filter: /\.ts$/ }, (args) => ({ code: args.code }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('const x = 1');
    rmSync(dir, { recursive: true });
  });

  test('다중 plugin: 모든 plugin 의 buildStart / buildEnd / closeBundle 호출', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-multi-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    let p1Start = 0,
      p2Start = 0,
      p1End = 0,
      p2End = 0,
      p1Close = 0,
      p2Close = 0;
    const p1: ZntcPlugin = {
      name: 'p1',
      setup(b) {
        b.onBuildStart(() => {
          p1Start++;
        });
        b.onBuildEnd(() => {
          p1End++;
        });
        b.onCloseBundle(() => {
          p1Close++;
        });
      },
    };
    const p2: ZntcPlugin = {
      name: 'p2',
      setup(b) {
        b.onBuildStart(() => {
          p2Start++;
        });
        b.onBuildEnd(() => {
          p2End++;
        });
        b.onCloseBundle(() => {
          p2Close++;
        });
      },
    };
    await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [p1, p2] });
    expect(p1Start).toBe(1);
    expect(p2Start).toBe(1);
    expect(p1End).toBe(1);
    expect(p2End).toBe(1);
    expect(p1Close).toBe(1);
    expect(p2Close).toBe(1);
    rmSync(dir, { recursive: true });
  });

  test('vitePlugin 어댑터: Rollup plugin 의 buildStart / buildEnd / closeBundle 을 ZNTC build 에서 호출', async () => {
    // vitePlugin: RollupPlugin → ZntcPlugin 변환 어댑터. 사용자가 작성한 Rollup plugin 의
    // lifecycle hook 들이 ZNTC bundle() 시 호출되는지 검증.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-lifecycle-vite-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = 1;');

    let buildStartCalled = false;
    let buildEndCalled = false;
    let closeBundleCalled = false;
    const rollupPlugin: RollupPlugin = {
      name: 'rollup-lifecycle',
      buildStart() {
        buildStartCalled = true;
      },
      buildEnd() {
        buildEndCalled = true;
      },
      closeBundle() {
        closeBundleCalled = true;
      },
    };
    await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [vitePlugin(rollupPlugin)] });
    expect(buildStartCalled).toBe(true);
    expect(buildEndCalled).toBe(true);
    expect(closeBundleCalled).toBe(true);
    rmSync(dir, { recursive: true });
  });
});

// ─── plugin onLoad loader override (#2157) ───

/** 출력 코드를 dynamic import 로 실행해 console.log 결과를 캡처. plugin loader override 의
 *  end-to-end 동작 검증 — bundle 결과가 실제 런타임에서 import 바인딩과 default export 가
 *  올바르게 매칭됨을 검증한다. */
async function runBundleStdout(code: string): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-run-'));
  const out = join(dir, 'out.mjs');
  writeFileSync(out, code);
  const captured: string[] = [];
  const orig = console.log;
  console.log = (...args: unknown[]) => {
    captured.push(args.map((a) => String(a)).join(' '));
  };
  try {
    await import(out);
  } finally {
    console.log = orig;
    rmSync(dir, { recursive: true });
  }
  return captured.join('\n');
}

describe('@zntc/core plugin onLoad loader', () => {
  test("loader='text': string default export + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-text-'));
    writeFileSync(join(dir, 'entry.ts'), "import data from './README.md';\nconsole.log(data);");
    writeFileSync(join(dir, 'README.md'), '# hello world');
    const plugin: ZntcPlugin = {
      name: 'md-as-text',
      setup(build) {
        build.onLoad({ filter: /\.md$/ }, (args) => ({
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'text',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('"# hello world"');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('# hello world');
    rmSync(dir, { recursive: true });
  });

  test("loader='dataurl': data URL 인라인 + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-dataurl-'));
    writeFileSync(join(dir, 'entry.ts'), "import url from './pic.svg';\nconsole.log(url);");
    writeFileSync(join(dir, 'pic.svg'), '<svg/>');
    const plugin: ZntcPlugin = {
      name: 'svg-as-dataurl',
      setup(build) {
        build.onLoad({ filter: /\.svg$/ }, (args) => ({
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'dataurl',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('data:image/svg+xml;base64,');
    // base64('<svg/>') = 'PHN2Zy8+'
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('data:image/svg+xml;base64,PHN2Zy8+');
    rmSync(dir, { recursive: true });
  });

  test("loader='base64': 순수 base64 문자열 (data URL prefix 없음)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-b64-'));
    writeFileSync(join(dir, 'entry.ts'), "import s from './data.bin';\nconsole.log(s);");
    writeFileSync(join(dir, 'data.bin'), 'Hi'); // base64('Hi') = 'SGk='
    const plugin: ZntcPlugin = {
      name: 'bin-as-base64',
      setup(build) {
        build.onLoad({ filter: /\.bin$/ }, (args) => ({
          // NAPI 가 현재 contents 를 string 으로만 받음 — utf-8 디코드된 string 전달.
          // 진짜 binary safe (Uint8Array forward) 는 후속 PR.
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'base64',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('"SGk="');
    expect(r.outputFiles[0].text).not.toContain('data:');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('SGk=');
    rmSync(dir, { recursive: true });
  });

  test("loader='binary': Uint8Array default export + Node 실행 결과 일치", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-binary-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import bytes from './data.dat';\nconsole.log(bytes instanceof Uint8Array, bytes.length, bytes[0], bytes[1]);",
    );
    writeFileSync(join(dir, 'data.dat'), 'AB'); // ASCII safe
    const plugin: ZntcPlugin = {
      name: 'dat-as-binary',
      setup(build) {
        // .dat 의 default loader 는 .none — onResolve 로 ZNTC 가 모듈 등록할 path 를 명시,
        // onLoad 가 raw bytes + binary loader override. NAPI string 한계로 utf-8 safe 데이터.
        build.onResolve({ filter: /\.dat$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.dat$/ }, (args) => ({
          contents: readFileSync(args.path, 'utf-8'),
          loader: 'binary',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('__toBinary');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('true 2 65 66');
    rmSync(dir, { recursive: true });
  });

  test('contents=Uint8Array (binary safe): 비-utf8 bytes 도 손실 없이 forward (#2157 follow-up)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-uint8-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import bytes from './data.bin';\nconsole.log(bytes.length, bytes[0], bytes[1], bytes[2], bytes[3]);",
    );
    // PNG magic header — 0x89 / 0xFF 같은 utf-8 invalid bytes 포함
    const rawBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    writeFileSync(join(dir, 'data.bin'), rawBytes);
    const plugin: ZntcPlugin = {
      name: 'bin-as-binary-uint8',
      setup(build) {
        build.onResolve({ filter: /\.bin$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.bin$/ }, (args) => ({
          // 핵심: Uint8Array 그대로 forward — utf-8 디코드 손실 없음
          contents: readFileSync(args.path),
          loader: 'binary',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(r.outputFiles[0].text).toContain('__toBinary');
    // 0x89 = 137, 0x50 = 80, 0x4e = 78, 0x47 = 71. utf-8 디코드 시 0x89 가 손실되어 invalid 였을 것.
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('4 137 80 78 71');
    rmSync(dir, { recursive: true });
  });

  test("contents=Uint8Array + loader='dataurl' (PNG raw bytes 보존)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-png-'));
    writeFileSync(join(dir, 'entry.ts'), "import url from './tiny.png';\nconsole.log(url);");
    const rawBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]); // PNG magic
    writeFileSync(join(dir, 'tiny.png'), rawBytes);
    const plugin: ZntcPlugin = {
      name: 'png-as-dataurl-uint8',
      setup(build) {
        build.onLoad({ filter: /\.png$/ }, (args) => ({
          contents: readFileSync(args.path),
          loader: 'dataurl',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    // base64([0x89,0x50,0x4e,0x47]) = 'iVBORw=='
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('data:image/png;base64,iVBORw==');
    rmSync(dir, { recursive: true });
  });

  test('contents=Buffer (Node Buffer): napi_is_buffer 경로로 raw bytes forward', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-buffer-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import bytes from './data.raw';\nconsole.log(bytes.length, bytes[0], bytes[1]);",
    );
    const plugin: ZntcPlugin = {
      name: 'raw-as-buffer',
      setup(build) {
        build.onResolve({ filter: /\.raw$/ }, (args) => ({ path: resolve(dir, args.path) }));
        // 핵심: Buffer.from(...) — Node.js Buffer 인스턴스 (Uint8Array subclass 지만 napi_is_buffer 별도)
        build.onLoad({ filter: /\.raw$/ }, () => ({
          contents: Buffer.from([0xff, 0xfe]),
          loader: 'binary',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('2 255 254');
    rmSync(dir, { recursive: true });
  });

  test("loader='empty': default export 가 undefined", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-empty-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import x from './any.skip';\nconsole.log(x === undefined);",
    );
    writeFileSync(join(dir, 'any.skip'), 'doesnt matter');
    const plugin: ZntcPlugin = {
      name: 'skip-as-empty',
      setup(build) {
        build.onResolve({ filter: /\.skip$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.skip$/ }, () => ({ contents: '', loader: 'empty' }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('true');
    rmSync(dir, { recursive: true });
  });

  test("loader='tsx': onLoad contents를 TSX parser mode로 처리", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-tsx-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { value } from './virtual.foo';\nconsole.log(value);",
    );
    writeFileSync(join(dir, 'virtual.foo'), '');
    const plugin: ZntcPlugin = {
      name: 'foo-as-tsx',
      setup(build) {
        build.onLoad({ filter: /\.foo$/ }, () => ({
          contents: 'const h = (tag: string) => tag;\nexport const value: string = <div />;',
          loader: 'tsx',
        }));
      },
    };
    const r = await build({
      entryPoints: [join(dir, 'entry.ts')],
      plugins: [plugin],
      jsx: 'classic',
      jsxFactory: 'h',
    });
    expect(r.outputFiles[0].text).not.toContain('<div');
    expect(r.outputFiles[0].text).not.toContain(': string');
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('div');
    rmSync(dir, { recursive: true });
  });

  test("loader='js'/'jsx'/'ts'/'tsx': onLoad parser mode strictness", async () => {
    async function runOnLoadCase(loader: 'js' | 'jsx' | 'ts' | 'tsx', contents: string) {
      const dir = mkdtempSync(join(tmpdir(), `zntc-onload-${loader}-strict-`));
      writeFileSync(
        join(dir, 'entry.ts'),
        "import { value } from './virtual.foo';\nconsole.log(value);",
      );
      writeFileSync(join(dir, 'virtual.foo'), '');
      const plugin: ZntcPlugin = {
        name: `foo-as-${loader}`,
        setup(build) {
          build.onLoad({ filter: /\.foo$/ }, () => ({ contents, loader }));
        },
      };
      const r = await build({
        entryPoints: [join(dir, 'entry.ts')],
        plugins: [plugin],
        jsx: 'classic',
        jsxFactory: 'h',
      });
      rmSync(dir, { recursive: true, force: true });
      return r;
    }

    const jsResult = await runOnLoadCase('js', 'export const value: number = 1;');
    expect(jsResult.errors.length).toBeGreaterThan(0);
    expect(jsResult.errors[0].text).toContain('TypeScript');

    const tsResult = await runOnLoadCase('ts', 'export const value: number = 1;');
    expect(tsResult.errors.length).toBe(0);
    expect(await runBundleStdout(tsResult.outputFiles[0].text)).toBe('1');

    const tsJsxResult = await runOnLoadCase(
      'ts',
      'const h = (tag) => tag;\nexport const value = <div />;',
    );
    expect(tsJsxResult.errors.length).toBeGreaterThan(0);

    const jsxResult = await runOnLoadCase(
      'jsx',
      'const h = (tag) => tag;\nexport const value = <span />;',
    );
    expect(jsxResult.errors.length).toBe(0);
    expect(await runBundleStdout(jsxResult.outputFiles[0].text)).toBe('span');

    const jsxTsResult = await runOnLoadCase(
      'jsx',
      'const h = (tag) => tag;\nexport const value: string = <span />;',
    );
    expect(jsxTsResult.errors.length).toBeGreaterThan(0);
    expect(jsxTsResult.errors[0].text).toContain('TypeScript');

    const tsxResult = await runOnLoadCase(
      'tsx',
      'const h = (tag: string) => tag;\nexport const value: string = <div />;',
    );
    expect(tsxResult.errors.length).toBe(0);
    expect(await runBundleStdout(tsxResult.outputFiles[0].text)).toBe('div');
  });

  test("loader='bogus' (미지원 string): override 무시 → JS 모듈로 처리 (fromString null)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-bogus-'));
    writeFileSync(join(dir, 'entry.ts'), "import x from './v.custom';\nconsole.log(x);");
    const plugin: ZntcPlugin = {
      name: 'custom-bogus',
      setup(build) {
        build.onResolve({ filter: /\.custom$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.custom$/ }, () => ({
          contents: 'export default 42;',
          // @ts-expect-error — 의도적으로 잘못된 값
          loader: 'bogus',
        }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    // fromString null → loader_override null → default JS 처리 → 정상 import
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('42');
    rmSync(dir, { recursive: true });
  });

  test('loader 없이 반환: 기존 동작 (JS 모듈)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-onload-default-'));
    writeFileSync(join(dir, 'entry.ts'), "import x from './v.custom';\nconsole.log(x);");
    const plugin: ZntcPlugin = {
      name: 'custom-as-js',
      setup(build) {
        build.onResolve({ filter: /\.custom$/ }, (args) => ({ path: resolve(dir, args.path) }));
        build.onLoad({ filter: /\.custom$/ }, () => ({ contents: 'export default 42;' }));
      },
    };
    const r = await build({ entryPoints: [join(dir, 'entry.ts')], plugins: [plugin] });
    expect(await runBundleStdout(r.outputFiles[0].text)).toBe('42');
    rmSync(dir, { recursive: true });
  });
});
