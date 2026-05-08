import {
  describe,
  existsSync,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > build HTML/assets', () => {
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
});
