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

describe('CLI: Vite-style app builder > dev server', () => {
  test('dev restarts and reloads zntc.config changes', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-config-restart-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'document.body.textContent = __APP_LABEL__; console.log(__APP_LABEL__);',
    );
    const writeConfig = (label: string) => {
      writeFileSync(
        join(dir, 'zntc.config.json'),
        JSON.stringify({ define: { __APP_LABEL__: JSON.stringify(label) } }),
      );
    };
    writeConfig('before');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], {
      cwd: dir,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stderr = '';
    proc.stderr?.on('data', (chunk) => {
      stderr += String(chunk);
    });
    await waitForServer(port);

    async function waitForBundleText(expected: string) {
      const started = Date.now();
      while (Date.now() - started < 8000) {
        try {
          const js = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
          if (js.includes(expected)) return js;
        } catch {
          // 서버가 재시작 중이면 잠깐 connection refused 가 날 수 있다.
        }
        await new Promise((r) => setTimeout(r, 100));
      }
      throw new Error(`bundle did not contain ${expected}`);
    }

    try {
      expect(await waitForBundleText('"before"')).toContain('"before"');
      writeConfig('after');
      expect(await waitForBundleText('"after"')).toContain('"after"');
      expect(stderr).toContain('config');
    } finally {
      if (proc.pid) {
        try {
          process.kill(-proc.pid, 'SIGTERM');
        } catch {
          proc.kill();
        }
      }
      rmSync(dir, { recursive: true, force: true });
    }
  }, 15000);
});
