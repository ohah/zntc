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

describe('CLI: Vite-style app builder > styles > CSS Modules PostCSS', () => {
  test('Sass output flows through PostCSS before CSS Modules scoping', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-scss-module-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./card.module.scss"; console.log(styles.card, styles.postcssAdded);',
    );
    writeFileSync(
      join(dir, 'src', 'card.module.scss'),
      '$fg: rgb(9, 8, 7); .card { color: $fg; .child { padding: 3px; } }',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-scss-postcss', Once(root) { root.append({ selector: '.postcss-added', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[sass] processed 1 Sass/SCSS file');
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toMatch(/card_card__[A-Za-z0-9_-]{8}/);
    expect(js).toMatch(/card_postcss_added__[A-Za-z0-9_-]{8}/);
    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toContain('rgb(9, 8, 7)');
    expect(css).toMatch(/\.card_card__[A-Za-z0-9_-]{8} \.card_child__/);
    expect(css).toMatch(/\.card_postcss_added__[A-Za-z0-9_-]{8}/);
    rmSync(dir, { recursive: true, force: true });
  });

  test('CSS Modules are transformed after PostCSS in app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./card.module.css"; console.log(styles.card, styles.injected);',
    );
    writeFileSync(join(dir, 'src', 'card.module.css'), '.card { color: red; }');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-css-mod-postcss', Once(root) { root.append({ selector: '.injected', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    expect(stderr).toContain('[css-modules] processed 1 CSS module file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const cssPath = (html.match(/href="([^"]+\.css)"/) ?? [])[1];
    expect(cssPath).toBeTruthy();
    const css = readFileSync(join(outdir, cssPath.slice(1)), 'utf8');
    expect(css).toMatch(/\.card_card__[A-Za-z0-9_-]{8}/);
    expect(css).toMatch(/\.card_injected__[A-Za-z0-9_-]{8}/);
    rmSync(dir, { recursive: true, force: true });
  });
});
