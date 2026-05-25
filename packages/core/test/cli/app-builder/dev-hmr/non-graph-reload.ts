// #3797 회귀 가드 — index.html 처럼 native watch 의 module graph 밖이면서 CSS 도 아닌
// 파일 변경은 drain else 분기에서 fallback FullReload broadcast 받아야 함.
// 가드 전 (pre-#3797): drain 의 cssDerived 분기만 broadcast → HTML/JSON 변경은 silent drop.
// pre-#3779 회귀 — 사용자가 reload 받지 못해 화면 stale.

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

describe('CLI: Vite-style app builder > dev HMR > non-graph file reload', () => {
  test('index.html 변경 → FullReload broadcast 수신 (#3797)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-html-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<!doctype html><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("v1");');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const messagePromise = new Promise<{ type: string }>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (event) => {
          const msg = JSON.parse(String(event.data));
          // connected 무시, full-reload 받으면 종료
          if (msg.type === 'full-reload') {
            ws.close();
            resolve(msg);
          }
        };
        ws.onerror = () => resolve({ type: 'error' });
        setTimeout(() => resolve({ type: 'timeout' }), 5000);
      });
      await new Promise((r) => setTimeout(r, 300));
      // HTML 변경 — module graph 밖, CSS 도 아님 → drain 의 fallback FullReload 가 처리해야.
      writeFileSync(
        join(dir, 'index.html'),
        '<!doctype html><meta name="v" content="2"><script type="module" src="/src/main.ts"></script>',
      );
      const msg = await messagePromise;
      expect(msg.type).toBe('full-reload');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
