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

describe('CLI: Vite-style app builder > dev HMR CSS updates > SCSS fast path', () => {
  test('dev single SCSS edit takes the css-update fast-path', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-scss-fast-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="box"></div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.scss";');
    writeFileSync(join(dir, 'src', 'style.scss'), '.box { color: rgb(1, 2, 3); }');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    async function fetchEmittedCss(): Promise<string> {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      const href = html.match(/<link\s+rel="stylesheet"\s+href="([^"]+)"/)?.[1];
      expect(href).toBeTruthy();
      return fetch(`http://localhost:${port}${href}`).then((r) => r.text());
    }
    try {
      expect(await fetchEmittedCss()).toContain('rgb(1, 2, 3)');

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
      writeFileSync(join(dir, 'src', 'style.scss'), '.box { color: rgb(4, 5, 6); }');
      const msg = await messagePromise;
      expect(msg.type).toBe('css-update');
      expect(msg.href).toMatch(/\/src\/style\.css$/);
      await new Promise((r) => setTimeout(r, 300));
      expect(await fetchEmittedCss()).toContain('rgb(4, 5, 6)');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
