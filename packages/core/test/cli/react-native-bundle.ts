import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: bundle --platform=react-native (#2540 PR #7)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-rn-bundle-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'src', 'index.ts'), 'console.log("rn-bundle");');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('기본 RN bundle 산출 — banner / __DEV__=false / globalThis 식별자', () => {
    const out = join(dir, 'out.js');
    const { exitCode } = runCli([
      '--bundle',
      join(dir, 'src/index.ts'),
      '--platform=react-native',
      '--rn-platform=ios',
      `--rn-project-root=${dir}`,
      '-o',
      out,
    ]);
    expect(exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
    // 산출물 내용으로 RN preset 적용 검증 — stderr logging 의 변동성에 의존 안 함.
    const content = readFileSync(out, 'utf8');
    expect(content).toContain('__BUNDLE_START_TIME__');
    expect(content).toContain('__ZNTC_RN_GLOBAL__');
    expect(content).toContain('__ZNTC_RN_BUNDLER__');
    expect(content).toContain('__DEV__=false');
  });

  test('entry 누락 시 친화 에러 메시지 + exit 1', () => {
    const { exitCode, stderr } = runCli([
      '--bundle',
      '--platform=react-native',
      '--rn-platform=ios',
    ]);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('entry');
  });

  test('--rn-platform=android 분기 — banner 동일 (preset 의 prelude 는 platform 무관)', () => {
    const out = join(dir, 'out-android.js');
    const { exitCode } = runCli([
      '--bundle',
      join(dir, 'src/index.ts'),
      '--platform=react-native',
      '--rn-platform=android',
      `--rn-project-root=${dir}`,
      '-o',
      out,
    ]);
    expect(exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
  });
});
