import {
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

describe('@zntc/core buildSync - TS export equals basic', () => {
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
});
