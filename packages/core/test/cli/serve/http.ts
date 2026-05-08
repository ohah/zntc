import {
  describe,
  expect,
  findFreePort,
  join,
  mkdtempSync,
  rmSync,
  spawn,
  test,
  tmpdir,
  waitForServer,
  writeFileSync,
  CLI,
  RUNTIME,
} from '../helpers';

describe('CLI: serve', () => {
  test('정적 파일 서빙', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-serve-'));
    writeFileSync(join(dir, 'index.html'), '<h1>Hello</h1>');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, '--serve', dir, `--port=${port}`]);

    await waitForServer(port);

    try {
      const res = await fetch(`http://localhost:${port}/`);
      expect(res.status).toBe(200);
      const text = await res.text();
      expect(text).toContain('<h1>Hello</h1>');

      // 없는 파일 → 404
      const res404 = await fetch(`http://localhost:${port}/nonexistent`);
      expect(res404.status).toBe(404);
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test('CORS 헤더 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-cors-'));
    writeFileSync(join(dir, 'index.html'), '<h1>Test</h1>');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, '--serve', dir, `--port=${port}`]);
    await new Promise((r) => setTimeout(r, 500));

    try {
      const res = await fetch(`http://localhost:${port}/`);
      expect(res.headers.get('Access-Control-Allow-Origin')).toBe('*');
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });
});
