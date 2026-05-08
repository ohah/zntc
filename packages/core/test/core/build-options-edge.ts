import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('BuildOptions: 엣지 케이스', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-edge-'));
    writeFileSync(join(dir, 'entry.ts'), 'export const x = () => 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('target: 잘못된 값은 무시 (변환 없음)', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es2099' as any,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('=>');
  });

  test('loader: 잘못된 값은 무시', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      loader: { '.ts': 'invalid_loader' },
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThan(0);
  });
});

// ─── 배치 E: S급 옵션 노출 테스트 ───
