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
  findFreePort,
  runCli,
} from './helpers';

describe('CLI: Vite-style app builder > preview fallback', () => {
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
});
