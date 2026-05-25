// #3795 회귀 가드 — native watch worker 의 출력이 지정된 outdir 외 다른 위치 (cwd 등) 로
// 누출되지 않음. 가드 전: prepareNapiOptions 가 outdir 를 NAPI 로 보내기 전 delete →
// bundler/watch.zig 가 outdir 를 모르고 `o.path` 그대로 (entry-relative or cwd) 출력 →
// 결과적으로 dev server 의 serveDir 와 mis-match.
// 본 PR 가 NAPI outdir parsing + watch.zig 의 writeOutputToOutdir helper 로 결합 보장.

import {
  CLI,
  RUNTIME,
  describe,
  existsSync,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > dev HMR > outdir 누출 가드', () => {
  test('zntc dev → outdir 외 cwd 등 다른 위치에 bundle.js 누출 없음 (#3795)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-outdir-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');

    const port = await findFreePort();
    // cwd 를 별도 staging dir 로 두고 dev 의 root 는 source dir — 만약 watch worker 가
    // entry-relative 또는 cwd 기준 fallback 한다면 staging 또는 dir 의 root 에 bundle.js
    // 가 leak 된다 (정상 동작은 dir/.zntc-dev/ 안에만 생성).
    const stagingCwd = mkdtempSync(join(tmpdir(), 'zntc-app-dev-cwd-'));
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: stagingCwd });
    await waitForServer(port);
    try {
      // 정상 — dev default outdir `.zntc-dev` 에 bundle.js 생성
      expect(existsSync(join(dir, '.zntc-dev', 'bundle.js'))).toBe(true);
      // 회귀 가드 — staging cwd 에는 bundle.js 가 leak 되면 안 됨
      expect(existsSync(join(stagingCwd, 'bundle.js'))).toBe(false);
      // 회귀 가드 — source root 직속 (dir/bundle.js) 에도 leak 없음
      expect(existsSync(join(dir, 'bundle.js'))).toBe(false);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
      rmSync(stagingCwd, { recursive: true, force: true });
    }
  });
});
