import {
  describe,
  test,
  expect,
  spawn,
  mkdtempSync,
  writeFileSync,
  rmSync,
  mkdirSync,
  tmpdir,
  join,
  CLI,
  RUNTIME,
  waitForServer,
  findFreePort,
} from '../helpers';

describe('CLI: Vite-style app builder > styles > dev', () => {
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

  // RFC #3833 v3 D1a'' Phase 2 — dev path 도 caller-side pre-warm. 사용자 explicit
  // `plugins:[css({postcss:{...override}})]` 가 controller 의 postcssOverride 로
  // 전달되어 prepare 의 PostCSS 단계에 적용. build path 와 동일 시맨틱 검증.
  test('dev applies user explicit css({postcss}) override (D1a Phase 2)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-override-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev-override</title><link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'style.css'), '.x{color:red}');
    // postcss.config 부재 → 자동발견 path null. override 만 활성화 확인.
    writeFileSync(
      join(dir, 'zntc.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        '    {',
        "      name: '@zntc/web/css',",
        '      __cssOptions: {',
        '        postcss: {',
        '          plugins: [',
        "            { postcssPlugin: 'dev-override-marker', Once(root) { root.append({ selector: '.dev-override-applied', nodes: [] }); } },",
        '          ],',
        '        },',
        '      },',
        '      setup() {},',
        '    },',
        '  ],',
        '};',
      ].join('\n'),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const css = await fetch(`http://localhost:${port}/src/style.css`).then((r) => r.text());
      expect(css).toContain('.dev-override-applied');
      expect(css).toContain('.x');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // issue #3847 fix 회귀 가드 — dev 의 zero-config PostCSS 가 **한 번만** 적용
  // (이전엔 prepare + afterBundle 둘 다 호출되어 마지막 emit 된 css 에 marker
  // 2번 emit). controller 의 preparePostcssApplied flag + runPostcssForAppDev
  // 의 skipPostcssRun 분기로 mirror 만 — emit 결과 marker 1번 보장. stderr
  // capture 가 timing-flaky 이므로 HTTP 응답 의 marker count 만 단언.
  test('dev zero-config PostCSS 1번만 적용 (#3847 double-pass 해소)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-singlepass-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'style.css'), '.x{color:red}');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'single-marker', Once(root) { root.append({ selector: '.single-pass', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const css = await fetch(`http://localhost:${port}/src/style.css`).then((r) => r.text());
      // marker 가 **정확히 1번** — double-pass 이전엔 2번 emit
      const markerMatches = css.match(/\.single-pass/g) ?? [];
      expect(markerMatches.length).toBe(1);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // dev + Sass 시나리오 — D1a'' Phase 2 + #3847 fix 후에도 Sass 컴파일 정상.
  // prepare 의 transformCssPreprocessors 가 sass 처리 → mirror 가 결과 .css 응답.
  test('dev Sass — $variable + nested 컴파일 결과 응답', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-sass-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/style.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("sass");');
    writeFileSync(
      join(dir, 'src', 'style.scss'),
      '$primary: red;\n.card { color: $primary; .inner { padding: 4px; } }',
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      // sass 컴파일 결과 .css 가 mirror 에 — HTML 의 link 가 .css 가리켜야
      const css = await fetch(`http://localhost:${port}/src/style.css`).then((r) => r.text());
      expect(css).toContain('color: red'); // $primary 변수 expanded
      expect(css).toMatch(/\.card\s+\.inner/); // nested rule expanded
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // dev + CSS Modules 시나리오 — D1a'' Phase 2 + #3847 fix 후 scoped class
  // names 가 bundle.js 안에 inline. proxy.js 자체는 bundler 가 처리 → bundle.js
  // 응답에 mapping 포함.
  test('dev CSS Modules — bundle.js 안 scoped class names mapping', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-cssmod-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import styles from "./Button.module.css"; globalThis.__styles = styles;',
    );
    writeFileSync(
      join(dir, 'src', 'Button.module.css'),
      '.primary { color: red; }\n.danger { color: darkred; }',
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      // bundle.js 안에 CSS Modules mapping inline (bundler 가 proxy 처리)
      const bundle = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
      // scoped class names + mapping key 양쪽 검증
      expect(bundle).toMatch(/Button_primary__[A-Za-z0-9_-]{8}/);
      expect(bundle).toMatch(/Button_danger__[A-Za-z0-9_-]{8}/);
      expect(bundle).toContain('primary');
      expect(bundle).toContain('danger');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
