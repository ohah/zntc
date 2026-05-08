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

describe('CLI: Vite-style app builder > env and options > env prefix', () => {
  test('--env-prefix controls app env exposure', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-env-prefix-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      ['console.log(import.meta.env.CUSTOM_NAME);', 'console.log(import.meta.env.VITE_NAME);'].join(
        '\n',
      ),
    );
    writeFileSync(join(dir, '.env.production'), 'CUSTOM_NAME=allowed\nVITE_NAME=hidden\n');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--env-prefix', 'CUSTOM_'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).toContain('"allowed"');
    expect(js).toContain('.VITE_NAME');
    expect(js).not.toContain('"hidden"');
    rmSync(dir, { recursive: true, force: true });
  });
});
