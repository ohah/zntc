import {
  describe,
  test,
  expect,
  spawn,
  execSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  CLI,
  RUNTIME,
  waitForServer,
  findFreePort,
  runCli,
  scriptPathFromHtml,
} from './helpers';

describe('CLI: Vite-style app builder > preview basics', () => {
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
});
