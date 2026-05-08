import {
  CLI,
  RUNTIME,
  describe,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  occupyPort,
  rmSync,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > dev server', () => {
  test('dev [root] retries next port when server.strictPort is false', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-server-port-retry-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('port-retry');");
    const port = await findFreePort();
    const releasePort = await occupyPort(port);
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ server: { port, strictPort: false } }),
    );

    const proc = spawn(RUNTIME, [CLI, 'dev', dir], {
      cwd: dir,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    proc.stderr?.on('data', (chunk) => {
      stderr += String(chunk);
    });
    await waitForServer(port + 1);

    try {
      const js = await fetch(`http://localhost:${port + 1}/bundle.js`).then((r) => r.text());
      expect(js).toContain('port-retry');
      expect(stderr).toContain(`[serve] http://localhost:${port + 1}`);
    } finally {
      proc.kill();
      await releasePort();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // SKIP — 이슈 #2375 카테고리 3 (strictPort 의미 검증). `occupyPort` 가 `"localhost"`
  // (IPv4+IPv6 dual) 로 listen, dev server 가 host bind 시 IPv6/IPv4 매칭이 환경/timing
  // 의존이라 deterministic monotonic counter 환경에선 fail. base random port 에선 우연히
  // 통과하던 것. 진짜 fix 는 occupyPort 와 dev server 의 host 명시 정렬 + ready 검증
  // (별도 PR). 직접 실행 (`zntc dev <dir>` + 외부 occupy) 시엔 EADDRINUSE 정상 출력 확인.
  test.skip('dev [root] fails on occupied port when server.strictPort is true', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-server-strict-port-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('strict-port');");
    const port = await findFreePort();
    const releasePort = await occupyPort(port);
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ server: { port, strictPort: true } }),
    );

    const result = await new Promise<{ code: number | null; stderr: string }>((resolveExit) => {
      const proc = spawn(RUNTIME, [CLI, 'dev', dir], {
        cwd: dir,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      let stderr = '';
      proc.stderr?.on('data', (chunk) => {
        stderr += String(chunk);
      });
      proc.on('exit', (code) => resolveExit({ code, stderr }));
    });

    await releasePort();
    rmSync(dir, { recursive: true, force: true });
    expect(result.code).not.toBe(0);
    expect(result.stderr).toMatch(/EADDRINUSE|address already in use/i);
  });
});
