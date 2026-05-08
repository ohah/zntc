import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
  scriptPathFromHtml,
} from './helpers';

describe('CLI: Vite-style app builder > build basics', () => {
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
});
