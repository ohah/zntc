import {
  describe,
  execSync,
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
  test('HTTPS 서빙 (--certfile / --keyfile)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-https-'));
    writeFileSync(join(dir, 'index.html'), '<h1>Secure</h1>');

    // 자체 서명 인증서 생성
    const certFile = join(dir, 'cert.pem');
    const keyFile = join(dir, 'key.pem');
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [
      CLI,
      '--serve',
      dir,
      `--port=${port}`,
      '--certfile',
      certFile,
      '--keyfile',
      keyFile,
    ]);

    await waitForServer(port, 20, 100, 'https');

    try {
      const res = await fetch(`https://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.status).toBe(200);
      const text = await res.text();
      expect(text).toContain('<h1>Secure</h1>');
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test('HTTPS 없는 파일 → 404', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-https-404-'));
    writeFileSync(join(dir, 'index.html'), '<h1>OK</h1>');

    const certFile = join(dir, 'cert.pem');
    const keyFile = join(dir, 'key.pem');
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [
      CLI,
      '--serve',
      dir,
      `--port=${port}`,
      '--certfile',
      certFile,
      '--keyfile',
      keyFile,
    ]);

    await waitForServer(port, 20, 100, 'https');

    try {
      const res = await fetch(`https://localhost:${port}/nonexistent`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.status).toBe(404);
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });

  test('HTTPS CORS 헤더 포함', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cli-https-cors-'));
    writeFileSync(join(dir, 'index.html'), '<h1>CORS</h1>');

    const certFile = join(dir, 'cert.pem');
    const keyFile = join(dir, 'key.pem');
    execSync(
      `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [
      CLI,
      '--serve',
      dir,
      `--port=${port}`,
      '--certfile',
      certFile,
      '--keyfile',
      keyFile,
    ]);

    await waitForServer(port, 20, 100, 'https');

    try {
      const res = await fetch(`https://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.headers.get('Access-Control-Allow-Origin')).toBe('*');
    } finally {
      proc.kill();
    }

    rmSync(dir, { recursive: true, force: true });
  });
});
