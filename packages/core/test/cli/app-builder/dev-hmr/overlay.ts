import {
  CLI,
  RUNTIME,
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
  test('dev initial build error replays an error overlay payload to HMR clients', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-overlay-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="root"></div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'const broken: = ;');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const messagePromise = new Promise<any>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (event) => {
          const msg = JSON.parse(String(event.data));
          if (msg.type === 'error') {
            ws.close();
            resolve(msg);
          }
        };
        ws.onerror = () => resolve({ type: 'error-event' });
        setTimeout(() => resolve({ type: 'timeout' }), 10000);
      });
      const msg = await messagePromise;
      expect(msg.type).toBe('error');
      expect(msg.errors[0].file).toContain('main.ts');
      expect(msg.errors[0].message).toContain('Type expected');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev serves a valid Shadow DOM runtime overlay client', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-overlay-client-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="root"></div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const client = await fetch(`http://localhost:${port}/__zntc_app_dev_hmr__`).then((r) =>
        r.text(),
      );
      expect(client).toContain('attachShadow');
      expect(client).toContain('unhandledrejection');
      expect(client).toContain('sourceMappingURL');
      expect(() => new Function(client)).not.toThrow();
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
