import {
  describe,
  test,
  expect,
  beforeAll,
  afterAll,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from './helpers';

describe('CLI: dev --platform=react-native (#2605 PR #J)', () => {
  let dir: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'zntc-cli-rn-dev-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'src', 'index.ts'), 'console.log("rn-dev");');
  });

  afterAll(() => rmSync(dir, { recursive: true, force: true }));

  test('entry 누락 시 친화 에러 메시지 + exit 1', () => {
    const { exitCode, stderr } = runCli(['--dev', '--platform=react-native', '--rn-platform=ios']);
    expect(exitCode).toBe(1);
    expect(stderr).toContain('entry');
  });

  test.skip('@zntc/react-native 미설치 환경 → friendly error (production npm publish e2e)', () => {
    // workspace 환경에서는 RN 패키지가 install 됨 → lazy load 항상 성공. peer
    // 미설치 환경 검증은 npm publish 후 별도 e2e 환경에서.
  });
});
