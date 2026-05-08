import {
  CLI,
  describe,
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

describe('CLI: Vite-style app builder > dev HMR and overlay', () => {
  test('dev under Bun runtime: /__hmr WebSocket connects', async () => {
    // RUNTIME=node 가 기본이라 Bun.serve 분기는 별도 케이스. bun 이 PATH 에 있다고 가정.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-bun-hmr-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<title>bun-dev</title><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');

    const port = await findFreePort();
    const proc = spawn('bun', [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const messagePromise = new Promise<any>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (event) => {
          const msg = JSON.parse(String(event.data));
          if (msg.type === 'connected') {
            ws.close();
            resolve(msg);
          }
        };
        ws.onerror = () => resolve({ type: 'error' });
        setTimeout(() => resolve({ type: 'timeout' }), 10000);
      });
      const msg = await messagePromise;
      expect(msg.type).toBe('connected');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
