import {
  CLI,
  RUNTIME,
  describe,
  execSync,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  runCli,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../../helpers';

describe('CLI: Vite-style app builder > preview SPA fallback HTTPS', () => {
  test('preview --spa-fallback works over HTTPS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-spa-https-'));
    try {
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
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
