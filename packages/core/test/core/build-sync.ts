import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  transpile,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

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
