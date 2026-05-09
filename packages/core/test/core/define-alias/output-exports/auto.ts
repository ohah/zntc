import {
  build,
  describe,
  expect,
  join,
  mkdtempSync,
  rmSync,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('@zntc/core define/alias > outputExports auto', () => {
  test("outputExports='auto' default-only → module.exports = X", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-default-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("outputExports='auto' named-only → exports.X = X (no esModule flag)", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-named-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("outputExports='auto' mixed → exports.X + esModule flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-auto-mixed-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
