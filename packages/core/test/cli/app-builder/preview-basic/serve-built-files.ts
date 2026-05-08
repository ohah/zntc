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
  scriptPathFromHtml,
} from '../helpers';

describe('CLI: Vite-style app builder > preview built files', () => {
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
});
