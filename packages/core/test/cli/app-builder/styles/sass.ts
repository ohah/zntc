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
} from '../helpers';

describe('CLI: Vite-style app builder > styles > Sass', () => {
  test('Sass/SCSS app styles are compiled before app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<section class="panel"><script type="module" src="/src/main.ts"></script></section>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.scss"; console.log("scss");');
    writeFileSync(join(dir, 'src', '_vars.scss'), '$panel-color: rgb(12, 34, 56);');
    writeFileSync(
      join(dir, 'src', 'style.scss'),
      '@use "./vars" as *; .panel { color: $panel-color; .inner { padding: 4px; } }',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 2 Sass/SCSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('href="/main.css"');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('rgb(12, 34, 56)');
    expect(css).toContain('.panel .inner');
    rmSync(dir, { recursive: true, force: true });
  });

  test('HTML-linked .sass styles are compiled and base-prefixed', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-sass-html-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/page.sass">',
        '<main class="page"><script type="module" src="/src/main.ts"></script></main>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("sass html");');
    writeFileSync(
      join(dir, 'src', 'page.sass'),
      '$page-color: rgb(31, 41, 59)\n.page\n  color: $page-color\n  .title\n    margin: 2px\n',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 1 Sass/SCSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('href="/app/src/page.css"');
    const css = readFileSync(join(outdir, 'src', 'page.css'), 'utf8');
    expect(css).toContain('rgb(31, 41, 59)');
    expect(css).toContain('.page .title');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Sass syntax errors fail build without emitting partial app output', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-error-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./broken.scss";');
    writeFileSync(join(dir, 'src', 'broken.scss'), '.broken { color: $missing');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).not.toBe(0);
    expect(stderr).toContain('broken.scss');
    expect(existsSync(join(outdir, 'index.html'))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });
});
