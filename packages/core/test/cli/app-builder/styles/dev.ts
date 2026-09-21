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
  existsSync,
  readFileSync,
  runCli,
} from '../helpers';

describe('CLI: Vite-style app builder > styles > dev', () => {
  /**
   * #4660 — JS 가 import 한 plain CSS 가 dev HTML 에 연결되지 않던 회귀.
   *
   * 기존 테스트들은 `index.html` 에 `<link>` 를 **손으로 적어 두어서** 자동 주입 경로를
   * 한 번도 거치지 않았다. 그래서 다음 결함이 오래 남아 있었다 — 네이티브 watch 의 ready
   * 이벤트가 `outputs` 에 JS 만 싣고 `asset_outputs`(CSS bundle)를 빼먹어, 주입기가 붙일
   * CSS 를 못 봤다. 파일은 디스크에 써지는데 페이지에는 연결되지 않는 상태였다.
   *
   * 여기서는 `<link>` 를 **적지 않고** JS 의 `import './styles.css'` 만으로 링크가
   * 자동 주입되는지 본다.
   */
  /**
   * #4660 적대적 검증 — 실행 중 JS 에 CSS import 를 **추가**하는 흐름.
   *
   * initial 빌드만 고치면 이 경로가 남는다. native 의 `graphChanged` 는 **JS 모듈 ID
   * 집합** 변화로만 켜지는데, CSS import 추가는 집합 크기를 바꾸지 않아 false 다.
   * 그래서 rebuild 가 asset 을 쓰고 그 목록을 이벤트로 실어 보내야 한다.
   *
   * ⚠️ outdir 스캔으로 때우면 dev 서빙용으로 미러된 **소스 CSS** 까지 잡혀 `<link>` 가
   * 중복된다 — 그래서 링크 "개수" 까지 단언한다.
   */
  test('#4660 dev injects the link when a CSS import is added while watching', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-add-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><div id="root"></div><script type="module" src="/main.ts"></script>',
    );
    // 처음엔 CSS import 가 **없다**.
    writeFileSync(join(dir, 'main.ts'), "console.log('no css yet');\n");
    writeFileSync(join(dir, 'styles.css'), 'body{background:red}');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    const linkCount = async () => {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      return [...html.matchAll(/<link[^>]+rel="stylesheet"/g)].length;
    };
    try {
      expect(await linkCount()).toBe(0);

      writeFileSync(join(dir, 'main.ts'), "import './styles.css';\nconsole.log('with css');\n");
      let n = 0;
      for (let i = 0; i < 80 && n === 0; i++) {
        await new Promise((r) => setTimeout(r, 250));
        n = await linkCount();
      }
      // 정확히 1개 — 소스 CSS 미러까지 잡히면 2개가 된다.
      expect(n).toBe(1);

      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      const href = /<link[^>]+rel="stylesheet"[^>]+href="([^"]+)"/.exec(html)?.[1] ?? '';
      const res = await fetch(`http://localhost:${port}${href}`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain('background');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30000);

  /**
   * #4672 — 혼합 위상(CSS Modules 로 파이프라인 CSS 가 생기고 plain CSS 도 import).
   *
   * 이때 링크는 생성 CSS(`/x.zntc.css`)인데 변경 통지가 소스 경로(`/plain.css`)를 가리키면,
   * 클라이언트가 링크를 하나도 못 찾아 **페이지를 통째로 reload** 한다. 단정할 수 없을 땐
   * `href` 를 비워 보내 "모든 stylesheet 갱신" 으로 가야 한다.
   *
   * 브라우저 없이 관찰 가능한 계약이라 **WebSocket 메시지**로 단언한다.
   */
  test('#4672/#4675 dev css-update pinpoints the linked plain CSS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-href-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><div id="root"></div><script type="module" src="/main.js"></script>',
    );
    // CSS Module 이 파이프라인 CSS 를 만들고, plain CSS 도 함께 import 한다.
    writeFileSync(join(dir, 's.module.css'), '.box{color:navy}');
    writeFileSync(join(dir, 'plain.css'), 'body{background:red}');
    writeFileSync(
      join(dir, 'main.js'),
      "import s from './s.module.css';\nimport './plain.css';\ndocument.body.className = s.box;\n",
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
      const seen: any[] = [];
      ws.onmessage = (e) => {
        try {
          seen.push(JSON.parse(String(e.data)));
        } catch {}
      };
      await new Promise((r) => {
        ws.onopen = r;
      });
      await new Promise((r) => setTimeout(r, 400));

      writeFileSync(join(dir, 'plain.css'), 'body{background:lime}');
      for (let i = 0; i < 60 && !seen.some((m) => m.type === 'css-update'); i++) {
        await new Promise((r) => setTimeout(r, 250));
      }
      const css = seen.find((m) => m.type === 'css-update');
      expect(css).toBeDefined();
      // (#4675) plain `.css` 도 이제 개별 링크가 걸리므로 **정확히 지목**된다.
      // #4672 가 원하던 결과다 — 지목할 수 있으면 그 링크 하나만 갱신하고, 지목할 수
      // 없을 때만 `null`(= 전부 갱신) 로 떨어진다. 후자는
      // `packages/web/src/dev-controller.test.ts` 의 `hrefFor` 유닛 테스트가 고정한다.
      expect(css.href).toBe('/plain.css');
      // 전체 리로드로 갈음되지 않았는지도 본다.
      expect(seen.some((m) => m.type === 'full-reload')).toBe(false);
      // ⚠️ 지목만으로는 부족하다 — 그 링크가 **새 내용**을 서빙해야 의미가 있다.
      // outdir 미러 갱신이 빠지면 href 는 맞는데 내용이 낡은 채로 통과한다.
      const served = await fetch(`http://localhost:${port}/plain.css`).then((r) => r.text());
      expect(served).toContain('lime');
      ws.close();
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30000);

  /**
   * #4674 — `zntc dev` 를 한 번 돌린 뒤 `zntc build` 가 실패하던 회귀.
   *
   * PostCSS temp root 로 프로젝트를 복사할 때는 `.zntc-dev` 를 제외하는데, CSS Module
   * **탐색**은 `outdir` 하나만 제외해서 `.zntc-dev/x.module.css` 를 잡았다. 복사본엔 그
   * 파일이 없으니 열다가 ENOENT 로 빌드가 죽는다 — 같은 질문("무엇이 source 인가")에
   * 두 곳이 다르게 답한 것이다.
   *
   * 단위 테스트(`skipDirs`)만으로는 두 목록이 다시 갈리는 걸 못 막으므로 실제 흐름을 고정한다.
   */
  test('#4674 build succeeds after dev has produced .zntc-dev', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-then-build-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>t</title><div id="root"></div><script type="module" src="/main.js"></script>',
    );
    writeFileSync(join(dir, 's.module.css'), '.box{color:navy}');
    writeFileSync(join(dir, 'plain.css'), 'body{background:red}');
    writeFileSync(
      join(dir, 'main.js'),
      "import s from './s.module.css';\nimport './plain.css';\ndocument.body.className = s.box;\n",
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    try {
      await waitForServer(port);
    } finally {
      proc.kill();
    }
    // dev 가 outdir 을 만들었는지 확인 — 안 만들었으면 이 테스트가 공허해진다.
    expect(existsSync(join(dir, '.zntc-dev'))).toBe(true);

    try {
      const built = runCli(['build', dir], { cwd: dir, timeout: 60000 });
      expect(built.stderr).not.toContain('ENOENT');
      expect(built.exitCode).toBe(0);
      // 산출 CSS 에 두 소스가 모두 들어가야 한다 (dev 잔재가 아니라 진짜 빌드 결과).
      const css = readFileSync(join(dir, 'dist', 'main.css'), 'utf8');
      expect(css).toContain('background:red');
      expect(css).toContain('color:navy');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 90000);

  test('#4660 dev auto-injects a stylesheet link for JS-imported CSS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-inject-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><div id="root"></div><script type="module" src="/main.ts"></script>',
    );
    writeFileSync(join(dir, 'main.ts'), "import './styles.css';\nconsole.log('ok');\n");
    writeFileSync(join(dir, 'styles.css'), 'body{background:red}');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      // 손으로 적지 않았으므로, 링크가 있다면 자동 주입된 것이다.
      const hrefs = [...html.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"]+)"/g)].map(
        (m) => m[1],
      );
      expect(hrefs.length).toBeGreaterThan(0);

      // 주입된 href 가 실제로 서빙되고 내용이 맞아야 한다 — 링크만 있고 404 면 의미 없다.
      const res = await fetch(`http://localhost:${port}${hrefs[0]}`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain('background');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  /**
   * #4679 — `postcss.config.*` 가 있으면 dev 의 **번들 CSS**(`main.css`)가 첫 편집에
   * PostCSS 변환을 잃고, 그 뒤로 갱신이 멈췄다.
   *
   * dev 에서 번들러의 입력 트리는 PostCSS temp root 다. CSS 를 고치면 temp root 에
   * **원본**이 덮여 쓰이는데(watch 동기화), 처리 결과는 outdir 에만 쓰여 temp root 로
   * 돌아오지 않았다 → 번들 CSS 에서 변환이 빠진다. 멈추는 쪽은 그 덮어쓰기가 파일을
   * 교체(inode 변경)해 macOS 의 파일 감시를 끊어 버린 것이었다 (#4682).
   *
   * 두 편집을 연달아 보는 게 핵심이다 — 한 번만 보면 "멈춤" 을 못 잡는다.
   */
  test('#4679 dev bundle CSS keeps PostCSS output across repeated edits', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-postcss-temproot-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><div id="root"></div><script type="module" src="/main.ts"></script>',
    );
    writeFileSync(join(dir, 'main.ts'), "import './plain.css';\nconsole.log('ok');\n");
    writeFileSync(join(dir, 'plain.css'), 'body{background:rgb(0, 0, 0)}');
    // 변환이 실제로 걸렸는지 눈으로 보려는 최소 플러그인 — 외부 패키지 의존 없음.
    writeFileSync(
      join(dir, 'postcss.config.cjs'),
      "module.exports = { plugins: [{ postcssPlugin: 'zntc-test-marker'," +
        " Once(root) { root.append('.ZNTC_MARK{color:#123456}'); } }] };\n",
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    // 번들 CSS 가 기대 내용을 담을 때까지 폴링. 안 오면 timeout 으로 실패 = "멈춤" 검출.
    async function waitForBundleCss(needle: string): Promise<string> {
      // 예산: 3회 x 7s + 서버 기동 여유 < 테스트 timeout(30s). 넘기면 harness 가
      // 죽여 버려 어떤 단언이 실패했는지조차 안 남는다.
      const deadline = Date.now() + 7000;
      let last = '';
      while (Date.now() < deadline) {
        try {
          // 재빌드 중에는 연결이 끊길 수 있다 — 네트워크 오류로 테스트가 죽으면
          // 정작 잡으려던 회귀와 구분이 안 된다. 다음 폴에서 재시도한다.
          last = await fetch(`http://localhost:${port}/main.css`).then((r) => r.text());
        } catch {
          last = '(fetch 실패)';
        }
        if (last.includes(needle)) return last;
        await new Promise((r) => setTimeout(r, 100));
      }
      throw new Error(`main.css 에서 ${needle} 를 기다리다 7s 초과. 마지막 응답:\n${last}`);
    }
    try {
      // cold — 변환이 걸려 있어야 한다.
      const cold = await waitForBundleCss('rgb(0, 0, 0)');
      expect(cold).toContain('.ZNTC_MARK');

      // 1회차 편집 — 값이 바뀌고 **변환은 남아 있어야** 한다.
      writeFileSync(join(dir, 'plain.css'), 'body{background:rgb(1, 1, 1)}');
      const first = await waitForBundleCss('rgb(1, 1, 1)');
      expect(first).toContain('rgb(1, 1, 1)');
      expect(first).toContain('.ZNTC_MARK');

      // 2회차 편집 — 여기서 멈추던 것이 원래 증상이다.
      writeFileSync(join(dir, 'plain.css'), 'body{background:rgb(2, 2, 2)}');
      const second = await waitForBundleCss('rgb(2, 2, 2)');
      expect(second).toContain('rgb(2, 2, 2)');
      expect(second).toContain('.ZNTC_MARK');
    } finally {
      proc.kill();
      // 종료를 기다린다 — 안 기다리면 죽어 가는 dev 서버가 자기가 감시하던 트리를
      // rmSync 하는 것과 경쟁하고, 뒤 테스트들과 겹쳐 돈다.
      await proc.exited;
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30000);

  /**
   * #4675 — CSS Module(또는 SCSS)과 plain `.css` 를 **같이** import 하면 dev 에서 plain
   * CSS 가 전혀 적용되지 않던 결함.
   *
   * dev 는 SCSS / CSS Modules 의 **생성 CSS** 만 링크했다. plain `.css` 는 outdir 에
   * 미러돼 서빙까지 되는데 `<link>` 가 없어 페이지에 도달하지 못했다.
   *
   * 고칠 때 "디렉토리에서 발견한 CSS 를 전부 링크" 하면 import 하지도 않은 파일까지
   * 적용된다. 그래서 **번들러가 실제로 따라간 CSS 목록**(watch 이벤트의 `cssModules`)
   * 으로만 링크한다 — 이 테스트는 그 둘을 한 번에 고정한다.
   */
  test('#4675 dev links imported plain CSS and skips unimported CSS', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-graph-css-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><div id="root"></div><script type="module" src="/main.js"></script>',
    );
    writeFileSync(join(dir, 's.module.css'), '.box{color:navy}');
    writeFileSync(join(dir, 'plain.css'), 'body{background:red}');
    // 아무도 import 하지 않는다 — 링크되면 안 된다.
    writeFileSync(join(dir, 'unused.css'), 'body{outline:9px solid fuchsia}');
    writeFileSync(
      join(dir, 'main.js'),
      "import s from './s.module.css';\nimport './plain.css';\ndocument.body.className = s.box;\n",
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      const hrefs = [...html.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"]+)"/g)].map(
        (m) => m[1],
      );
      // CSS Module 의 생성 CSS 와 import 된 plain CSS 가 둘 다 있어야 한다.
      expect(hrefs).toContain('/s.module.zntc.css');
      expect(hrefs).toContain('/plain.css');
      // import 하지 않은 CSS 는 없어야 한다.
      expect(hrefs).not.toContain('/unused.css');
      // 번들 CSS 는 같은 내용의 합본이라 중복이다 — 그래프 링크가 덮었으면 걸지 않는다.
      expect(hrefs).not.toContain('/main.css');

      // 링크가 실제로 서빙되고 내용이 맞아야 한다 — 링크만 있고 404 면 의미 없다.
      const plain = await fetch(`http://localhost:${port}/plain.css`);
      expect(plain.status).toBe(200);
      expect(await plain.text()).toContain('background');
    } finally {
      proc.kill();
      await proc.exited;
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30000);

  /**
   * #4671 — CSS import 를 지워도 주입된 `<link>` 가 남아 스타일이 계속 적용되던 결함.
   *
   * 주입기는 추가만 하고 지우지 않았다. outdir 의 **파일** 정리는 `reconcileOutdir` 가
   * 맡는데 HTML 의 **링크** 를 맞추는 짝이 없었다.
   *
   * 사용자가 `index.html` 에 손으로 적은 링크는 건드리면 안 되므로, 우리가 주입한 것만
   * 마커로 구분해 지운다 — 이 테스트가 그 경계를 함께 고정한다.
   */
  test('#4671 dev removes the injected link when the CSS import goes away', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-stale-link-'));
    writeFileSync(
      join(dir, 'index.html'),
      '<title>dev</title><link rel="stylesheet" href="/hand.css">' +
        '<div id="root"></div><script type="module" src="/main.js"></script>',
    );
    writeFileSync(join(dir, 'hand.css'), 'h1{color:teal}');
    writeFileSync(join(dir, 'styles.css'), 'body{background:red}');
    writeFileSync(join(dir, 'main.js'), "import './styles.css';\nconsole.log(1);\n");

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    const hrefs = async (): Promise<string[]> => {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      return [...html.matchAll(/<link[^>]+rel="stylesheet"[^>]+href="([^"]+)"/g)].map((m) => m[1]!);
    };
    try {
      expect(await hrefs()).toContain('/styles.css');

      // import 를 지운다 → 주입된 링크가 사라져야 한다.
      writeFileSync(join(dir, 'main.js'), 'console.log(1);\n');
      const deadline = Date.now() + 15000;
      let after: string[] = [];
      while (Date.now() < deadline) {
        after = await hrefs();
        if (!after.includes('/styles.css')) break;
        await new Promise((r) => setTimeout(r, 200));
      }
      expect(after).not.toContain('/styles.css');
      // ⚠️ 사용자가 손으로 적은 링크는 남아야 한다 — 마커 구분이 없으면 같이 지워진다.
      expect(after).toContain('/hand.css');
    } finally {
      proc.kill();
      await proc.exited;
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30000);

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

  // #3858/#3861 회귀 가드 — add+delete cycle. native onRebuild 의 prepare 와
  // drain (fs.watch) 의 rebuildAppDevCss 가 dual watch → race. drain 도
  // prepare 호출하도록 fix (#3861). reconcileOutdirCss factory 와 함께 cycle
  // 후 outdir mirror 자동 정리.
  test('dev: 신규 .css add+delete cycle (#3861)', async () => {
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
      await new Promise((r) => setTimeout(r, 1500));
      const r1 = await fetch(`http://localhost:${port}/src/tmp.css`);
      expect(r1.status).toBe(200);

      // (2) 삭제 → poll fetch 까지 404 (reconcile + fs cache race window 회피).
      // reconcileOutdirCss 의 prev/current diff 로 사라진 path unlink 후 APFS
      // dirent cache 가 갱신되기까지 추가 cycle 가능 — 최대 8초 poll.
      rmSync(join(dir, 'src', 'tmp.css'));
      let last = 200;
      for (let i = 0; i < 16; i++) {
        await new Promise((r) => setTimeout(r, 500));
        const r2 = await fetch(`http://localhost:${port}/src/tmp.css`);
        last = r2.status;
        if (last === 404) break;
      }
      expect(last).toBe(404);
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
