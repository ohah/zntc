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

describe('CLI: serve HTTPS basics', () => {
  test('HTTPS 서빙 (--certfile / --keyfile)', async () => {
    const { dir, certFile, keyFile } = createHttpsFixture('zntc-cli-https-', '<h1>Secure</h1>');
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
      expect(await res.text()).toContain('<h1>Secure</h1>');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
