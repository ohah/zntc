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

  // issue #3858 — dev 모드에서 import 없이 raw `.css` 신규 파일 add 시 watcher 가
  // 잡고 outdir 로 mirror 되어야 dev server fetch 가 200 반환. graph-based watch
  // 의 fundamental gap 검증 — 신규 .css 가 watcher 로 push 되는지 + prepare 의
  // tempRoot 가 reconcile 되는지. **TDD failing test** — fix 도입 전엔 404 또는
  // PostCSS 미적용 raw content 반환.
  test('dev: 신규 raw .css add → import 없이 fetch 200 (#3858)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-newcss-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/initial.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    // 초기 .css 1개 — server start 시 prepare/PostCSS 1 cycle 돌게 함.
    writeFileSync(join(dir, 'src', 'initial.css'), '.initial{color:red}');
    writeFileSync(
      join(dir, 'postcss.config.mjs'),
      [
        'export default {',
        '  plugins: [',
        "    { postcssPlugin: 'add-marker', Once(root) { root.append({ selector: '.postcss-marker', nodes: [] }); } },",
        '  ],',
        '};',
      ].join('\n'),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      // 신규 .css 추가 (graph 진입 없음 — main.ts 가 import 안 함, HTML link 도 안 함)
      writeFileSync(join(dir, 'src', 'new.css'), '.fresh{color:blue}');
      // watcher debounce + prepare 1 cycle 기다림 (debounceMs=30 + prepare overhead)
      await new Promise((r) => setTimeout(r, 800));
      // fetch — outdir 에 mirror 되어야 함
      const resp = await fetch(`http://localhost:${port}/src/new.css`);
      expect(resp.status).toBe(200);
      const css = await resp.text();
      expect(css).toContain('.fresh');
      // PostCSS 가 신규 .css 에도 적용되어야 (postcss.config 있으니)
      expect(css).toContain('.postcss-marker');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  // #3858 의 ADD case 는 PASS. DELETE case (reconcile + native event race) 는
  // test 환경의 macOS /var/folders symlink + APFS dirent cache 와의 상호작용으로
  // unstable — 별도 follow-up issue 로 분리. `.todo` 표기.
  test.todo('dev: 신규 .css add+delete cycle (#3858 follow-up)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-cssdel-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/initial.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'initial.css'), '.x{color:red}');
    writeFileSync(join(dir, 'postcss.config.mjs'), 'export default { plugins: [] };\n');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      // (1) 신규 .css 추가 + 200 검증
      writeFileSync(join(dir, 'src', 'tmp.css'), '.tmp{color:blue}');
      await new Promise((r) => setTimeout(r, 2500));
      const r1 = await fetch(`http://localhost:${port}/src/tmp.css`);
      expect(r1.status).toBe(200);

      // (2) 삭제 → fetch 404 (mirror 정리 검증)
      rmSync(join(dir, 'src', 'tmp.css'));
      await new Promise((r) => setTimeout(r, 2500));
      const r2 = await fetch(`http://localhost:${port}/src/tmp.css`);
      expect(r2.status).toBe(404);
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
      // 404/HTML fallback 회피 가드 (review #2)
      expect(bundle).not.toContain('<html');
      expect(bundle).not.toMatch(/Not\s*Found/i);
      // scoped class names — generated CSS Modules 결과
      expect(bundle).toMatch(/Button_primary__[A-Za-z0-9_-]{8}/);
      expect(bundle).toMatch(/Button_danger__[A-Za-z0-9_-]{8}/);
      // mapping shape — proxy module 의 default mapping 이 JSON-literal 로
      // `{ "primary": "Button_primary__<hash>", "danger": "..." }` 형태 inline
      // (bundler 가 whitespace 보존). 단순 substring `primary`/`danger` 는
      // scoped 이름 안에 포함되어 false-green — JSON key 패턴 (`:\s*` 허용) 명시
      // 검증 (review #1).
      expect(bundle).toMatch(/"primary":\s*"Button_primary__[A-Za-z0-9_-]{8}"/);
      expect(bundle).toMatch(/"danger":\s*"Button_danger__[A-Za-z0-9_-]{8}"/);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
