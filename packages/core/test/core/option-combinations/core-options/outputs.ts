import {
  afterAll,
  beforeAll,
  buildSync,
  createOptionCombinationFixture,
  describe,
  expect,
  join,
  readFileSync,
  removeOptionCombinationFixture,
  rmSync,
  test,
  writeFileSync,
} from '../helpers';

describe('옵션 조합 통합 테스트 - core options - outputs', () => {
  let dir: string;

  beforeAll(() => {
    dir = createOptionCombinationFixture();
  });

  afterAll(() => {
    removeOptionCombinationFixture(dir);
  });

  test('sourcemap + sourceRoot + outfile 조합', () => {
    const outfile = join(dir, 'combo-out', 'bundle.js');
    buildSync({
      entryPoints: [join(dir, 'app.ts')],
      sourcemap: true,
      sourceRoot: '/src',
      outfile,
      dropLabels: ['DEV'],
    });
    const map = readFileSync(outfile + '.map', 'utf-8');
    expect(map).toContain('/src');
    expect(map).toContain('mappings');
    rmSync(join(dir, 'combo-out'), { recursive: true, force: true });
  });

  test('write + outdir + metafile 조합', () => {
    const outdir = join(dir, 'meta-out');
    const result = buildSync({
      entryPoints: [join(dir, 'lib.ts')],
      outdir,
      metafile: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.metafile).toBeDefined();
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written.length).toBeGreaterThan(0);
    rmSync(outdir, { recursive: true, force: true });
  });

  test('allowOverwrite: false → 입력=출력 시 에러', () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'lib.ts')],
        outfile: join(dir, 'lib.ts'),
      }),
    ).toThrow('overwrite');
  });

  test('allowOverwrite: true → 입력=출력 허용', () => {
    const outfile = join(dir, 'overwrite-test.ts');
    writeFileSync(outfile, 'export const z = 1;');
    const result = buildSync({
      entryPoints: [outfile],
      outfile,
      allowOverwrite: true,
    });
    expect(result.errors.length).toBe(0);
    rmSync(outfile, { force: true });
  });
});
