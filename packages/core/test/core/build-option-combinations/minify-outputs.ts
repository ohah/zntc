import {
  afterAll,
  beforeAll,
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

describe('@zntc/core build 옵션 조합 - minify and outputs', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-combo-'));
    writeFileSync(
      join(dir, 'index.ts'),
      'import { helper } from "./util";\nconsole.log(helper());',
    );
    writeFileSync(join(dir, 'util.ts'), 'export function helper() { return 42; }');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('minifyWhitespace만 적용', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minifyWhitespace: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text.split('\n').length).toBeLessThan(20);
  });

  test('minifyIdentifiers 적용 시 출력 크기 감소', () => {
    const normal = buildSync({ entryPoints: [join(dir, 'index.ts')] });
    const minified = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minifyIdentifiers: true,
    });
    expect(minified.errors.length).toBe(0);
    expect(minified.outputFiles[0].text.length).toBeLessThanOrEqual(
      normal.outputFiles[0].text.length,
    );
  });

  test('sourcemap + minify + metafile 동시', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'index.ts')],
      minify: true,
      sourcemap: true,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBe(2);
    expect(result.metafile).toBeDefined();
    const map = JSON.parse(result.outputFiles.find((f) => f.path.endsWith('.map'))!.text);
    expect(map.version).toBe(3);
  });
});
