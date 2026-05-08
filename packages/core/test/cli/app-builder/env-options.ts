import {
  describe,
  test,
  expect,
  spawn,
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
  findFreePort,
  runCli,
  scriptPathFromHtml,
} from './helpers';

describe('CLI: Vite-style app builder > env and options', () => {
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
});
