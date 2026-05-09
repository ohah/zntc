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
} from '../../helpers';

describe('@zntc/core browserslist > build API > target priority', () => {
  test('browserslist: build API — target + browserslist 동시 지정 시 browserslist 우선', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bs-both-'));
    writeFileSync(
      join(dir, 'entry.ts'),
      'export async function run() { return await Promise.resolve(1); }',
    );
    // target=es5(모두 다운레벨)인데 browserslist=modern(esnext) → 변환 안 해야 함
    const r = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es5',
      browserslist: 'chrome 100',
    });
    expect(r.outputFiles[0].text).not.toContain('__async');
    rmSync(dir, { recursive: true });
  });
});
