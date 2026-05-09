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
} from '../helpers';

describe('@zntc/core buildSync - graph pre-pass skip cases', () => {
  test('graph pre-pass skip: no-op ESM/TS bundle still folds numeric const imports', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-esm-'));
    try {
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
    } finally {
      rmSync(skipDir, { recursive: true, force: true });
    }
  });

  test('graph pre-pass skip: target downlevel without helper syntax stays stable', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-target-'));
    try {
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
    } finally {
      rmSync(skipDir, { recursive: true, force: true });
    }
  });

  test('graph pre-pass skip: type-only imports do not pull runtime modules', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-type-only-'));
    try {
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
    } finally {
      rmSync(skipDir, { recursive: true, force: true });
    }
  });
});
