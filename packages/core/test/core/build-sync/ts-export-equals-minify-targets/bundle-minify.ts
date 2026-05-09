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

describe('@zntc/core buildSync - TS export equals bundle minify', () => {
  test('TS export = identifier (bundle + minify): __commonJS wrapper 안에서 일관된 mangle', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-bundle-minify-'));
    try {
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
