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

describe('CLI: Vite-style app builder > env and options > env object', () => {
  test('full import.meta.env object is statically injected in app build', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-env-object-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      'console.log(import.meta.env.VITE_TITLE, import.meta.env.BASE_URL, import.meta.env.MODE, import.meta.env);',
    );
    writeFileSync(join(dir, '.env.production'), 'VITE_TITLE=Object Env\n');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir, '--base', '/app/'], {
      cwd: dir,
    });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.replace('/app/', '')), 'utf8');
    expect(js).toContain('"Object Env"');
    expect(js).toContain('"/app/"');
    expect(js).toContain('"production"');
    expect(js).toContain('"VITE_TITLE":"Object Env"');
    expect(js).not.toContain('import.meta.env');
    rmSync(dir, { recursive: true, force: true });
  });
});
