import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  readFileSync,
  rmSync,
  existsSync,
  mkdirSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: Vite-style app builder > styles > build collisions', () => {
  test('build does not collide when JS imports CSS that HTML also references', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-collision-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(
      join(dir, 'index.html'),
      '<link rel="stylesheet" href="/src/main.css"><script type="module" src="/src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), "import './main.css';\nconsole.log('ok');");
    writeFileSync(join(dir, 'src', 'main.css'), '.hero{color:red}');

    const outdir = join(dir, 'dist');
    const { exitCode, stderr } = runCli(['build', dir, '--outdir', outdir, '--no-splitting'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    expect(stderr).not.toContain('OutputCollision');
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    expect(html).toContain('href="/src/main.css"');
    expect(existsSync(join(outdir, 'main.css'))).toBe(true);
    expect(existsSync(join(outdir, 'src', 'main.css'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });
});
