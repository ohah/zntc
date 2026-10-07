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
      // The wrapper's second parameter can be minified to any identifier. The
      // generated `exports` write must use that exact parameter and class binding.
      const exportMatch = out.match(
        /\(([A-Za-z_$][\w$]*)\s*,\s*([A-Za-z_$][\w$]*)\)\s*=>\s*\{[\s\S]*?\b\2\.exports=([A-Za-z_$][\w$]*)/,
      );
      if (!exportMatch)
        throw new Error(`no wrapper parameter-backed module.exports in output: ${out}`);
      expect(out).toMatch(new RegExp(`class\\s+${exportMatch[3]}\\b`));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
