import {
  describe,
  test,
  expect,
  spawn,
  execSync,
  mkdtempSync,
  writeFileSync,
  rmSync,
  tmpdir,
  join,
  CLI,
  RUNTIME,
  waitForServer,
  findFreePort,
} from './helpers';

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

// ─── CLI 인자 파싱 엣지케이스 ───
