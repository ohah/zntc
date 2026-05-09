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

describe('@zntc/core buildSync - TS export equals define folding', () => {
  test('TS export = process.env ternary + define: 컴파일 시 분기 결정 + constant fold', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-export-equals-define-'));
    try {
      writeFileSync(
        join(dir, 'app.ts'),
        'const value = process.env.NODE_ENV === "production" ? "prod" : "dev";\nexport = { mode: value };',
      );
      const result = buildSync({
        entryPoints: [join(dir, 'app.ts')],
        define: { 'process.env.NODE_ENV': '"production"' },
      });
      expect(result.errors.length).toBe(0);
      const out = result.outputFiles[0].text;
      expect(out).toContain('module.exports');
      // define 치환 → constant fold → "prod" 만 남음 ("dev" 분기 dead-code).
      expect(out).toContain('"prod"');
      expect(out).not.toContain('"dev"');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
