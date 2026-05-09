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

describe('@zntc/core define/alias > outputExports validation', () => {
  test("outputExports='default' + named 섞이면 result.errors 에 명시 진단", async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-output-exports-conflict-'));
    try {
      writeFileSync(
        join(dir, 'index.ts'),
        'export const a = 1;\nexport default { x: "ALSO_HAS_DEFAULT" };',
      );

      const result = await build({
        entryPoints: [join(dir, 'index.ts')],
        format: 'cjs',
        outputExports: 'default',
      });
      expect(result.errors.length).toBeGreaterThan(0);
      const errMsg = result.errors[0].text;
      expect(errMsg).toContain('output.exports');
      expect(errMsg).toContain('default-only');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
