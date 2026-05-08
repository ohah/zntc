import {
  CLI,
  RUNTIME,
  describe,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  scriptPathFromHtml,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > env and options > mode parity', () => {
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
});
