import {
  describe,
  expect,
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
} from '../../helpers';

describe('CLI: Vite-style app builder > styles > CSS Modules basics > Sass modules', () => {
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
