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
} from '../../helpers';

describe('CLI: Vite-style app builder > styles > CSS Modules basics > invalid identifiers', () => {
  test('CSS Modules omit named exports for invalid JS identifiers', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-app-css-module-invalid-export-'));
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'index.html'), '<script type="module" src="/src/main.ts"></script>');
    writeFileSync(
      join(dir, 'src', 'main.ts'),
      [
        'import styles, { ok } from "./names.module.css";',
        'console.log(styles.default, styles.class, styles["1abc"], styles.ok, ok);',
      ].join('\n'),
    );
    writeFileSync(
      join(dir, 'src', 'names.module.css'),
      ['.default { color: red; }', '.class { color: green; }', '.ok { color: blue; }'].join('\n'),
    );

    const outdir = join(dir, 'dist');
    const { exitCode } = runCli(['build', dir, '--outdir', outdir], { cwd: dir });
    expect(exitCode).toBe(0);
    const html = readFileSync(join(outdir, 'index.html'), 'utf8');
    const scriptPath = scriptPathFromHtml(html);
    const js = readFileSync(join(outdir, scriptPath.slice(1)), 'utf8');
    expect(js).not.toMatch(/\bconst\s+default\s*=/);
    expect(js).not.toMatch(/\bconst\s+class\s*=/);
    expect(js).toMatch(/\bconst\s+ok\s*=/);
    expect(js).toContain('"default":');
    expect(js).toContain('"class":');
    expect(js).toContain('"ok":');
    rmSync(dir, { recursive: true, force: true });
  });
});
