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

describe('@zntc/core browserslist > build API', () => {
  test('browserslist: build API — 출력 파일 수 일치 (트랜스파일 결과 누락 방지)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-outfiles-'));
    writeFileSync(join(dir, 'a.ts'), 'export const A = 1;');
    writeFileSync(join(dir, 'b.ts'), 'export const B = 2;');
    writeFileSync(
      join(dir, 'entry.ts'),
      "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);",
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'last 2 chrome versions',
    });
    expect(r.outputFiles.length).toBeGreaterThan(0);
    expect(r.outputFiles[0].text).toContain('1');
    expect(r.outputFiles[0].text).toContain('2');
    rmSync(dir, { recursive: true });
  });

  test('browserslist: build API — minify 동시 적용', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-minify-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export const longVariableName = 42;\nconsole.log(longVariableName);',
    );
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      browserslist: 'chrome 100',
      minify: true,
    });
    // minify 적용 확인: 공백 압축
    expect(r.outputFiles[0].text.length).toBeLessThan(100);
    rmSync(dir, { recursive: true });
  });
});
