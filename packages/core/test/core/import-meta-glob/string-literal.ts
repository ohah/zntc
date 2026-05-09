import {
  describe,
  test,
  expect,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from '../helpers';

describe('import.meta.glob > string literal guard', () => {
  test('glob: 코드 내 문자열에 import.meta.glob이 있어도 오탐 안 함', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-glob-string-'));
    try {
      writeFileSync(
        join(dir, 'no-false-match.ts'),
        'const msg = "use import.meta.glob() to load";\nexport { msg };',
      );
      const result = buildSync({ entryPoints: [join(dir, 'no-false-match.ts')], format: 'esm' });
      expect(result.errors.length).toBe(0);
      // 문자열 리터럴 안의 import.meta.glob은 교체되지 않아야 함
      expect(result.outputFiles[0].text).toContain('import.meta.glob');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
