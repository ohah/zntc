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

describe('CLI: Vite-style app builder > styles', () => {
  test('JS-imported CSS is linked from HTML and processed by PostCSS', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="card">PostCSS</div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css"; console.log("css");');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '.card { color: red; }\n.card { background: white; }\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-test-postcss', Once(root) { root.append({ selector: '.postcss-ok', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('rel="stylesheet"');
    expect(html).toContain('href="/main.css"');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.postcss-ok');
    rmSync(dir, { recursive: true, force: true });
  });

  test('Tailwind v4 @tailwindcss/postcss app fixture', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-tailwind-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<main class="text-red-500"><script type="module" src="/src/main.ts"></script></main>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.css";');
    writeFileSync(
      join(dir, 'src', 'style.css'),
      '@import "tailwindcss";\n@source "../index.html";\n',
    );
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      'export default { plugins: { "@tailwindcss/postcss": {} } };\n',
    );

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stderr).toContain('[postcss] processed 1 CSS file');
    const css = readFileSync(join(outdir, 'main.css'), 'utf8');
    expect(css).toContain('.text-red-500');
    expect(css).not.toContain('@import "tailwindcss"');
    rmSync(dir, { recursive: true, force: true });
  });

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
    // 키워드 (`default`/`class`), 숫자 시작, 비-식별자 문자 등은 named export 로 못 만든다.
    // proxy 가 이를 무시하고 default styles 객체에는 그대로 보존되는지 확인.
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
    // .1abc 는 valid CSS class 가 아니므로 .module.css 에 직접 못 쓴다 — JS access 만 검증.

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    // 예약어/숫자-시작은 named export 미생성 — proxy 에 emit 됐다면 `const default`/`class`
    // 같은 invalid binding 이라 bundler 가 parse-fail 했을 것 (exitCode 0 자체가 그 증거).
    // valid 식별자 `ok` 는 export 됐어야 하고 (bundler 가 unused export 의 `export` 키워드는
    // 떼더라도 binding 자체는 남는다).
    expect(js).not.toMatch(/\bconst\s+default\s*=/);
    expect(js).not.toMatch(/\bconst\s+class\s*=/);
    expect(js).toMatch(/\bconst\s+ok\s*=/);
    // 그러나 default styles 객체에는 모든 키가 보존되어야 함.
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

  test('build does not collide when JS imports CSS that HTML also references', () => {
    // entry main.ts 가 import './main.css' 하고 HTML 도 같은 파일을 link 로 참조하면
    // bundler 가 main.css 를 emit. 이전엔 stylesheet 처리에서 OutputCollision 으로
    // hard-fail 했지만, 이제는 bundler emit 결과를 재사용하고 HTML href 만 rewrite 한다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-collision-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/main.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "import './main.css';\nconsole.log('ok');");
    writeFileSync(join(dir, 'src', 'main.css'), '.hero{color:red}');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir, '--no-splitting'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('OutputCollision');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    // bundler 가 emit 한 main.css 와 stylesheet 가 가리키는 src/main.css 가 서로 다른 path 로 분리.
    expect(html).toContain('href="/src/main.css"');
    expect(existsSync(join(outdir, 'main.css'))).toBe(true);
    expect(existsSync(join(outdir, 'src', 'main.css'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('dev applies PostCSS config and serves transformed CSS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-postcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'style.css'), '.x{color:red}');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'zntc-dev-postcss', Once(root) { root.append({ selector: '.dev-postcss-ok', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    const stderrChunks: string[] = [];
    proc.stderr?.on('data', (chunk) => stderrChunks.push(chunk.toString()));
    await waitForServer(port);
    try {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      expect(html).toContain('<title>dev</title>');
      expect(html).toContain('/__zntc_app_dev_hmr__');
      // stylesheet source 의 root-기준 relative path 가 link href 와 emit path 양쪽에서 보존된다.
      expect(html).toContain('href="/src/style.css"');
      const css = await fetch(`http://localhost:${port}/src/style.css`).then((r) => r.text());
      expect(css).toContain('.dev-postcss-ok');
      const stderrText = stderrChunks.join('');
      expect(stderrText).toContain('[postcss] processed 1 CSS file');
      expect(stderrText).not.toContain('skipped in dev mode');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev CSS source edit emits css-update instead of full-reload', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-hmr-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'style.css'), '.x{color:red}');
    writeFileSync(join(dir, 'postcss.config.mjs'), 'export default { plugins: [] };\n');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const messagePromise = new Promise<any>((resolve) => {
        const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
        ws.onmessage = (event) => {
          const msg = JSON.parse(String(event.data));
          if (msg.type === 'css-update' || msg.type === 'full-reload') {
            ws.close();
            resolve(msg);
          }
        };
        ws.onerror = () => resolve({ type: 'error' });
        setTimeout(() => resolve({ type: 'timeout' }), 10000);
      });
      await new Promise((r) => setTimeout(r, 300));
      writeFileSync(join(dir, 'src', 'style.css'), '.x{color:blue}');
      const msg = await messagePromise;
      expect(msg.type).toBe('css-update');
      expect(msg.href).toBe('/src/style.css');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
