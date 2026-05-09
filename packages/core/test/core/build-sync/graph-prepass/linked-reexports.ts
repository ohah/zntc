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

describe('@zntc/core buildSync - graph pre-pass linked re-exports', () => {
  test('graph pre-pass skip: re-export and namespace access stay linked', () => {
    const skipDir = mkdtempSync(join(tmpdir(), 'zntc-prepass-skip-reexport-'));
    try {
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
    } finally {
      rmSync(skipDir, { recursive: true, force: true });
    }
  });
});
