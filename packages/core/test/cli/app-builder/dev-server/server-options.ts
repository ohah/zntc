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
  waitForServer,
  waitForText,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > dev server', () => {
  test('dev [root] uses config server.port and server.host', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-server-config-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('server-config');");
    const port = await findFreePort();
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ server: { port, host: true } }));

    const proc = spawn(RUNTIME, [CLI, 'dev', dir], {
      cwd: dir,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let exitState = '';
    proc.stdout?.on('data', (chunk) => {
      stdout += String(chunk);
    });
    proc.stderr?.on('data', (chunk) => {
      stderr += String(chunk);
    });
    proc.on('exit', (code, signal) => {
      exitState = `exit:${code ?? ''}:${signal ?? ''}`;
    });
    const expectedServeLog = `[serve] http://0.0.0.0:${port}`;
    await Promise.all([
      waitForServer(port, 100),
      waitForText(() => `${stdout}${stderr}${exitState}`, expectedServeLog, 10000),
    ]);

    try {
      const js = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
      expect(js).toContain('server-config');
      expect(`${stdout}${stderr}`).toContain(expectedServeLog);
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 10000);

  test('dev [root] CLI --port overrides config server.port', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-server-cli-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(join(dir, 'src', 'main.ts'), "console.log('cli-port');");
    const configPort = await findFreePort();
    const cliPort = configPort + 100;
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ server: { port: configPort } }));

    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${cliPort}`], { cwd: dir });
    await waitForServer(cliPort);

    try {
      const js = await fetch(`http://localhost:${cliPort}/bundle.js`).then((r) => r.text());
      expect(js).toContain('cli-port');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
