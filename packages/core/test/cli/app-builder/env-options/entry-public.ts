import {
  describe,
  expect,
  existsSync,
  join,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  runCli,
  test,
  tmpdir,
  writeFileSync,
} from '../helpers';

describe('CLI: Vite-style app builder > env and options > entry/public', () => {
  test('custom --entry-html and --public-dir false', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-entry-public-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    mkdirSync(join(dir, 'public'), { recursive: true });
    writeFileSync(
      join(dir, 'app.html'),
      '<h1>%VITE_TITLE%</h1><script type="module" src="./src/main.ts"></script>',
    );
    writeFileSync(join(dir, 'src', 'main.ts'), 'console.log(import.meta.env.VITE_TITLE);');
    writeFileSync(join(dir, '.env.production'), 'VITE_TITLE=Custom Entry\n');
    writeFileSync(join(dir, 'public', 'favicon.svg'), '<svg></svg>');

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(
      ['build', dir, '--entry-html', 'app.html', '--public-dir', 'false', '--outdir', outdir],
      { cwd: dir },
    );
    expect(exitCode).toBe(0);
    expect(readFileSync(join(outdir, 'index.html'), 'utf8')).toContain('<h1>Custom Entry</h1>');
    expect(existsSync(join(outdir, 'favicon.svg'))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });
});
