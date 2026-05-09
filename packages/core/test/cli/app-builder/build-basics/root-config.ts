import {
  describe,
  expect,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  scriptPathFromHtml,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > build root config', () => {
  test('build [root] loads root argument config from outside cwd', () => {
    const parent = mkdtempSync(join(tmpdir(), 'zntc-app-build-parent-config-'));
    try {
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
        join(dir, 'zntc.config.production.json'),
        JSON.stringify({ define: { __APP_LABEL__: JSON.stringify('root-mode-config') } }),
      );

      const outdir = join(parent, 'dist');
      const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir], { cwd: parent });
      expect(exitCode).toBe(0);
      expect(stderr).not.toContain('error:');

      const html = readFileSync(join(outdir, 'index.html'), 'utf8');
      const scriptPath = scriptPathFromHtml(html);
      const js = readFileSync(join(outdir, scriptPath.replace(/^\//, '')), 'utf8');
      expect(js).toContain('"root-mode-config"');
      expect(js).not.toContain('__APP_LABEL__');
    } finally {
      rmSync(parent, { recursive: true, force: true });
    }
  });
});
