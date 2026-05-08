import {
  describe,
  test,
  expect,
  buildSync,
  readFileSync,
  rmSync,
  join,
  useBuildOptionsFixture,
} from './helpers';

describe('BuildOptions: 누락 옵션 노출 (#1005) > output files', () => {
  const getDir = useBuildOptionsFixture();

  test('write + outdir: 디스크에 파일이 기록됨', () => {
    const dir = getDir();
    const outdir = join(dir, 'out-dir');
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
      write: true,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('fn');
    rmSync(outdir, { recursive: true, force: true });
  });

  test('outfile: 단일 파일 출력 경로 지정', () => {
    const dir = getDir();
    const outfile = join(dir, 'custom-out', 'my-bundle.js');
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outfile,
    });
    expect(result.errors.length).toBe(0);
    const written = readFileSync(outfile, 'utf-8');
    expect(written).toContain('fn');
    rmSync(join(dir, 'custom-out'), { recursive: true, force: true });
  });

  test('outdir 지정 시 write 자동 true', () => {
    const dir = getDir();
    const outdir = join(dir, 'auto-write');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
    });
    const written = readFileSync(join(outdir, 'bundle.js'), 'utf-8');
    expect(written).toContain('fn');
    rmSync(outdir, { recursive: true, force: true });
  });

  test('write: false → 디스크에 기록하지 않음', () => {
    const dir = getDir();
    const outdir = join(dir, 'no-write');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outdir,
      write: false,
    });
    expect(() => readFileSync(join(outdir, 'bundle.js'))).toThrow();
  });

  test('outfile + sourcemap: 소스맵이 outfile 옆에 생성됨', () => {
    const dir = getDir();
    const outfile = join(dir, 'sm-out', 'bundle.js');
    buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      outfile,
      sourcemap: true,
    });
    const mapContent = readFileSync(outfile + '.map', 'utf-8');
    expect(mapContent).toContain('mappings');
    rmSync(join(dir, 'sm-out'), { recursive: true, force: true });
  });
});
