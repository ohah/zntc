import {
  CLI,
  RUNTIME,
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
} from '../../helpers';

function createHttpsFixture(prefix: string, html: string) {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  writeFileSync(join(dir, 'index.html'), html);
  const certFile = join(dir, 'cert.pem');
  const keyFile = join(dir, 'key.pem');
  execSync(
    `openssl req -x509 -newkey rsa:2048 -keyout ${keyFile} -out ${certFile} -days 1 -nodes -subj "/CN=localhost" 2>/dev/null`,
  );
  return { dir, certFile, keyFile };
}

async function startHttpsServe(dir: string, certFile: string, keyFile: string) {
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
  return { port, proc };
}

describe('CLI: serve HTTPS status and CORS', () => {
  test('HTTPS 없는 파일 → 404', async () => {
    const { dir, certFile, keyFile } = createHttpsFixture('zntc-cli-https-404-', '<h1>OK</h1>');
    const { port, proc } = await startHttpsServe(dir, certFile, keyFile);
    try {
      const res = await fetch(`https://localhost:${port}/nonexistent`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.status).toBe(404);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('HTTPS CORS 헤더 포함', async () => {
    const { dir, certFile, keyFile } = createHttpsFixture('zntc-cli-https-cors-', '<h1>CORS</h1>');
    const { port, proc } = await startHttpsServe(dir, certFile, keyFile);
    try {
      const res = await fetch(`https://localhost:${port}/`, {
        tls: { rejectUnauthorized: false },
      } as any);
      expect(res.headers.get('Access-Control-Allow-Origin')).toBe('*');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
