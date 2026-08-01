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

  // (#4602) 예전엔 해석 불가 target 을 **조용히 무시**했다. 그런데 그건 사용자가 요청한
  // 다운레벨이 아무 말 없이 사라지는 것과 같아서, 오타(`es2099`·`safari-11`)가 런타임에서야
  // 드러났다. CLI(`zntc: unknown target ...` + exit 1)·esbuild 와 맞춰 throw 한다.
  test('target: 해석 불가 값은 throw (조용히 무시하지 않음)', () => {
    expect(() =>
      buildSync({
        entryPoints: [join(dir, 'entry.ts')],
        target: 'es2099' as any,
      }),
    ).toThrow(/unknown target/);
  });

  // 대조군 — 유효한 값은 종전대로 통과해야 한다. 위 테스트만 있으면 "항상 throw" 로 바꿔도
  // 통과하므로 가드가 공허해진다.
  test('target: 유효한 값은 정상 처리 (대조군)', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      target: 'es2020',
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
