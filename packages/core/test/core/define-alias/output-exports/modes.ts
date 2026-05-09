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

describe('@zntc/core define/alias > outputExports modes', () => {
  test("outputExports='named' default-only → exports.default + esModule flag", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-named-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("outputExports='default' default-only → module.exports = X", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-default-'));
    try {
      writeFileSync(join(dir, 'index.ts'), 'const x = "DEFAULT_MODE";\nexport default x;');

      const result = await build({
        entryPoints: [join(dir, 'index.ts')],
        format: 'cjs',
        outputExports: 'default',
      });
      expect(result.errors.length).toBe(0);
      const text = result.outputFiles[0].text;
      expect(text).toContain('module.exports = ');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("outputExports='none' → 모든 export 출력 안 함", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-none-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
