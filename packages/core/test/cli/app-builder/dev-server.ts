import {
  describe,
  test,
  expect,
  spawn,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  CLI,
  RUNTIME,
  waitForServer,
  waitForText,
  findFreePort,
  occupyPort,
} from './helpers';

describe('CLI: Vite-style app builder > dev server', () => {
  test('dev [root] serves prepared app HTML and development env', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'public'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<title>%VITE_TITLE%</title><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'console.log(import.meta.env.VITE_TITLE, import.meta.env.MODE, process.env.NODE_ENV);',
    );
    writeFileSync(join(dir, '.env.development'), 'VITE_TITLE=Dev App\n');
    writeFileSync(join(dir, 'public', 'favicon.svg'), '<svg></svg>');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`, '--base', '/app/'], {
      cwd: dir,
    });
    await waitForServer(port);

    try {
      const html = await fetch(`http://localhost:${port}/app/`).then((r) => r.text());
      expect(html).toContain('<title>Dev App</title>');
      expect(html).toContain('src="/app/bundle.js"');

      const js = await fetch(`http://localhost:${port}/app/bundle.js`).then((r) => r.text());
      expect(js).toContain('"Dev App"');
      expect(js).toContain('"development"');
      expect(js).not.toContain('process.env.NODE_ENV');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev [root] loads root argument config from outside cwd', async () => {
    const parent = mkdtempSync(join(tmpdir(), 'zntc-app-dev-parent-config-'));
    const dir = join(parent, 'app');
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'document.body.textContent = __APP_LABEL__; console.log(__APP_LABEL__);',
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ define: { __APP_LABEL__: JSON.stringify('base-config') } }),
    );
    writeFileSync(
      join(dir, 'zntc.config.development.json'),
      JSON.stringify({ define: { __APP_LABEL__: JSON.stringify('root-dev-config') } }),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: parent });
    await waitForServer(port);

    try {
      const js = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
      expect(js).toContain('"root-dev-config"');
      expect(js).not.toContain('__APP_LABEL__');
    } finally {
      proc.kill();
      rmSync(parent, { recursive: true, force: true });
    }
  });

  test('dev [root] uses config server.port and server.host', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-server-config-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('server-config');");
    const port = await findFreePort();
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ server: { port, host: true } }));

    const proc = spawn(RUNTIME, [CLI, 'dev', dir], {
      cwd: dir,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let exitState = '';
    proc.stdout?.on('data', (chunk) => {
      stdout += String(chunk);
    });
    proc.stderr?.on('data', (chunk) => {
      stderr += String(chunk);
    });
    proc.on('exit', (code, signal) => {
      exitState = `exit:${code ?? ''}:${signal ?? ''}`;
    });
    const expectedServeLog = `[serve] http://0.0.0.0:${port}`;
    await Promise.all([
      waitForServer(port, 100),
      waitForText(() => `${stdout}${stderr}${exitState}`, expectedServeLog, 10000),
    ]);

    try {
      const js = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
      expect(js).toContain('server-config');
      expect(`${stdout}${stderr}`).toContain(expectedServeLog);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 10000);

  test('dev [root] CLI --port overrides config server.port', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-server-cli-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('cli-port');");
    const configPort = await findFreePort();
    const cliPort = configPort + 100;
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ server: { port: configPort } }));

    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${cliPort}`], { cwd: dir });
    await waitForServer(cliPort);

    try {
      const js = await fetch(`http://localhost:${cliPort}/bundle.js`).then((r) => r.text());
      expect(js).toContain('cli-port');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

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
