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
} from '../../helpers';

describe('CLI: Vite-style app builder > dev HMR CSS updates > module reload', () => {
  test('dev .module.scss edit triggers full reload (not css-update fast-path)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-module-scss-reload-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import s from "./card.module.scss"; console.log(s.card);',
    );
    writeFileSync(join(dir, 'src', 'card.module.scss'), '.card { color: rgb(1, 2, 3); }');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const messagePromise = new Promise<any>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (event) => {
          const msg = JSON.parse(String(event.data));
          if (msg.type === 'css-update' || msg.type === 'full-reload') {
            ws.close();
            resolve(msg);
          }
        };
        ws.onerror = () => resolve({ type: 'error' });
        setTimeout(() => resolve({ type: 'timeout' }), 10000);
      });
      await new Promise((r) => setTimeout(r, 300));
      writeFileSync(join(dir, 'src', 'card.module.scss'), '.card { color: rgb(7, 8, 9); }');
      const msg = await messagePromise;
      expect(msg.type).toBe('full-reload');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
