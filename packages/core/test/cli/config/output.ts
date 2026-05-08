import {
  describe,
  test,
  expect,
  mkdtempSync,
  writeFileSync,
  rmSync,
  existsSync,
  tmpdir,
  join,
  runCli,
} from '../helpers';

describe('CLI: zntc.config output options', () => {
  test('zntc.config.json 의 outdir 이 자동 적용됨 (단일 build, CLI --outdir 미지정)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-outdir-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('SINGLE_OUTDIR_OK');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './dist' }),
    );
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('SINGLE_OUTDIR_OK');
    expect(existsSync(join(dir, 'dist'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('zntc.config.json 의 outfile 이 자동 적용됨 (단일 build, CLI --outfile 미지정)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-outfile-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('SINGLE_OUTFILE_OK');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outfile: './out.js' }),
    );
    const { stdout, exitCode } = runCli(['--bundle'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(stdout).not.toContain('SINGLE_OUTFILE_OK');
    expect(existsSync(join(dir, 'out.js'))).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  test('CLI --outdir 이 config.outdir 을 override', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-config-outdir-override-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(
      join(dir, 'zntc.config.json'),
      JSON.stringify({ entryPoints: ['./entry.ts'], outdir: './from-config' }),
    );
    const { exitCode } = runCli(['--bundle', '--outdir', './from-cli'], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(existsSync(join(dir, 'from-cli'))).toBe(true);
    expect(existsSync(join(dir, 'from-config'))).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  test('config 의 sourcemap=true 가 적용됨 (default=false override)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-cfg-sourcemap-'));
    writeFileSync(join(dir, 'entry.ts'), "console.log('hi');");
    writeFileSync(join(dir, 'zntc.config.json'), JSON.stringify({ sourcemap: true }));
    const outFile = join(dir, 'out.js');
    const { exitCode } = runCli(['--bundle', '-o', outFile, join(dir, 'entry.ts')], { cwd: dir });
    expect(exitCode).toBe(0);
    expect(existsSync(outFile + '.map')).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });
});
