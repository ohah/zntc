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
} from '../../helpers';

describe('CLI: Vite-style app builder > dev HMR CSS updates > nested paths', () => {
  test('dev preserves sub-directory CSS path (no basename collision)', async () => {
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
