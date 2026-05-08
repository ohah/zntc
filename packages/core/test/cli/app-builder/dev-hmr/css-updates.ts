import {
  CLI,
  RUNTIME,
  describe,
  expect,
  findFreePort,
  join,
  mkdirSync,
  mkdtempSync,
  rmSync,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > dev HMR and overlay', () => {
  test('dev single SCSS edit takes the css-update fast-path', async () => {
    // 단일 non-module `.scss` 변경은 그 파일만 재컴파일 → outdir mirror → CssUpdate
    // broadcast 로 끝난다 (full reload 안 함, BACKLOG #71). `.module.scss` 는 여전히 full
    // reload (class map 갱신 가능).
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-scss-fast-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<div class="box"></div><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'import "./style.scss";');
    writeFileSync(join(dir, 'src', 'style.scss'), '.box { color: rgb(1, 2, 3); }');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    async function fetchEmittedCss(): Promise<string> {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      const href = html.match(/<link\s+rel="stylesheet"\s+href="([^"]+)"/)?.[1];
      expect(href).toBeTruthy();
      return fetch(`http://localhost:${port}${href}`).then((r) => r.text());
    }
    try {
      expect(await fetchEmittedCss()).toContain('rgb(1, 2, 3)');

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
      writeFileSync(join(dir, 'src', 'style.scss'), '.box { color: rgb(4, 5, 6); }');
      const msg = await messagePromise;
      expect(msg.type).toBe('css-update');
      // CssUpdate 의 href 는 컴파일된 `.css` 경로 — broadcast payload 에 포함됨.
      expect(msg.href).toMatch(/\/src\/style\.css$/);
      await new Promise((r) => setTimeout(r, 300));
      expect(await fetchEmittedCss()).toContain('rgb(4, 5, 6)');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev .module.scss edit triggers full reload (not css-update fast-path)', async () => {
    // `.module.scss` 는 class-name map 이 변할 수 있어 fast-path 자격 박탈 — full reload
    // 가 보장되어야 한다 (`isSassOnlyChange` 가 module variant 를 제외하는지 검증).
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-module-scss-reload-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'import s from "./card.module.scss"; console.log(s.card);',
    );
    writeFileSync(join(dir, 'src', 'card.module.scss'), '.card { color: rgb(1, 2, 3); }');

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
      writeFileSync(join(dir, 'src', 'card.module.scss'), '.card { color: rgb(7, 8, 9); }');
      const msg = await messagePromise;
      expect(msg.type).toBe('full-reload');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev preserves sub-directory CSS path (no basename collision)', async () => {
    // 서브디렉토리에 같은 basename 을 가진 두 CSS 파일이 있으면, root-기준 relative path 가
    // 보존되어 HTML link 와 emit path 가 둘 다 분리된다.
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-css-nested-'));
    mkdirSync(join(dir, 'src', 'a'), { recursive: true });
    mkdirSync(join(dir, 'src', 'b'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      [
        '<link rel="stylesheet" href="/src/a/style.css">',
        '<link rel="stylesheet" href="/src/b/style.css">',
        '<script type="module" src="/src/main.ts"></script>',
      ].join(''),
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log("ok");');
    writeFileSync(join(dir, 'src', 'a', 'style.css'), '.aaa{color:red}');
    writeFileSync(join(dir, 'src', 'b', 'style.css'), '.bbb{color:blue}');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: dir });
    await waitForServer(port);
    try {
      const html = await fetch(`http://localhost:${port}/`).then((r) => r.text());
      expect(html).toContain('href="/src/a/style.css"');
      expect(html).toContain('href="/src/b/style.css"');
      const aCss = await fetch(`http://localhost:${port}/src/a/style.css`).then((r) => r.text());
      const bCss = await fetch(`http://localhost:${port}/src/b/style.css`).then((r) => r.text());
      expect(aCss).toContain('.aaa');
      expect(bCss).toContain('.bbb');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
