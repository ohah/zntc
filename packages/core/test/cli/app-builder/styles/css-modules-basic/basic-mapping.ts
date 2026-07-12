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

describe('CLI: Vite-style app builder > styles > CSS Modules basics > mapping', () => {
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
    // #4466: CSS Modules 를 거친 CSS 도 자산 파이프라인을 탄다 — url() 이 원문으로
    // 남지 않고 재작성된다. icon.png 는 4바이트(inline limit 4096 이하)라 data URL.
    expect(css).not.toContain('url("./icon.png")');
    expect(css).toContain('url("data:image/png;base64,');
    rmSync(dir, { recursive: true, force: true });
  });
});
