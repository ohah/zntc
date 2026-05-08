import {
  describe,
  test,
  expect,
  spawn,
  execSync,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  CLI,
  RUNTIME,
  waitForServer,
  waitForText,
  findFreePort,
  occupyPort,
  runCli,
} from './helpers';

describe('CLI: Vite-style app builder', () => {
  function scriptPathFromHtml(html: string): string {
    const match = html.match(/<script[^>]+src="([^"]+)"/);
    expect(match).not.toBeNull();
    return match![1];
  }

  test('build [root] rewrites HTML, injects env, and copies public/', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-build-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'public'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<!doctype html>',
        '<html><head>',
        '<title>%VITE_TITLE%</title>',
        '<link rel="icon" href="/favicon.svg">',
        '</head><body>',
        '<script type="module" src="/src/main.ts"></script>',
        '</body></html>',
      ].join(''),
    );
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'console.log(import.meta.env.MODE, import.meta.env.PROD, import.meta.env.BASE_URL, import.meta.env.VITE_TITLE, process.env.NODE_ENV);',
    );
    writeFileSync(join(dir, '.env.production'), 'VITE_TITLE=ZNTC App\n');
    writeFileSync(join(dir, 'public', 'favicon.svg'), '<svg></svg>');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(
      ['build', dir, '--outdir', outdir, '--base', '/app/', '--clean'],
      {
        cwd: dir,
      },
    );
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('error:');

    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('<title>ZNTC App</title>');
    expect(html).toContain('href="/app/favicon.svg"');
    const scriptPath = scriptPathFromHtml(html);
    expect(scriptPath).toMatch(/^\/app\/main-[a-f0-9]+\.js$/);
    const js = readFileSync(join(outdir, scriptPath.replace('/app/', '')), 'utf8');
    expect(js).toContain('"ZNTC App"');
    expect(js).toContain('"production"');
    expect(js).not.toContain('process.env.NODE_ENV');
    expect(existsSync(join(outdir, 'favicon.svg'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('build [root] loads root argument config from outside cwd', () => {
    const parent = mkdtempSync(join(tmpdir(), 'zntc-app-build-parent-config-'));
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
      join(dir, 'zntc.config.production.json'),
      JSON.stringify({ define: { __APP_LABEL__: JSON.stringify('root-mode-config') } }),
    );

    const outdir = join(parent, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: parent });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('error:');

    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.replace(/^\//, '')), 'utf8');
    expect(js).toContain('"root-mode-config"');
    expect(js).not.toContain('__APP_LABEL__');
    rmSync(parent, { recursive: true, force: true });
  });

  test('public output collision fails deterministically', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-public-collision-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'public'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log(1);');
    writeFileSync(join(dir, 'public', 'index.html'), 'collision');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('PublicDirCollision');
    rmSync(dir, { recursive: true, force: true });
  });

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

  test('preview [outdir] serves built files under base without rebuilding', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<h1>%VITE_TITLE%</h1><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log(import.meta.env.MODE);');
    writeFileSync(join(dir, '.env.production'), 'VITE_TITLE=Preview App\n');

    const outdir = join(dir, 'dist');
    const buildResult = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(buildResult.exitCode).toBe(0);

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'preview', outdir, `--port=${port}`, '--base', '/app/'], {
      cwd: dir,
    });
    await waitForServer(port);

    try {
      const html = await fetch(`http://localhost:${port}/app/`).then((r) => r.text());
      expect(html).toContain('<h1>Preview App</h1>');
      const scriptPath = scriptPathFromHtml(html);
      expect(scriptPath).toMatch(/^\/app\/main-[a-f0-9]+\.js$/);
      const js = await fetch(`http://localhost:${port}${scriptPath}`).then((r) => r.text());
      expect(js).toContain('"production"');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('preview --spa-fallback serves index.html for route-like misses only', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-spa-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="app">spa</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('spa');");

    const outdir = join(dir, 'dist');
    const buildResult = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(buildResult.exitCode).toBe(0);

    const port = await findFreePort();
    const proc = spawn(
      RUNTIME,
      [CLI, 'preview', outdir, `--port=${port}`, '--base', '/app/', '--spa-fallback'],
      { cwd: dir },
    );
    await waitForServer(port);

    try {
      const html = await fetch(`http://localhost:${port}/app/dashboard/settings`, {
        headers: { accept: 'text/html' },
      }).then((r) => r.text());
      expect(html).toContain('<div id="app">spa</div>');

      const missingAsset = await fetch(`http://localhost:${port}/app/missing.png`);
      expect(missingAsset.status).toBe(404);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('preview --spa-fallback works over HTTPS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-spa-https-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<main id="app">secure spa</main><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('secure spa');");

    const outdir = join(dir, 'dist');
    const buildResult = runCli(['build', dir, '--outdir', outdir, '--base', '/secure/'], {
      cwd: dir,
    });
    expect(buildResult.exitCode).toBe(0);

    const certFile = join(dir, 'cert.pem');
    const keyFile = join(dir, 'key.pem');
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = await findFreePort();
    const proc = spawn(
      RUNTIME,
      [
        CLI,
        'preview',
        outdir,
        `--port=${port}`,
        '--base',
        '/secure/',
        '--spa-fallback',
        '--certfile',
        certFile,
        '--keyfile',
        keyFile,
      ],
      { cwd: dir },
    );
    await waitForServer(port, 20, 100, 'https');

    try {
      const route = await fetch(`https://localhost:${port}/secure/dashboard/settings`, {
        headers: { accept: 'text/html' },
        tls: { rejectUnauthorized: false },
      } as any);
      expect(route.status).toBe(200);
      expect(await route.text()).toContain('<main id="app">secure spa</main>');

      const missingAsset = await fetch(`https://localhost:${port}/secure/missing.png`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(missingAsset.status).toBe(404);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('build injects modulepreload links for static split chunks', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-modulepreload-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<script type="module" src="/src/admin.ts"></script>',
        '<script type="module" src="/src/client.ts"></script>',
      ].join(''),
    );
    writeFileSync(
      join(dir, 'src', 'admin.ts'),
      'import { shared } from "./shared"; console.log("admin", shared);',
    );
    writeFileSync(
      join(dir, 'src', 'client.ts'),
      'import { shared } from "./shared"; console.log("client", shared);',
    );
    writeFileSync(join(dir, 'src', 'shared.ts'), 'export const shared = "shared";');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toMatch(/<link rel="modulepreload" href="\/app\/chunk-[a-f0-9]+\.js">/);
    const scripts = html.match(/<script[^>]+src="([^"]+)"/g) ?? [];
    expect(scripts.length).toBe(2);
    expect(scripts[0]).toMatch(/\/app\/admin-[a-f0-9]+\.js/);
    expect(scripts[1]).toMatch(/\/app\/client-[a-f0-9]+\.js/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('modulepreload deduplicates shared chunk across multiple entries', () => {
    // 여러 entry 가 같은 shared chunk 를 import 하면 modulepreload 는 entry 마다 중복
    // 추가하지 말고 단 1회만 주입되어야 한다 (`appendModulePreloadImports` 의 seen set
    // 동작 검증). ZNTC 코드 분할은 동일 reachability mask 모듈을 한 chunk 로 머지하므로
    // 이 setup 에서는 1개의 shared chunk 만 생긴다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-modulepreload-dedup-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<script type="module" src="/src/page-a.ts"></script>',
        '<script type="module" src="/src/page-b.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'shared.ts'), 'export const s = "shared";');
    writeFileSync(
      join(dir, 'src', 'page-a.ts'),
      'import { s } from "./shared"; console.log("a", s);',
    );
    writeFileSync(
      join(dir, 'src', 'page-b.ts'),
      'import { s } from "./shared"; console.log("b", s);',
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const preloadHrefs = [...html.matchAll(/<link rel="modulepreload" href="([^"]+)">/g)].map(
      (m) => m[1],
    );
    expect(preloadHrefs.length).toBeGreaterThanOrEqual(1);
    expect(new Set(preloadHrefs).size).toBe(preloadHrefs.length);
    // shared chunk 만 modulepreload 대상이고 entry chunk 자신은 포함되지 않아야 한다.
    const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
    for (const href of preloadHrefs) {
      expect(scripts).not.toContain(href);
    }
    rmSync(dir, { recursive: true, force: true });
  });

  test('multiple module scripts each map to their own entry output', () => {
    // Entry chunk 들은 emitter 내부에서 exec_order(=DFS post-order) 로 정렬되어
    // 출력되므로, html 의 <script> 순서와 outputs 순서가 항상 일치한다고 가정하면
    // 깨질 수 있다. build.zig 는 entry path → output 을 module_ids 로 매칭하므로
    // 여기서는 alphabetical 역순/공유 의존성 등으로 자연스럽게 정렬을 흔들면서도
    // 각 <script> 가 자기 entry 의 hashed output 으로 정확히 rewrite 되는지 확인한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-entry-mapping-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        // 알파벳 역순 (zeta, alpha) — DFS exec_index 와 무관하게 src 가 자기 chunk 로 매핑되어야 함.
        '<script type="module" src="/src/zeta.ts"></script>',
        '<script type="module" src="/src/alpha.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'shared.ts'), 'export const s = "s";');
    writeFileSync(
      join(dir, 'src', 'alpha.ts'),
      'import { s } from "./shared"; console.log("ALPHA", s);',
    );
    writeFileSync(
      join(dir, 'src', 'zeta.ts'),
      'import { s } from "./shared"; console.log("ZETA", s);',
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scripts = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
    expect(scripts.length).toBe(2);
    expect(scripts[0]).toMatch(/\/zeta-[a-f0-9]+\.js$/);
    expect(scripts[1]).toMatch(/\/alpha-[a-f0-9]+\.js$/);
    // 각 hashed output 의 실제 내용도 자기 entry 의 console.log 를 포함해야 함.
    const zetaPath = join(outdir, scripts[0].replace(/^\//, ''));
    const alphaPath = join(outdir, scripts[1].replace(/^\//, ''));
    expect(readFileSync(zetaPath, 'utf8')).toContain('ZETA');
    expect(readFileSync(alphaPath, 'utf8')).toContain('ALPHA');
    rmSync(dir, { recursive: true, force: true });
  });

  test('preview without --spa-fallback returns 404 for route-like misses', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-no-spa-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="app">noop</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('noop');");

    const outdir = join(dir, 'dist');
    const buildResult = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(buildResult.exitCode).toBe(0);

    const port = await findFreePort();
    // --spa-fallback 미지정 — route-like 요청도 그대로 404 여야 한다.
    const proc = spawn(RUNTIME, [CLI, 'preview', outdir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);

    try {
      const res = await fetch(`http://localhost:${port}/dashboard/settings`, {
        headers: { accept: 'text/html' },
      });
      expect(res.status).toBe(404);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('preview --spa-fallback=custom.html honors a custom fallback file', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-spa-custom-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="app">root</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('root');");

    const outdir = join(dir, 'dist');
    const buildResult = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(buildResult.exitCode).toBe(0);
    // 별도 custom fallback 파일을 outdir 에 직접 추가 — preview 만 검증하면 충분.
    writeFileSync(join(outdir, 'custom.html'), '<title>CUSTOM_FALLBACK</title>');

    const port = await findFreePort();
    const proc = spawn(
      RUNTIME,
      [CLI, 'preview', outdir, `--port=${port}`, '--spa-fallback=custom.html'],
      { cwd: dir },
    );
    await waitForServer(port);

    try {
      const html = await fetch(`http://localhost:${port}/some/route`, {
        headers: { accept: 'text/html' },
      }).then((r) => r.text());
      expect(html).toContain('CUSTOM_FALLBACK');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('build rewrites stylesheet url assets and HTML assets with query/hash', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-assets-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/style.css?v=1">',
        '<img src="/src/logo.png?raw#x">',
        '<script type="module" src="/src/main.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('assets');");
    writeFileSync(join(dir, 'src', 'style.css'), ".hero{background:url('./bg.png?v=2#hash')}");
    writeFileSync(join(dir, 'src', 'bg.png'), 'bg');
    writeFileSync(join(dir, 'src', 'logo.png'), 'logo');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);

    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    // stylesheet source 의 root-기준 relative path 가 link href 에 보존된다.
    expect(html).toContain('href="/app/src/style.css?v=1"');
    expect(html).toContain('src="/app/logo.png?raw#x"');
    expect(readFileSync(join(outdir, 'src', 'style.css'), 'utf8')).toContain(
      'url("/app/bg.png?v=2#hash")',
    );
    expect(existsSync(join(outdir, 'bg.png'))).toBe(true);
    expect(existsSync(join(outdir, 'logo.png'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('custom --entry-html and --public-dir false', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-entry-public-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'public'), { recursive: true });
    writeFileSync(
      join(dir, 'app.html'),
      '<h1>%VITE_TITLE%</h1><script type="module" src="./src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log(import.meta.env.VITE_TITLE);');
    writeFileSync(join(dir, '.env.production'), 'VITE_TITLE=Custom Entry\n');
    writeFileSync(join(dir, 'public', 'favicon.svg'), '<svg></svg>');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(
      ['build', dir, '--entry-html', 'app.html', '--public-dir', 'false', '--outdir', outdir],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(readFileSync(join(outdir, 'index.html'), 'utf8')).toContain('<h1>Custom Entry</h1>');
    expect(existsSync(join(outdir, 'favicon.svg'))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test('full import.meta.env object is statically injected in app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-env-object-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'console.log(import.meta.env.VITE_TITLE, import.meta.env.BASE_URL, import.meta.env.MODE, import.meta.env);',
    );
    writeFileSync(join(dir, '.env.production'), 'VITE_TITLE=Object Env\n');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.replace('/app/', '')), 'utf8');
    expect(js).toContain('"Object Env"');
    expect(js).toContain('"/app/"');
    expect(js).toContain('"production"');
    expect(js).toContain('"VITE_TITLE":"Object Env"');
    expect(js).not.toContain('import.meta.env');
    rmSync(dir, { recursive: true, force: true });
  });

  test('same app uses development env in dev and production env in build', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-env-parity-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log(import.meta.env.VITE_NAME);');
    writeFileSync(join(dir, '.env.development'), 'VITE_NAME=from-dev\n');
    writeFileSync(join(dir, '.env.production'), 'VITE_NAME=from-prod\n');

    const outdir = join(dir, 'dist');
    const buildResult = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(buildResult.exitCode).toBe(0);
    const builtHtml = readFileSync(join(outdir, 'index.html'), 'utf8');
    const builtScriptPath = scriptPathFromHtml(builtHtml);
    expect(readFileSync(join(outdir, builtScriptPath.slice(1)), 'utf8')).toContain('"from-prod"');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);

    try {
      const js = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
      expect(js).toContain('"from-dev"');
      expect(js).not.toContain('from-prod');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('--env-prefix controls app env exposure', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-env-prefix-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      ['console.log(import.meta.env.CUSTOM_NAME);', 'console.log(import.meta.env.VITE_NAME);'].join(
        '\n',
      ),
    );
    writeFileSync(join(dir, '.env.production'), 'CUSTOM_NAME=allowed\nVITE_NAME=hidden\n');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--env-prefix', 'CUSTOM_'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toContain('"allowed"');
    expect(js).toContain('.VITE_NAME');
    expect(js).not.toContain('"hidden"');
    rmSync(dir, { recursive: true, force: true });
  });

  test('JS-imported CSS is linked from HTML and processed by PostCSS', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">PostCSS</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css"; console.log("css");');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '.card { color: red; }\n.card { background: white; }\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-test-postcss', Once(root) { root.append({ selector: '.postcss-ok', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('rel="stylesheet"');
    expect(html).toContain('href="/main.css"');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.postcss-ok');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Tailwind v4 @tailwindcss/postcss app fixture', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-tailwind-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<main class="text-red-500"><script type="module" src="/src/main.ts"></script></main>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '@import "tailwindcss";\n@source "../index.html";\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      'export default { plugins: { "@tailwindcss/postcss": {} } };\n',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.text-red-500');
    expect(css).not.toContain('@import "tailwindcss"');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Sass/SCSS app styles are compiled before app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<section class="panel"><script type="module" src="/src/main.ts"></script></section>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.scss"; console.log("scss");');
    writeFileSync(join(dir, 'src', '_vars.scss'), '$panel-color: rgb(12, 34, 56);');
    writeFileSync(
      join(dir, 'src', 'style.scss'),
      '@use "./vars" as *; .panel { color: $panel-color; .inner { padding: 4px; } }',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 2 Sass/SCSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('href="/main.css"');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('rgb(12, 34, 56)');
    expect(css).toContain('.panel .inner');
    rmSync(dir, { recursive: true, force: true });
  });

  test('HTML-linked .sass styles are compiled and base-prefixed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-sass-html-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/page.sass">',
        '<main class="page"><script type="module" src="/src/main.ts"></script></main>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("sass html");');
    writeFileSync(
      join(dir, 'src', 'page.sass'),
      '$page-color: rgb(31, 41, 59)\n.page\n  color: $page-color\n  .title\n    margin: 2px\n',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 1 Sass/SCSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('href="/app/src/page.css"');
    const css = readFileSync(join(outdir, 'src', 'page.css'), 'utf8');
    expect(css).toContain('rgb(31, 41, 59)');
    expect(css).toContain('.page .title');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Sass output flows through PostCSS before CSS Modules scoping', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-module-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./card.module.scss"; console.log(styles.card, styles.postcssAdded);',
    );
    writeFileSync(
      join(dir, 'src', 'card.module.scss'),
      '$fg: rgb(9, 8, 7); .card { color: $fg; .child { padding: 3px; } }',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-scss-postcss', Once(root) { root.append({ selector: '.postcss-added', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 1 Sass/SCSS file');
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toMatch(/card_card__[A-Za-z0-9_-]{8}/);
    expect(js).toMatch(/card_postcss_added__[A-Za-z0-9_-]{8}/);
    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toContain('rgb(9, 8, 7)');
    expect(css).toMatch(/\.card_card__[A-Za-z0-9_-]{8} \.card_child__/);
    expect(css).toMatch(/\.card_postcss_added__[A-Za-z0-9_-]{8}/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('Sass syntax errors fail build without emitting partial app output', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-error-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./broken.scss";');
    writeFileSync(join(dir, 'src', 'broken.scss'), '.broken { color: $missing');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).not.toBe(0);
    expect(stderr).toContain('broken.scss');
    expect(existsSync(join(outdir, 'index.html'))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test('CSS Modules default and named exports map to scoped CSS in app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="app"></div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      [
        'import styles, { card } from "./card.module.css";',
        'document.getElementById("app").className = `${styles.card} ${styles["title-text"]} ${card}`;',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'src', 'card.module.css'),
      [
        '.card { color: rgb(255, 0, 0); background-image: url("./icon.png"); }',
        '.card.active { outline-color: rgb(0, 0, 0); }',
        '.title-text { background: white; }',
      ].join('\n'),
    );
    writeFileSync(join(dir, 'src', 'icon.png'), 'icon');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');

    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('rel="stylesheet"');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toContain('"card"');
    expect(js).toMatch(/card_card__[A-Za-z0-9_-]{8}/);
    expect(js).not.toContain('import "./card.module.css"');

    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toMatch(/\.card_card__[A-Za-z0-9_-]{8}/);
    expect(css).toMatch(/\.card_active__[A-Za-z0-9_-]{8}/);
    expect(css).toMatch(/\.card_title_text__[A-Za-z0-9_-]{8}/);
    expect(css).toContain('url("./icon.png")');
    rmSync(dir, { recursive: true, force: true });
  });

  test('CSS Modules omit named exports for invalid JS identifiers', () => {
    // 키워드 (`default`/`class`), 숫자 시작, 비-식별자 문자 등은 named export 로 못 만든다.
    // proxy 가 이를 무시하고 default styles 객체에는 그대로 보존되는지 확인.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-invalid-export-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      [
        'import styles, { ok } from "./names.module.css";',
        'console.log(styles.default, styles.class, styles["1abc"], styles.ok, ok);',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'src', 'names.module.css'),
      ['.default { color: red; }', '.class { color: green; }', '.ok { color: blue; }'].join('\n'),
    );
    // .1abc 는 valid CSS class 가 아니므로 .module.css 에 직접 못 쓴다 — JS access 만 검증.

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    // 예약어/숫자-시작은 named export 미생성 — proxy 에 emit 됐다면 `const default`/`class`
    // 같은 invalid binding 이라 bundler 가 parse-fail 했을 것 (exitCode 0 자체가 그 증거).
    // valid 식별자 `ok` 는 export 됐어야 하고 (bundler 가 unused export 의 `export` 키워드는
    // 떼더라도 binding 자체는 남는다).
    expect(js).not.toMatch(/\bconst\s+default\s*=/);
    expect(js).not.toMatch(/\bconst\s+class\s*=/);
    expect(js).toMatch(/\bconst\s+ok\s*=/);
    // 그러나 default styles 객체에는 모든 키가 보존되어야 함.
    expect(js).toContain('"default":');
    expect(js).toContain('"class":');
    expect(js).toContain('"ok":');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Sass CSS Modules compile to scoped class maps', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-module-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./button.module.scss"; console.log(styles.button, styles.child);',
    );
    writeFileSync(
      join(dir, 'src', 'button.module.scss'),
      '$fg: rgb(1, 2, 3); .button { color: $fg; .child { margin: 1px; } }',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 1 Sass/SCSS file');
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toMatch(/button_button__[A-Za-z0-9_-]{8}/);
    expect(js).toMatch(/button_child__[A-Za-z0-9_-]{8}/);
    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toContain('rgb(1, 2, 3)');
    expect(css).toMatch(/\.button_button__[A-Za-z0-9_-]{8} \.button_child__/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('CSS Modules are transformed after PostCSS in app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./card.module.css"; console.log(styles.card, styles.injected);',
    );
    writeFileSync(join(dir, 'src', 'card.module.css'), '.card { color: red; }');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-css-mod-postcss', Once(root) { root.append({ selector: '.injected', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toMatch(/\.card_card__[A-Za-z0-9_-]{8}/);
    expect(css).toMatch(/\.card_injected__[A-Za-z0-9_-]{8}/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('build does not collide when JS imports CSS that HTML also references', () => {
    // entry main.ts 가 import './main.css' 하고 HTML 도 같은 파일을 link 로 참조하면
    // bundler 가 main.css 를 emit. 이전엔 stylesheet 처리에서 OutputCollision 으로
    // hard-fail 했지만, 이제는 bundler emit 결과를 재사용하고 HTML href 만 rewrite 한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-collision-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/main.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "import './main.css';\nconsole.log('ok');");
    writeFileSync(join(dir, 'src', 'main.css'), '.hero{color:red}');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir, '--no-splitting'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('OutputCollision');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    // bundler 가 emit 한 main.css 와 stylesheet 가 가리키는 src/main.css 가 서로 다른 path 로 분리.
    expect(html).toContain('href="/src/main.css"');
    expect(existsSync(join(outdir, 'main.css'))).toBe(true);
    expect(existsSync(join(outdir, 'src', 'main.css'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('dev applies PostCSS config and serves transformed CSS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'style.css'), '.x{color:red}');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-dev-postcss', Once(root) { root.append({ selector: '.dev-postcss-ok', nodes: [] }); } },",
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
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      expect(html).toContain('<title>dev</title>');
      expect(html).toContain('/__zntc_app_dev_hmr__');
      // stylesheet source 의 root-기준 relative path 가 link href 와 emit path 양쪽에서 보존된다.
      expect(html).toContain('href="/src/style.css"');
      const css = await fetch(`http://localhost:${port}/src/style.css`).then((r) => r.text());
      expect(css).toContain('.dev-postcss-ok');
      const stderrText = stderrChunks.join('');
      expect(stderrText).toContain('[postcss] processed 1 CSS file');
      expect(stderrText).not.toContain('skipped in dev mode');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev CSS source edit emits css-update instead of full-reload', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-hmr-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'style.css'), '.x{color:red}');
    writeFileSync(join(dir, 'postcss.config.mjs'), 'export default { plugins: [] };\n');

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
      writeFileSync(join(dir, 'src', 'style.css'), '.x{color:blue}');
      const msg = await messagePromise;
      expect(msg.type).toBe('css-update');
      expect(msg.href).toBe('/src/style.css');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

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

  test('dev single SCSS edit takes the css-update fast-path', async () => {
    // 단일 non-module `.scss` 변경은 그 파일만 재컴파일 → outdir mirror → CssUpdate
    // broadcast 로 끝난다 (full reload 안 함, BACKLOG #71). `.module.scss` 는 여전히 full
    // reload (class map 갱신 가능).
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
      // CssUpdate 의 href 는 컴파일된 `.css` 경로 — broadcast payload 에 포함됨.
      expect(msg.href).toMatch(/\/src\/style\.css$/);
      await new Promise((r) => setTimeout(r, 300));
      expect(await fetchEmittedCss()).toContain('rgb(4, 5, 6)');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev .module.scss edit triggers full reload (not css-update fast-path)', async () => {
    // `.module.scss` 는 class-name map 이 변할 수 있어 fast-path 자격 박탈 — full reload
    // 가 보장되어야 한다 (`isSassOnlyChange` 가 module variant 를 제외하는지 검증).
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

  test('dev preserves sub-directory CSS path (no basename collision)', async () => {
    // 서브디렉토리에 같은 basename 을 가진 두 CSS 파일이 있으면, root-기준 relative path 가
    // 보존되어 HTML link 와 emit path 가 둘 다 분리된다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-nested-'));
    mkdirSync(join(dir, 'src', 'a'), { recursive: true });
    mkdirSync(join(dir, 'src', 'b'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/a/style.css">',
        '<link rel="stylesheet" href="/src/b/style.css">',
        '<script type="module" src="/src/main.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'a', 'style.css'), '.aaa{color:red}');
    writeFileSync(join(dir, 'src', 'b', 'style.css'), '.bbb{color:blue}');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      expect(html).toContain('href="/src/a/style.css"');
      expect(html).toContain('href="/src/b/style.css"');
      const aCss = await fetch(`http://localhost:${port}/src/a/style.css`).then((r) => r.text());
      const bCss = await fetch(`http://localhost:${port}/src/b/style.css`).then((r) => r.text());
      expect(aCss).toContain('.aaa');
      expect(bCss).toContain('.bbb');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

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

// ─── mode-specific config 자동 머지 (#2110 / Phase 3-3) ───
