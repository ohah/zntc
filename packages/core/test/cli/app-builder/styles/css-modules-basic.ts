import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
  scriptPathFromHtml,
} from '../helpers';

describe('CLI: Vite-style app builder > styles > CSS Modules basics', () => {
  test('CSS Modules default and named exports map to scoped CSS in app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div id="app"></div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      [
        'import styles, { card } from "./card.module.css";',
        'document.getElementById("app").className = `${styles.card} ${styles["title-text"]} ${card}`;',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'src', 'card.module.css'),
      [
        '.card { color: rgb(255, 0, 0); background-image: url("./icon.png"); }',
        '.card.active { outline-color: rgb(0, 0, 0); }',
        '.title-text { background: white; }',
      ].join('\n'),
    );
    writeFileSync(join(dir, 'src', 'icon.png'), 'icon');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');

    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('rel="stylesheet"');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toContain('"card"');
    expect(js).toMatch(/card_card__[A-Za-z0-9_-]{8}/);
    expect(js).not.toContain('import "./card.module.css"');

    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toMatch(/\.card_card__[A-Za-z0-9_-]{8}/);
    expect(css).toMatch(/\.card_active__[A-Za-z0-9_-]{8}/);
    expect(css).toMatch(/\.card_title_text__[A-Za-z0-9_-]{8}/);
    expect(css).toContain('url("./icon.png")');
    rmSync(dir, { recursive: true, force: true });
  });

  test('CSS Modules omit named exports for invalid JS identifiers', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-invalid-export-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      [
        'import styles, { ok } from "./names.module.css";',
        'console.log(styles.default, styles.class, styles["1abc"], styles.ok, ok);',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'src', 'names.module.css'),
      ['.default { color: red; }', '.class { color: green; }', '.ok { color: blue; }'].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).not.toMatch(/\bconst\s+default\s*=/);
    expect(js).not.toMatch(/\bconst\s+class\s*=/);
    expect(js).toMatch(/\bconst\s+ok\s*=/);
    expect(js).toContain('"default":');
    expect(js).toContain('"class":');
    expect(js).toContain('"ok":');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Sass CSS Modules compile to scoped class maps', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-module-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./button.module.scss"; console.log(styles.button, styles.child);',
    );
    writeFileSync(
      join(dir, 'src', 'button.module.scss'),
      '$fg: rgb(1, 2, 3); .button { color: $fg; .child { margin: 1px; } }',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 1 Sass/SCSS file');
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toMatch(/button_button__[A-Za-z0-9_-]{8}/);
    expect(js).toMatch(/button_child__[A-Za-z0-9_-]{8}/);
    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toContain('rgb(1, 2, 3)');
    expect(css).toMatch(/\.button_button__[A-Za-z0-9_-]{8} \.button_child__/);
    rmSync(dir, { recursive: true, force: true });
  });
});
