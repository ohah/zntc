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

describe('CLI: Vite-style app builder > dev server', () => {
  test('dev [root] serves prepared app HTML and development env', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-dev-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'public'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<title>%VITE_TITLE%</title><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'console.log(import.meta.env.VITE_TITLE, import.meta.env.MODE, process.env.NODE_ENV);',
    );
    writeFileSync(join(dir, '.env.development'), 'VITE_TITLE=Dev App\n');
    writeFileSync(join(dir, 'public', 'favicon.svg'), '<svg></svg>');

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`, '--base', '/app/'], {
      cwd: dir,
    });
    await waitForServer(port);

    try {
      const html = await fetch(`http://localhost:${port}/app/`).then((r) => r.text());
      expect(html).toContain('<title>Dev App</title>');
      expect(html).toContain('src="/app/bundle.js"');

      const js = await fetch(`http://localhost:${port}/app/bundle.js`).then((r) => r.text());
      expect(js).toContain('"Dev App"');
      expect(js).toContain('"development"');
      expect(js).not.toContain('process.env.NODE_ENV');
    } finally {
      proc.kill();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('dev [root] loads root argument config from outside cwd', async () => {
    const parent = mkdtempSync(join(tmpdir(), 'zntc-app-dev-parent-config-'));
    const dir = join(parent, 'app');
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'document.body.textContent = __APP_LABEL__; console.log(__APP_LABEL__);',
    );
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ define: { __APP_LABEL__: JSON.stringify('base-config') } }),
    );
    writeFileSync(
      join(dir, 'zntc.config.development.json'),
      JSON.stringify({ define: { __APP_LABEL__: JSON.stringify('root-dev-config') } }),
    );

    const port = await findFreePort();
    const proc = spawn(RUNTIME, [CLI, 'dev', dir, `--port=${port}`], { cwd: parent });
    await waitForServer(port);

    try {
      const js = await fetch(`http://localhost:${port}/bundle.js`).then((r) => r.text());
      expect(js).toContain('"root-dev-config"');
      expect(js).not.toContain('__APP_LABEL__');
    } finally {
      proc.kill();
      rmSync(parent, { recursive: true, force: true });
    }
  });
});
