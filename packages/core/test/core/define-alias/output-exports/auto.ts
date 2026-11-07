import { runInNewContext } from 'node:vm';
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
      const initialExports: Record<string, unknown> = {};
      const module = { exports: initialExports };
      runInNewContext(text, { module, exports: initialExports });
      const published = module.exports;
      expect(published).toBe(initialExports);
      expect(Object.keys(published).sort()).toEqual(['a', 'b']);
      expect(Reflect.ownKeys(published).sort()).toEqual(['a', 'b']);
      expect(published.a).toEqual(1);
      expect(published.b).toEqual('AUTO_NAMED');
      expect(Object.hasOwn(published, '__esModule')).toBe(false);
      expect(Reflect.set(published, 'a', 99)).toBe(false);
      expect(Reflect.set(published, 'b', 99)).toBe(false);
      expect(published.a).toEqual(1);
      expect(published.b).toEqual('AUTO_NAMED');
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
      const initialExports: Record<string, unknown> = {};
      const module = { exports: initialExports };
      runInNewContext(text, { module, exports: initialExports });
      const published = module.exports;
      expect(published).toBe(initialExports);
      expect(Object.keys(published).sort()).toEqual(['a', 'default']);
      expect(Reflect.ownKeys(published).sort()).toEqual(['__esModule', 'a', 'default']);
      expect(published.a).toEqual('AUTO_MIXED_NAMED');
      expect(published.default).toEqual({ x: 'AUTO_MIXED_DEFAULT' });
      expect(Object.getOwnPropertyDescriptor(published, '__esModule')).toEqual({
        value: true,
        enumerable: false,
        writable: false,
        configurable: false,
      });
      expect(Reflect.set(published, 'a', 99)).toBe(false);
      expect(Reflect.set(published, 'default', 99)).toBe(false);
      expect(published.a).toEqual('AUTO_MIXED_NAMED');
      expect(published.default).toEqual({ x: 'AUTO_MIXED_DEFAULT' });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
