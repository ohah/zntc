import {
  describe,
  test,
  expect,
  build,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('@zntc/core define/alias > outputExports', () => {
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
});
