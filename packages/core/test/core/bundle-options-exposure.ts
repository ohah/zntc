import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  build,
  buildSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  join,
  tmpdir,
} from './helpers';

describe('BundleOptions: 전체 옵션 노출', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-all-opts-'));
    writeFileSync(join(dir, 'entry.ts'), '/** @license MIT */\nexport const x = 1;');
  });

  afterAll(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  test('legalComments: none → 라이센스 주석 제거', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      legalComments: 'none',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).not.toContain('@license');
  });

  test('legalComments: eof → 파일 끝에 주석 이동', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      legalComments: 'eof',
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('@license');
  });

  test('preserveModules: 모듈별 개별 파일 출력', async () => {
    writeFileSync(join(dir, 'mod-a.ts'), 'export const a = 1;');
    writeFileSync(
      join(dir, 'mod-entry.ts'),
      'import { a } from "./mod-a";\nexport const b = a + 1;',
    );
    const result = await build({
      entryPoints: [join(dir, 'mod-entry.ts')],
      preserveModules: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test('preserveModulesRoot: 출력 경로 기준', async () => {
    const result = await build({
      entryPoints: [join(dir, 'mod-entry.ts')],
      preserveModules: true,
      preserveModulesRoot: dir,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles.length).toBeGreaterThanOrEqual(2);
  });

  test('timing: 옵션 파싱 확인', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      timing: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('devMode: dev 모드 활성화', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
    });
    expect(result.errors.length).toBe(0);
    expect(result.outputFiles[0].text).toContain('__zntc_modules');
  });

  test('devMode: RN HMR reload fallback은 DevSettings wrapper를 우선 사용', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
    });
    expect(result.errors.length).toBe(0);
    const code = result.outputFiles[0].text;
    expect(code).toContain('require("react-native")');
    expect(code).toContain('rn.DevSettings.reload(why)');
    expect(code).toContain('setTimeout(fn, 0)');
    expect(code).not.toContain('__zntc_g.nativeModuleProxy.DevSettings.reload()');
  });

  test('reactRefresh: Fast Refresh 활성화', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      reactRefresh: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('configurableExports: configurable:true 추가', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      configurableExports: true,
    });
    expect(result.errors.length).toBe(0);
  });

  test('globalIdentifiers: 예약 식별자', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      globalIdentifiers: ['__global', 'self'],
    });
    expect(result.errors.length).toBe(0);
  });

  test('rootDir + collectModuleCodes: dev 모드 옵션 조합', () => {
    const result = buildSync({
      entryPoints: [join(dir, 'entry.ts')],
      devMode: true,
      rootDir: dir,
      collectModuleCodes: true,
    });
    expect(result.errors.length).toBe(0);
  });
});

// ─── 옵션 조합 + 엣지 케이스 통합 테스트 ───
