import {
  buildSync,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  transpile,
  writeFileSync,
} from './helpers';

describe('@zntc/core buildSync - TS export equals minify and targets', () => {
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
});
