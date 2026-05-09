import {
  describe,
  expect,
  existsSync,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  scriptPathFromHtml,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > build HTML/public basics', () => {
  test('build [root] rewrites HTML, injects env, and copies public/', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-build-'));
    try {
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
        { cwd: dir },
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
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
