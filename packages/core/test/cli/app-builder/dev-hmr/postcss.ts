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
  test('dev incremental PostCSS reprocesses only the changed CSS', async () => {
    // 단일 CSS 변경 시 changedPath 만 reprocess → stderr 에 "processed 1 CSS file".
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-incr-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/a.css">',
        '<link rel="stylesheet" href="/src/b.css">',
        '<script type="module" src="/src/main.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'a.css'), '.a{color:red}');
    writeFileSync(join(dir, 'src', 'b.css'), '.b{color:blue}');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-noop', Once() {} },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    const stderrChunks: string[] = [];
    proc.stderr?.on('data', (chunk) => stderrChunks.push(chunk.toString()));
    await waitForServer(port);
    try {
      // 초기 빌드: 두 CSS 모두 처리.
      expect(stderrChunks.join('')).toContain('[postcss] processed 2 CSS file');
      stderrChunks.length = 0;

      // a.css 한 파일만 변경 → incremental, "processed 1 CSS file".
      const messagePromise = new Promise<any>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (event) => {
          const msg = JSON.parse(String(event.data));
          if (msg.type === 'css-update' || msg.type === 'full-reload') {
            ws.close();
            resolve(msg);
          }
        };
        setTimeout(() => resolve({ type: 'timeout' }), 10000);
      });
      await new Promise((r) => setTimeout(r, 300));
      writeFileSync(join(dir, 'src', 'a.css'), '.a{color:green}');
      await messagePromise;
      // 이벤트 후 stderr flush 위해 잠시 대기.
      await new Promise((r) => setTimeout(r, 200));
      expect(stderrChunks.join('')).toContain('[postcss] processed 1 CSS file');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
