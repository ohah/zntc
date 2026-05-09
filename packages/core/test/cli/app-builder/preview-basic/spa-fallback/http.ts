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
  runCli,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../../helpers';

describe('CLI: Vite-style app builder > preview SPA fallback HTTP', () => {
  test('preview --spa-fallback serves index.html for route-like misses only', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-preview-spa-'));
    try {
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
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
